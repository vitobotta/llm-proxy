# frozen_string_literal: true

require_relative "test_helper"

class NullLogger
  def info(_msg); end
  def warn(_msg); end
  def error(_msg); end
  def debug(_msg); end
end

class TestProviderSelector < Minitest::Test
  def setup
    @providers = [
      { "provider" => "prov_a", "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka" }.freeze,
      { "provider" => "prov_b", "model" => "m-b", "base_url" => "https://b.example.com/v1", "api_key" => "kb" }.freeze
    ].freeze
    @model_config = { "name" => "test-model", "providers" => [
      { "provider" => "prov_a", "model" => "m-a", "primary" => true },
      { "provider" => "prov_b", "model" => "m-b" }
    ]}
  end

  def selector
    @selector ||= ProviderSelector.new("test-model", @providers, model_config: @model_config)
  end

  def test_initial_active_index_from_primary
    assert_equal 0, selector.instance_variable_get(:@active_index)
  end

  def test_initial_active_index_without_primary
    config = { "name" => "t", "providers" => [
      { "provider" => "prov_a", "model" => "m-a" },
      { "provider" => "prov_b", "model" => "m-b" }
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
    avg = { avg_ttft: 2.0, avg_tps: 100.0, sample_count: 5 }
    score = selector.send(:score_from_avg, avg)
    ttft_score = [4.0 / 2.0, 1.0].min
    tps_score = [100.0 / 100.0, 3.0].min
    expected = ttft_score * 0.5 + tps_score * 0.5
    assert_in_delta expected, score, 0.001
  end

  def test_score_from_avg_ttft_cap
    avg = { avg_ttft: 1.0, avg_tps: 50.0, sample_count: 3 }
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
    avg = { avg_ttft: 4.0, avg_tps: 500.0, sample_count: 5 }
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
      # Monkey-patch CONFIG_PATH temporarily
      old_path = ProviderSelector.const_get(:CONFIG_PATH)
      ProviderSelector.send(:remove_const, :CONFIG_PATH)
      ProviderSelector.const_set(:CONFIG_PATH, mock_path)

      selector.persist_active_index

      raw = YAML.unsafe_load_file(mock_path)
      model = raw["models"].find { |m| m["name"] == "test-model" }
      assert model["providers"][0]["primary"]
    ensure
      ProviderSelector.send(:remove_const, :CONFIG_PATH) if ProviderSelector.const_defined?(:CONFIG_PATH)
      ProviderSelector.const_set(:CONFIG_PATH, old_path)
      File.delete(mock_path) if File.exist?(mock_path)
    end
  end

  def test_prune_stale_samples
    selector.update_metrics("prov_a", 1.0, 50.0)
    samples = selector.instance_variable_get(:@samples)["prov_a"]
    samples[0][:timestamp] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 700
    selector.update_metrics("prov_a", 2.0, 60.0)
    samples = selector.instance_variable_get(:@samples)["prov_a"]
    assert_equal 1, samples.length
  end

  def test_max_samples_enforced
    102.times { |i| selector.update_metrics("prov_a", 1.0, 50.0 + i) }
    samples = selector.instance_variable_get(:@samples)["prov_a"]
    assert_equal 100, samples.length
  end
end
