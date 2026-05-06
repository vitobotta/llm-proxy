# frozen_string_literal: true

require "json"

module Streaming
  THINKING_STRINGS = ['"reasoning_content"', '"thinking"', '"reasoning"'].freeze
  CONTENT_STRINGS = ['"content"', '"text"'].freeze
  TOOL_CALL_STRING = '"tool_calls"'
  USAGE_STRING = '"usage"'

  ChunkResult = Struct.new(:usage, :has_thinking, :has_content, :has_tool_call)

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

    result.has_thinking = true if !result.has_thinking && THINKING_STRINGS.any? { |s| chunk.include?(s) }

    if chunk.include?(TOOL_CALL_STRING)
      result.has_tool_call = true
      result.has_content = true
    elsif !result.has_content
      result.has_content = true if CONTENT_STRINGS.any? { |s| chunk.include?(s) }
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
               usage_data.dig("output_tokens_details", "reasoning_tokens") || 0
    content = completion ? completion - thinking : nil
    { completion: completion, thinking: thinking, content: content }
  end

  def self.compute_tps(token_count, first_time, last_time)
    return nil unless token_count && token_count > 0 && first_time && last_time
    elapsed = last_time - first_time
    elapsed > 0 ? (token_count / elapsed).round(1) : nil
  end

  def self.stream_response(http, request, request_start, on_chunk: nil)
    first_token_time = nil
    first_thinking_time = nil
    last_thinking_time = nil
    first_content_time = nil
    last_content_time = nil
    last_any_token_time = nil
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

        if cr.has_thinking
          last_thinking_time = now
          last_any_token_time = now
          first_thinking_time ||= now
          first_token_time ||= now
        end

        if cr.has_content
          last_content_time = now
          last_any_token_time = now
          first_content_time ||= now
          first_token_time ||= now
        end

        on_chunk&.call(chunk, cr, now)
      end
    end

    if error
      { error: error }
    else
      {
        first_token_time: first_token_time,
        first_thinking_time: first_thinking_time,
        last_thinking_time: last_thinking_time,
        first_content_time: first_content_time,
        last_content_time: last_content_time,
        last_any_token_time: last_any_token_time,
        usage_data: usage_data,
        request_start: request_start
      }
    end
  end

  def track_chunk!(chunk_result, now, timers)
    if chunk_result.has_thinking
      timers[:last_thinking] = now
      if !timers[:thinking_detected]
        timers[:thinking_detected] = true
        timers[:first_thinking] ||= now
        timers[:first_token] ||= now
      end
    end

    if chunk_result.has_content
      timers[:last_content] = now
      if !timers[:content_detected]
        timers[:content_detected] = true
        timers[:first_content] ||= now
        timers[:first_token] ||= now
      end
    end
  end

  def build_stream_result(log_prefix, timers, usage_data)
    ttft = timers[:first_token] ? (timers[:first_token] - @request_start).round(3) : nil

    if usage_data
      tokens = Streaming.extract_token_counts(usage_data)
      content_tps = Streaming.compute_tps(tokens[:content], timers[:first_content], timers[:last_content])
      thinking_tps = Streaming.compute_tps(tokens[:thinking], timers[:first_thinking], timers[:last_thinking])

      log_parts = []
      log_parts << "content=#{tokens[:content]}" if tokens[:content]&.positive?
      log_parts << "thinking=#{tokens[:thinking]}" if tokens[:thinking]&.positive?
      log_parts << "ttft=#{ttft}s"
      log_parts << "content_tps=#{content_tps}" if content_tps&.positive?
      log_parts << "thinking_tps=#{thinking_tps}" if thinking_tps&.positive?

      settings.logger.info("#{log_prefix} Success | #{log_parts.join(' ')}")
      { success: true, content_tokens: tokens[:content], thinking_tokens: tokens[:thinking], ttft: ttft, content_tps: content_tps, thinking_tps: thinking_tps }
    else
      settings.logger.info("#{log_prefix} Success | ttft=#{ttft}s (no usage data from provider)")
      { success: true, content_tokens: nil, thinking_tokens: nil, ttft: ttft, content_tps: nil, thinking_tps: nil }
    end
  end

  def streaming_error(message, detail: nil)
    "data: #{ { error: { message: message, detail: detail } }.to_json }\n\n"
  end
end
