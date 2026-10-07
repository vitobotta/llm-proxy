# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/config_validator"

class TestConfigValidator < Minitest::Test
  def base
    {
      "providers" => {
        "p_a" => {"base_url" => "https://a/", "api_key" => "ka"},
        "p_b" => {"base_url" => "https://b/", "api_key" => "kb"}
      },
      "models" => [
        {"name" => "m1", "providers" => [{"provider" => "p_a", "model" => "x"}]}
      ]
    }
  end

  def validate(cfg)
    ConfigValidator.validate(cfg, NullLogger.new)
  end

  def test_happy_path
    errors, _ = validate(base)
    assert_empty errors
  end

  def test_rejects_unknown_provider_reference
    cfg = base
    cfg["models"][0]["providers"] << {"provider" => "ghost", "model" => "g"}
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("ghost") }, "expected error mentioning unknown provider: #{errors.inspect}")
  end

  def test_rejects_missing_api_key
    cfg = base
    cfg["providers"]["p_a"]["api_key"] = nil
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_key") }, "expected api_key error: #{errors.inspect}")
  end

  def test_rejects_empty_api_key
    cfg = base
    cfg["providers"]["p_a"]["api_key"] = "   "
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_key") }, "expected api_key error: #{errors.inspect}")
  end

  def test_rejects_missing_base_url
    cfg = base
    cfg["providers"]["p_a"]["base_url"] = nil
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("base_url") }, "expected base_url error: #{errors.inspect}")
  end

  def test_rejects_missing_models
    cfg = base
    cfg["models"] = []
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("Missing 'models'") }, errors.inspect)
  end

  def test_rejects_model_without_name
    cfg = base
    cfg["models"] << {"providers" => [{"provider" => "p_a", "model" => "x"}]}
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("missing 'name'") }, errors.inspect)
  end

  def test_rejects_invalid_context_length
    cfg = base
    cfg["models"][0]["context_length"] = -1
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("context_length") }, errors.inspect)
  end

  def test_rejects_invalid_probe_interval_type
    cfg = base
    cfg["models"][0]["probe_interval"] = "fast"
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("probe_interval") }, errors.inspect)
  end

  def test_accepts_valid_model_ttft_timeout
    cfg = base
    cfg["models"][0]["ttft_timeout"] = 30
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_accepts_model_ttft_timeout_false_to_disable
    cfg = base
    cfg["models"][0]["ttft_timeout"] = false
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_accepts_blank_model_ttft_timeout
    cfg = base
    cfg["models"][0]["ttft_timeout"] = nil
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_rejects_invalid_model_ttft_timeout
    cfg = base
    cfg["models"][0]["ttft_timeout"] = "fast"
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("ttft_timeout") }, errors.inspect)

    cfg = base
    cfg["models"][0]["ttft_timeout"] = 0
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("ttft_timeout") }, errors.inspect)

    cfg = base
    cfg["models"][0]["ttft_timeout"] = 86_401
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("ttft_timeout") }, errors.inspect)
  end

  def test_rejects_excessive_max_attempts
    cfg = base.merge("retries" => {"max_attempts" => 1_000_000})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("max_attempts") }, errors.inspect)
  end

  def test_rejects_invalid_backoff_base
    cfg = base.merge("retries" => {"backoff_base" => -1})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("backoff_base") }, errors.inspect)
  end

  def test_rejects_zero_max_rounds
    cfg = base.merge("retries" => {"max_rounds" => 0})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("max_rounds") }, errors.inspect)
  end

  def test_rejects_negative_max_rounds
    cfg = base.merge("retries" => {"max_rounds" => -1})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("max_rounds") }, errors.inspect)
  end

  def test_rejects_excessive_max_rounds
    cfg = base.merge("retries" => {"max_rounds" => 1_000_000})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("max_rounds") }, errors.inspect)
  end

  def test_accepts_valid_max_rounds
    cfg = base.merge("retries" => {"max_rounds" => 5})
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_warns_on_high_max_rounds
    cfg = base.merge("retries" => {"max_rounds" => 7})
    _, warnings = validate(cfg)
    assert(warnings.any? { |w| w.include?("max_rounds") }, warnings.inspect)
  end

  def test_rejects_excessive_max_request_body
    cfg = base.merge("limits" => {"max_request_body" => 10 * 1024 * 1024 * 1024})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("max_request_body") }, errors.inspect)
  end

  def test_rejects_invalid_timeouts
    cfg = base.merge("timeouts" => {"open" => 0, "read" => 99999999, "write" => "x"})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("timeouts.open") }, errors.inspect)
    assert(errors.any? { |e| e.include?("timeouts.read") }, errors.inspect)
    assert(errors.any? { |e| e.include?("timeouts.write") }, errors.inspect)
  end

  def test_accepts_valid_ttft
    cfg = base.merge("timeouts" => {"ttft" => 15})
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_accepts_missing_ttft
    cfg = base.merge("timeouts" => {"open" => 10, "read" => 300})
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_rejects_zero_ttft
    cfg = base.merge("timeouts" => {"ttft" => 0})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("timeouts.ttft") }, errors.inspect)
  end

  def test_rejects_negative_ttft
    cfg = base.merge("timeouts" => {"ttft" => -5})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("timeouts.ttft") }, errors.inspect)
  end

  def test_rejects_string_ttft
    cfg = base.merge("timeouts" => {"ttft" => "15"})
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("timeouts.ttft") }, errors.inspect)
  end

  # -- api_keys (multiple keys per provider) -------------------------

  def test_accepts_api_keys_without_api_key
    cfg = base
    cfg["providers"]["p_a"].delete("api_key")
    cfg["providers"]["p_a"]["api_keys"] = %w[one two]
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_rejects_empty_api_keys_with_no_api_key
    cfg = base
    cfg["providers"]["p_a"].delete("api_key")
    cfg["providers"]["p_a"]["api_keys"] = []
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_key") }, errors.inspect)
  end

  def test_rejects_blank_api_keys_entries
    cfg = base
    cfg["providers"]["p_a"]["api_keys"] = ["ok", "  "]
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_keys") }, errors.inspect)
  end

  def test_rejects_non_array_api_keys
    cfg = base
    cfg["providers"]["p_a"]["api_keys"] = "not-a-list"
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_keys") }, errors.inspect)
  end

  def test_warns_when_both_api_key_and_api_keys
    cfg = base
    cfg["providers"]["p_a"]["api_key"] = "single"
    cfg["providers"]["p_a"]["api_keys"] = %w[a b]
    errors, warnings = validate(cfg)
    assert_empty errors, errors.inspect
    assert(warnings.any? { |w| w.include?("p_a") && w.include?("api_keys") }, warnings.inspect)
  end

  # -- headers (custom per-provider request headers) -----------------

  def test_accepts_valid_headers
    cfg = base
    cfg["providers"]["p_a"]["headers"] = {"X-Custom" => "v"}
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_rejects_non_hash_headers
    cfg = base
    cfg["providers"]["p_a"]["headers"] = "oops"
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("headers") }, errors.inspect)
  end

  def test_rejects_non_scalar_header_value
    cfg = base
    cfg["providers"]["p_a"]["headers"] = {"X-Custom" => ["a", "b"]}
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("X-Custom") }, errors.inspect)
  end

  def test_warns_on_protected_header
    cfg = base
    cfg["providers"]["p_a"]["headers"] = {"Authorization" => "x"}
    _, warnings = validate(cfg)
    assert(warnings.any? { |w| w.include?("Authorization") && w.include?("managed by the proxy") }, warnings.inspect)
  end

  def test_model_provider_headers_validated
    cfg = base
    cfg["models"][0]["providers"][0]["headers"] = "bad"
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("headers") }, errors.inspect)
  end

  # Date/Time header values (e.g. unquoted `anthropic-version: 2023-06-01`)
  # must keep working — they are stringified on send, not rejected.

  def test_accepts_date_header
    cfg = base
    cfg["providers"]["p_a"]["headers"] = {"anthropic-version" => Date.new(2023, 6, 1)}
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  def test_accepts_time_header
    cfg = base
    cfg["providers"]["p_a"]["headers"] = {"X-Timestamp" => Time.at(0)}
    errors, _ = validate(cfg)
    assert_empty errors, errors.inspect
  end

  # api_keys must be an array of non-empty strings before normalisation, so a
  # boolean/mapping/number can never silently become a credential.

  def test_rejects_false_api_keys
    cfg = base
    cfg["providers"]["p_a"]["api_keys"] = false
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_keys") }, errors.inspect)
  end

  def test_rejects_non_string_api_keys_entries
    cfg = base
    cfg["providers"]["p_a"]["api_keys"] = [false]
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_keys") }, errors.inspect)
  end

  def test_rejects_mapping_api_keys
    cfg = base
    cfg["providers"]["p_a"]["api_keys"] = {"a" => 1}
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("p_a") && e.include?("api_keys") }, errors.inspect)
  end
end
