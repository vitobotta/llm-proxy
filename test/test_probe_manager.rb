# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/probe_manager"

class TestProbeManager < Minitest::Test
  class FakeSelector
    attr_reader :metrics_calls, :evaluate_calls, :probe_finished_called

    def initialize(others)
      @others = others
      @metrics_calls = []
      @evaluate_calls = 0
      @probe_finished_called = false
      @paused = {}
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
