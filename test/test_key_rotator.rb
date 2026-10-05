# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/key_rotator"

class TestKeyRotator < Minitest::Test
  def setup
    KeyRotator.reset!
  end

  def teardown
    KeyRotator.reset!
  end

  # -- extract_keys --------------------------------------------------

  def test_extract_keys_single_api_key
    assert_equal ["only"], KeyRotator.extract_keys({"api_key" => "only"})
  end

  def test_extract_keys_list
    assert_equal %w[k1 k2 k3], KeyRotator.extract_keys({"api_keys" => %w[k1 k2 k3]})
  end

  def test_extract_keys_prefers_api_keys_when_both_present
    keys = KeyRotator.extract_keys({"api_key" => "single", "api_keys" => %w[a b]})
    assert_equal %w[a b], keys
  end

  def test_extract_keys_strips_and_drops_blanks_and_dupes
    keys = KeyRotator.extract_keys({"api_keys" => [" k1 ", "", "  ", "k2", "k1"]})
    assert_equal %w[k1 k2], keys
  end

  def test_extract_keys_empty_when_no_keys
    assert_equal [], KeyRotator.extract_keys({})
    assert_equal [], KeyRotator.extract_keys({"api_key" => "  ", "api_keys" => []})
  end

  def test_extract_keys_falls_back_to_api_key_when_list_blank
    assert_equal ["solo"], KeyRotator.extract_keys({"api_key" => "solo", "api_keys" => ["", "  "]})
  end

  def test_extract_keys_ignores_non_array_api_keys
    # api_keys: false must never become the credential "false".
    assert_equal ["real"], KeyRotator.extract_keys({"api_key" => "real", "api_keys" => false})
  end

  def test_extract_keys_drops_non_string_entries
    assert_equal ["a"], KeyRotator.extract_keys({"api_keys" => [false, "a", 123, {"x" => 1}]})
  end

  # -- acquire / pause ordering -------------------------------------

  def test_acquire_returns_first_key_initially
    r = KeyRotator.new(%w[k1 k2 k3])
    assert_equal "k1", r.acquire
  end

  def test_multiple
    assert KeyRotator.new(%w[k1 k2]).multiple?
    refute KeyRotator.new(%w[k1]).multiple?
    refute KeyRotator.new([]).multiple?
  end

  def test_acquire_skips_paused_keys_in_order
    r = KeyRotator.new(%w[k1 k2 k3])
    r.pause("k1", Time.now.to_f + 60)
    assert_equal "k2", r.acquire
  end

  def test_acquire_returns_nil_when_all_paused
    r = KeyRotator.new(%w[k1 k2])
    r.pause("k1", Time.now.to_f + 60)
    r.pause("k2", Time.now.to_f + 60)
    assert_nil r.acquire
  end

  def test_acquire_excludes_a_key
    r = KeyRotator.new(%w[k1 k2])
    assert_equal "k2", r.acquire(exclude: "k1")
  end

  def test_acquire_excludes_multiple_keys
    r = KeyRotator.new(%w[k1 k2 k3])
    assert_equal "k3", r.acquire(exclude: ["k1", "k2"])
    assert_nil r.acquire(exclude: ["k1", "k2", "k3"])
  end

  def test_paused_key_becomes_available_after_reset
    r = KeyRotator.new(%w[k1 k2])
    r.pause("k1", Time.now.to_f - 1) # already expired
    assert_equal "k1", r.acquire
  end

  def test_pause_keeps_longest
    r = KeyRotator.new(%w[k1])
    base = Time.now.to_f
    r.pause("k1", base + 100)
    r.pause("k1", base + 10) # shorter — must not downgrade
    r.pause("k1", base + 200)
    assert_in_delta base + 200, r.resume_time, 0.01
  end

  def test_resume_clears_pause
    r = KeyRotator.new(%w[k1 k2])
    r.pause("k1", Time.now.to_f + 60)
    r.resume("k1")
    assert_equal "k1", r.acquire
    assert_nil r.resume_time
  end

  def test_resume_time_is_soonest_future_pause
    r = KeyRotator.new(%w[k1 k2])
    base = Time.now.to_f
    r.pause("k1", base + 300)
    r.pause("k2", base + 60)
    assert_in_delta base + 60, r.resume_time, 0.01
  end

  def test_resume_time_nil_when_no_pause
    r = KeyRotator.new(%w[k1 k2])
    assert_nil r.resume_time
  end

  def test_paused_count
    r = KeyRotator.new(%w[k1 k2 k3])
    r.pause("k1", Time.now.to_f + 60)
    r.pause("k2", Time.now.to_f + 60)
    assert_equal 2, r.paused_count
  end

  # -- registry -----------------------------------------------------

  def test_for_reuses_rotator_for_same_provider_and_base
    pc = {"provider" => "open", "base_url" => "https://o/v1", "api_keys" => %w[k1 k2]}
    a = KeyRotator.for(pc)
    b = KeyRotator.for(pc)
    assert_same a, b
  end

  def test_for_replaces_rotator_when_key_list_changes
    a = KeyRotator.for({"provider" => "open", "base_url" => "https://o/v1", "api_keys" => %w[k1 k2]})
    a.pause("k1", Time.now.to_f + 60)
    b = KeyRotator.for({"provider" => "open", "base_url" => "https://o/v1", "api_keys" => %w[k1 k2 k3]})
    refute_same a, b
    assert_equal %w[k1 k2 k3], b.keys
    assert_equal "k1", b.acquire, "fresh rotator should not carry stale pause state"
  end

  def test_for_distinct_providers_are_distinct_rotators
    a = KeyRotator.for({"provider" => "a", "base_url" => "https://a/v1", "api_key" => "k"})
    b = KeyRotator.for({"provider" => "b", "base_url" => "https://b/v1", "api_key" => "k"})
    refute_same a, b
  end
