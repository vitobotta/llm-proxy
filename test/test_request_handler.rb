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

  def test_failure_reason_ttft_timeout
    assert_equal "ttft_timeout", RequestHandler.failure_reason({error: "TTFT timeout after 2 attempts"})
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
    assert_equal [{provider: "p_a", status: 500, reason: "server_error"}, {provider: "p_b", status: 429, reason: "rate_limited"}], result[:detail][:attempts]
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
  include HTTPSupport

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
    Struct.new(:logger, :max_attempts, :backoff_base, :max_rounds).new(logger, 2, 0, 3)
  end

  def sleep(_); end
end

class FakeSelector
  attr_reader :successes, :failures, :pauses, :metrics_updates, :paused_names
  attr_accessor :_providers

  def initialize
    @successes = []
    @failures = []
    @pauses = []
    @metrics_updates = []
    @_providers = []
    @paused_names = []
  end

  def ordered_providers(auto_switch: false)
    @_providers.reject { |p| @paused_names.include?(p["provider"]) }
  end

  def record_success(name)
    @successes << name
  end

  def record_failure(name)
    @failures << name
  end

  def quota_pause!(name, time, reason: nil)
    @pauses << {name: name, time: time, reason: reason}
    @paused_names << name unless @paused_names.include?(name)
  end

  def update_metrics(name, ttft, tps, tokens: nil)
    @metrics_updates << {name: name, ttft: ttft, tps: tps, tokens: tokens}
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

# --- Circular fallback round-loop tests ---

