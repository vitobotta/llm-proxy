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
    assert_equal({"prompt_tokens" => 10, "completion_tokens" => 50}, cr.usage)
  end

  def test_parse_chunk_word_usage_in_content_is_not_treated_as_usage_block
    # The fast-path `chunk.include?("usage")` will fire, but the actual
    # JSON has no `usage` key — so parse_chunk should return usage=nil.
    chunk = 'data: {"choices":[{"delta":{"content":"Check your usage limit"}}]}' + "\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert_nil cr.usage
    assert cr.has_content
  end

  def test_parse_chunk_word_content_inside_string_does_not_set_has_content
    # The substring "content" appears inside a string value, not as a JSON key.
    # The regex requires it to be preceded by a non-identifier char and followed
    # by `:`, so it must not match here.
    chunk = 'data: {"choices":[{"delta":{"role":"assistant","name":"my_content_helper"}}]}' + "\n\n"
    cr = Streaming.parse_chunk(chunk)
    refute cr.has_content, "content substring inside a value must not flip has_content"
  end

  def test_parse_chunk_handles_chunk_with_only_done
    cr = Streaming.parse_chunk("data: [DONE]\n\n")
    refute cr.has_content
    refute cr.has_thinking
    assert_nil cr.usage
  end

  def test_parse_chunk_oversize_chunk_does_not_blow_up
    # A 1 MB chunk built from many tiny SSE lines — parse_chunk must complete.
    chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n" * 10_000
    cr = Streaming.parse_chunk(chunk)
    assert cr.has_content
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
    assert_equal({"completion_tokens" => 5}, cr.usage)
  end

  def test_extract_token_counts_openai_format
    usage = {"completion_tokens" => 100, "completion_tokens_details" => {"reasoning_tokens" => 30}}
    result = Streaming.extract_token_counts(usage)
    assert_equal 100, result[:completion]
    assert_equal 30, result[:thinking]
    assert_equal 70, result[:content]
  end

  def test_extract_token_counts_anthropic_format
    usage = {"output_tokens" => 80, "output_tokens_details" => {"reasoning_tokens" => 20}}
    result = Streaming.extract_token_counts(usage)
    assert_equal 80, result[:completion]
    assert_equal 20, result[:thinking]
    assert_equal 60, result[:content]
  end

  def test_extract_token_counts_no_thinking
    usage = {"completion_tokens" => 50}
    result = Streaming.extract_token_counts(usage)
    assert_equal 50, result[:completion]
    assert_equal 0, result[:thinking]
    assert_equal 50, result[:content]
    refute result[:content_clamped]
  end

  def test_extract_token_counts_clamps_negative_content
    usage = {"completion_tokens" => 10, "completion_tokens_details" => {"reasoning_tokens" => 30}}
    result = Streaming.extract_token_counts(usage)
    assert_equal 10, result[:completion]
    assert_equal 30, result[:thinking]
    assert_equal 0, result[:content], "content must be clamped to 0 instead of going negative"
    assert result[:content_clamped]
  end

  def test_note_negative_content_once_returns_true_only_first_time
    Streaming.reset_negative_token_warnings!
    assert_equal true, Streaming.note_negative_content_once("k1")
    assert_equal false, Streaming.note_negative_content_once("k1")
    assert_equal true, Streaming.note_negative_content_once("k2")
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
    timers = Streaming::TimerTracker.new
    now = 100.0
    cr = Streaming::ChunkResult.new(nil, true, false, false)
    track_chunk!(cr, now, timers)

    assert_equal now, timers.first_thinking
    assert_equal now, timers.last_thinking
    assert_equal now, timers.first_token
    assert timers.thinking_detected
  end

  def test_track_chunk_sets_content_timers
    timers = Streaming::TimerTracker.new
    now = 100.0
    cr = Streaming::ChunkResult.new(nil, false, true, false)
    track_chunk!(cr, now, timers)

    assert_equal now, timers.first_content
    assert_equal now, timers.last_content
    assert_equal now, timers.first_token
    assert timers.content_detected
  end

  def test_track_chunk_first_token_unchanged_on_subsequent_chunks
    timers = Streaming::TimerTracker.new
    cr_think = Streaming::ChunkResult.new(nil, true, false, false)
    track_chunk!(cr_think, 100.0, timers)
    cr_content = Streaming::ChunkResult.new(nil, false, true, false)
    track_chunk!(cr_content, 200.0, timers)

    assert_equal 100.0, timers.first_token
    assert_equal 200.0, timers.last_content
  end

  def test_parse_chunk_ignores_empty_content_in_role_delta
    chunk = 'data: {"choices":[{"delta":{"role":"assistant","content":""}}]}' + "\n\n"
    cr = Streaming.parse_chunk(chunk)
    refute cr.has_content, "empty content in role delta should not trigger content detection"
  end

  def test_parse_chunk_does_not_confuse_reasoning_content_as_content
    chunk = 'data: {"choices":[{"delta":{"reasoning_content":"thinking..."}}]}' + "\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert cr.has_thinking, "should detect thinking"
    refute cr.has_content, "reasoning_content should not trigger content detection"
  end

  # --- consume_stream ---

  def test_consume_stream_extracts_usage_from_final_chunk
    usage_chunk = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([usage_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new

    usage, _perf_metrics, _server_duration = Streaming.consume_stream(response, tracker: tracker)
    assert_equal({"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}, usage)
  end

  def test_consume_stream_returns_nil_when_no_usage
    content_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([content_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new

    usage, _perf_metrics, _server_duration = Streaming.consume_stream(response, tracker: tracker)
    assert_nil usage
  end

  def test_consume_stream_tracks_thinking_timestamps
    think_chunk = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([think_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new

    Streaming.consume_stream(response, tracker: tracker)
    assert tracker.thinking_detected
    assert tracker.first_thinking
    assert tracker.last_thinking
  end

  def test_consume_stream_tracks_content_timestamps
    content_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([content_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new

    Streaming.consume_stream(response, tracker: tracker)
    assert tracker.content_detected
    assert tracker.first_content
    assert tracker.last_content
  end

  def test_consume_stream_yields_chunk_cr_and_now_to_block
    content_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"yo\"}}]}\n\n"
    response = MockResponse.new([content_chunk])
    tracker = Streaming::TimerTracker.new
    yielded = []

    Streaming.consume_stream(response, tracker: tracker) do |chunk, cr, now|
      yielded << {chunk: chunk, cr: cr, now: now}
    end

    assert_equal 1, yielded.length
    assert_equal content_chunk, yielded[0][:chunk]
    assert yielded[0][:cr].is_a?(Streaming::ChunkResult)
    assert yielded[0][:now].is_a?(Numeric)
  end

  def test_consume_stream_calls_block_for_every_chunk
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"a\"}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}\n\n",
      "data: [DONE]\n\n"
    ]
    response = MockResponse.new(chunks)
    tracker = Streaming::TimerTracker.new
    call_count = 0

    Streaming.consume_stream(response, tracker: tracker) { |_c, _cr, _n| call_count += 1 }
    assert_equal 3, call_count
  end

  def test_consume_stream_last_usage_wins
    usage1 = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n"
    usage2 = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}\n\n"
    response = MockResponse.new([usage1, usage2])
    tracker = Streaming::TimerTracker.new

    usage, _perf_metrics, _server_duration = Streaming.consume_stream(response, tracker: tracker)
    assert_equal({"prompt_tokens" => 10, "completion_tokens" => 5}, usage)
  end

  # --- stream_response ---

  def test_stream_response_success_with_usage
    usage_json = {choices: [], usage: {prompt_tokens: 10, completion_tokens: 5}}.to_json
    content_json = {choices: [{delta: {content: "hi"}}]}.to_json
    chunks = "data: #{content_json}\n\ndata: #{usage_json}\n\ndata: [DONE]\n\n"
    response = MockHTTPResponse.new("200", chunks)
    http = MockHTTP.new(response)
    request = Object.new

    result = Streaming.stream_response(http, request, 1000.0)

    assert_nil result[:error]
    assert_equal 1000.0, result[:request_start]
    assert result[:usage_data].is_a?(Hash)
    assert_equal 10, result[:usage_data]["prompt_tokens"]
    assert result[:first_token_time], "first_token_time should be set after content chunk"
    assert result[:first_content_time], "first_content_time should be set"
  end

  def test_stream_response_error_returns_error_hash
    response = MockHTTPResponse.new("500", "Internal Server Error")
    http = MockHTTP.new(response)
    request = Object.new

    result = Streaming.stream_response(http, request, 1000.0)

    assert result[:error], "should return error for non-200"
    assert_includes result[:error], "500"
    assert_includes result[:error], "Internal Server Error"
  end

  def test_stream_response_success_without_usage
    content_json = {choices: [{delta: {content: "hello"}}]}.to_json
    chunks = "data: #{content_json}\n\ndata: [DONE]\n\n"
    response = MockHTTPResponse.new("200", chunks)
    http = MockHTTP.new(response)
    request = Object.new

    result = Streaming.stream_response(http, request, 1000.0)

    assert_nil result[:error]
    assert_nil result[:usage_data]
    assert result[:first_token_time]
    assert result[:first_content_time]
  end

  def test_stream_response_calls_on_chunk_callback
    content_json = {choices: [{delta: {content: "x"}}]}.to_json
    chunks = "data: #{content_json}\n\ndata: [DONE]\n\n"
    response = MockHTTPResponse.new("200", chunks)
    http = MockHTTP.new(response)
    request = Object.new
    received = []

    Streaming.stream_response(http, request, 1000.0, on_chunk: ->(chunk, cr, now) {
      received << {chunk: chunk, has_content: cr.has_content, now: now}
    })

    assert received.length >= 1, "on_chunk should have been called"
    assert received.any? { |r| r[:has_content] }, "at least one chunk should have content"
  end

  def test_stream_response_thinking_tracks_thinking_timers
    think_json = {choices: [{delta: {reasoning_content: "thinking..."}}]}.to_json
    content_json = {choices: [{delta: {content: "answer"}}]}.to_json
    chunks = "data: #{think_json}\n\ndata: #{content_json}\n\ndata: [DONE]\n\n"
    response = MockHTTPResponse.new("200", chunks)
    http = MockHTTP.new(response)
    request = Object.new

    result = Streaming.stream_response(http, request, 1000.0)

    assert_nil result[:error]
    assert result[:first_thinking_time], "first_thinking_time should be set"
    assert result[:last_thinking_time], "last_thinking_time should be set"
    assert result[:first_content_time], "first_content_time should be set after content chunk"
  end

  # --- build_stream_result ---

  def test_build_stream_result_with_usage_data
    handler = BuildStreamResultHarness.new(1000.0)
    tracker = Streaming::TimerTracker.new
    tracker.record_thinking(1000.1)
    tracker.record_content(1000.2)
    tracker.record_content(1000.5)

    usage = {"completion_tokens" => 100, "completion_tokens_details" => {"reasoning_tokens" => 30}}
    result = handler.build_stream_result("[test]", tracker, usage)

    assert_equal true, result[:success]
    assert_equal 70, result[:content_tokens]
    assert_equal 30, result[:thinking_tokens]
    assert_in_delta(0.1, result[:ttft], 0.01)
    assert result[:content_tps], "content_tps should be computed"
    assert result[:total_tps], "total_tps should be computed"
  end

  def test_build_stream_result_without_usage_data
    handler = BuildStreamResultHarness.new(1000.0)
    tracker = Streaming::TimerTracker.new
    tracker.record_content(1000.3)

    result = handler.build_stream_result("[test]", tracker, nil)

    assert_equal true, result[:success]
    assert_nil result[:content_tokens]
    assert_nil result[:thinking_tokens]
    assert_nil result[:content_tps]
    assert_nil result[:thinking_tps]
    assert_in_delta(0.3, result[:ttft], 0.01)
  end

  def test_build_stream_result_no_tokens_received
    handler = BuildStreamResultHarness.new(1000.0)
    tracker = Streaming::TimerTracker.new

    result = handler.build_stream_result("[test]", tracker, nil)

    assert_equal true, result[:success]
    assert_nil result[:ttft], "ttft should be nil when no tokens received"
  end

  def test_build_stream_result_negative_content_clamped
    Streaming.reset_negative_token_warnings!
    handler = BuildStreamResultHarness.new(1000.0)
    tracker = Streaming::TimerTracker.new
    tracker.record_content(1000.1)
    tracker.record_content(1000.2)

    usage = {"completion_tokens" => 10, "completion_tokens_details" => {"reasoning_tokens" => 30}}
    result = handler.build_stream_result("[test-negative]", tracker, usage)

    assert_equal 0, result[:content_tokens]
    assert_equal 30, result[:thinking_tokens]
  end

  # --- server-side timing (Groq / Fireworks) ---

  def test_extract_token_counts_groq_server_tps
    usage = {"completion_tokens" => 100, "completion_time" => 2.0}
    result = Streaming.extract_token_counts(usage)
    assert_equal 50.0, result[:server_tps]
    assert_equal 100, result[:completion]
    assert_equal 0, result[:thinking]
    assert_equal 100, result[:content]
  end

  def test_extract_token_counts_fireworks_server_tps
    usage = {"completion_tokens" => 100}
    perf_metrics = {"generation-duration" => 2.5}
    result = Streaming.extract_token_counts(usage, perf_metrics: perf_metrics)
    assert_equal 40.0, result[:server_tps]
  end

  def test_extract_token_counts_no_server_tps
    usage = {"completion_tokens" => 50}
    result = Streaming.extract_token_counts(usage)
    assert_nil result[:server_tps]
  end

  def test_build_stream_result_prefers_server_tps
    handler = BuildStreamResultHarness.new(1000.0)
    tracker = Streaming::TimerTracker.new
    tracker.record_content(1000.1)
    tracker.record_content(1000.5)

    usage = {"completion_tokens" => 100, "completion_time" => 2.0}
    result = handler.build_stream_result("[test]", tracker, usage)

    assert_equal 50.0, result[:total_tps], "total_tps should use server-side completion_time"
  end

  def test_extract_token_counts_groq_server_ttft
    usage = {"prompt_time" => 0.2, "queue_time" => 0.05, "completion_tokens" => 100}
    result = Streaming.extract_token_counts(usage)
    assert_equal 0.25, result[:server_ttft]
  end

  def test_extract_token_counts_fireworks_server_ttft
    perf_metrics = {"server-time-to-first-token" => 0.3}
    usage = {"completion_tokens" => 50}
    result = Streaming.extract_token_counts(usage, perf_metrics: perf_metrics)
    assert_equal 0.3, result[:server_ttft]
  end

  def test_build_stream_result_prefers_server_ttft
    handler = BuildStreamResultHarness.new(1000.0)
    tracker = Streaming::TimerTracker.new
    tracker.record_content(1000.5)  # arrival TTFT would be 0.5

    usage = {"prompt_time" => 0.2, "queue_time" => 0.05, "completion_tokens" => 10}
    result = handler.build_stream_result("[test]", tracker, usage)

    assert_in_delta 0.25, result[:ttft], 0.001, "ttft should use server-side prompt_time+queue_time"
  end

  def test_parse_chunk_extracts_perf_metrics
    chunk = "data: {\"choices\":[],\"perf_metrics\":{\"generation-duration\":1.5,\"server-time-to-first-token\":0.1}}\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert cr.perf_metrics
    assert_equal 1.5, cr.perf_metrics["generation-duration"]
    assert_equal 0.1, cr.perf_metrics["server-time-to-first-token"]
  end

  def test_consume_stream_extracts_perf_metrics
    perf_chunk = "data: {\"choices\":[],\"perf_metrics\":{\"generation-duration\":1.5}}\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([perf_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new

    _usage, perf_metrics, _server_duration = Streaming.consume_stream(response, tracker: tracker)
    assert perf_metrics
    assert_equal 1.5, perf_metrics["generation-duration"]
  end

  def test_parse_chunk_extracts_server_duration_from_energy_comment
    chunk = ": energy {\"energy_joules\": 8.41, \"duration_seconds\": 2.292, \"carbon_g_co2eq\": 0.0001}\n\n"
    cr = Streaming.parse_chunk(chunk)
    assert_equal 2.292, cr.server_duration
  end

  def test_extract_token_counts_tokens_per_second
    usage = {"completion_tokens" => 100, "tokens_per_second" => 51.36}
    result = Streaming.extract_token_counts(usage)
    assert_equal 51.4, result[:server_tps], "server_tps should use tokens_per_second from usage"
  end

  def test_extract_token_counts_server_duration_fallback
    usage = {"completion_tokens" => 100}
    result = Streaming.extract_token_counts(usage, server_duration: 2.5)
    assert_equal 40.0, result[:server_tps], "server_tps should fall back to completion/server_duration"
  end

  def test_consume_stream_extracts_server_duration
    usage_chunk = "data: {\"choices\":[],\"usage\":{\"completion_tokens\":50}}\n\n"
    energy_chunk = ": energy {\"duration_seconds\": 1.5}\n\n"
    response = MockResponse.new([usage_chunk, energy_chunk])
    tracker = Streaming::TimerTracker.new

    _usage, _perf_metrics, server_duration = Streaming.consume_stream(response, tracker: tracker)
    assert_equal 1.5, server_duration
  end

  # --- consume_stream TTFT timeout ---

  def test_consume_stream_raises_ttft_timeout_when_no_first_token
    ping_chunk = ": ping\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([ping_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new
    request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 100

    assert_raises(HTTPSupport::TTFTTimeoutError) do
      Streaming.consume_stream(response, tracker: tracker, ttft_timeout: 5, request_start: request_start)
    end
  end

  def test_consume_stream_does_not_raise_when_first_token_within_deadline
    content_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([content_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new
    request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    usage, _perf, _sd = Streaming.consume_stream(response, tracker: tracker,
      ttft_timeout: 100, request_start: request_start)
    assert tracker.first_token, "first_token should be set"
  end

  def test_consume_stream_no_ttft_timeout_when_disabled
    ping_chunk = ": ping\n\n"
    response = MockResponse.new([ping_chunk])
    tracker = Streaming::TimerTracker.new
    request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1000

    Streaming.consume_stream(response, tracker: tracker, ttft_timeout: nil, request_start: request_start)
  end

  def test_consume_stream_ttft_check_before_yield
    ping_chunk = ": ping\n\n"
    response = MockResponse.new([ping_chunk])
    tracker = Streaming::TimerTracker.new
    request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 100
    yielded = false

    assert_raises(HTTPSupport::TTFTTimeoutError) do
      Streaming.consume_stream(response, tracker: tracker, ttft_timeout: 5, request_start: request_start) do |_c, _cr, _n|
        yielded = true
      end
    end
    refute yielded, "block should not be called when TTFT times out"
  end

  def test_consume_stream_ttft_not_raised_after_first_token
    content_chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
    ping_chunk = ": ping\n\n"
    done_chunk = "data: [DONE]\n\n"
    response = MockResponse.new([content_chunk, ping_chunk, done_chunk])
    tracker = Streaming::TimerTracker.new
    # Deadline is in the past, but first_token is set on chunk 1.
    # Subsequent chunks should NOT trigger the timeout.
    request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 100

    Streaming.consume_stream(response, tracker: tracker, ttft_timeout: 5, request_start: request_start)
    assert tracker.first_token, "first_token should be set"
  end

  def test_consume_stream_no_request_start_skips_ttft_check
    ping_chunk = ": ping\n\n"
    response = MockResponse.new([ping_chunk])
    tracker = Streaming::TimerTracker.new

    Streaming.consume_stream(response, tracker: tracker, ttft_timeout: 5, request_start: nil)
  end
end

# --- Mock helpers ---

class MockResponse
  def initialize(chunks)
    @chunks = chunks
  end

  def read_body
    @chunks.each { |c| yield c }
  end
end

class MockHTTPResponse
  attr_reader :code, :body

  def initialize(code, body)
    @code = code
    @body = body
  end

  def read_body
    yield @body
  end

  def is_a?(klass)
    klass.name == "Net::HTTPSuccess" && @code == "200"
  end

  def [](_key)
    nil
  end
end

class MockHTTP
  def initialize(response)
    @response = response
  end

  def request(_req)
    yield @response
  end
end

class BuildStreamResultHarness
  include Streaming

  attr_reader :settings

  def initialize(request_start)
    @request_start = request_start
    logger = NullLogger.new
    @settings = Struct.new(:logger).new(logger)
  end
end
