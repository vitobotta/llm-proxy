# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/config_validator"

class TestConfigValidator < Minitest::Test
  def base
    {
      "providers" => {
        "p_a" => { "base_url" => "https://a/", "api_key" => "ka" },
        "p_b" => { "base_url" => "https://b/", "api_key" => "kb" }
      },
      "models" => [
        { "name" => "m1", "providers" => [{ "provider" => "p_a", "model" => "x" }] }
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
    cfg["models"][0]["providers"] << { "provider" => "ghost", "model" => "g" }
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
    cfg["models"] << { "providers" => [{ "provider" => "p_a", "model" => "x" }] }
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

  def test_rejects_excessive_max_attempts
    cfg = base.merge("retries" => { "max_attempts" => 1_000_000 })
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("max_attempts") }, errors.inspect)
  end

  def test_rejects_invalid_backoff_base
    cfg = base.merge("retries" => { "backoff_base" => -1 })
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("backoff_base") }, errors.inspect)
  end

  def test_rejects_excessive_max_request_body
    cfg = base.merge("limits" => { "max_request_body" => 10 * 1024 * 1024 * 1024 })
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("max_request_body") }, errors.inspect)
  end

  def test_rejects_invalid_timeouts
    cfg = base.merge("timeouts" => { "open" => 0, "read" => 99999999, "write" => "x" })
    errors, _ = validate(cfg)
    assert(errors.any? { |e| e.include?("timeouts.open") }, errors.inspect)
    assert(errors.any? { |e| e.include?("timeouts.read") }, errors.inspect)
    assert(errors.any? { |e| e.include?("timeouts.write") }, errors.inspect)
  end
end
