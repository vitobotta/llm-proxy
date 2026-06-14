# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/request_handler"
require_relative "../lib/config_store"
require_relative "../lib/metrics"
require "puma/const"
require "puma/null_io"
require "puma/client"

class TestRequestHandler < Minitest::Test
  def test_failure_reason_rate_limited_from_status
    assert_equal "rate_limited", RequestHandler.failure_reason({status: 429, error: "HTTP 429: too many"})
  end

  def test_failure_reason_server_error
    assert_equal "server_error", RequestHandler.failure_reason({status: 502, error: "HTTP 502: bad gateway"})
  end

  def test_failure_reason_client_error
    assert_equal "client_error", RequestHandler.failure_reason({status: 400, error: "bad request"})
  end

  def test_failure_reason_timeout
    assert_equal "timeout", RequestHandler.failure_reason({error: "Timeout after 3 attempts"})
  end

  def test_failure_reason_client_disconnect
    assert_equal "client_disconnect", RequestHandler.failure_reason({error: "Client disconnected"})
  end

  def test_failure_reason_connection_reset
    assert_equal "connection_reset", RequestHandler.failure_reason({error: "Connection reset after 2 attempts"})
  end

  def test_failure_reason_unknown_for_nil
    assert_equal "unknown", RequestHandler.failure_reason(nil)
  end

  def test_failure_reason_generic_error
    assert_equal "error", RequestHandler.failure_reason({error: "weird unexplained thing"})
  end

  def test_failure_reason_quota_exhausted
    assert_equal "quota_exhausted", RequestHandler.failure_reason({quota_pause_until: Time.now.to_f + 60})
  end

  def test_failure_reason_rate_limited_from_error_string
    assert_equal "rate_limited", RequestHandler.failure_reason({error: "Rate limited"})
  end

  class FakeHelper
    extend RequestHandler::ClassMethods if defined?(RequestHandler::ClassMethods)
    include RequestHandler

    attr_accessor :logs

    def initialize
      @logs = []
    end

    def settings
      logger = Object.new
      logs_ref = @logs
      logger.define_singleton_method(:info) { |m| logs_ref << [:info, m] }
      logger.define_singleton_method(:warn) { |m| logs_ref << [:warn, m] }
      logger.define_singleton_method(:error) { |m| logs_ref << [:error, m] }
      logger.define_singleton_method(:debug) { |m| logs_ref << [:debug, m] }
      Struct.new(:logger).new(logger)
    end
  end

  def test_build_failure_summary_aggregates_attempts
    h = FakeHelper.new
    attempts = [
      {provider: "p_a", status: 500, error: "boom", reason: "server_error"},
      {provider: "p_b", status: 429, error: "rate", reason: "rate_limited"}
    ]
    result = h.build_failure_summary(attempts, false)
    refute result[:success]
    assert_includes result[:error], "p_a: server_error"
    assert_includes result[:error], "p_b: rate_limited"
    assert_equal 429, result[:status], "last attempt status should be propagated"
    assert_equal attempts, result[:detail][:attempts]
    refute result[:detail][:deadline_hit]
  end

  def test_build_failure_summary_when_deadline_hit_before_attempts
    h = FakeHelper.new
    result = h.build_failure_summary([], true)
    assert_equal 503, result[:status]
    assert_includes result[:error], "deadline exceeded"
  end

  def test_build_failure_summary_falls_back_to_502_when_last_status_missing
    h = FakeHelper.new
    attempts = [{provider: "p_a", status: nil, error: "Timeout", reason: "timeout"}]
    result = h.build_failure_summary(attempts, false)
    assert_equal 502, result[:status]
  end

  def test_build_failure_summary_no_providers_returns_503
    h = FakeHelper.new
    result = h.build_failure_summary([], false)
    assert_equal 503, result[:status]
    assert_includes result[:error], "No providers available"
  end

  def test_proxy_uses_error_sinatra_notfound_not_generic_not_found
    src = File.read(File.expand_path("../proxy.rb", __dir__))
    refute_match(/^\s*not_found do/, src,
      "proxy.rb must NOT use `not_found do` — it overrides halt-based 404 messages (e.g. 'Model X not found')")
    assert_match(/error Sinatra::NotFound do/, src,
      "proxy.rb must use `error Sinatra::NotFound do` to only catch genuine no-route cases")
  end

  class MockStreamApp
    include RequestHandler
    include Streaming
  end

  class BrokenStream
    def initialize(error_class)
      @error_class = error_class
    end

    def <<(_data)
      raise @error_class, "broken pipe"
    end
  end

  def test_handle_streaming_error_does_nothing_on_success
    out = []
    MockStreamApp.new.handle_streaming_error({success: true}, out)
    assert_empty out
  end

  def test_handle_streaming_error_raises_client_disconnected_on_epipe
    out = BrokenStream.new(Errno::EPIPE)
    assert_raises(HTTPSupport::ClientDisconnected) do
      MockStreamApp.new.handle_streaming_error({success: false, error: "fail"}, out)
    end
  end

  def test_handle_streaming_error_raises_client_disconnected_on_io_error
    out = BrokenStream.new(IOError)
    assert_raises(HTTPSupport::ClientDisconnected) do
      MockStreamApp.new.handle_streaming_error({success: false, error: "fail"}, out)
    end
  end

  def test_handle_streaming_error_raises_client_disconnected_on_puma_connection_error
    out = BrokenStream.new(Puma::ConnectionError)
    assert_raises(HTTPSupport::ClientDisconnected) do
      MockStreamApp.new.handle_streaming_error({success: false, error: "fail"}, out)
    end
  end
