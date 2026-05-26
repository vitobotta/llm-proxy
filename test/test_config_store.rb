# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../lib/config_validator"
require_relative "../lib/config_store"

class TestConfigStore < Minitest::Test
  class FakeApp
    attr_reader :settings_hash

    def initialize
      @settings_hash = {}
    end

    def set(key, value)
      @settings_hash[key] = value
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yaml")
    @prev_config_file = ENV["CONFIG_FILE"]
    ENV["CONFIG_FILE"] = @config_path
    write_config(MOCK_CONFIG)
    ConfigStore.instance_variable_set(:@config_path, @config_path)
    ConfigStore.instance_variable_set(:@data, {})
    ConfigStore.instance_variable_set(:@app_ref, nil)
    ConfigStore.load!(MOCK_CONFIG, logger: NullLogger.new)
  end

  def teardown
    ENV["CONFIG_FILE"] = @prev_config_file
    FileUtils.remove_entry(@tmpdir)
  end

  def write_config(cfg)
    File.write(@config_path, YAML.dump(cfg))
  end

  def test_register_app_propagates_settings_at_boot
    app = FakeApp.new
    ConfigStore.register_app!(app)
    assert_equal 2, app.settings_hash[:max_attempts]
    assert_equal 1, app.settings_hash[:backoff_base]
  end

  def test_reload_re_propagates_settings_to_registered_app
    app = FakeApp.new
    ConfigStore.register_app!(app)
    assert_equal 2, app.settings_hash[:max_attempts]

    new_cfg = MOCK_CONFIG.merge("retries" => {"max_attempts" => 7, "backoff_base" => 3})
    write_config(new_cfg)

    # Stub prewarm_connections! to avoid spawning a thread that hits real URLs
    HTTPSupport.singleton_class.class_eval do
      alias_method :__orig_prewarm, :prewarm_connections!
      define_method(:prewarm_connections!) { |*_args, **_kw| nil }
    end

    err_logger = Class.new(NullLogger) do
      attr_reader :errors
      def initialize
        super
        @errors = []
      end

      def error(msg)
        @errors << msg
      end
    end.new

    ok = ConfigStore.reload!(logger: err_logger)

    assert ok, "reload! should succeed (errors: #{err_logger.errors.inspect})"
    assert_equal 7, app.settings_hash[:max_attempts]
    assert_equal 3, app.settings_hash[:backoff_base]
  ensure
    HTTPSupport.singleton_class.class_eval do
      if method_defined?(:__orig_prewarm) || private_method_defined?(:__orig_prewarm)
        alias_method :prewarm_connections!, :__orig_prewarm
        remove_method :__orig_prewarm
      end
    end
  end

  def test_reload_triggers_prewarm_only_when_new_providers_added
    prewarm_calls = []
    HTTPSupport.singleton_class.class_eval do
      alias_method :__orig_prewarm3, :prewarm_connections!
      define_method(:prewarm_connections!) do |_config, providers, *_args, **_kw|
        prewarm_calls << providers.keys.sort
        nil
      end
    end

    # Reload with no provider change — should NOT prewarm.
    write_config(MOCK_CONFIG)
    assert ConfigStore.reload!(logger: NullLogger.new)
    assert_empty prewarm_calls, "reload with same providers should not prewarm"

    # Reload with a new provider added — SHOULD prewarm.
    cfg_with_new = Marshal.load(Marshal.dump(MOCK_CONFIG)) # deep copy
    cfg_with_new["providers"]["prov_c"] = {"base_url" => "https://c.example.com/v1", "api_key" => "kc"}
    write_config(cfg_with_new)
    assert ConfigStore.reload!(logger: NullLogger.new)

    refute_empty prewarm_calls, "new provider should trigger prewarm"
    assert_includes prewarm_calls.last, "prov_c"
  ensure
    HTTPSupport.singleton_class.class_eval do
      if method_defined?(:__orig_prewarm3) || private_method_defined?(:__orig_prewarm3)
        alias_method :prewarm_connections!, :__orig_prewarm3
        remove_method :__orig_prewarm3
      end
    end
  end

  def test_concurrent_snapshot_reads_during_reload_are_internally_consistent
    # Each call to ConfigStore.<accessor> is atomic on its own (single ivar
    # read under MRI's GVL), but two separate calls are NOT guaranteed to
    # come from the same snapshot — a reload may happen between them.
    # Consumers that need a consistent view of multiple fields must grab the
    # @data snapshot once and read fields off it. This test pins that
    # invariant: snapshot-based reads must never mix old + new values.
    HTTPSupport.singleton_class.class_eval do
      alias_method :__orig_prewarm_stress, :prewarm_connections!
      define_method(:prewarm_connections!) { |*_args, **_kw| nil }
    end

    cfg_a = MOCK_CONFIG.merge("retries" => {"max_attempts" => 2, "backoff_base" => 1})
    cfg_b = MOCK_CONFIG.merge("retries" => {"max_attempts" => 7, "backoff_base" => 3})

    stop = false
    seen_combos = Set.new
    seen_lock = Mutex.new

    readers = 8.times.map do
      Thread.new do
        until stop
          snap = ConfigStore.instance_variable_get(:@data)
          ma = snap[:max_attempts]
          bb = snap[:backoff_base]
          seen_lock.synchronize { seen_combos << [ma, bb] }
        end
      end
    end

    writer = Thread.new do
      30.times do |i|
        cfg = i.even? ? cfg_a : cfg_b
        File.write(@config_path, YAML.dump(cfg))
        ConfigStore.reload!(logger: NullLogger.new)
      end
    end

    writer.join
    stop = true
    readers.each(&:join)

    allowed = [[2, 1], [7, 3]]
    torn = seen_combos.reject { |c| allowed.include?(c) }
    assert_empty torn, "snapshot reads must never see torn combos; got: #{torn.inspect}"
    refute_empty seen_combos
  ensure
    HTTPSupport.singleton_class.class_eval do
      if method_defined?(:__orig_prewarm_stress) || private_method_defined?(:__orig_prewarm_stress)
        alias_method :prewarm_connections!, :__orig_prewarm_stress
        remove_method :__orig_prewarm_stress
      end
    end
  end

  def test_reload_without_registered_app_does_not_raise
    new_cfg = MOCK_CONFIG.merge("retries" => {"max_attempts" => 5, "backoff_base" => 2})
    write_config(new_cfg)
    HTTPSupport.singleton_class.class_eval do
      alias_method :__orig_prewarm2, :prewarm_connections!
      define_method(:prewarm_connections!) { |*_args, **_kw| nil }
    end

    assert ConfigStore.reload!(logger: NullLogger.new)
    assert_equal 5, ConfigStore.max_attempts
  ensure
    HTTPSupport.singleton_class.class_eval do
      if method_defined?(:__orig_prewarm2) || private_method_defined?(:__orig_prewarm2)
        alias_method :prewarm_connections!, :__orig_prewarm2
        remove_method :__orig_prewarm2
      end
    end
  end
end
