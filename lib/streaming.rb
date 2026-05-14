# frozen_string_literal: true

require "json"

module Streaming
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

  ChunkResult = Struct.new(:usage, :has_thinking, :has_content, :has_tool_call)

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

  def self.parse_chunk(chunk)
    result = ChunkResult.new(nil, false, false, false)

    if chunk.include?(USAGE_STRING)
      chunk.scan(/^data:\s*(.+)$/).each do |raw|
        line = raw.first.strip
        next if line == "[DONE]" || line.empty?
        begin
          data = JSON.parse(line)
          if data.key?("usage")
            result.usage = data["usage"]
            break
          end
        rescue JSON::ParserError
          next
        end
      end
    end

    result.has_thinking = true if !result.has_thinking && THINKING_PATTERNS.any? { |r| chunk.match?(r) }

    if chunk.match?(TOOL_CALL_PATTERN)
      result.has_tool_call = true
      result.has_content = true
    elsif !result.has_content
      result.has_content = true if CONTENT_PATTERNS.any? { |r| chunk.match?(r) }
    end

    result
  end

  def self.extract_sse_content(accumulated)
    content_len = 0
    thinking_len = 0

    accumulated.scan(/^data:\s*(.+)$/).each do |raw|
      line = raw.first.strip
      next if line == "[DONE]" || line.empty?
      begin
        data = JSON.parse(line)
        delta = data.dig("choices", 0, "delta")
        next unless delta
        content_len += delta["content"].to_s.length if delta["content"]
        thinking_len += delta["reasoning_content"].to_s.length if delta["reasoning_content"]
      rescue JSON::ParserError
        next
      end
    end

    { content_len: content_len, thinking_len: thinking_len }
  end

  def self.extract_token_counts(usage_data)
    completion = usage_data.dig("completion_tokens") || usage_data.dig("output_tokens")
    thinking = usage_data.dig("completion_tokens_details", "reasoning_tokens") ||
               usage_data.dig("output_tokens_details", "reasoning_tokens") ||
               usage_data.dig("reasoning_tokens") || 0
    content = completion ? completion - thinking : nil
    { completion: completion, thinking: thinking, content: content }
  end

  def self.compute_tps(token_count, first_time, last_time)
    return nil unless token_count && token_count > 0 && first_time && last_time
    elapsed = last_time - first_time
    elapsed > 0 ? (token_count / elapsed).round(1) : nil
  end

  def self.stream_response(http, request, request_start, on_chunk: nil)
    timers = TimerTracker.new
    usage_data = nil
    error = nil

    http.request(request) do |response|
      unless response.is_a?(Net::HTTPSuccess)
        error = "HTTP #{response.code}: #{response.body}"
        next
      end

      response.read_body do |chunk|
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cr = parse_chunk(chunk)

        usage_data = cr.usage if cr.usage

        timers.record_thinking(now) if cr.has_thinking
        timers.record_content(now) if cr.has_content

        on_chunk&.call(chunk, cr, now)
      end
    end

    if error
      { error: error }
    else
      {
        first_token_time: timers.first_token,
        first_thinking_time: timers.first_thinking,
        last_thinking_time: timers.last_thinking,
        first_content_time: timers.first_content,
        last_content_time: timers.last_content,
        last_any_token_time: timers.last_any_token,
        usage_data: usage_data,
        request_start: request_start
      }
    end
  end

  def track_chunk!(chunk_result, now, tracker)
    tracker.record_thinking(now) if chunk_result.has_thinking
    tracker.record_content(now) if chunk_result.has_content
  end

  def build_stream_result(log_prefix, tracker, usage_data)
    ttft = tracker.first_token ? (tracker.first_token - @request_start).round(3) : nil

    if usage_data
      tokens = Streaming.extract_token_counts(usage_data)
      content_tps = Streaming.compute_tps(tokens[:content], tracker.first_content, tracker.last_content)
      thinking_tps = Streaming.compute_tps(tokens[:thinking], tracker.first_thinking, tracker.last_thinking)
      total_tps = Streaming.compute_tps(tokens[:completion], tracker.first_token, tracker.last_any_token)

      log_parts = []
      log_parts << "content=#{tokens[:content]}" if tokens[:content]&.positive?
      log_parts << "thinking=#{tokens[:thinking]}" if tokens[:thinking]&.positive?
      log_parts << "ttft=#{ttft}s"
      log_parts << "content_tps=#{content_tps}" if content_tps&.positive?
      log_parts << "thinking_tps=#{thinking_tps}" if thinking_tps&.positive?
      log_parts << "total_tps=#{total_tps}" if total_tps&.positive?

      settings.logger.info("#{log_prefix} Success | #{log_parts.join(' ')}")
      { success: true, content_tokens: tokens[:content], thinking_tokens: tokens[:thinking], ttft: ttft, content_tps: content_tps, thinking_tps: thinking_tps, total_tps: total_tps }
    else
      settings.logger.info("#{log_prefix} Success | ttft=#{ttft}s (no usage data from provider)")
      { success: true, content_tokens: nil, thinking_tokens: nil, ttft: ttft, content_tps: nil, thinking_tps: nil }
    end
  end

  def streaming_error(message, detail: nil)
    "data: #{ { error: { message: message, detail: detail } }.to_json }\n\n"
  end
end
