# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/state_persistence"
require "tmpdir"
require "json"

class TestStatePersistence < Minitest::Test
  def setup
    @providers = [
      { "provider" => "prov_a", "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka" }.freeze,
      { "provider" => "prov_b", "model" => "m-b", "base_url" => "https://b.example.com/v1", "api_key" => "kb" }.freeze
    ].freeze
    @model_config = { "name" => "test-model", "providers" => [
      { "provider" => "prov_a", "model" => "m-a", "primary" => true },
      { "provider" => "prov_b", "model" => "m-b" }
    ]}
    @tmpdir = Dir.mktmpdir("state_persistence_test_")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def selector
    @selector ||= ProviderSelector.new("test-model", @providers, model_config: @model_config)
  end

  def test_to_state_includes_active_provider
    state = selector.to_state
    assert_equal "prov_a", state[:active_provider]
  end

  def test_to_state_includes_samples
    selector.update_metrics("prov_a", 1.5, 80.0)
    state = selector.to_state
    samples = state[:samples]["prov_a"]
    refute_nil samples
    assert_equal 1, samples.length
    assert_equal 1.5, samples.first["ttft"]
    assert_equal 80.0, samples.first["tps"]
    assert samples.first["ts"].is_a?(Float)
  end

  def test_to_state_includes_circuits
    selector.record_failure("prov_b")
    selector.record_failure("prov_b")
    selector.record_failure("prov_b")
    state = selector.to_state
    circuit = state[:circuits]["prov_b"]
    refute_nil circuit
    assert_equal 3, circuit[:failures]
    refute_nil circuit[:opened_at]
  end

  def test_restore_state_restores_active_provider
    selector.update_metrics("prov_b", 0.5, 120.0)
    selector.update_metrics("prov_b", 0.6, 110.0)

    state = {
      "active_provider" => "prov_b",
      "samples" => {
        "prov_b" => [
          { "ttft" => 0.5, "tps" => 120.0, "ts" => Time.now.to_f - 10 },
          { "ttft" => 0.6, "tps" => 110.0, "ts" => Time.now.to_f - 5 }
        ]
      },
      "circuits" => {},
      "request_count" => 7
    }

    selector.restore_state!(state)
    assert_equal 1, selector.instance_variable_get(:@active_index)
    assert_equal 7, selector.instance_variable_get(:@request_count)
  end

  def test_restore_state_prunes_stale_samples
    old_ts = Time.now.to_f - 200
    state = {
      "active_provider" => "prov_a",
      "samples" => {
        "prov_a" => [
          { "ttft" => 1.0, "tps" => 50.0, "ts" => old_ts }
        ]
      },
      "circuits" => {}
    }

    selector.restore_state!(state)
    samples = selector.instance_variable_get(:@samples)["prov_a"]
    assert_nil samples
  end

  def test_restore_state_expires_old_circuit_breaker
    opened_at = Time.now.to_f - 120
    state = {
      "active_provider" => "prov_a",
      "samples" => {},
      "circuits" => {
        "prov_b" => { "failures" => 3, "opened_at" => opened_at }
      }
    }

    selector.restore_state!(state)
    circuit = selector.instance_variable_get(:@circuits)["prov_b"]
    assert_nil circuit.opened_at
    assert_equal 0, circuit.failures
  end

  def test_restore_state_ignores_unknown_providers
    state = {
      "active_provider" => "prov_unknown",
      "samples" => { "prov_unknown" => [{ "ttft" => 1.0, "ts" => Time.now.to_f }] },
      "circuits" => { "prov_unknown" => { "failures" => 1, "opened_at" => nil } }
    }

    selector.restore_state!(state)
    assert_equal 0, selector.instance_variable_get(:@active_index)
  end

  def test_state_persistence_save_and_load
    selector.update_metrics("prov_a", 1.2, 90.0)

    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      write_state_file("test-model" => selector)
      assert File.exist?(File.join(@tmpdir, "provider_state.json"))

      state = StatePersistence.load
      refute_nil state
      assert_equal StatePersistence::STATE_VERSION, state["version"]
      assert state["saved_at"].is_a?(Float)
      assert state["models"].is_a?(Hash)
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_state_persistence_load_missing_file
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      assert_nil StatePersistence.load
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_state_persistence_load_invalid_version
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      File.write(File.join(@tmpdir, "provider_state.json"), JSON.generate({ "version" => 999, "models" => {} }))
      assert_nil StatePersistence.load
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_round_trip_via_file
    selector.update_metrics("prov_a", 1.0, 100.0)
    selector.record_failure("prov_b")
    selector.record_failure("prov_b")

    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      write_state_file("test-model" => selector)

      new_selector = ProviderSelector.new("test-model", @providers, model_config: @model_config)
      state_data = StatePersistence.load
      new_selector.restore_state!(state_data["models"]["test-model"])

      assert_equal 0, new_selector.instance_variable_get(:@active_index)
      samples = new_selector.instance_variable_get(:@samples)["prov_a"]
      refute_nil samples
      assert_equal 1, samples.length
      assert_equal 1.0, samples.first[:ttft]

      circuit_b = new_selector.instance_variable_get(:@circuits)["prov_b"]
      assert_equal 2, circuit_b.failures
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  private

  def write_state_file(selectors)
    models_state = {}
    selectors.each { |name, sel| models_state[name] = sel.to_state }
    state = {
      "version" => StatePersistence::STATE_VERSION,
      "saved_at" => Time.now.to_f,
      "models" => models_state
    }
    File.write(File.join(@tmpdir, "provider_state.json"), JSON.generate(state))
  end
end
