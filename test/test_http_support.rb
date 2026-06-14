# frozen_string_literal: true

require_relative "test_helper"
require "time"

class TestHTTPSupport < Minitest::Test
  def test_retryable_error_is_standard_error
    assert HTTPSupport::RetryableError < StandardError
  end

  def test_client_disconnected_is_standard_error
    assert HTTPSupport::ClientDisconnected < StandardError
  end

  def test_retryable_codes_include_5xx
    assert_includes HTTPSupport::RETRYABLE_CODES, 500
    assert_includes HTTPSupport::RETRYABLE_CODES, 502
    assert_includes HTTPSupport::RETRYABLE_CODES, 503
    assert_includes HTTPSupport::RETRYABLE_CODES, 504
  end

  def test_retryable_codes_exclude_429
    refute_includes HTTPSupport::RETRYABLE_CODES, 429, "429 is now handled via QuotaExhaustedError, not retryable"
  end

  def test_retryable_codes_exclude_4xx_client_errors
    refute_includes HTTPSupport::RETRYABLE_CODES, 400
    refute_includes HTTPSupport::RETRYABLE_CODES, 401
    refute_includes HTTPSupport::RETRYABLE_CODES, 403
    refute_includes HTTPSupport::RETRYABLE_CODES, 404
    refute_includes HTTPSupport::RETRYABLE_CODES, 422
  end

  def test_cached_uri_returns_uri
    uri = HTTPSupport.cached_uri("https://api.example.com/v1", "chat/completions")
    assert_kind_of URI::Generic, uri
  end

  def test_cached_uri_caches_result
    uri1 = HTTPSupport.cached_uri("https://api.example.com/v1", "chat/completions")
    uri2 = HTTPSupport.cached_uri("https://api.example.com/v1", "chat/completions")
    assert_same uri1, uri2
  end

  def test_sse_headers_include_required_fields
    assert_equal "text/event-stream", HTTPSupport::SSE_HEADERS["Content-Type"]
    assert_equal "no-cache", HTTPSupport::SSE_HEADERS["Cache-Control"]
    assert_equal "no", HTTPSupport::SSE_HEADERS["X-Accel-Buffering"]
  end

  def test_protected_headers_include_auth_headers
    assert_includes HTTPSupport::PROTECTED_HEADERS, "authorization"
    assert_includes HTTPSupport::PROTECTED_HEADERS, "x-api-key"
    assert_includes HTTPSupport::PROTECTED_HEADERS, "api-key"
    assert_includes HTTPSupport::PROTECTED_HEADERS, "host"
  end

  def test_build_upstream_request_default_auth
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "test-key",
      "model" => "gpt-4",
      "headers" => nil
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", {"model" => "gpt-4"}, "gpt-4", nil, stream: true
    )
    assert_equal "Bearer test-key", request["Authorization"]
  end

  def test_build_upstream_request_anthropic_auth
    provider_config = {
      "provider" => "anthropic",
      "base_url" => "https://api.anthropic.com/v1",
      "api_key" => "ant-key",
      "model" => "claude-4",
      "headers" => nil
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "messages", {"model" => "claude-4"}, "claude-4", nil, stream: true
    )
    assert_equal "ant-key", request["x-api-key"]
    assert_nil request["Authorization"]
  end

  def test_build_upstream_request_includes_stream_options
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "key",
      "model" => "gpt-4",
      "headers" => nil
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", {}, "gpt-4", nil, stream: true
    )
    body = JSON.parse(request.body)
    assert_equal true, body["stream"]
    assert_equal({"include_usage" => true}, body["stream_options"])
  end

  def test_build_upstream_request_preserves_reasoning_and_passthrough_fields
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "key",
      "model" => "o1",
      "headers" => nil
    }
    incoming_body = {
      "model" => "client-supplied-model",
      "messages" => [{"role" => "user", "content" => "hi"}],
      "reasoning_effort" => "high",
      "reasoning" => {"effort" => "medium", "summary" => "auto"},
      "temperature" => 0.5,
      "max_tokens" => 200,
      "tools" => [{"type" => "function", "function" => {"name" => "x"}}],
      "tool_choice" => "auto",
      "response_format" => {"type" => "json_object"},
      "metadata" => {"trace" => "abc"}
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", incoming_body, "upstream-model-id", nil, stream: true
    )
    body = JSON.parse(request.body)

    # Pass-through: every client-supplied field except `model` survives unchanged.
    assert_equal "high", body["reasoning_effort"]
    assert_equal({"effort" => "medium", "summary" => "auto"}, body["reasoning"])
    assert_equal 0.5, body["temperature"]
    assert_equal 200, body["max_tokens"]
    assert_equal [{"type" => "function", "function" => {"name" => "x"}}], body["tools"]
    assert_equal "auto", body["tool_choice"]
    assert_equal({"type" => "json_object"}, body["response_format"])
    assert_equal({"trace" => "abc"}, body["metadata"])

    # Proxy-set: model rewritten to upstream's value, stream + stream_options added.
    assert_equal "upstream-model-id", body["model"]
    assert_equal true, body["stream"]
    assert_equal({"include_usage" => true}, body["stream_options"])
  end

  def test_build_upstream_request_does_not_mutate_caller_body
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "key",
      "model" => "o1",
      "headers" => nil
    }
    incoming_body = {"model" => "client-id", "messages" => [], "reasoning_effort" => "high"}
    original = Marshal.load(Marshal.dump(incoming_body))

    HTTPSupport.build_upstream_request(provider_config, "chat/completions", incoming_body, "upstream-id", nil, stream: true)

    # Caller's hash must be unchanged — important because the same body Hash
    # is reused across fallback attempts in with_auto_select.
    assert_equal original, incoming_body
  end

  def test_build_upstream_request_no_stream_options_when_false
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "key",
      "model" => "gpt-4",
      "headers" => nil
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", {}, "gpt-4", nil, stream: false
    )
    body = JSON.parse(request.body)
    assert_equal false, body["stream"]
    refute body.key?("stream_options")
  end

  def test_build_upstream_request_merges_provider_headers
    provider_config = {
      "provider" => "openrouter",
      "base_url" => "https://openrouter.ai/api/v1",
      "api_key" => "key",
      "model" => "m",
      "headers" => {"HTTP-Referer" => "https://test.com", "X-Title" => "Test"}
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", {}, "m", nil, stream: true
    )
    assert_equal "https://test.com", request["HTTP-Referer"]
    assert_equal "Test", request["X-Title"]
  end

  def test_build_upstream_request_strips_protected_provider_headers
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "real-key",
      "model" => "m",
      "headers" => {"Authorization" => "Bearer hijack", "Host" => "evil.example.com", "X-Custom" => "ok"}
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", {}, "m", nil, stream: true
    )
    assert_equal "Bearer real-key", request["Authorization"], "provider config Authorization must not override real auth"
    assert_equal "ok", request["X-Custom"]
    refute_equal "evil.example.com", request["Host"]
  end

  def test_build_upstream_request_protects_incoming_headers
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "key",
      "model" => "m",
      "headers" => nil
    }
    incoming = {"Authorization" => "evil-token", "X-Custom" => "allowed"}
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", {}, "m", incoming, stream: true
    )
    assert_equal "Bearer key", request["Authorization"]
    assert_equal "allowed", request["X-Custom"]
  end

  def test_timeout_exceptions_include_all_three
    assert_includes HTTPSupport::TIMEOUT_EXCEPTIONS, Net::OpenTimeout
    assert_includes HTTPSupport::TIMEOUT_EXCEPTIONS, Net::ReadTimeout
    assert_includes HTTPSupport::TIMEOUT_EXCEPTIONS, Net::WriteTimeout
  end

  def test_parse_retry_after_delta_seconds
    assert_equal 5.0, HTTPSupport.parse_retry_after("5")
    assert_equal 12.5, HTTPSupport.parse_retry_after("12.5")
  end

  def test_parse_retry_after_http_date
    now = Time.utc(2026, 5, 26, 14, 0, 0)
    future = Time.utc(2026, 5, 26, 14, 0, 30).httpdate
    assert_in_delta 30.0, HTTPSupport.parse_retry_after(future, now: now), 0.01
  end

  def test_parse_retry_after_past_date_clamped_to_zero
    now = Time.utc(2026, 5, 26, 14, 0, 0)
    past = Time.utc(2026, 5, 26, 13, 0, 0).httpdate
    val = HTTPSupport.parse_retry_after(past, now: now)
    assert val <= 0, "past date should yield non-positive delay, got: #{val}"
  end

  class FakeResponse
    def initialize(body:, content_length: nil)
      @body = body
      @headers = {}
      @headers["Content-Length"] = content_length.to_s if content_length
    end

    def [](k)
      @headers[k]
    end

    attr_reader :body
  end

  def test_read_capped_error_body_truncates_oversize
    big = "x" * (HTTPSupport::MAX_UPSTREAM_BODY_SIZE + 100)
    r = FakeResponse.new(body: big)
    out = HTTPSupport.read_capped_error_body(r)
    assert out.end_with?("... (truncated)")
    assert_equal HTTPSupport::MAX_UPSTREAM_BODY_SIZE + "... (truncated)".bytesize, out.bytesize
  end

  def test_read_capped_error_body_short_circuits_on_content_length
    # 1 GB Content-Length — we should refuse to even call .body.
    body_invoked = false
    fake = Class.new do
      define_method(:initialize) { @hdr = {"Content-Length" => (1024 * 1024 * 1024).to_s} }
      define_method(:[]) { |k| @hdr[k] }
      define_method(:body) do
        body_invoked = true
        "x" * (1024 * 1024 * 1024)
      end
    end.new

    out = HTTPSupport.read_capped_error_body(fake)
    refute body_invoked, "body() must not be invoked when Content-Length exceeds cap"
    assert_includes out, "exceeds"
    assert_includes out, "suppressed"
  end

  def test_read_capped_error_body_handles_read_failure
    fake = Class.new do
      def [](_)
        nil
      end

      def body
        raise IOError, "stream broken"
      end
    end.new
    out = HTTPSupport.read_capped_error_body(fake)
    assert_includes out, "failed to read"
    assert_includes out, "IOError"
  end

  def test_uri_cache_evicts_oldest_at_capacity
    HTTPSupport::URI_CACHE_LOCK.synchronize { HTTPSupport::URI_CACHE.clear }
    cap = HTTPSupport::MAX_URI_CACHE_SIZE

    (cap + 5).times do |i|
      HTTPSupport.cached_uri("https://host-#{i}.example.com/v1", "chat/completions")
    end

    size = HTTPSupport::URI_CACHE_LOCK.synchronize { HTTPSupport::URI_CACHE.size }
    assert size <= cap, "cache must be capped at #{cap}, got #{size}"

    # The oldest 5 entries should have been evicted; the newest are still there.
    keys = HTTPSupport::URI_CACHE_LOCK.synchronize { HTTPSupport::URI_CACHE.keys }
    refute_includes keys, "https://host-0.example.com/v1/chat/completions"
    assert_includes keys, "https://host-#{cap + 4}.example.com/v1/chat/completions"
  end

  def test_parse_retry_after_garbage_returns_zero
    assert_equal 0.0, HTTPSupport.parse_retry_after("not a date or number")
    assert_equal 0.0, HTTPSupport.parse_retry_after(nil)
    assert_equal 0.0, HTTPSupport.parse_retry_after("")
  end

  # -- Mock helpers for pool and handle_upstream_error tests --

  class MockHttp
    attr_accessor :started
    alias_method :started?, :started

    def finish
      @started = false
    end
  end

  class MockErrorResponse
    def initialize(code:, body:, headers: {})
      @code = code.to_s
      @body = body
      @headers = headers
    end

    attr_reader :code, :body

    def [](k)
      @headers[k]
    end
  end

  class MockApp
    include HTTPSupport

    MockSettings = Struct.new(:logger)

    def settings
      MockSettings.new(NullLogger.new)
    end
  end

  def setup
    HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL.clear }
    @mock_app = MockApp.new
  end

  # -- Connection pool: checkout --

  def test_checkout_http_returns_nil_when_pool_empty
    uri = URI.parse("https://example.com")
    assert_nil HTTPSupport.checkout_http(uri)
  end

  def test_checkout_http_returns_started_entry
    uri = URI.parse("https://example.com")
    mock = MockHttp.new
    mock.started = true
    HTTPSupport.checkin_http(uri, mock)
    result = HTTPSupport.checkout_http(uri)
    assert_same mock, result
  end

  def test_checkout_http_skips_unstarted_entry
    uri = URI.parse("https://example.com")
    mock = MockHttp.new
    mock.started = false
    HTTPSupport.checkin_http(uri, mock)
    assert_nil HTTPSupport.checkout_http(uri)
  end

  def test_checkout_http_evicts_stale_created_entry
    uri = URI.parse("https://example.com")
    mock = MockHttp.new
    mock.started = true
    key = "#{uri.host}:#{uri.port}"
    old_time = Time.now.to_f - HTTPSupport::POOL_MAX_AGE - 10
    HTTPSupport::POOL_LOCK.synchronize do
      HTTPSupport::CONNECTION_POOL[key] = [
        {http: mock, created: old_time, last_used: Time.now.to_f}
      ]
    end
    assert_nil HTTPSupport.checkout_http(uri)
  end

  def test_checkout_http_evicts_stale_idle_entry
    uri = URI.parse("https://example.com")
    mock = MockHttp.new
    mock.started = true
    key = "#{uri.host}:#{uri.port}"
    old_idle = Time.now.to_f - HTTPSupport::POOL_MAX_IDLE - 10
    HTTPSupport::POOL_LOCK.synchronize do
      HTTPSupport::CONNECTION_POOL[key] = [
        {http: mock, created: Time.now.to_f, last_used: old_idle}
      ]
    end
    assert_nil HTTPSupport.checkout_http(uri)
  end

  # -- Connection pool: checkin --

  def test_checkin_http_stores_entry
    uri = URI.parse("https://example.com")
    mock = MockHttp.new
    mock.started = true
    HTTPSupport.checkin_http(uri, mock)
    key = "#{uri.host}:#{uri.port}"
    entries = HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL[key] }
    assert_equal 1, entries.size
    assert_same mock, entries.first[:http]
  end

  def test_checkin_http_ignores_nil
    uri = URI.parse("https://example.com")
    HTTPSupport.checkin_http(uri, nil)
    key = "#{uri.host}:#{uri.port}"
    entries = HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL[key] }
    assert_nil entries
  end

  def test_checkin_http_evicts_stale_before_adding
    uri = URI.parse("https://example.com")
    key = "#{uri.host}:#{uri.port}"
    stale = MockHttp.new
    stale.started = true
    old_time = Time.now.to_f - HTTPSupport::POOL_MAX_AGE - 10
    HTTPSupport::POOL_LOCK.synchronize do
      HTTPSupport::CONNECTION_POOL[key] = [
        {http: stale, created: old_time, last_used: old_time}
      ]
    end
    fresh = MockHttp.new
    fresh.started = true
    HTTPSupport.checkin_http(uri, fresh)
    entries = HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL[key] }
    assert_equal 1, entries.size
    assert_same fresh, entries.first[:http]
  end

  # -- Connection pool: discard --

  def test_discard_http_finishes_started_connection
    mock = MockHttp.new
    mock.started = true
    HTTPSupport.discard_http(mock)
    refute mock.started?, "discard should finish a started connection"
  end

  def test_discard_http_handles_nil
    # Should not raise
    HTTPSupport.discard_http(nil)
  end

  def test_discard_http_handles_already_finished
    mock = MockHttp.new
    mock.started = false
    # Should not raise
    HTTPSupport.discard_http(mock)
  end

  # -- Connection pool: flush_pool! --

  def test_flush_pool_clears_all_entries
    uri_a = URI.parse("https://a.example.com")
    uri_b = URI.parse("https://b.example.com")
    mock_a = MockHttp.new; mock_a.started = true
    mock_b = MockHttp.new; mock_b.started = true
    HTTPSupport.checkin_http(uri_a, mock_a)
    HTTPSupport.checkin_http(uri_b, mock_b)
    HTTPSupport.flush_pool!
    assert_empty HTTPSupport::CONNECTION_POOL
    refute mock_a.started?, "flush should finish started connections"
    refute mock_b.started?, "flush should finish started connections"
  end

  def test_flush_pool_handles_empty_pool
    HTTPSupport.flush_pool!
    assert_empty HTTPSupport::CONNECTION_POOL
  end

  # -- fresh_http --

  def test_fresh_http_returns_net_http_with_correct_settings
    uri = URI.parse("https://api.example.com/v1")
    timeouts = {open: 5, read: 10, write: 8}
    http = HTTPSupport.fresh_http(uri, timeouts: timeouts)
    assert_kind_of Net::HTTP, http
    assert_equal "api.example.com", http.address
    assert_equal 443, http.port
    assert http.use_ssl?
    assert_equal 5, http.open_timeout
    assert_equal 10, http.read_timeout
    assert_equal 8, http.write_timeout
    assert_equal HTTPSupport::KEEP_ALIVE_TIMEOUT, http.keep_alive_timeout
  end

  def test_fresh_http_disables_ssl_for_http_uri
    uri = URI.parse("http://api.example.com/v1")
    timeouts = {open: 5, read: 10, write: 8}
    http = HTTPSupport.fresh_http(uri, timeouts: timeouts)
    refute http.use_ssl?
  end

  def test_fresh_http_uses_custom_port
    uri = URI.parse("http://localhost:8080/v1")
    timeouts = {open: 1, read: 2, write: 3}
    http = HTTPSupport.fresh_http(uri, timeouts: timeouts)
    assert_equal "localhost", http.address
    assert_equal 8080, http.port
  end

  # -- extract_reset_time_from_body --

  def test_extract_reset_time_from_body_with_reset_field
    future = (Time.now.to_f + 120).round(3)
    body = JSON.generate({"reset" => future})
    result = HTTPSupport.extract_reset_time_from_body(body, default_seconds: 60)
    assert_equal future.to_f, result
  end

  def test_extract_reset_time_from_body_with_error_reset
    future = (Time.now.to_f + 90).round(3)
    body = JSON.generate({"error" => {"reset" => future}})
    result = HTTPSupport.extract_reset_time_from_body(body, default_seconds: 60)
    assert_equal future.to_f, result
  end

  def test_extract_reset_time_from_body_with_retry_after_ms
    body = JSON.generate({"retry_after_ms" => 5000})
    result = HTTPSupport.extract_reset_time_from_body(body, default_seconds: 60)
    assert_in_delta Time.now.to_f + 5.0, result, 1.0
  end

  def test_extract_reset_time_from_body_with_error_retry_after_ms
    body = JSON.generate({"error" => {"retry_after_ms" => 3000}})
    result = HTTPSupport.extract_reset_time_from_body(body, default_seconds: 60)
    assert_in_delta Time.now.to_f + 3.0, result, 1.0
  end

  def test_extract_reset_time_from_body_with_bad_json
    result = HTTPSupport.extract_reset_time_from_body("not json at all", default_seconds: 60)
    assert_in_delta Time.now.to_f + 60, result, 1.0
  end

  def test_extract_reset_time_from_body_with_missing_fields
    body = JSON.generate({"something" => "else", "count" => 42})
    result = HTTPSupport.extract_reset_time_from_body(body, default_seconds: 30)
    assert_in_delta Time.now.to_f + 30, result, 1.0
  end

  def test_extract_reset_time_from_body_with_nil_body
    result = HTTPSupport.extract_reset_time_from_body(nil, default_seconds: 45)
    assert_in_delta Time.now.to_f + 45, result, 1.0
  end

  def test_extract_reset_time_from_body_ignores_past_reset
    past = (Time.now.to_f - 100).round(3)
    body = JSON.generate({"reset" => past})
    result = HTTPSupport.extract_reset_time_from_body(body, default_seconds: 60)
    # Past reset should be ignored, falls through to default
    assert_in_delta Time.now.to_f + 60, result, 1.0
  end

  # -- handle_upstream_error --

  def test_handle_upstream_error_429_raises_quota_exhausted
    response = MockErrorResponse.new(code: 429, body: "rate limited")
    err = assert_raises(HTTPSupport::QuotaExhaustedError) do
      @mock_app.handle_upstream_error(response, "[test]")
    end
    assert_equal 429, err.status
    assert_equal "rate_limited", err.reason
  end

  def test_handle_upstream_error_402_raises_quota_exhausted
    response = MockErrorResponse.new(code: 402, body: '{"error":{"message":"insufficient_quota"}}')
    err = assert_raises(HTTPSupport::QuotaExhaustedError) do
      @mock_app.handle_upstream_error(response, "[test]")
    end
    assert_equal 402, err.status
    assert_equal "payment_required", err.reason
  end

  def test_handle_upstream_error_500_raises_retryable
    response = MockErrorResponse.new(code: 500, body: "internal server error")
    err = assert_raises(HTTPSupport::RetryableError) do
      @mock_app.handle_upstream_error(response, "[test]")
    end
    assert_includes err.message, "500"
  end

  def test_handle_upstream_error_400_returns_failure_hash
    response = MockErrorResponse.new(code: 400, body: "bad request")
    result = @mock_app.handle_upstream_error(response, "[test]")
    assert_equal false, result[:success]
    assert_includes result[:error], "400"
    assert_equal 400, result[:status]
  end

  def test_handle_upstream_error_502_raises_retryable
    response = MockErrorResponse.new(code: 502, body: "bad gateway")
    assert_raises(HTTPSupport::RetryableError) do
      @mock_app.handle_upstream_error(response, "[test]")
    end
  end

  def test_handle_upstream_error_403_with_quota_body_raises_quota_exhausted
    response = MockErrorResponse.new(code: 403, body: '{"error":{"message":"quota exceeded"}}')
    err = assert_raises(HTTPSupport::QuotaExhaustedError) do
      @mock_app.handle_upstream_error(response, "[test]")
    end
    assert_equal 403, err.status
  end

  def test_handle_upstream_error_sets_reset_time
    future = (Time.now.to_f + 120).round(3)
    body = JSON.generate({"reset" => future})
    response = MockErrorResponse.new(code: 429, body: body)
    err = assert_raises(HTTPSupport::QuotaExhaustedError) do
      @mock_app.handle_upstream_error(response, "[test]")
    end
    assert_equal future.to_f, err.reset_time
  end
end