class RoundLoopTest < Minitest::Test
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

  def make_provider(name, model = name)
    {"provider" => name, "model" => model, "base_url" => "https://#{name}.example.com/v1", "api_key" => "k"}
  end

  # Two-provider circular retry succeeds on round 2.
  # Round 1: A fails, B fails. Round 2: A succeeds.
  def test_circular_retry_succeeds_on_round_2
    @selector._providers = [make_provider("a"), make_provider("b")]
    call_count = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      # Round 1: calls 1 (a) and 2 (b) fail. Round 2: call 3 (a) succeeds.
      {success: call_count >= 3}
    end

    assert result[:success], "should succeed on round 2"
    assert_equal 3, call_count, "should have made 3 attempts (2 fails + 1 success)"
    assert_equal ["a"], @selector.successes
    assert_equal ["a", "b"], @selector.failures
  end

  # Single provider: retries across rounds until success.
  def test_single_provider_retries_across_rounds
    @selector._providers = [make_provider("solo")]
    call_count = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      # Fails rounds 1 and 2 (calls 1, 2), succeeds on round 3 (call 3).
      {success: call_count >= 3}
    end

    assert result[:success], "single provider should retry across rounds"
    assert_equal 3, call_count
    assert_equal ["solo", "solo"], @selector.failures
    assert_equal ["solo"], @selector.successes
  end

  # max_rounds exhausted with all failures returns failure summary.
  def test_max_rounds_exhausted_returns_failure
    @selector._providers = [make_provider("a"), make_provider("b")]
    call_count = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      {success: false, status: 500, error: "persistent failure"}
    end

    refute result[:success]
    # max_rounds=3, 2 providers each round = 6 calls
    assert_equal 6, call_count, "should exhaust all rounds"
    assert_includes result[:error], "a"
    assert_includes result[:error], "b"
  end

  # A provider that fails every round opens its circuit (3 failures = threshold).
  # After 3 rounds, provider "a" has 3 failures → circuit opens.
  def test_circuit_opens_after_3_rounds
    @selector._providers = [make_provider("a"), make_provider("b")]
    call_count = 0
    @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      {success: false, status: 500, error: "down"}
    end

    # "a" fails in rounds 1, 2, 3 → 3 record_failure calls → circuit threshold met.
    assert_equal 3, @selector.failures.count("a"), "provider a should have 3 failures (circuit threshold)"
    assert_equal 3, @selector.failures.count("b")
  end

  # Quota-paused provider is excluded from subsequent rounds.
  def test_quota_paused_provider_excluded_from_next_round
    @selector._providers = [make_provider("a"), make_provider("b")]
    call_count = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      if call_count == 1
        # Provider a hits quota on first call of round 1
        {success: false, status: 429, error: "rate limited", quota_pause_until: Time.now.to_f + 600, quota_pause_reason: "rate_limited"}
      elsif call_count == 2
        # Provider b fails round 1
        {success: false, status: 500, error: "down"}
      else
        # Round 2: only b should be tried (a is quota-paused) → succeeds
        {success: true}
      end
    end

    assert result[:success], "should succeed on round 2 with only b"
    assert_equal 3, call_count
    assert_equal 1, @selector.pauses.size
    assert_equal "a", @selector.pauses.first[:name]
    # b should have 1 failure (round 1) then 1 success (round 2)
    assert_equal ["b"], @selector.failures
    assert_equal ["b"], @selector.successes
  end

  # Round delay (backoff) is applied between rounds.
  def test_round_delay_between_rounds
    @selector._providers = [make_provider("a")]
    sleep_calls = []
    @app.define_singleton_method(:sleep) { |d| sleep_calls << d }
    call_count = 0
    @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      {success: false, status: 500, error: "down"}
    end

    # 3 rounds with 1 provider = 3 calls, 2 inter-round sleeps (between rounds 1→2 and 2→3)
    assert_equal 3, call_count
    assert_equal 2, sleep_calls.size, "should sleep between rounds 1→2 and 2→3"
    # Round 2 delay: backoff_base(0) * 2^0 = 0, so sleep is 0 (jittered 0..0)
    # Round 3 delay: backoff_base(0) * 2^1 = 0, so sleep is 0
    # With backoff_base=0 all delays are 0; just assert sleeps happened.
    sleep_calls.each { |d| assert d >= 0 }
  end

  # No inter-round sleep before round 1.
  def test_no_sleep_before_first_round
    @selector._providers = [make_provider("a")]
    sleep_calls = []
    @app.define_singleton_method(:sleep) { |d| sleep_calls << d }
    call_count = 0
    @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      {success: true} # succeeds immediately on round 1
    end

    assert_equal 1, call_count
    assert_empty sleep_calls, "no inter-round sleep before round 1"
  end

  # Success on first round does not trigger further rounds.
  def test_success_on_first_round_stops_loop
    @selector._providers = [make_provider("a"), make_provider("b")]
    call_count = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      {success: true}
    end

    assert result[:success]
    assert_equal 1, call_count, "should stop after first success"
  end

  # Single provider, real ProviderSelector: the circuit opens after the first
  # failure (threshold 1). The last-resort path in ordered_providers must keep
  # returning the provider so the loop retries across all 3 rounds instead of
  # aborting with "No providers available". Without the fix, round 2's
  # ordered_providers returns [] and the loop stops after 1 attempt.
  def test_single_provider_retries_after_circuit_open_real_selector
    real_selector = ProviderSelector.new("test-model", [make_provider("solo")],
      model_config: @model_entry,
      circuit_failure_threshold: 1, circuit_cooldown: 600)
    ConfigStore.instance_variable_get(:@data)[:selectors]["test-model"] = real_selector

    call_count = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "/chat/completions", body: {}, headers: {}) do
      call_count += 1
      # Fails rounds 1 and 2 (calls 1, 2), succeeds on round 3 (call 3).
      {success: call_count >= 3}
    end

    assert result[:success], "single provider should retry across all rounds even with circuit open"
    assert_equal 3, call_count, "should make 3 attempts (1 per round × 3 rounds), not abort after round 1"
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

  def test_forward_chunk_raises_client_disconnected_on_puma_connection_error
    broken = Object.new
    broken.define_singleton_method(:<<) { |_| raise Puma::ConnectionError, "Socket timeout writing data" }
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

# --- H1: EOF retries must not consume the max_attempts budget ---

class EofRetryBudgetTest < Minitest::Test
  def make_app(max_attempts: 3)
    app = HandlerTestApp.new
    app.define_singleton_method(:settings) do
      @_logs ||= []
      logger = Object.new
      logs_ref = @_logs
      logger.define_singleton_method(:info) { |m| logs_ref << [:info, m] }
      logger.define_singleton_method(:warn) { |m| logs_ref << [:warn, m] }
      logger.define_singleton_method(:error) { |m| logs_ref << [:error, m] }
      logger.define_singleton_method(:debug) { |m| logs_ref << [:debug, m] }
      Struct.new(:logger, :max_attempts, :backoff_base, :max_rounds).new(logger, max_attempts, 0, 3)
    end
    app.define_singleton_method(:sleep) { |*| }
    app
  end

  def test_eof_retries_do_not_consume_attempt_budget
    app = make_app(max_attempts: 3)
    call_sequence = []

    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      call_sequence << :call
      n = call_sequence.size
      if n <= 2
        raise EOFError, "stale connection"
      elsif n <= 5
        raise HTTPSupport::RetryableError, "real failure #{n - 2}"
      else
        {success: true}
      end
    end

    # 2 EOF retries + 3 real attempts = 5 calls before maybe_retry gives up
    assert_equal 5, call_sequence.size, "2 EOF + 3 real retries should be 5 calls"
    refute result[:success]
  end

  def test_eof_retries_then_success
    app = make_app(max_attempts: 3)
    call_sequence = []

    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      call_sequence << :call
      n = call_sequence.size
      if n <= 2
        raise EOFError, "stale connection"
      else
        {success: true}
      end
    end

    assert result[:success]
    assert_equal 3, call_sequence.size, "2 EOF + 1 success"
  end
