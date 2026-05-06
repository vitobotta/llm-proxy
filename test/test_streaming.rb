# frozen_string_literal: true

require_relative "test_helper"

class TestStreaming < Minitest::Test
  include Streaming

  def test_parse_chunk_detects_thinking
    chunk = 'data: {"choices":[{"delta":{"reasoning_content":"hello"}}]}' + "\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert cr.has_thinking
    refute cr.has_content
  end

  def test_parse_chunk_detects_content
    chunk = 'data: {"choices":[{"delta":{"content":"world"}}]}' + "\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert cr.has_content
    refute cr.has_thinking
  end

  def test_parse_chunk_detects_tool_calls
    chunk = 'data: {"choices":[{"delta":{"tool_calls":[{"id":"x","function":{"name":"f"}}]}}]}' + "\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert cr.has_tool_call
    assert cr.has_content
  end

  def test_parse_chunk_extracts_usage
    chunk = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":50}}\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert_equal({ "prompt_tokens" => 10, "completion_tokens" => 50 }, cr.usage)
  end

  def test_parse_chunk_ignores_done_line
    chunk = "data: [DONE]\n\n"
    cr = Streaming.parse_chunk(chunk)
    refute cr.has_thinking
    refute cr.has_content
    refute cr.has_tool_call
    assert_nil cr.usage
  end

  def test_parse_chunk_skips_invalid_json_in_usage_scan
    chunk = "data: {not json}\ndata: {\"choices\":[],\"usage\":{\"completion_tokens\":5}}\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert_equal({ "completion_tokens" => 5 }, cr.usage)
  end

  def test_extract_token_counts_openai_format
    usage = { "completion_tokens" => 100, "completion_tokens_details" => { "reasoning_tokens" => 30 } }
    result = Streaming.extract_token_counts(usage)
    assert_equal 100, result[:completion]
    assert_equal 30, result[:thinking]
    assert_equal 70, result[:content]
  end

  def test_extract_token_counts_anthropic_format
    usage = { "output_tokens" => 80, "output_tokens_details" => { "reasoning_tokens" => 20 } }
    result = Streaming.extract_token_counts(usage)
    assert_equal 80, result[:completion]
    assert_equal 20, result[:thinking]
    assert_equal 60, result[:content]
  end

  def test_extract_token_counts_no_thinking
    usage = { "completion_tokens" => 50 }
    result = Streaming.extract_token_counts(usage)
    assert_equal 50, result[:completion]
    assert_equal 0, result[:thinking]
    assert_equal 50, result[:content]
  end

  def test_compute_tps_normal
    result = Streaming.compute_tps(100, 0.0, 1.0)
    assert_equal 100.0, result
  end

  def test_compute_tps_zero_elapsed
    result = Streaming.compute_tps(100, 0.0, 0.0)
    assert_nil result
  end

  def test_compute_tps_zero_tokens
    result = Streaming.compute_tps(0, 0.0, 1.0)
    assert_nil result
  end

  def test_compute_tps_nil_inputs
    assert_nil Streaming.compute_tps(nil, 0.0, 1.0)
    assert_nil Streaming.compute_tps(100, nil, 1.0)
    assert_nil Streaming.compute_tps(100, 0.0, nil)
  end

  def test_track_chunk_sets_thinking_timers
    timers = { thinking_detected: false, content_detected: false }
    now = 100.0
    cr = Streaming::ChunkResult.new(nil, true, false, false)
    track_chunk!(cr, now, timers)

    assert_equal now, timers[:first_thinking]
    assert_equal now, timers[:last_thinking]
    assert_equal now, timers[:first_token]
    assert timers[:thinking_detected]
  end

  def test_track_chunk_sets_content_timers
    timers = { thinking_detected: false, content_detected: false }
    now = 100.0
    cr = Streaming::ChunkResult.new(nil, false, true, false)
    track_chunk!(cr, now, timers)

    assert_equal now, timers[:first_content]
    assert_equal now, timers[:last_content]
    assert_equal now, timers[:first_token]
    assert timers[:content_detected]
  end

  def test_track_chunk_first_token_unchanged_on_subsequent_chunks
    timers = { thinking_detected: false, content_detected: false }
    cr_think = Streaming::ChunkResult.new(nil, true, false, false)
    track_chunk!(cr_think, 100.0, timers)
    cr_content = Streaming::ChunkResult.new(nil, false, true, false)
    track_chunk!(cr_content, 200.0, timers)

    assert_equal 100.0, timers[:first_token]
    assert_equal 200.0, timers[:last_content]
  end

  def test_extract_sse_content
    accumulated = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\ndata: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}\n\n"
    result = Streaming.extract_sse_content(accumulated)
    assert_equal 5, result[:content_len]
    assert_equal 8, result[:thinking_len]
  end
end
