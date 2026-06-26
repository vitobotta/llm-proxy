# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/probe_manager"
require_relative "../lib/config_store"
require_relative "../lib/metrics"

class TestProbeManager < Minitest::Test
  class FakeSelector
    attr_reader :metrics_calls, :evaluate_calls, :probe_finished_called, :pauses

    def initialize(others)
      @others = others
      @metrics_calls = []
      @evaluate_calls = 0
      @paused = {}
      @pauses = []
      @mutex = Mutex.new
    end

    def other_providers
      @others
    end

    def update_metrics(provider_name, ttft, tps)
      @mutex.synchronize { @metrics_calls << [provider_name, ttft, tps] }
    end

    def evaluate_and_select(_logger, auto_switch:)
      @evaluate_calls += 1
    end

    def probe_finished
      @probe_finished_called = true
    end

    def quota_paused?(provider_name)
      @paused.key?(provider_name)
    end

    def circuit_open?(_provider_name)
      false
    end

    def quota_pause!(name, time, reason: nil)
      @pauses << {name: name, time: time, reason: reason}
      @paused[name] = true
    end
  end

  def setup
    @captured_logs = []
    @logger = Class.new(NullLogger) do
      attr_reader :messages
      def initialize(messages)
        super()
        @messages = messages
      end

      def info(m)
        @messages << [:info, m]
      end

      def error(m)
        @messages << [:error, m]
      end

      def warn(m)
        @messages << [:warn, m]
      end

      def debug(m)
        @messages << [:debug, m]
      end
    end.new(@captured_logs)
  end

  def test_results_aggregated_from_many_concurrent_probes
    n = 20
    others = (0...n).map { |i| {"provider" => "p#{i}", "model" => "m#{i}", "base_url" => "https://example.invalid/v1", "api_key" => "k"} }

    # Stub probe_provider to return distinct results, sleeping a bit so threads truly overlap.
    ProbeManager.singleton_class.class_eval do
      alias_method :__orig_probe_provider, :probe_provider
      define_method(:probe_provider) do |provider_config, *_args, **_kw|
        sleep(0.005)
        {ttft: provider_config["provider"][1..].to_f * 0.01, tps: provider_config["provider"][1..].to_f * 10}
      end
    end

    selector = FakeSelector.new(others)
    thread = ProbeManager.launch(selector, "test-model", "chat/completions", {}, timeouts: {open: 1, read: 1, write: 1}, auto_switch: false, logger: @logger)
    thread.join(5) or flunk("probe thread did not finish")

    assert_equal n, selector.metrics_calls.size, "every probe result must be recorded"
    recorded_names = selector.metrics_calls.map(&:first).sort
    expected_names = (0...n).map { |i| "p#{i}" }.sort
    assert_equal expected_names, recorded_names

    assert_equal 1, selector.evaluate_calls
    assert selector.probe_finished_called
  ensure
    ProbeManager.singleton_class.class_eval do
      if method_defined?(:__orig_probe_provider) || private_method_defined?(:__orig_probe_provider)
        alias_method :probe_provider, :__orig_probe_provider
        remove_method :__orig_probe_provider
      end
    end
  end

  def test_global_rate_limit_skips_when_exceeded
    ProbeManager.reset_rate_limiter!
    others = [{"provider" => "p1", "model" => "m", "base_url" => "https://x", "api_key" => "k"}]

    ProbeManager.singleton_class.class_eval do
      alias_method :__orig_probe_provider_rate, :probe_provider
      define_method(:probe_provider) { |*_args, **_kw| {ttft: 0.01, tps: 100.0} }
    end

    sel1 = FakeSelector.new(others)
    sel2 = FakeSelector.new(others)
    sel3 = FakeSelector.new(others)

    # max_per_minute=2; first two launches proceed, third returns nil.
    t1 = ProbeManager.launch(sel1, "m1", "p", {}, timeouts: {open: 1, read: 1, write: 1}, auto_switch: false, logger: @logger, max_per_minute: 2)
    t2 = ProbeManager.launch(sel2, "m2", "p", {}, timeouts: {open: 1, read: 1, write: 1}, auto_switch: false, logger: @logger, max_per_minute: 2)
    t3 = ProbeManager.launch(sel3, "m3", "p", {}, timeouts: {open: 1, read: 1, write: 1}, auto_switch: false, logger: @logger, max_per_minute: 2)

    refute_nil t1
    refute_nil t2
    assert_nil t3, "third launch must be rate-limited"
    [t1, t2].each { |t| t.join(5) }

    # The rate-limited launch must still unstick the selector's @probing flag
    assert sel3.probe_finished_called, "probe_finished must be called on rate-limited skip"

    assert(@captured_logs.any? { |level, msg| msg.is_a?(String) && msg.include?("rate") && msg.include?("m3") }, "rate-limit skip should be logged: #{@captured_logs.inspect}")
  ensure
    ProbeManager.reset_rate_limiter!
    ProbeManager.singleton_class.class_eval do
      if method_defined?(:__orig_probe_provider_rate) || private_method_defined?(:__orig_probe_provider_rate)
        alias_method :probe_provider, :__orig_probe_provider_rate
        remove_method :__orig_probe_provider_rate
      end
    end
  end

  def test_allow_probe_without_limit_is_always_true
    ProbeManager.reset_rate_limiter!
    100.times { assert ProbeManager.allow_probe?(nil) }
    100.times { assert ProbeManager.allow_probe?(0) }
  end

  def test_hung_probe_is_killed_after_deadline
    others = [
      {"provider" => "fast", "model" => "m", "base_url" => "https://example.invalid/v1", "api_key" => "k"},
      {"provider" => "hung", "model" => "m", "base_url" => "https://example.invalid/v1", "api_key" => "k"}
    ]

    ProbeManager.singleton_class.class_eval do
      alias_method :__orig_probe_provider3, :probe_provider
      define_method(:probe_provider) do |provider_config, *_args, **_kw|
        if provider_config["provider"] == "hung"
          sleep(60)
          {ttft: 0.01, tps: 999.0}
        else
          {ttft: 0.05, tps: 50.0}
        end
      end
    end

    selector = FakeSelector.new(others)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    thread = ProbeManager.launch(selector, "test-model", "chat/completions", {}, timeouts: {open: 1, read: 1, write: 1}, auto_switch: false, logger: @logger, deadline_seconds: 1)
    finished = thread.join(10)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute_nil finished, "outer probe thread must complete"
    assert elapsed < 5, "outer probe should finish well under sleep(60), got #{elapsed}s"

    assert selector.probe_finished_called

    by_provider = selector.metrics_calls.group_by(&:first)
    refute_nil by_provider["hung"], "hung probe must still record a result"
    assert_equal Float::INFINITY, by_provider["hung"].first[1], "hung probe should be +Inf ttft"
    refute_nil by_provider["fast"], "fast probe must record real result"

    assert(@captured_logs.any? { |level, msg| level == :warn && msg.include?("hung") && msg.include?("deadline") }, "warn log mentioning hung + deadline expected; got #{@captured_logs.inspect}")
  ensure
    ProbeManager.singleton_class.class_eval do
      if method_defined?(:__orig_probe_provider3) || private_method_defined?(:__orig_probe_provider3)
        alias_method :probe_provider, :__orig_probe_provider3
        remove_method :__orig_probe_provider3
      end
    end
  end

  def test_failing_probe_does_not_abort_other_probes
    others = [
      {"provider" => "ok", "model" => "m", "base_url" => "https://example.invalid/v1", "api_key" => "k"},
      {"provider" => "fail", "model" => "m", "base_url" => "https://example.invalid/v1", "api_key" => "k"}
    ]

    ProbeManager.singleton_class.class_eval do
      alias_method :__orig_probe_provider2, :probe_provider
      define_method(:probe_provider) do |provider_config, *_args, **_kw|
        raise "kaboom" if provider_config["provider"] == "fail"
        {ttft: 0.1, tps: 50.0}
      end
    end

    selector = FakeSelector.new(others)
    thread = ProbeManager.launch(selector, "test-model", "chat/completions", {}, timeouts: {open: 1, read: 1, write: 1}, auto_switch: false, logger: @logger)
    thread.join(5)

    assert selector.probe_finished_called, "probe_finished must run even on inner failure"

    recorded = selector.metrics_calls.map(&:first).sort
    assert_equal ["fail", "ok"], recorded, "both probes (success + failure) should record metrics"

    fail_metric = selector.metrics_calls.find { |name, _, _| name == "fail" }
    assert_equal Float::INFINITY, fail_metric[1], "failing probe recorded as +Inf ttft"

    assert(@captured_logs.any? { |level, msg| level == :error && msg.include?("kaboom") }, "error should be logged: #{@captured_logs.inspect}")
  ensure
    ProbeManager.singleton_class.class_eval do
      if method_defined?(:__orig_probe_provider2) || private_method_defined?(:__orig_probe_provider2)
        alias_method :probe_provider, :__orig_probe_provider2
        remove_method :__orig_probe_provider2
      end
    end
  end
