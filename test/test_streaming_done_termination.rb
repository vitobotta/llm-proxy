# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/request_handler"
require_relative "../lib/config_store"
require_relative "../lib/metrics"
require_relative "../lib/probe_manager"
# Lightweight app harness mirroring the one in test/test_request_handler.rb —
# only the methods try_stream touches.
class TerminationTestApp
  include RequestHandler
  include Streaming
  include HTTPSupport

  attr_accessor :request_id

  def initialize
    @request_id = "term-test-req-1"
  end

  def settings
    @_settings_logs ||= []
    logger = Object.new
    logs_ref = @_settings_logs
    logger.define_singleton_method(:info) { |m| logs_ref << [:info, m] }
    logger.define_singleton_method(:warn) { |m| logs_ref << [:warn, m] }
    logger.define_singleton_method(:error) { |m| logs_ref << [:error, m] }
    logger.define_singleton_method(:debug) { |m| logs_ref << [:debug, m] }
    Struct.new(:logger, :max_attempts, :backoff_base, :max_rounds).new(logger, 2, 0, 3)
  end

  def sleep(_); end
end

# --- Mock HTTP plumbing: fake Net::HTTP subclass that yields a canned
# --- response to `request`.
class TerminationMockHTTP
  attr_accessor :started, :read_timeout, :response

  def initialize
    @started = false
    @read_timeout = 300
  end

  def start
    @started = true
  end

  def started?
    @started
  end

  def request(_req)
    yield @response
  end
end

