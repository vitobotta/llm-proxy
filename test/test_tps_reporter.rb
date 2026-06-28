# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/tps_reporter"

# Capturing logger that appends to a shared array. Defined at top level so
# the array is accessible from the logger instance's info method.
class CapturingLogger < NullLogger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def info(msg)
    @lines << msg
  end
end

class TestTpsReporter < Minitest::Test
  def setup
    @logger = CapturingLogger.new
    TpsReporter.stop! if TpsReporter.running?
  end

  def teardown
    TpsReporter.stop! if TpsReporter.running?
  end

  def test_start_and_stop_lifecycle
    TpsReporter.start!(logger: @logger, interval: 1)
    assert TpsReporter.running?
    TpsReporter.stop!
    refute TpsReporter.running?
  end

  def test_start_with_zero_interval_does_not_start
    TpsReporter.start!(logger: @logger, interval: 0)
    refute TpsReporter.running?
  end

  def test_start_with_nil_interval_does_not_start
    TpsReporter.start!(logger: @logger, interval: nil)
    refute TpsReporter.running?
  end

  def test_start_with_negative_interval_does_not_start
    TpsReporter.start!(logger: @logger, interval: -1)
    refute TpsReporter.running?
  end

  def make_selector_with_samples(provider_name = "prov_a")
    providers = [
      {"provider" => provider_name, "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka"}.freeze
    ].freeze
    model_config = {"name" => "test-model", "providers" => [{"provider" => provider_name, "model" => "m-a", "primary" => true}]}
    ProviderSelector.new("test-model", providers, model_config: model_config)
  end

  def stub_config_store(selector, model_config)
    ConfigStore.define_singleton_method(:selectors) { {"test-model" => selector} }
    ConfigStore.define_singleton_method(:models) { {"test-model" => model_config} }
  end

  def test_report_skips_idle_providers
    providers = [
      {"provider" => "prov_a", "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka"}.freeze,
      {"provider" => "prov_b", "model" => "m-b", "base_url" => "https://b.example.com/v1", "api_key" => "kb"}.freeze
    ].freeze
    model_config = {"name" => "test-model", "providers" => [
      {"provider" => "prov_a", "model" => "m-a", "primary" => true},
      {"provider" => "prov_b", "model" => "m-b"}
    ]}

    selector = ProviderSelector.new("test-model", providers, model_config: model_config)
    selector.update_metrics("prov_a", 1.0, 100.0, tokens: 100)

    stub_config_store(selector, model_config)
    TpsReporter.instance_variable_set(:@logger, @logger)
    TpsReporter.report(activity_window: 10, eval_window: 60)

    tps_lines = @logger.lines.select { |l| l.is_a?(String) && l.include?("[tps]") }
    assert_equal 1, tps_lines.length, "only active provider should be logged"
    assert tps_lines.first.include?("test-model/prov_a")
  end

  def test_report_includes_aggregate_when_available
    selector = make_selector_with_samples
    selector.update_metrics("prov_a", 1.0, 100.0, tokens: 100)

    stub_config_store(selector, {"name" => "test-model", "providers" => [{"provider" => "prov_a", "model" => "m-a", "primary" => true}]})
    TpsReporter.instance_variable_set(:@logger, @logger)
    TpsReporter.report(activity_window: 10, eval_window: 60)

    tps_lines = @logger.lines.select { |l| l.is_a?(String) && l.include?("[tps]") }
    refute_empty tps_lines
    assert tps_lines.first.include?("tps=100.0"), "should include aggregate: #{tps_lines.first}"
    refute tps_lines.first.include?("*"), "aggregate should not have fallback marker: #{tps_lines.first}"
  end

  def test_report_uses_median_fallback_without_tokens
    selector = make_selector_with_samples
    selector.update_metrics("prov_a", 1.0, 100.0)  # no tokens/elapsed

    stub_config_store(selector, {"name" => "test-model", "providers" => [{"provider" => "prov_a", "model" => "m-a", "primary" => true}]})
    TpsReporter.instance_variable_set(:@logger, @logger)
    TpsReporter.report(activity_window: 10, eval_window: 60)

    tps_lines = @logger.lines.select { |l| l.is_a?(String) && l.include?("[tps]") }
    refute_empty tps_lines
    assert tps_lines.first.include?("tps=100.0*"), "should use median with fallback marker: #{tps_lines.first}"
  end

  def test_log_line_format
    TpsReporter.instance_variable_set(:@logger, @logger)
    m = {aggregate: 150.0, median: 140.0, p90: 180.0, n: 5, total_tokens: 750}
    TpsReporter.send(:log_line, "test-model", "prov_a", m)

    assert_equal 1, @logger.lines.length
    line = @logger.lines.first
    assert line.include?("[tps] test-model/prov_a")
    assert line.include?("tps=150.0")
    assert line.include?("p50=140.0")
    assert line.include?("p90=180.0")
    assert line.include?("n=5")
    assert line.include?("tokens=750")
  end
end
