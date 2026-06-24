# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/config_store"
require_relative "../lib/state_persistence"
require "tmpdir"
require "json"

class TestStatePersistence < Minitest::Test
  def setup
    @providers = [
      {"provider" => "prov_a", "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka"}.freeze,
      {"provider" => "prov_b", "model" => "m-b", "base_url" => "https://b.example.com/v1", "api_key" => "kb"}.freeze
    ].freeze
    @model_config = {"name" => "test-model", "providers" => [
      {"provider" => "prov_a", "model" => "m-a", "primary" => true},
      {"provider" => "prov_b", "model" => "m-b"}
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
    assert_equal 3, circuit["failures"]
    refute_nil circuit["opened_at"]
  end

  def test_restore_state_restores_active_provider
    selector.update_metrics("prov_b", 0.5, 120.0)
    selector.update_metrics("prov_b", 0.6, 110.0)

    state = {
      "active_provider" => "prov_b",
      "samples" => {
        "prov_b" => [
          {"ttft" => 0.5, "tps" => 120.0, "ts" => Time.now.to_f - 10},
          {"ttft" => 0.6, "tps" => 110.0, "ts" => Time.now.to_f - 5}
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
          {"ttft" => 1.0, "tps" => 50.0, "ts" => old_ts}
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
        "prov_b" => {"failures" => 3, "opened_at" => opened_at}
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
      "samples" => {"prov_unknown" => [{"ttft" => 1.0, "ts" => Time.now.to_f}]},
      "circuits" => {"prov_unknown" => {"failures" => 1, "opened_at" => nil}}
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
      File.write(File.join(@tmpdir, "provider_state.json"), JSON.generate({"version" => 999, "models" => {}}))
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

  def test_load_returns_nil_for_malformed_json
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      File.write(File.join(@tmpdir, "provider_state.json"), "{not valid json")
      assert_nil StatePersistence.load
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_load_returns_nil_when_not_a_hash
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      File.write(File.join(@tmpdir, "provider_state.json"), JSON.generate([1, 2, 3]))
      assert_nil StatePersistence.load
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_load_returns_nil_when_version_missing
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      File.write(File.join(@tmpdir, "provider_state.json"), JSON.generate({"models" => {}}))
      assert_nil StatePersistence.load
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_load_returns_nil_for_truncated_file
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      full = JSON.generate({"version" => 1, "saved_at" => 1.0, "models" => {"x" => {"active_provider" => "y"}}})
      truncated = full[0..(full.bytesize / 2)]
      File.write(File.join(@tmpdir, "provider_state.json"), truncated)
      assert_nil StatePersistence.load
    ensure
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_save_cleans_up_temp_file_on_rename_failure
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      # Stub build_state to avoid needing ConfigStore.
      StatePersistence.singleton_class.class_eval do
        alias_method :__orig_build_state, :build_state
        define_method(:build_state) { {"version" => StatePersistence::STATE_VERSION, "models" => {}} }
      end

      # Force File.rename to fail. Use the real File.rename via a stub.
      File.singleton_class.class_eval do
        alias_method :__orig_rename, :rename
        define_method(:rename) { |_src, _dst| raise Errno::EACCES, "stubbed" }
      end

      captured = []
      err_logger = Class.new(NullLogger) do
        define_method(:error) { |m| captured << m }
      end.new

      # Should NOT raise NameError (the bug). Should log the error and clean up tmp.
      StatePersistence.save(logger: err_logger)

      refute_empty captured, "expected an error to be logged"
      refute(captured.any? { |m| m.include?("NameError") }, "rescue path must not raise NameError, got: #{captured.inspect}")

      # No leftover .tmp.* files in the directory
      leftovers = Dir.entries(@tmpdir).select { |f| f.start_with?("provider_state.json.tmp.") }
      assert_empty leftovers, "tmp file should be cleaned up, found: #{leftovers}"
    ensure
      ENV["STATE_DIR"] = old_env
      File.singleton_class.class_eval do
        if method_defined?(:__orig_rename) || private_method_defined?(:__orig_rename)
          alias_method :rename, :__orig_rename
          remove_method :__orig_rename
        end
      end
      StatePersistence.singleton_class.class_eval do
        if method_defined?(:__orig_build_state) || private_method_defined?(:__orig_build_state)
          alias_method :build_state, :__orig_build_state
          remove_method :__orig_build_state
        end
      end
    end
  end

  # --- restore! tests ---

  def test_restore_calls_restore_state_on_matching_selectors
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      sel = selector
      sel.update_metrics("prov_a", 1.5, 80.0)
      sel.update_metrics("prov_a", 2.0, 90.0)
      write_state_file({"test-model" => sel})

      fresh = ProviderSelector.new("test-model", @providers, model_config: @model_config)
      selectors_map = {"test-model" => fresh}
      models_map = {"test-model" => @model_config}

      ConfigStore.singleton_class.class_eval do
        alias_method :__orig_sp_sel, :selectors rescue nil
        alias_method :__orig_sp_mod, :models rescue nil
        define_method(:selectors) { selectors_map }
        define_method(:models) { models_map }
      end

      StatePersistence.restore!(logger: NullLogger.new)

      assert_equal "prov_a", fresh.active_provider_name
    ensure
      ConfigStore.singleton_class.class_eval do
        if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
          alias_method :selectors, :__orig_sp_sel
          remove_method :__orig_sp_sel
        end
        if method_defined?(:__orig_sp_mod) || private_method_defined?(:__orig_sp_mod)
          alias_method :models, :__orig_sp_mod
          remove_method :__orig_sp_mod
        end
      end
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_restore_skips_unknown_models
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      sel = selector
      write_state_file({"test-model" => sel, "unknown-model" => sel})

      selectors_map = {"test-model" => sel}
      models_map = {"test-model" => @model_config}

      captured = []
      dbg_logger = Class.new do
        define_method(:info) { |_m| }
        define_method(:warn) { |_m| }
        define_method(:error) { |_m| }
        define_method(:debug) { |m| captured << m }
      end.new

      ConfigStore.singleton_class.class_eval do
        alias_method :__orig_sp_sel, :selectors rescue nil
        alias_method :__orig_sp_mod, :models rescue nil
        define_method(:selectors) { selectors_map }
        define_method(:models) { models_map }
      end

      StatePersistence.restore!(logger: dbg_logger)

      assert(captured.any? { |m| m.include?("unknown-model") }, "should log skip for unknown model")
    ensure
      ConfigStore.singleton_class.class_eval do
        if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
          alias_method :selectors, :__orig_sp_sel
          remove_method :__orig_sp_sel
        end
        if method_defined?(:__orig_sp_mod) || private_method_defined?(:__orig_sp_mod)
          alias_method :models, :__orig_sp_mod
          remove_method :__orig_sp_mod
        end
      end
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_restore_returns_early_when_no_state
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      ConfigStore.singleton_class.class_eval do
        alias_method :__orig_sp_sel, :selectors rescue nil
        alias_method :__orig_sp_mod, :models rescue nil
        define_method(:selectors) { {} }
        define_method(:models) { {} }
      end

      result = StatePersistence.restore!
      assert_nil result
    ensure
      ConfigStore.singleton_class.class_eval do
        if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
          alias_method :selectors, :__orig_sp_sel
          remove_method :__orig_sp_sel
        end
        if method_defined?(:__orig_sp_mod) || private_method_defined?(:__orig_sp_mod)
          alias_method :models, :__orig_sp_mod
          remove_method :__orig_sp_mod
        end
      end
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_restore_calls_realign_active_index
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      sel = selector
      write_state_file({"test-model" => sel})

      realign_called = []
      original_realign = sel.method(:realign_active_index!)
      sel.define_singleton_method(:realign_active_index!) do |mc|
        realign_called << mc
        original_realign.call(mc)
      end

      selectors_map = {"test-model" => sel}
      models_map = {"test-model" => @model_config}

      ConfigStore.singleton_class.class_eval do
        alias_method :__orig_sp_sel, :selectors rescue nil
        alias_method :__orig_sp_mod, :models rescue nil
        define_method(:selectors) { selectors_map }
        define_method(:models) { models_map }
      end

      StatePersistence.restore!(logger: NullLogger.new)

      assert_equal 1, realign_called.length
      assert_equal @model_config, realign_called.first
    ensure
      ConfigStore.singleton_class.class_eval do
        if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
          alias_method :selectors, :__orig_sp_sel
          remove_method :__orig_sp_sel
        end
        if method_defined?(:__orig_sp_mod) || private_method_defined?(:__orig_sp_mod)
          alias_method :models, :__orig_sp_mod
          remove_method :__orig_sp_mod
        end
      end
      ENV["STATE_DIR"] = old_env
    end
  end

  def test_restore_logs_warning_on_restore_failure
    old_env = ENV["STATE_DIR"]
    ENV["STATE_DIR"] = @tmpdir
    begin
      sel = selector
      write_state_file({"test-model" => sel})

      sel.define_singleton_method(:restore_state!) { |_state| raise RuntimeError, "boom" }

      captured = []
      warn_logger = Class.new do
        define_method(:info) { |_m| }
        define_method(:warn) { |m| captured << m }
        define_method(:error) { |_m| }
        define_method(:debug) { |_m| }
      end.new

      selectors_map = {"test-model" => sel}
      models_map = {"test-model" => @model_config}

      ConfigStore.singleton_class.class_eval do
        alias_method :__orig_sp_sel, :selectors rescue nil
        alias_method :__orig_sp_mod, :models rescue nil
        define_method(:selectors) { selectors_map }
        define_method(:models) { models_map }
      end

      StatePersistence.restore!(logger: warn_logger)

      assert(captured.any? { |m| m.include?("boom") }, "should log restore failure")
    ensure
      ConfigStore.singleton_class.class_eval do
        if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
          alias_method :selectors, :__orig_sp_sel
          remove_method :__orig_sp_sel
        end
        if method_defined?(:__orig_sp_mod) || private_method_defined?(:__orig_sp_mod)
          alias_method :models, :__orig_sp_mod
          remove_method :__orig_sp_mod
        end
      end
      ENV["STATE_DIR"] = old_env
    end
  end

  # --- build_state tests ---

  def test_build_state_returns_version_and_models
    sel = selector
    selectors_map = {"test-model" => sel}

    ConfigStore.singleton_class.class_eval do
      alias_method :__orig_sp_sel, :selectors rescue nil
      define_method(:selectors) { selectors_map }
    end

    state = StatePersistence.build_state

    assert_equal StatePersistence::STATE_VERSION, state[:version]
    assert_kind_of Float, state[:saved_at]
    assert_equal({"test-model" => sel.to_state}, state[:models])
  ensure
    ConfigStore.singleton_class.class_eval do
      if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
        alias_method :selectors, :__orig_sp_sel
        remove_method :__orig_sp_sel
      end
    end
  end

  def test_build_state_aggregates_multiple_selectors
    sel_a = selector
    providers_b = [
      {"provider" => "prov_x", "model" => "m-x", "base_url" => "https://x.example.com/v1", "api_key" => "kx"}.freeze,
      {"provider" => "prov_y", "model" => "m-y", "base_url" => "https://y.example.com/v1", "api_key" => "ky"}.freeze
    ].freeze
    model_config_b = {"name" => "model-b", "providers" => [
      {"provider" => "prov_x", "model" => "m-x", "primary" => true},
      {"provider" => "prov_y", "model" => "m-y"}
    ]}
    sel_b = ProviderSelector.new("model-b", providers_b, model_config: model_config_b)

    selectors_map = {"test-model" => sel_a, "model-b" => sel_b}

    ConfigStore.singleton_class.class_eval do
      alias_method :__orig_sp_sel, :selectors rescue nil
      define_method(:selectors) { selectors_map }
    end

    state = StatePersistence.build_state

    assert_equal 2, state[:models].size
    assert_equal sel_a.to_state, state[:models]["test-model"]
    assert_equal sel_b.to_state, state[:models]["model-b"]
  ensure
    ConfigStore.singleton_class.class_eval do
      if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
        alias_method :selectors, :__orig_sp_sel
        remove_method :__orig_sp_sel
      end
    end
  end

  def test_build_state_with_empty_selectors
    ConfigStore.singleton_class.class_eval do
      alias_method :__orig_sp_sel, :selectors rescue nil
      define_method(:selectors) { {} }
    end

    state = StatePersistence.build_state

    assert_equal({}, state[:models])
    assert_equal StatePersistence::STATE_VERSION, state[:version]
  ensure
    ConfigStore.singleton_class.class_eval do
      if method_defined?(:__orig_sp_sel) || private_method_defined?(:__orig_sp_sel)
        alias_method :selectors, :__orig_sp_sel
        remove_method :__orig_sp_sel
      end
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
