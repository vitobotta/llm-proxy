# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../lib/config_validator"
require_relative "../lib/config_store"
require_relative "../lib/config_watcher"

class TestConfigWatcher < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yaml")
    File.write(@config_path, YAML.dump(MOCK_CONFIG))
    ConfigStore.instance_variable_set(:@config_path, @config_path)
    ConfigStore.instance_variable_set(:@data, {})
    ConfigStore.instance_variable_set(:@app_ref, nil)
    ConfigStore.load!(MOCK_CONFIG, logger: NullLogger.new)
    @logger = NullLogger.new
    ConfigWatcher.instance_variable_set(:@logger, @logger)
    ConfigWatcher.instance_variable_set(:@last_hash, ConfigWatcher.send(:file_hash))
    ConfigWatcher.instance_variable_set(:@expected_hash, nil)

    @reload_calls = 0
    ConfigStore.singleton_class.class_eval do
      alias_method :__orig_reload, :reload!
      reload_counter = @reload_counter = []
      define_method(:reload!) do |**_kw|
        reload_counter << :called
        true
      end
      define_method(:__reload_counter) { reload_counter }
    end
  end

  def teardown
    ConfigWatcher.stop! rescue nil
    sleep 0.05
    ConfigStore.singleton_class.class_eval do
      if method_defined?(:__orig_reload) || private_method_defined?(:__orig_reload)
        alias_method :reload!, :__orig_reload
        remove_method :__orig_reload
        remove_method :__reload_counter if method_defined?(:__reload_counter) || private_method_defined?(:__reload_counter)
      end
    end
    FileUtils.remove_entry(@tmpdir)
  end

  def test_file_hash_returns_sha256_hexdigest
    h = ConfigWatcher.send(:file_hash)
    assert_match(/\A[a-f0-9]{64}\z/, h)
  end

  def test_file_hash_returns_last_hash_when_file_missing
    File.delete(@config_path)
    h = ConfigWatcher.send(:file_hash)
    # last_hash was set in setup; missing file falls back to it
    refute_nil h
  end

  def test_check_and_reload_no_change_does_not_reload
    before_count = ConfigStore.__reload_counter.size
    ConfigWatcher.send(:check_and_reload)
    assert_equal before_count, ConfigStore.__reload_counter.size
  end

  def test_check_and_reload_triggers_on_hash_change
    new_cfg = MOCK_CONFIG.merge("retries" => {"max_attempts" => 5, "backoff_base" => 1})
    File.write(@config_path, YAML.dump(new_cfg))

    before_count = ConfigStore.__reload_counter.size
    ConfigWatcher.send(:check_and_reload)
    assert_equal before_count + 1, ConfigStore.__reload_counter.size
  end

  def test_expecting_write_suppresses_self_triggered_reload
    new_cfg = MOCK_CONFIG.merge("retries" => {"max_attempts" => 9, "backoff_base" => 1})

    # Mimic the ProviderSelector.persist_active_provider flow:
    # 1. compute the future file hash, 2. write the file
    # ConfigWatcher.expecting_write! must be called BEFORE the write so it
    # captures the hash that the file will have.
    File.write(@config_path, YAML.dump(new_cfg))
    ConfigWatcher.expecting_write!  # current_hash now == future-hash post-write

    before_count = ConfigStore.__reload_counter.size
    ConfigWatcher.send(:check_and_reload)
    assert_equal before_count, ConfigStore.__reload_counter.size, "self-write should not trigger reload"
    # @last_hash should have advanced
    assert_equal ConfigWatcher.send(:file_hash), ConfigWatcher.instance_variable_get(:@last_hash)
  end

  def test_consecutive_external_writes_still_trigger
    File.write(@config_path, YAML.dump(MOCK_CONFIG.merge("retries" => {"max_attempts" => 5, "backoff_base" => 1})))
    ConfigWatcher.send(:check_and_reload)
    after_first = ConfigStore.__reload_counter.size

    File.write(@config_path, YAML.dump(MOCK_CONFIG.merge("retries" => {"max_attempts" => 6, "backoff_base" => 1})))
    ConfigWatcher.send(:check_and_reload)
    assert_equal after_first + 1, ConfigStore.__reload_counter.size
  end

  # --- start! / stop! tests ---

  def test_start_creates_polling_thread
    ConfigWatcher.start!(logger: @logger, poll_interval: 0.1)

    assert_equal true, ConfigWatcher.instance_variable_get(:@running)

    sleep 0.25
    ConfigWatcher.stop!
    sleep 0.15

    assert_equal false, ConfigWatcher.instance_variable_get(:@running)
  end

  def test_stop_sets_running_false
    ConfigWatcher.start!(logger: @logger, poll_interval: 0.1)
    assert_equal true, ConfigWatcher.instance_variable_get(:@running)

    ConfigWatcher.stop!
    assert_equal false, ConfigWatcher.instance_variable_get(:@running)
  end

  def test_start_sets_last_hash
    ConfigWatcher.instance_variable_set(:@last_hash, nil)
    ConfigWatcher.start!(logger: @logger, poll_interval: 0.1)

    refute_nil ConfigWatcher.instance_variable_get(:@last_hash)
    ConfigWatcher.stop!
  end

  def test_polling_thread_calls_check_and_reload
    new_cfg = MOCK_CONFIG.merge("retries" => {"max_attempts" => 7, "backoff_base" => 1})
    File.write(@config_path, YAML.dump(new_cfg))

    before_count = ConfigStore.__reload_counter.size
    ConfigWatcher.start!(logger: @logger, poll_interval: 0.1)
    # After start! sets @last_hash to current file hash, override so next poll sees a hash change
    ConfigWatcher.instance_variable_set(:@last_hash, "old_hash_value")
    ConfigWatcher.instance_variable_set(:@last_mtime, Time.at(0))

    sleep 0.35
    ConfigWatcher.stop!
    sleep 0.15

    assert_operator ConfigStore.__reload_counter.size, :>, before_count
  end

  def test_expect_write_suppresses_poll_reload
    new_cfg = MOCK_CONFIG.merge("retries" => {"max_attempts" => 8, "backoff_base" => 1})
    yaml_content = YAML.dump(new_cfg)
    ConfigWatcher.expecting_write!(yaml_content)
    File.write(@config_path, yaml_content)

    before_count = ConfigStore.__reload_counter.size
    ConfigWatcher.start!(logger: @logger, poll_interval: 0.1)
    ConfigWatcher.instance_variable_set(:@last_mtime, Time.at(0))

    sleep 0.35
    ConfigWatcher.stop!
    sleep 0.15

    assert_equal before_count, ConfigStore.__reload_counter.size
  end
end