class TerminationTest < Minitest::Test
  OUTPUT_TEXT_DELTA = JSON.generate("type" => "response.output_text.delta", "delta" => "Hello from mock")

  def setup
    @app = TerminationTestApp.new
    @app.define_singleton_method(:sleep) { |*| }

    @orig_data = ConfigStore.instance_variable_get(:@data)
    ConfigStore.instance_variable_set(:@data, {
      selectors: {},
      models: {},
      probe_interval: 60,
      probe_max_per_minute: 2,
      timeouts: {open: 1, read: 60, write: 60},
      tracking_enabled: true,
      quota_pause_default_seconds: 60
    })

    @orig_create_http = HTTPSupport.method(:create_http)
    @orig_discard_http = HTTPSupport.method(:discard_http)
    @orig_checkin_http = HTTPSupport.method(:checkin_http)
    @orig_build_upstream = HTTPSupport.method(:build_upstream_request)
  end

  def teardown
    HTTPSupport.define_singleton_method(:create_http, @orig_create_http)
    HTTPSupport.define_singleton_method(:discard_http, @orig_discard_http)
    HTTPSupport.define_singleton_method(:checkin_http, @orig_checkin_http)
    HTTPSupport.define_singleton_method(:build_upstream_request, @orig_build_upstream)
    ConfigStore.instance_variable_set(:@data, @orig_data)
  end

  def mock_http!(response)
    mock_http = TerminationMockHTTP.new
    mock_http.response = response
    HTTPSupport.define_singleton_method(:create_http) { |*a, **kw| mock_http }
    HTTPSupport.define_singleton_method(:discard_http) { |*a| }
    HTTPSupport.define_singleton_method(:checkin_http) { |*a| }
    HTTPSupport.define_singleton_method(:build_upstream_request) { |*a, **kw| [URI.parse("https://upstream.example.com/v1"), Object.new] }
    mock_http
  end

  def run_stream(chunks, responses_api:)
    mock_http!(SseResponse.new(*chunks))
    out = []
    result = @app.try_stream(
      {"base_url" => "https://upstream.example.com/v1", "api_key" => "k"},
      responses_api ? "responses" : "chat/completions", {}, "m", {},
      out: out, log_prefix: "[term]", responses_api: responses_api
    )
    [result, out]
  end

  class DropResponse < Net::HTTPSuccess
    def initialize(first_chunk)
      super("1.1", "200", "OK")
      @first_chunk = first_chunk
    end

    def read_body
      yield @first_chunk
      raise EOFError, "end of file reached"
    end

    def [](_key); nil; end

    def body; ""; end
  end

  class SseResponse < Net::HTTPSuccess
    def initialize(*chunks)
      super("1.1", "200", "OK")
      @chunks = chunks
    end

    def read_body
      @chunks.each { |c| yield c }
    end

    def [](_key); nil; end

    def body; ""; end
  end

  def test_responses_truncated_done_injects_not_found_event_before_done
    result, out = run_stream([
      "data: #{OUTPUT_TEXT_DELTA}\n\n",
      "data: [DONE]\n\n"
    ], responses_api: true)
    assert result[:success]
    full = out.join
    nf_idx = full.index('"type":"response.not_found"')
    done_idx = full.index("data: [DONE]")
    refute_nil nf_idx, "synthetic response.not_found must be injected"
    refute_nil done_idx
    assert nf_idx < done_idx, "response.not_found must precede [DONE]"
    assert_includes full, '"code":"upstream_stopped"'
  end

  def test_responses_healthy_stream_no_injection_and_passthrough_order
    created = 'data: {"type":"response.created","response":{"id":"r1"}}\n\n'
    completed = 'data: {"type":"response.completed","response":{"usage":{"output_tokens":1}}}' + "\n\n"
    result, out = run_stream([
      created,
      "data: #{OUTPUT_TEXT_DELTA}\n\n",
      completed,
      "data: [DONE]\n\n"
    ], responses_api: true)
    assert result[:success]
    full = out.join
    refute_includes full, "response.failed"
    refute_includes full, "response.not_found"
    assert full.index(created) < full.index("Hello from mock"), "created must precede delta"
    assert full.index("Hello from mock") < full.index('"type":"response.completed"'), "delta must precede completed"
    assert full.end_with?("data: [DONE]\n\n")
  end

  def test_responses_completion_without_delta_injects_failed
    created = 'data: {"type":"response.created","response":{"id":"r1"}}\n\n'
    completed = 'data: {"type":"response.completed","response":{"usage":{"output_tokens":1}}}' + "\n\n"
    result, out = run_stream([
      created,
      completed,
      "data: [DONE]\n\n"
    ], responses_api: true)
    assert result[:success]
    full = out.join
    failed_idx = full.index('"type":"response.failed"')
    done_idx = full.index("data: [DONE]")
    refute_nil failed_idx
    refute_nil done_idx
    assert failed_idx < done_idx
    assert_includes full, '"code":"upstream_stopped"'
  end

  def test_chat_mode_truncated_stream_has_no_injection
    mock_http!(DropResponse.new("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"))
    out = []
    result = @app.try_stream(
      {"base_url" => "https://upstream.example.com/v1", "api_key" => "k"},
      "chat/completions", {}, "m", {},
      out: out, log_prefix: "[term]"
    )
    refute result[:success], "truncated chat stream should fail via partial-stream error"
    full = out.join
    refute_includes full, "response.failed"
    refute_includes full, "response.not_found"
    assert_includes full, '"choices":[{"delta":{"content":"hello"}}]'
  end

  def test_responses_crlf_done_does_not_emit_before_synthetic
    result, out = run_stream([
      "data: #{OUTPUT_TEXT_DELTA}\n\n",
      "data: [DONE]\r\n\r\n"
    ], responses_api: true)
    assert result[:success]
    full = out.join
    nf_idx = full.index('"type":"response.not_found"')
    done_idx = full.index("data: [DONE]")
    refute_nil nf_idx
    refute_nil done_idx
    assert nf_idx < done_idx, "synthetic event must precede the CRLF [DONE]"
    assert_equal 1, full.scan(/data: \[DONE\]/).length, "exactly one [DONE]"
    assert_includes full, '"code":"upstream_stopped"'
  end

  def test_responses_container_only_stream_gets_synthetic_not_found
    created = 'data: {"type":"response.created","response":{"id":"r1"}}' + "\n\n"
    result, out = run_stream([
      created,
      "data: [DONE]\n\n"
    ], responses_api: true)
    assert result[:success]
    full = out.join
    nf_idx = full.index('"type":"response.not_found"')
    done_idx = full.index("data: [DONE]")
    refute_nil nf_idx, "container-only streams must get a synthetic terminal event"
    refute_nil done_idx
    assert nf_idx < done_idx
  end

  def test_responses_healthy_stream_with_containers_no_injection
    created = 'data: {"type":"response.created","response":{"id":"r1"}}' + "\n\n"
    item_added = 'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message"}}' + "\n\n"
    completed = 'data: {"type":"response.completed","response":{"usage":{"output_tokens":1}}}' + "\n\n"
    result, out = run_stream([
      created,
      item_added,
      "data: #{OUTPUT_TEXT_DELTA}\n\n",
      completed,
      "data: [DONE]\n\n"
    ], responses_api: true)
    assert result[:success]
    full = out.join
    refute_includes full, "response.failed"
    refute_includes full, "response.not_found"
    assert full.end_with?("data: [DONE]\n\n")
  end
end