end

class ProbeProviderTest < Minitest::Test
  def setup
    @captured_logs = []
    @logger = Class.new(NullLogger) do
      attr_reader :messages
      def initialize(messages)
        super()
        @messages = messages
      end
      def info(m); @messages << [:info, m]; end
      def error(m); @messages << [:error, m]; end
      def warn(m); @messages << [:warn, m]; end
      def debug(m); @messages << [:debug, m]; end
    end.new(@captured_logs)
    @provider_config = {"provider" => "test_prov", "model" => "m", "base_url" => "https://example.invalid/v1", "api_key" => "k"}
    @selector = TestProbeManager::FakeSelector.new([@provider_config])
    ConfigStore.instance_variable_set(:@data, {quota_pause_default_seconds: 60})
  end

  def test_probe_provider_success_with_usage_data
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stub_streaming(first_token_time: now + 0.1, first_content_time: now + 0.1, last_content_time: now + 0.5, last_any_token_time: now + 0.5, usage_data: {"completion_tokens" => 50, "prompt_tokens" => 10, "completion_time" => 0.5}) do
      result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
      assert result[:tps] && result[:tps] > 0, "tps should be positive, got #{result[:tps]}"
      assert result[:ttft] < Float::INFINITY, "ttft should be finite"
    end
  end

  def test_probe_provider_no_usage_data_returns_nil_tps
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stub_streaming(first_token_time: now + 0.1, usage_data: nil) do
      result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
      assert_nil result[:tps]
      assert result[:ttft] < Float::INFINITY
    end
  end

  def test_probe_provider_success_nil_tps_without_server_timing
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stub_streaming(first_token_time: now + 0.1, first_content_time: now + 0.1, last_content_time: now + 0.5, last_any_token_time: now + 0.5, usage_data: {"completion_tokens" => 50, "prompt_tokens" => 10}) do
      result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
      assert_nil result[:tps], "tps should be nil without server timing (no arrival-window fallback)"
      assert result[:ttft] < Float::INFINITY
    end
  end

  def test_probe_provider_server_ttft_preferred
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stub_streaming(first_token_time: now + 0.5, usage_data: {"completion_tokens" => 50, "completion_time" => 0.5}, perf_metrics: {"server-time-to-first-token" => 0.3}) do
      result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
      assert_in_delta 0.3, result[:ttft], 0.001, "server TTFT should win over arrival value"
      assert result[:tps] && result[:tps] > 0
    end
  end

  def test_probe_provider_error_returns_infinite_ttft
    stub_streaming(error: "HTTP 500: internal server error") do
      result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
      assert_equal Float::INFINITY, result[:ttft]
      assert_nil result[:tps]
    end
  end

  def test_probe_provider_quota_error_pauses_provider
    stub_streaming(error: "HTTP 429: insufficient_quota") do
      result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
      assert_equal Float::INFINITY, result[:ttft]
      assert_equal 1, @selector.pauses.size
      assert_equal "rate_limited", @selector.pauses.first[:reason]
    end
  end

  def test_probe_provider_402_payment_required
    stub_streaming(error: "HTTP 402: payment required") do
      result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
      assert_equal Float::INFINITY, result[:ttft]
      assert_equal 1, @selector.pauses.size
      assert_equal "payment_required", @selector.pauses.first[:reason]
    end
  end

  def test_probe_provider_connection_error_returns_infinite_ttft
    http_mock = Object.new
    http_mock.define_singleton_method(:started?) { false }
    http_mock.define_singleton_method(:start) { raise Errno::ECONNREFUSED, "Connection refused" }

    HTTPSupport.singleton_class.class_eval do
      alias_method :__orig_create_http, :create_http
      define_method(:create_http) { |*_a, **_k| http_mock }
    end

    result = ProbeManager.probe_provider(@provider_config, "/chat/completions", {}, "m", {}, timeouts: {open: 1, read: 1, write: 1}, logger: @logger, selector: @selector)
    assert_equal Float::INFINITY, result[:ttft]
    assert_nil result[:tps]
  ensure
    HTTPSupport.singleton_class.class_eval do
      alias_method :create_http, :__orig_create_http
      remove_method :__orig_create_http
    end
  end

  private

  def stub_streaming(stream_result, &block)
    http_mock = Object.new
    http_mock.define_singleton_method(:started?) { true }
    http_mock.define_singleton_method(:start) {}

    HTTPSupport.singleton_class.class_eval do
      alias_method :__orig_create_http_probe, :create_http
      define_method(:create_http) { |*_a, **_k| http_mock }
    end
    Streaming.singleton_class.class_eval do
      alias_method :__orig_stream_response_probe, :stream_response
      define_method(:stream_response) { |*_a, **_k| stream_result }
    end

    block.call
  ensure
    HTTPSupport.singleton_class.class_eval do
      alias_method :create_http, :__orig_create_http_probe
      remove_method :__orig_create_http_probe
    end
    Streaming.singleton_class.class_eval do
      alias_method :stream_response, :__orig_stream_response_probe
      remove_method :__orig_stream_response_probe
    end
  end
end
