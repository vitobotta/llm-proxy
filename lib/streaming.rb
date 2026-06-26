# frozen_string_literal: true

require "json"

module Streaming
  NEGATIVE_TOKEN_WARNED = {}
  NEGATIVE_TOKEN_LOCK = Mutex.new

  def self.reset_negative_token_warnings!
    NEGATIVE_TOKEN_LOCK.synchronize { NEGATIVE_TOKEN_WARNED.clear }
  end

  def self.note_negative_content_once(provider_key)
    NEGATIVE_TOKEN_LOCK.synchronize do
      return false if NEGATIVE_TOKEN_WARNED[provider_key]
      NEGATIVE_TOKEN_WARNED[provider_key] = true
    end
    true
  end

  THINKING_PATTERNS = [
    /[^a-zA-Z_]"reasoning_content"\s*:\s*"/,
    /[^a-zA-Z_]"thinking"\s*:\s*"/,
    /[^a-zA-Z_]"reasoning"\s*:\s*"/
  ].freeze
  CONTENT_PATTERNS = [
    /[^a-zA-Z_]"content"\s*:\s*"[^"}]/,
    /[^a-zA-Z_]"text"\s*:\s*"[^"}]/
  ].freeze
  TOOL_CALL_PATTERN = /[^a-zA-Z_]"tool_calls"\s*:\s*\[/
  USAGE_STRING = '"usage"'

  ChunkResult = Struct.new(:usage, :has_thinking, :has_content, :has_tool_call, :perf_metrics, :server_duration)

  class TimerTracker
    attr_reader :first_token, :first_thinking, :last_thinking,
      :first_content, :last_content, :last_any_token,
      :thinking_detected, :content_detected

    def initialize
      @first_token = nil
      @first_thinking = nil
      @last_thinking = nil
      @first_content = nil
      @last_content = nil
      @last_any_token = nil
      @thinking_detected = false
      @content_detected = false
    end

    def record_thinking(now)
      @last_thinking = now
      @last_any_token = now
      unless @thinking_detected
        @thinking_detected = true
        @first_thinking ||= now
        @first_token ||= now
      end
    end

    def record_content(now)
      @last_content = now
      @last_any_token = now
      unless @content_detected
        @content_detected = true
        @first_content ||= now
        @first_token ||= now
      end
    end
  end

  PERF_METRICS_STRING = '"perf_metrics"'
  ENERGY_COMMENT_PREFIX = ": energy"

  def self.parse_chunk(chunk)
    result = ChunkResult.new(nil, false, false, false, nil, nil)

    # vLLM energy comment line: ": energy {"duration_seconds": 1.234, ...}"
    # This is an SSE comment line (not a data: line) that contains the
    # server-side total request duration. Used as a fallback for server_tps
    # when the provider doesn't report tokens_per_second.
    if chunk.include?(ENERGY_COMMENT_PREFIX)
      chunk.split("\n").each do |line|
        next unless line.start_with?(ENERGY_COMMENT_PREFIX)
        json_part = line.sub(/\A#{Regexp.escape(ENERGY_COMMENT_PREFIX)}\s*/, "").strip
        begin
          energy = JSON.parse(json_part)
          duration = energy["duration_seconds"]
          result.server_duration = duration if duration.is_a?(Numeric) && duration > 0
        rescue JSON::ParserError
          next
        end
      end
    end

    if chunk.include?(USAGE_STRING) || chunk.include?(PERF_METRICS_STRING)
      chunk.scan(/^data:\s*(.+)$/).each do |raw|
        line = raw.first.strip
        next if line == "[DONE]" || line.empty?
        begin
          data = JSON.parse(line)
          if data.key?("usage")
            result.usage = data["usage"]
          end
          if data.key?("perf_metrics")
            result.perf_metrics = data["perf_metrics"]
          end
          break if result.usage && result.perf_metrics
        rescue JSON::ParserError
          next
        end
      end
    end

    result.has_thinking = THINKING_PATTERNS.any? { |r| chunk.match?(r) }

    if chunk.match?(TOOL_CALL_PATTERN)
      result.has_tool_call = true
      result.has_content = true
    else
      result.has_content = CONTENT_PATTERNS.any? { |r| chunk.match?(r) }
    end

    result
  end


  def self.extract_token_counts(usage_data, perf_metrics: nil, server_duration: nil)
    completion = usage_data.dig("completion_tokens") || usage_data.dig("output_tokens")
    thinking = usage_data.dig("completion_tokens_details", "reasoning_tokens") ||
      usage_data.dig("output_tokens_details", "reasoning_tokens") ||
      usage_data.dig("reasoning_tokens") || 0
    raw_content = completion ? completion - thinking : nil
    clamped = !raw_content.nil? && raw_content < 0
    content = clamped ? 0 : raw_content

    # Server-side timing — matches provider dashboards when available.
    server_tps = nil
    server_ttft = nil

    # Groq: usage["completion_time"] (decode-only seconds) + prompt_time/queue_time.
    if completion && completion > 0
      groq_completion_time = usage_data["completion_time"]
      if groq_completion_time.is_a?(Numeric) && groq_completion_time > 0
        server_tps = (completion / groq_completion_time).round(1)
      end
    end

    groq_prompt_time = usage_data["prompt_time"]
    groq_queue_time = usage_data["queue_time"]
    if groq_prompt_time.is_a?(Numeric) && groq_queue_time.is_a?(Numeric)
      server_ttft = (groq_prompt_time + groq_queue_time).round(3)
    end

    # Generic: usage["tokens_per_second"] — decode-only rate reported by
    # DeepSeek, Kimi (Moonshot), and other vLLM-based/OpenAI-compatible providers.
    # This is the closest to what provider dashboards display.
    if server_tps.nil?
      tps_field = usage_data["tokens_per_second"]
      if tps_field.is_a?(Numeric) && tps_field > 0
        server_tps = tps_field.round(1)
      end
    end

    # Fireworks: perf_metrics["generation-duration"] + server-time-to-first-token.
    if perf_metrics && server_tps.nil?
      gen_dur = perf_metrics["generation-duration"]
      if completion && completion > 0 && gen_dur.is_a?(Numeric) && gen_dur > 0
        server_tps = (completion / gen_dur).round(1)
      end
    end

    if perf_metrics && server_ttft.nil?
      fw_ttft = perf_metrics["server-time-to-first-token"]
      server_ttft = fw_ttft.to_f.round(3) if fw_ttft.is_a?(Numeric) && fw_ttft > 0
    end

    # vLLM energy comment: server_duration is the total request time
    # (prefill + decode). Dividing completion_tokens by it gives a
    # total-time TPS — lower than decode-only but far more accurate than
    # the arrival-window estimate for short generations.
    if server_tps.nil? && server_duration && completion && completion > 0
      server_tps = (completion / server_duration).round(1)
    end

    {completion: completion, thinking: thinking, content: content, content_clamped: clamped,
     server_tps: server_tps, server_ttft: server_ttft}
  end

  def self.compute_tps(token_count, first_time, last_time)
    return nil unless token_count && token_count > 0 && first_time && last_time
    elapsed = last_time - first_time
    (elapsed > 0) ? (token_count / elapsed).round(1) : nil
  end

  # Walks response.read_body, parsing each chunk and updating `tracker`
  # with thinking/content timestamps. Captures cr.usage, cr.perf_metrics, and
  # cr.server_duration as they appear (last-seen-wins). The caller-supplied
  # block receives (chunk, cr, now) per chunk and may write the chunk to a
  # client, accumulate it, or do nothing.
  # Returns [usage, perf_metrics, server_duration] — any may be nil.
  def self.consume_stream(response, tracker:)
    usage = nil
    perf_metrics = nil
    server_duration = nil
    response.read_body do |chunk|
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cr = parse_chunk(chunk)
      usage = cr.usage if cr.usage
      perf_metrics = cr.perf_metrics if cr.perf_metrics
      server_duration = cr.server_duration if cr.server_duration
      tracker.record_thinking(now) if cr.has_thinking
      tracker.record_content(now) if cr.has_content
      yield(chunk, cr, now) if block_given?
    end
    [usage, perf_metrics, server_duration]
  end

  def self.stream_response(http, request, request_start, on_chunk: nil)
    timers = TimerTracker.new
    usage_data = nil
    perf_metrics = nil
    server_duration = nil
    error = nil

    http.request(request) do |response|
      unless response.is_a?(Net::HTTPSuccess)
        error = "HTTP #{response.code}: #{response.body}"
        next
      end

      usage_data, perf_metrics, server_duration = consume_stream(response, tracker: timers) do |chunk, cr, now|
        on_chunk&.call(chunk, cr, now)
      end
    end

    if error
      {error: error}
    else
      {
        first_token_time: timers.first_token,
        first_thinking_time: timers.first_thinking,
        last_thinking_time: timers.last_thinking,
        first_content_time: timers.first_content,
        last_content_time: timers.last_content,
        last_any_token_time: timers.last_any_token,
        usage_data: usage_data,
        perf_metrics: perf_metrics,
        server_duration: server_duration,
        request_start: request_start
      }
    end
  end

  def track_chunk!(chunk_result, now, tracker)
    tracker.record_thinking(now) if chunk_result.has_thinking
    tracker.record_content(now) if chunk_result.has_content
  end

  def build_stream_result(log_prefix, tracker, usage_data, perf_metrics: nil, server_duration: nil)
    ttft = tracker.first_token ? (tracker.first_token - @request_start).round(3) : nil

    if usage_data
      tokens = Streaming.extract_token_counts(usage_data, perf_metrics: perf_metrics, server_duration: server_duration)
      if tokens[:content_clamped] && Streaming.note_negative_content_once(log_prefix)
        settings.logger.warn("#{log_prefix} provider reported reasoning_tokens (#{tokens[:thinking]}) > completion_tokens (#{tokens[:completion]}); clamping content to 0. This indicates a bug at the provider — please verify their usage accounting.")
      end
      content_tps = Streaming.compute_tps(tokens[:content], tracker.first_content, tracker.last_content)
      thinking_tps = Streaming.compute_tps(tokens[:thinking], tracker.first_thinking, tracker.last_thinking)
      # Prefer server-side generation timing (matches provider dashboards) when
      # the provider reports it; fall back to the arrival-window estimate.
      total_tps = tokens[:server_tps] || Streaming.compute_tps(tokens[:completion], tracker.first_token, tracker.last_any_token)
      # Same for TTFT: server-side (queue + prefill) over arrival TTFT.
      ttft = tokens[:server_ttft] || ttft

      log_parts = []
      log_parts << "content=#{tokens[:content]}" if tokens[:content]&.positive?
      log_parts << "thinking=#{tokens[:thinking]}" if tokens[:thinking]&.positive?
      log_parts << "ttft=#{ttft}s"
      log_parts << "content_tps=#{content_tps}" if content_tps&.positive?
      log_parts << "thinking_tps=#{thinking_tps}" if thinking_tps&.positive?
      log_parts << "total_tps=#{total_tps}" if total_tps&.positive?

      settings.logger.info("#{log_prefix} Success | #{log_parts.join(" ")}")
      {success: true, content_tokens: tokens[:content], thinking_tokens: tokens[:thinking], ttft: ttft, content_tps: content_tps, thinking_tps: thinking_tps, total_tps: total_tps}
    else
      settings.logger.info("#{log_prefix} Success | ttft=#{ttft}s (no usage data from provider)")
      {success: true, content_tokens: nil, thinking_tokens: nil, ttft: ttft, content_tps: nil, thinking_tps: nil}
    end
  end

  def streaming_error(message, detail: nil)
    "data: #{{error: {message: message, detail: detail}}.to_json}\n\n"
  end
end