end

# --- Extended tests for with_auto_select, record_metrics, forward_chunk ---

class HandlerTestApp
  include RequestHandler
  include Streaming

  attr_accessor :request_id

  def initialize
    @request_id = "test-req-1"
  end

  def settings
    @_logs ||= []
    logger = Object.new
    logs_ref = @_logs
    logger.define_singleton_method(:info) { |m| logs_ref << [:info, m] }
    logger.define_singleton_method(:warn) { |m| logs_ref << [:warn, m] }
    logger.define_singleton_method(:error) { |m| logs_ref << [:error, m] }
    logger.define_singleton_method(:debug) { |m| logs_ref << [:debug, m] }
    Struct.new(:logger, :max_attempts, :backoff_base).new(logger, 2, 0)
  end

  def sleep(_); end
end

class FakeSelector
  attr_reader :successes, :failures, :pauses, :metrics_updates
  attr_accessor :_providers

  def initialize
    @successes = []
    @failures = []
    @pauses = []
    @metrics_updates = []
    @_providers = []
  end

  def ordered_providers(auto_switch: false)
    @_providers
  end

  def record_success(name)
    @successes << name
  end

  def record_failure(name)
    @failures << name
  end

  def quota_pause!(name, time, reason: nil)
    @pauses << {name: name, time: time, reason: reason}
  end

  def update_metrics(name, ttft, tps)
    @metrics_updates << {name: name, ttft: ttft, tps: tps}
  end

  def record_and_maybe_probe(_interval)
    false
  end
end

