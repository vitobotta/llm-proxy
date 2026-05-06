# frozen_string_literal: true

require_relative "test_helper"

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
      provider_config, "chat/completions", { "model" => "gpt-4" }, "gpt-4", nil, stream: true
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
      provider_config, "messages", { "model" => "claude-4" }, "claude-4", nil, stream: true
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
    assert_equal({ "include_usage" => true }, body["stream_options"])
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
      "headers" => { "HTTP-Referer" => "https://test.com", "X-Title" => "Test" }
    }
    _uri, request = HTTPSupport.build_upstream_request(
      provider_config, "chat/completions", {}, "m", nil, stream: true
    )
    assert_equal "https://test.com", request["HTTP-Referer"]
    assert_equal "Test", request["X-Title"]
  end

  def test_build_upstream_request_protects_incoming_headers
    provider_config = {
      "provider" => "openai",
      "base_url" => "https://api.openai.com/v1",
      "api_key" => "key",
      "model" => "m",
      "headers" => nil
    }
    incoming = { "Authorization" => "evil-token", "X-Custom" => "allowed" }
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
end
