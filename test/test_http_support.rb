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

  def test_retryable_codes_include_429_5xx
    assert_includes HTTPSupport::RETRYABLE_CODES, 429
    assert_includes HTTPSupport::RETRYABLE_CODES, 500
    assert_includes HTTPSupport::RETRYABLE_CODES, 502
    assert_includes HTTPSupport::RETRYABLE_CODES, 503
    assert_includes HTTPSupport::RETRYABLE_CODES, 504
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
end