class WithAutoSelectTest < Minitest::Test
  def setup
    @app = HandlerTestApp.new
    @selector = FakeSelector.new
    @model_entry = {"name" => "test-model", "probing_enabled" => false, "auto_switch" => false}
    ConfigStore.instance_variable_set(:@data, {
      selectors: {"test-model" => @selector},
      models: {"test-model" => @model_entry},
      probe_interval: 60,
      probe_max_per_minute: 2,
      timeouts: {open: 1, read: 1, write: 1},
      tracking_enabled: true,
      quota_pause_default_seconds: 60
    })
  end

  def test_with_auto_select_success_on_first_provider
    @selector._providers = [
      {"provider" => "openai", "model" => "gpt-4", "base_url" => "https://api.openai.com/v1", "api_key" => "k"}
    ]

    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      {success: true, ttft: 0.5, content_tps: 50.0, total_tps: 50.0}
    end

    assert result[:success]
    assert_equal ["openai"], @selector.successes
    assert_empty @selector.failures
  end

  def test_with_auto_select_fallback_on_failure
    @selector._providers = [
      {"provider" => "openai", "model" => "gpt-4", "base_url" => "https://api.openai.com/v1", "api_key" => "k"},
      {"provider" => "anthropic", "model" => "claude-3", "base_url" => "https://api.anthropic.com/v1", "api_key" => "k2"}
    ]

    call = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call += 1
      if call == 1
        {success: false, status: 500, error: "server error"}
      else
        {success: true, ttft: 0.3}
      end
    end

    assert result[:success]
    assert_equal ["anthropic"], @selector.successes
    assert_equal ["openai"], @selector.failures
  end

  def test_with_auto_select_all_failures_returns_summary
    @selector._providers = [
      {"provider" => "openai", "model" => "gpt-4", "base_url" => "https://api.openai.com/v1", "api_key" => "k"}
    ]

    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      {success: false, status: 502, error: "bad gateway"}
    end

    refute result[:success]
    assert_includes result[:error], "openai"
  end

  def test_with_auto_select_quota_pause_skips_record_failure
    @selector._providers = [
      {"provider" => "openai", "model" => "gpt-4", "base_url" => "https://api.openai.com/v1", "api_key" => "k"}
    ]

    @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      {success: false, status: 429, error: "rate limited", quota_pause_until: Time.now.to_f + 60, quota_pause_reason: "rate_limited"}
    end

    assert_equal 1, @selector.pauses.size
    assert_empty @selector.failures, "quota-exhausted providers should NOT get record_failure"
  end

  def test_with_auto_select_records_metrics_on_success_with_probing
    probing_model = {"name" => "test-model", "probing_enabled" => true, "auto_switch" => false}
    ConfigStore.instance_variable_set(:@data, ConfigStore.instance_variable_get(:@data).merge(
      models: {"test-model" => probing_model}
    ))
    @selector._providers = [
      {"provider" => "openai", "model" => "gpt-4", "base_url" => "https://api.openai.com/v1", "api_key" => "k"}
    ]

    result = @app.with_auto_select(model: probing_model, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      {success: true, ttft: 0.5, total_tps: 80.0}
    end

    assert result[:success]
    assert_equal 1, @selector.metrics_updates.size
    assert_equal 0.5, @selector.metrics_updates.first[:ttft]
  end

  def test_with_auto_select_empty_providers_returns_failure
    @selector._providers = []

    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      flunk "should not be called"
    end

    refute result[:success]
    assert_equal 503, result[:status]
  end
end

class ForwardChunkTest < Minitest::Test
  def test_forward_chunk_to_client_writes_data
    out = []
    HandlerTestApp.new.forward_chunk_to_client(out, "data: hello\n\n")
    assert_equal ["data: hello\n\n"], out
  end

  def test_forward_chunk_raises_client_disconnected_on_epipe
    broken = Object.new
    broken.define_singleton_method(:<<) { |_| raise Errno::EPIPE }
    assert_raises(HTTPSupport::ClientDisconnected) do
      HandlerTestApp.new.forward_chunk_to_client(broken, "data")
    end
  end

  def test_forward_chunk_raises_client_disconnected_on_io_error
    broken = Object.new
    broken.define_singleton_method(:<<) { |_| raise IOError }
    assert_raises(HTTPSupport::ClientDisconnected) do
      HandlerTestApp.new.forward_chunk_to_client(broken, "data")
    end
  end
end

class RecordMetricsTest < Minitest::Test
  def test_record_metrics_calls_update_metrics_with_ttft_and_tps
    selector = FakeSelector.new
    HandlerTestApp.new.record_metrics(selector, "openai", {ttft: 0.5, total_tps: 80.0})
    assert_equal 1, selector.metrics_updates.size
    assert_equal "openai", selector.metrics_updates.first[:name]
    assert_equal 0.5, selector.metrics_updates.first[:ttft]
    assert_equal 80.0, selector.metrics_updates.first[:tps]
  end

  def test_record_metrics_skips_when_no_ttft
    selector = FakeSelector.new
    HandlerTestApp.new.record_metrics(selector, "openai", {total_tps: 80.0})
    assert_empty selector.metrics_updates
  end

  def test_record_metrics_uses_content_tps_as_fallback
    selector = FakeSelector.new
    HandlerTestApp.new.record_metrics(selector, "openai", {ttft: 0.3, content_tps: 60.0})
    assert_equal 60.0, selector.metrics_updates.first[:tps]
  end
end