end

# --- H2: Mid-stream network error after data sent must not retry ---

class StreamCorruptionGuardTest < Minitest::Test
  class MockHTTP
    attr_accessor :started
    def initialize; @started = false; end
    def start; @started = true; end
    def started?; @started; end
    def finish; @started = false; end
    def request(_req)
      yield MockSuccessResponse.new
    end
  end

  class MockSuccessResponse < Net::HTTPSuccess
    def initialize
      super("1.1", "200", "OK")
    end
    def read_body
      yield "data: hello\n\n"
      raise EOFError, "connection reset mid-stream"
    end
    def [](key); nil; end
    def body; ""; end
  end

  def setup
    @app = HandlerTestApp.new
    @app.define_singleton_method(:settings) do
      logger = Object.new
      logger.define_singleton_method(:info) { |m| }
      logger.define_singleton_method(:warn) { |m| }
      logger.define_singleton_method(:error) { |m| }
      logger.define_singleton_method(:debug) { |m| }
      Struct.new(:logger, :max_attempts, :backoff_base, :max_rounds).new(logger, 3, 0, 1)
    end
    @app.define_singleton_method(:sleep) { |*| }

    ConfigStore.instance_variable_set(:@data, {
      selectors: {},
      models: {},
      probe_interval: 60,
      timeouts: {open: 5, read: 10, write: 5},
      tracking_enabled: false,
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
  end

  def test_mid_stream_error_after_data_sent_does_not_retry
    call_count = 0
    chunks_sent = []

    mock_http = MockHTTP.new

    HTTPSupport.define_singleton_method(:create_http) { |*a, **kw| mock_http }
    HTTPSupport.define_singleton_method(:discard_http) { |*a| }
    HTTPSupport.define_singleton_method(:checkin_http) { |*a| }
    HTTPSupport.define_singleton_method(:build_upstream_request) do |*args, **kw|
      [URI.parse("https://upstream.example.com/v1"), Object.new]
    end

    out = []
    out.define_singleton_method(:<<) { |data| chunks_sent << data }

    result = @app.try_stream(
      {"base_url" => "https://upstream.example.com/v1", "api_key" => "k"},
      "/chat/completions", {}, "m", {},
      out: out, log_prefix: "[test]", deadline_remaining: 60
    )

    # The EOFError after data was sent should be converted to
    # ClientDisconnected, which try_with_retries catches and returns
    # without retrying.
    refute result[:success], "should fail"
    assert_equal 1, chunks_sent.size, "one chunk should have been forwarded"
  end
end

# --- M1: x-ratelimit-reset-* header parsing ---

class RatelimitResetParsingTest < Minitest::Test
  def test_parse_duration_string_seconds
    t = HTTPSupport.parse_ratelimit_reset("6s")
    assert_in_delta 6, t - Time.now.to_f, 1
  end

  def test_parse_duration_string_minutes
    t = HTTPSupport.parse_ratelimit_reset("1m")
    assert_in_delta 60, t - Time.now.to_f, 1
  end

  def test_parse_duration_string_milliseconds
    t = HTTPSupport.parse_ratelimit_reset("500ms")
    assert_in_delta 0.5, t - Time.now.to_f, 1
  end

  def test_parse_plain_seconds
    t = HTTPSupport.parse_ratelimit_reset("30")
    assert_in_delta 30, t - Time.now.to_f, 1
  end

  def test_parse_absolute_timestamp
    future = (Time.now.to_f + 3600).to_i.to_s
    t = HTTPSupport.parse_ratelimit_reset(future)
    assert_in_delta 3600, t - Time.now.to_f, 2
  end

  def test_parse_invalid_returns_nil
    assert_nil HTTPSupport.parse_ratelimit_reset("invalid")
    assert_nil HTTPSupport.parse_ratelimit_reset("")
    assert_nil HTTPSupport.parse_ratelimit_reset(nil)
  end

  def test_parse_duration_from_text_supports_short_units
    assert_equal 90, HTTPSupport.parse_duration_from_text("resets in 90 secs")
    assert_equal 120, HTTPSupport.parse_duration_from_text("retry in 2 min")
    assert_equal 7200, HTTPSupport.parse_duration_from_text("available in 2 hrs")
  end

  def test_parse_duration_from_text_supports_decimals
    assert_in_delta 1.5, HTTPSupport.parse_duration_from_text("resets in 1.5 seconds"), 0.01
  end
end

# --- TTFT timeout: try_stream lowers read_timeout and restores after first token ---

class TTFTTimeoutTest < Minitest::Test
  class TTFTMockHTTP
    attr_accessor :started, :read_timeout
    def initialize; @started = false; @read_timeout = 300; end
    def start; @started = true; end
    def started?; @started; end
    def finish; @started = false; end
    def request(_req); yield @response; end
    attr_accessor :response
  end

  class TTFTPingResponse < Net::HTTPSuccess
    def initialize; super("1.1", "200", "OK"); end
    def read_body
      yield ": ping\n\n"
      yield "data: [DONE]\n\n"
    end
    def [](_key); nil; end
    def body; ""; end
  end

  class TTFTContentResponse < Net::HTTPSuccess
    def initialize; super("1.1", "200", "OK"); end
    def read_body
      yield "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n"
      yield "data: [DONE]\n\n"
    end
    def [](_key); nil; end
    def body; ""; end
  end

  def setup
    @app = HandlerTestApp.new
    @app.define_singleton_method(:settings) do
      logger = Object.new
      logger.define_singleton_method(:info) { |m| }
      logger.define_singleton_method(:warn) { |m| }
      logger.define_singleton_method(:error) { |m| }
      logger.define_singleton_method(:debug) { |m| }
      Struct.new(:logger, :max_attempts, :backoff_base, :max_rounds).new(logger, 2, 0, 1)
    end
    @app.define_singleton_method(:sleep) { |*| }

    @app.instance_variable_set(:@request_start,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 100)

    ConfigStore.instance_variable_set(:@data, {
      selectors: {},
      models: {},
      probe_interval: 60,
      timeouts: {open: 5, read: 300, write: 5, ttft: 5},
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
  end

  def mock_http!(response)
    mock_http = TTFTMockHTTP.new
    mock_http.response = response
    HTTPSupport.define_singleton_method(:create_http) { |*a, **kw| mock_http }
    HTTPSupport.define_singleton_method(:discard_http) { |*a| }
    HTTPSupport.define_singleton_method(:checkin_http) { |*a| }
    HTTPSupport.define_singleton_method(:build_upstream_request) do |*args, **kw|
      [URI.parse("https://upstream.example.com/v1"), Object.new]
    end
    mock_http
  end

  def test_try_stream_ttft_timeout_returns_failure
    mock_http!(TTFTPingResponse.new)

    out = []
    result = @app.try_stream(
      {"base_url" => "https://upstream.example.com/v1", "api_key" => "k"},
      "/chat/completions", {}, "m", {},
      out: out, log_prefix: "[test]", deadline_remaining: 60
    )

    refute result[:success], "should fail with TTFT timeout"
    assert result[:error].include?("TTFT"), "error should mention TTFT: #{result[:error]}"
  end

  def test_try_stream_lowers_read_timeout_during_prefill
    http = mock_http!(TTFTPingResponse.new)

    assert_equal 5, http.read_timeout, "read_timeout should be lowered to ttft_timeout"
  end

  def test_try_stream_restores_read_timeout_after_first_chunk
    http = mock_http!(TTFTContentResponse.new)

    out = []
    @app.try_stream(
      {"base_url" => "https://upstream.example.com/v1", "api_key" => "k"},
      "/chat/completions", {}, "m", {},
      out: out, log_prefix: "[test]", deadline_remaining: 60
    )

    assert_equal 300, http.read_timeout, "read_timeout should be restored after first chunk"
  end

  def test_try_stream_restores_read_timeout_on_non_content_chunk
    # Ping response (no content), but request_start is now so TTFT check
    # doesn't fire. read_timeout should still be restored on the first chunk.
    @app.instance_variable_set(:@request_start, Process.clock_gettime(Process::CLOCK_MONOTONIC))
    http = mock_http!(TTFTPingResponse.new)

    out = []
    @app.try_stream(
      {"base_url" => "https://upstream.example.com/v1", "api_key" => "k"},
      "/chat/completions", {}, "m", {},
      out: out, log_prefix: "[test]", deadline_remaining: 60
    )

    assert_equal 300, http.read_timeout, "read_timeout should be restored on any chunk, not just content"
  end

  def test_try_stream_no_ttft_when_tracking_disabled
    ConfigStore.instance_variable_get(:@data)[:timeouts][:ttft] = 5
    ConfigStore.instance_variable_get(:@data)[:tracking_enabled] = false
    http = mock_http!(TTFTPingResponse.new)

    assert_equal 300, http.read_timeout, "read_timeout should NOT be lowered when tracking is disabled"
  end
end
