# frozen_string_literal: true

require_relative "test_helper"

class TestProviderSelector < Minitest::Test
  def test_persist_active_provider_logs_failure
    require_relative "../lib/config_store"
    captured = []
    logger = Class.new(NullLogger) do
      define_method(:warn) { |m| captured << m }
    end.new

    # Force the YAML loader to raise.
    ConfigStore.singleton_class.class_eval do
      alias_method :__orig_load_yaml, :load_yaml_file
      define_method(:load_yaml_file) { |*_args| raise Errno::ENOENT, "stubbed" }
    end

    ProviderSelector.persist_active_provider("test-model", 0, logger: logger)

    refute_empty captured
    assert captured.first.include?("test-model"), "log must include model name: #{captured.inspect}"
    assert captured.first.include?("Errno::ENOENT"), "log must include exception class: #{captured.inspect}"
  ensure
    ConfigStore.singleton_class.class_eval do
      if method_defined?(:__orig_load_yaml) || private_method_defined?(:__orig_load_yaml)
        alias_method :load_yaml_file, :__orig_load_yaml
        remove_method :__orig_load_yaml
      end
    end
  end

  def test_provider_stats_tracks_last_success_at
    selector
    @selector.record_success("prov_a")
    sleep(0.01)
    @selector.record_success("prov_a")

    stats = @selector.provider_stats["prov_a"]
    refute_nil stats[:last_success_at], "last_success_at must be set"
    assert stats[:last_success_age_seconds] >= 0
    assert stats[:last_success_age_seconds] < 5, "should be fresh, got #{stats[:last_success_age_seconds]}"

    # Provider that's never succeeded gets nil
    other = @selector.provider_stats["prov_b"]
    assert_nil other[:last_success_at]
    assert_nil other[:last_success_age_seconds]
  end

  def setup
    @providers = [
      {"provider" => "prov_a", "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka"}.freeze,
      {"provider" => "prov_b", "model" => "m-b", "base_url" => "https://b.example.com/v1", "api_key" => "kb"}.freeze
    ].freeze
    @model_config = {"name" => "test-model", "providers" => [
      {"provider" => "prov_a", "model" => "m-a", "primary" => true},
      {"provider" => "prov_b", "model" => "m-b"}
    ]}
  end

  def selector
    @selector ||= ProviderSelector.new("test-model", @providers, model_config: @model_config)
  end

  def test_initial_active_index_from_primary
    assert_equal 0, selector.instance_variable_get(:@active_index)
  end

  def test_initial_active_index_without_primary
    config = {"name" => "t", "providers" => [
      {"provider" => "prov_a", "model" => "m-a"},
      {"provider" => "prov_b", "model" => "m-b"}
    ]}
    s = ProviderSelector.new("t", @providers, model_config: config)
    assert_equal 0, s.instance_variable_get(:@active_index)
  end

  def test_active_provider_name
    assert_equal "prov_a", selector.active_provider_name
  end

  def test_ordered_providers_returns_active_first
    ordered = selector.ordered_providers
    assert_equal "prov_a", ordered[0]["provider"]
  end

  def test_ordered_providers_cached
    ordered1 = selector.ordered_providers
    ordered2 = selector.ordered_providers
    assert_same ordered1, ordered2
  end

  def test_update_metrics_invalidates_cache
    ordered1 = selector.ordered_providers
    selector.update_metrics("prov_a", 1.0, 50.0)
    ordered2 = selector.ordered_providers
    refute_same ordered1, ordered2
  end

  def test_probe_finished_invalidates_cache
    ordered1 = selector.ordered_providers
    selector.probe_finished
    ordered2 = selector.ordered_providers
    refute_same ordered1, ordered2
  end

  def test_score_from_avg_ttft_saturation
    avg = {avg_ttft: 2.0, avg_tps: 100.0, sample_count: 5}
    score = selector.send(:score_from_avg, avg)
    ttft_score = [4.0 / 2.0, 1.0].min
    tps_score = [100.0 / 100.0, 3.0].min
    expected = ttft_score * 0.5 + tps_score * 0.5
    assert_in_delta expected, score, 0.001
  end

  def test_score_from_avg_ttft_cap
    avg = {avg_ttft: 1.0, avg_tps: 50.0, sample_count: 3}
    score = selector.send(:score_from_avg, avg)
    ttft_score = 1.0
    tps_score = [50.0 / 100.0, 3.0].min
    expected = ttft_score * 0.5 + tps_score * 0.5
    assert_in_delta expected, score, 0.001
  end

  def test_score_from_avg_nil_returns_neg_infinity
    score = selector.send(:score_from_avg, nil)
    assert_equal(-Float::INFINITY, score)
  end

  def test_score_from_avg_tps_cap
    avg = {avg_ttft: 4.0, avg_tps: 500.0, sample_count: 5}
    score = selector.send(:score_from_avg, avg)
    tps_score = [500.0 / 100.0, 3.0].min
    assert_equal 3.0, tps_score
    expected = 1.0 * 0.5 + 3.0 * 0.5
    assert_in_delta expected, score, 0.001
  end

  def test_evaluate_and_select_switches_on_better_provider
    3.times { selector.update_metrics("prov_a", 5.0, 10.0) }
    3.times { selector.update_metrics("prov_b", 0.5, 150.0) }

    selector.evaluate_and_select(NullLogger.new, auto_switch: true)

    assert_equal 1, selector.instance_variable_get(:@active_index)
  end

  def test_evaluate_and_select_hysteresis_prevents_flapping
    3.times { selector.update_metrics("prov_a", 1.0, 100.0) }
    3.times { selector.update_metrics("prov_b", 0.9, 105.0) }

    selector.evaluate_and_select(NullLogger.new, auto_switch: true)

    assert_equal 0, selector.instance_variable_get(:@active_index)
  end

  def test_evaluate_and_select_no_switch_below_min_samples
    3.times { selector.update_metrics("prov_a", 5.0, 10.0) }
    selector.update_metrics("prov_b", 0.5, 150.0)

    selector.evaluate_and_select(NullLogger.new, auto_switch: true)

    assert_equal 0, selector.instance_variable_get(:@active_index)
  end

  def test_record_and_maybe_probe
    refute selector.record_and_maybe_probe(3)
    refute selector.record_and_maybe_probe(3)
    assert selector.record_and_maybe_probe(3)
    selector.probe_finished
    refute selector.record_and_maybe_probe(3)
  end

  def test_other_providers
    others = selector.other_providers
    assert_equal 1, others.length
    assert_equal "prov_b", others[0]["provider"]
  end

  def test_active_metrics
    selector.update_metrics("prov_a", 2.0, 80.0)
    selector.update_metrics("prov_a", 1.0, 90.0)
    metrics = selector.active_metrics
    assert_in_delta 1.5, metrics[:ttft], 0.01
    assert_in_delta 85.0, metrics[:tps], 0.01
    assert_equal 2, metrics[:sample_count]
  end

  def test_active_metrics_nil_when_no_data
    assert_nil selector.active_metrics
  end

  def test_persist_active_index_writes_primary_flag
    mock_path = File.join(__dir__, "tmp_config_#{Process.pid}.yaml")

    begin
      File.write(mock_path, YAML.dump(MOCK_CONFIG))
      old_method = ProviderSelector.method(:config_path)
      ProviderSelector.define_singleton_method(:config_path) { mock_path }

      selector.persist_active_index

      raw = YAML.unsafe_load_file(mock_path)
      model = raw["models"].find { |m| m["name"] == "test-model" }
      assert model["providers"][0]["primary"]
    ensure
      ProviderSelector.define_singleton_method(:config_path, old_method)
      File.delete(mock_path) if File.exist?(mock_path)
    end
  end

  def test_prune_stale_samples
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config, sample_window: 300)
    s.update_metrics("prov_a", 1.0, 50.0)
    samples = s.instance_variable_get(:@samples)["prov_a"]
    samples[0][:timestamp] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 700
    s.update_metrics("prov_a", 2.0, 60.0)
    samples = s.instance_variable_get(:@samples)["prov_a"]
    assert_equal 1, samples.length
  end

  def test_sample_window_configurable
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config, sample_window: 120)
    s.update_metrics("prov_a", 1.0, 50.0)
    samples = s.instance_variable_get(:@samples)["prov_a"]
    samples[0][:timestamp] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 200
    s.update_metrics("prov_a", 2.0, 60.0)
    samples = s.instance_variable_get(:@samples)["prov_a"]
    assert_equal 1, samples.length
  end

  def test_max_samples_enforced
    102.times { |i| selector.update_metrics("prov_a", 1.0, 50.0 + i) }
    samples = selector.instance_variable_get(:@samples)["prov_a"]
    assert_equal 100, samples.length
  end

  # --- circuit breaker cooldown tests ---

  def test_circuit_auto_closes_after_cooldown
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config,
      circuit_failure_threshold: 2, circuit_cooldown: 0.2)

    # Record failures to open circuit
    s.record_failure("prov_a")
    s.record_failure("prov_a")

    circuits = s.instance_variable_get(:@circuits)
    refute_nil circuits["prov_a"].opened_at, "circuit should be open after threshold failures"

    # Before cooldown expires, circuit_open? should return true
    assert s.send(:circuit_open?, "prov_a"), "circuit should be open before cooldown"

    # Wait for cooldown
    sleep 0.3

    # After cooldown, circuit should auto-close
    refute s.send(:circuit_open?, "prov_a"), "circuit should auto-close after cooldown"
    assert_equal 0, circuits["prov_a"].failures, "failures should reset after cooldown"
    assert_nil circuits["prov_a"].opened_at, "opened_at should be nil after cooldown"
  end

  def test_circuit_stays_open_before_cooldown
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config,
      circuit_failure_threshold: 2, circuit_cooldown: 60)

    s.record_failure("prov_a")
    s.record_failure("prov_a")

    assert s.send(:circuit_open?, "prov_a"), "circuit should be open"
    circuits = s.instance_variable_get(:@circuits)
    refute_nil circuits["prov_a"].opened_at
  end

  def test_circuit_open_returns_false_when_not_opened
    refute selector.send(:circuit_open?, "prov_a"), "circuit should not be open initially"
  end

  def test_record_failure_opens_circuit_at_threshold
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config,
      circuit_failure_threshold: 3, circuit_cooldown: 60)

    s.record_failure("prov_a")
    s.record_failure("prov_a")
    refute s.send(:circuit_open?, "prov_a"), "should not be open below threshold"

    s.record_failure("prov_a")
    assert s.send(:circuit_open?, "prov_a"), "should open at threshold"
  end

  def test_circuit_cooldown_resets_opened_at_to_nil
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config,
      circuit_failure_threshold: 1, circuit_cooldown: 0.1)

    s.record_failure("prov_a")
    assert s.send(:circuit_open?, "prov_a")

    sleep 0.2

    # check_circuit_open should reset the state
    result = s.send(:check_circuit_open, "prov_a")
    refute result
    circuits = s.instance_variable_get(:@circuits)
    assert_nil circuits["prov_a"].opened_at
    assert_equal 0, circuits["prov_a"].failures
  end

  # --- quota pause expiry tests ---

  def test_quota_pause_expires_after_duration
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config)
    now = Time.now.to_f

    # Set a quota pause that expires soon
    s.quota_pause!("prov_a", now + 0.2, reason: "rate limited")

    assert s.quota_paused?("prov_a"), "should be paused initially"

    sleep 0.3

    refute s.quota_paused?("prov_a"), "should not be paused after expiry"
  end

  def test_quota_pause_still_active_before_expiry
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config)
    now = Time.now.to_f

    s.quota_pause!("prov_a", now + 60, reason: "quota exceeded")

    assert s.quota_paused?("prov_a"), "should be paused before expiry"
    pauses = s.instance_variable_get(:@quota_pauses)
    refute_nil pauses["prov_a"].paused_until
    assert_equal "quota exceeded", pauses["prov_a"].reason
  end

  def test_check_quota_paused_returns_false_when_not_paused
    refute selector.send(:check_quota_paused, "prov_a"), "should not be paused initially"
  end

  def test_check_quota_paused_clears_expired_pause
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config)
    now = Time.now.to_f
    s.quota_pause!("prov_a", now + 0.1, reason: "test")

    sleep 0.2

    result = s.send(:check_quota_paused, "prov_a")
    refute result, "should return false after expiry"
    pauses = s.instance_variable_get(:@quota_pauses)
    assert_nil pauses["prov_a"].paused_until, "paused_until should be cleared"
    assert_nil pauses["prov_a"].reason, "reason should be cleared"
  end

  def test_quota_pause_does_not_expire_when_future
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config)
    now = Time.now.to_f
    s.quota_pause!("prov_b", now + 3600, reason: "long pause")

    result = s.send(:check_quota_paused, "prov_b")
    assert result, "should still be paused"
  end

  def test_ordered_providers_excludes_circuit_open
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config,
      circuit_failure_threshold: 1, circuit_cooldown: 60)

    # Open circuit for active provider (prov_a)
    s.record_failure("prov_a")

    ordered = s.ordered_providers
    refute ordered.any? { |p| p["provider"] == "prov_a" }, "circuit-open provider should be excluded"
    assert_equal "prov_b", ordered.first["provider"]
  end

  def test_ordered_providers_excludes_quota_paused
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config)
    now = Time.now.to_f

    # Pause the active provider
    s.quota_pause!("prov_a", now + 60, reason: "exhausted")

    ordered = s.ordered_providers
    refute ordered.any? { |p| p["provider"] == "prov_a" }, "quota-paused provider should be excluded"
    assert_equal "prov_b", ordered.first["provider"]
  end
end