end

# -- Integration: try_with_retries rotates keys on quota -------------

class KeyRotationRetryTest < Minitest::Test
  class RotApp
    include HTTPSupport
    attr_reader :slept

    def initialize(max_attempts: 3, backoff_base: 1)
      @max_attempts = max_attempts
      @backoff_base = backoff_base
      @slept = []
    end

    def settings
      Struct.new(:max_attempts, :backoff_base, :logger).new(@max_attempts, @backoff_base, NullLogger.new)
    end

    def sleep(d)
      @slept << d
    end
  end

  def quota!
    HTTPSupport::QuotaExhaustedError.new(reset_time: Time.now.to_f + 60, status: 429, reason: "rate_limited")
  end

  def test_rotates_to_next_key_on_quota_then_succeeds
    rotator = KeyRotator.new(%w[k1 k2])
    used = []
    result = RotApp.new.try_with_retries(log_prefix: "[t]", body_model: "m", rotator: rotator) do |key|
      used << key
      raise quota! if key == "k1"
      {success: true, key: key}
    end
    assert result[:success]
    assert_equal %w[k1 k2], used, "should try first key, then rotate to the second"
  end

  def test_all_keys_exhausted_reports_quota_pause
    rotator = KeyRotator.new(%w[k1 k2])
    used = []
    result = RotApp.new.try_with_retries(log_prefix: "[t]", body_model: "m", rotator: rotator) do |key|
      used << key
      raise quota!
    end
    refute result[:success]
    assert_equal %w[k1 k2], used
    assert result[:quota_pause_until], "should report a provider quota pause once all keys are exhausted"
    assert_equal "rate_limited", result[:quota_pause_reason]
  end

  def test_rotation_tries_every_key_regardless_of_max_attempts
    rotator = KeyRotator.new(%w[k1 k2 k3])
    used = []
    RotApp.new(max_attempts: 1).try_with_retries(log_prefix: "[t]", body_model: "m", rotator: rotator) do |key|
      used << key
      raise quota!
    end
    assert_equal %w[k1 k2 k3], used, "key rotation must not be bounded by max_attempts"
  end

  def test_earlier_key_not_retried_when_cooldown_expires_mid_rotation
    rotator = KeyRotator.new(%w[k1 k2 k3])
    used = []
    # reset_time == now: every pause expires immediately, so a rotation that
    # excludes only the last key would revisit k1 and starve the healthy k3.
    RotApp.new(max_attempts: 1).try_with_retries(log_prefix: "[t]", body_model: "m", rotator: rotator) do |key|
      used << key
      raise HTTPSupport::QuotaExhaustedError.new(reset_time: Time.now.to_f, status: 429, reason: "rate_limited")
    end
    assert_equal %w[k1 k2 k3], used, "each key must be tried exactly once even when cooldowns expire immediately"
  end

  def test_single_key_provider_returns_quota_immediately
    rotator = KeyRotator.new(%w[only])
    calls = 0
    result = RotApp.new.try_with_retries(log_prefix: "[t]", body_model: "m", rotator: rotator) do |key|
      calls += 1
      raise quota!
    end
    refute result[:success]
    assert_equal 1, calls, "single-key provider must not rotate"
    assert result[:quota_pause_until]
  end

  def test_non_quota_errors_do_not_rotate_keys
    rotator = KeyRotator.new(%w[k1 k2])
    used = []
    result = RotApp.new(max_attempts: 2).try_with_retries(log_prefix: "[t]", body_model: "m", rotator: rotator) do |key|
      used << key
      raise HTTPSupport::RetryableError, "boom"
    end
    refute result[:success]
    assert_equal ["k1", "k1"], used, "non-quota retries reuse the current key and must not rotate"
  end

  def test_all_keys_already_paused_short_circuits
    rotator = KeyRotator.new(%w[k1 k2])
    rotator.pause("k1", Time.now.to_f + 60)
    rotator.pause("k2", Time.now.to_f + 60)
    calls = 0
    result = RotApp.new.try_with_retries(log_prefix: "[t]", body_model: "m", rotator: rotator) do |_key|
      calls += 1
      {success: true}
    end
    refute result[:success]
    assert_equal 0, calls, "must not attempt any key when all are rate-limited"
    assert_equal "rate_limited", result[:quota_pause_reason]
  end
end
