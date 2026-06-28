# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/request_handler"

class TestQuotaExhaustedError < Minitest::Test
  def test_quota_exhausted_error_attributes
    reset_time = Time.now.to_f + 60
    err = HTTPSupport::QuotaExhaustedError.new(reset_time: reset_time, status: 429, reason: "rate_limited")
    assert_equal reset_time, err.reset_time
    assert_equal 429, err.status
    assert_equal "rate_limited", err.reason
    assert_includes err.message, "rate_limited"
  end

  def test_quota_exhausted_error_default_reason
    reset_time = Time.now.to_f + 60
    err = HTTPSupport::QuotaExhaustedError.new(reset_time: reset_time, status: 402)
    assert_equal "quota_exhausted", err.reason
    assert_equal 402, err.status
  end
end

class TestQuotaExhaustedDetection < Minitest::Test
  def test_quota_exhausted_402_always
    assert HTTPSupport.quota_exhausted?(402, "")
    assert HTTPSupport.quota_exhausted?(402, "Payment Required")
  end

  def test_quota_exhausted_429_with_quota_body_patterns
    assert HTTPSupport.quota_exhausted?(429, '{"error": {"code": "insufficient_quota"}}')
    assert HTTPSupport.quota_exhausted?(429, "You have exceeded your usage limit")
    assert HTTPSupport.quota_exhausted?(429, "billing limit reached")
    assert HTTPSupport.quota_exhausted?(429, "Your credit balance is low")
    assert HTTPSupport.quota_exhausted?(429, "plan limit exceeded")
    assert HTTPSupport.quota_exhausted?(429, "quota exceeded for this month")
  end

  def test_quota_exhausted_429_all_are_quota
    assert HTTPSupport.quota_exhausted?(429, "Too many requests")
    assert HTTPSupport.quota_exhausted?(429, "")
  end

  def test_quota_exhausted_403_with_quota_body_patterns
    assert HTTPSupport.quota_exhausted?(403, "insufficient_quota for this key")
    assert HTTPSupport.quota_exhausted?(403, "billing issue detected")
  end

  def test_quota_not_exhausted_403_empty_and_no_pattern
    refute HTTPSupport.quota_exhausted?(403, "")
    refute HTTPSupport.quota_exhausted?(403, "Forbidden")
    refute HTTPSupport.quota_exhausted?(403, "Access denied")
  end

  def test_quota_not_exhausted_403_nil_body
    refute HTTPSupport.quota_exhausted?(403, nil), "403 with nil body should not match"
  end

  def test_quota_not_exhausted_other_status_codes
    refute HTTPSupport.quota_exhausted?(500, "Internal Server Error")
    refute HTTPSupport.quota_exhausted?(502, "Bad Gateway")
    refute HTTPSupport.quota_exhausted?(400, "Bad Request")
    refute HTTPSupport.quota_exhausted?(200, "OK")
  end
end

class TestExtractResetTime < Minitest::Test
  FakeResponse = Struct.new(:headers, :body, :code)

  def make_response(body:, headers: {}, code: 429)
    r = FakeResponse.new(headers, body, code)
    def r.[](k); headers[k]; end
    r
  end

  def test_extract_from_retry_after_seconds
    now = Time.now.to_f
    r = make_response(body: "", headers: {"Retry-After" => "30"})
    result = HTTPSupport.extract_reset_time(r, "", 429, default_seconds: 60)
    assert_in_delta now + 30, result, 1.0
  end

  def test_extract_from_x_ratelimit_reset_requests
    future = (Time.now + 120).to_i.to_s
    r = make_response(body: "", headers: {"x-ratelimit-reset-requests" => future})
    result = HTTPSupport.extract_reset_time(r, "", 429, default_seconds: 60)
    assert result > Time.now.to_f, "reset time should be in the future"
  end

  def test_extract_from_body_reset_time
    future = (Time.now + 300).to_f
    body = %({"reset_time": #{future}})
    r = make_response(body: body)
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta future, result, 1.0
  end

  def test_extract_from_body_error_nested_reset
    future = (Time.now + 300).to_f
    body = %({"error": {"reset": #{future}}})
    r = make_response(body: body)
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta future, result, 1.0
  end

  def test_extract_from_body_retry_after_ms
    body = %({"retry_after_ms": 30000})
    r = make_response(body: body)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta now + 30, result, 1.0
  end

  def test_fallback_to_default_seconds
    r = make_response(body: "plain error")
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, "plain error", 429, default_seconds: 120)
    assert_in_delta now + 120, result, 1.0
  end

  def test_past_reset_time_falls_back
    past = (Time.now - 100).to_f.to_s
    r = make_response(body: "", headers: {"x-ratelimit-reset-requests" => past})
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, "", 429, default_seconds: 60)
    assert_in_delta now + 60, result, 1.0
  end

  def test_nil_body_falls_back_to_default
    r = make_response(body: nil)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, nil, 429, default_seconds: 60)
    assert_in_delta now + 60, result, 1.0, "nil body should fall back to default"
  end

  def test_extract_from_text_resets_in_days
    body = JSON.generate({"error" => {"message" => "Monthly usage limit reached. Resets in 1 day."}})
    r = make_response(body: body)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta now + 86400, result, 2.0, "should parse 'Resets in 1 day' from error message"
  end

  def test_extract_from_text_resets_in_hours
    body = JSON.generate({"error" => {"message" => "Rate limit exceeded. Resets in 2 hours."}})
    r = make_response(body: body)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta now + 7200, result, 2.0, "should parse 'Resets in 2 hours' from error message"
  end

  def test_extract_from_text_retry_in_minutes
    body = JSON.generate({"error" => {"message" => "retry in 30 minutes"}})
    r = make_response(body: body)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta now + 1800, result, 2.0, "should parse 'retry in 30 minutes' from error message"
  end

  def test_extract_from_text_plain_body
    body = "Usage limit reached. Resets in 12 hours. Please upgrade."
    r = make_response(body: body)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta now + 43200, result, 2.0, "should parse 'Resets in 12 hours' from plain text body"
  end

  def test_extract_from_text_top_level_message
    body = JSON.generate({"message" => "Available in 45 minutes"})
    r = make_response(body: body)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta now + 2700, result, 2.0, "should parse from top-level message field"
  end

  def test_extract_from_text_no_match_falls_back
    body = JSON.generate({"error" => {"message" => "Something went wrong"}})
    r = make_response(body: body)
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, body, 429, default_seconds: 60)
    assert_in_delta now + 60, result, 1.0, "no duration text should fall back to default"
  end

  def test_retry_after_header_not_capped_at_60
    # MAX_RETRY_AFTER was raised from 60 to 86400 to allow monthly quota
    # pauses from Retry-After headers, not just transient rate limits.
    r = make_response(body: "", headers: {"Retry-After" => "3600"})
    now = Time.now.to_f
    result = HTTPSupport.extract_reset_time(r, "", 429, default_seconds: 60)
    assert_in_delta now + 3600, result, 2.0, "Retry-After of 3600s should not be capped at 60"
  end

  def test_parse_duration_from_text_variants
    assert_equal 86400, HTTPSupport.parse_duration_from_text("Resets in 1 day")
    assert_equal 86400, HTTPSupport.parse_duration_from_text("resets in 1 days")
    assert_equal 3600, HTTPSupport.parse_duration_from_text("retry in 1 hour")
    assert_equal 1800, HTTPSupport.parse_duration_from_text("try again in 30 minutes")
    assert_equal 45, HTTPSupport.parse_duration_from_text("available in 45 seconds")
    assert_nil HTTPSupport.parse_duration_from_text("no duration here")
    assert_nil HTTPSupport.parse_duration_from_text(nil)
  end
end

class TestProviderSelectorQuotaPause < Minitest::Test
  def setup
    @providers = [
      {"provider" => "prov_a", "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka"}.freeze,
      {"provider" => "prov_b", "model" => "m-b", "base_url" => "https://b.example.com/v1", "api_key" => "kb"}.freeze,
      {"provider" => "prov_c", "model" => "m-c", "base_url" => "https://c.example.com/v1", "api_key" => "kc"}.freeze
    ].freeze
    @model_config = {"name" => "test-model", "providers" => [
      {"provider" => "prov_a", "model" => "m-a", "primary" => true},
      {"provider" => "prov_b", "model" => "m-b"},
      {"provider" => "prov_c", "model" => "m-c"}
    ]}
  end

  def selector
    @selector ||= ProviderSelector.new("test-model", @providers, model_config: @model_config)
  end

  def test_quota_pause_not_paused_by_default
    refute selector.quota_paused?("prov_a")
    refute selector.quota_paused?("prov_b")
  end

  def test_quota_pause_sets_and_checks
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_b", reset_time, reason: "rate_limited")
    assert selector.quota_paused?("prov_b")
    refute selector.quota_paused?("prov_a")
  end

  def test_quota_pause_auto_expires
    past_time = Time.now.to_f - 10
    selector.quota_pause!("prov_b", past_time, reason: "rate_limited")
    refute selector.quota_paused?("prov_b"), "expired quota pause should auto-clear"
  end

  def test_quota_pause_excluded_from_ordered_providers
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_b", reset_time, reason: "rate_limited")
    ordered = selector.ordered_providers
    names = ordered.map { |p| p["provider"] }
    refute_includes names, "prov_b", "quota-paused provider should be excluded from ordered_providers"
    assert_includes names, "prov_a"
    assert_includes names, "prov_c"
  end

  def test_quota_pause_clear_resets
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_b", reset_time, reason: "rate_limited")
    assert selector.quota_paused?("prov_b")
    selector.clear_quota_pause("prov_b")
    refute selector.quota_paused?("prov_b")
  end

  def test_ordered_providers_config_order_without_auto_switch
    ordered = selector.ordered_providers(auto_switch: false)
    names = ordered.map { |p| p["provider"] }
    assert_equal ["prov_a", "prov_b", "prov_c"], names
  end

  def test_ordered_providers_config_order_with_quota_pause_no_auto_switch
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_b", reset_time, reason: "rate_limited")
    ordered = selector.ordered_providers(auto_switch: false)
    names = ordered.map { |p| p["provider"] }
    assert_equal ["prov_a", "prov_c"], names, "paused provider excluded, others in config order"
  end

  def test_ordered_providers_sorted_by_score_with_auto_switch
    3.times { selector.update_metrics("prov_b", 0.5, 150.0) }
    3.times { selector.update_metrics("prov_c", 3.0, 20.0) }
    ordered = selector.ordered_providers(auto_switch: true)
    names = ordered.map { |p| p["provider"] }
    assert_equal "prov_a", names[0], "active provider first"
    assert_equal "prov_b", names[1], "prov_b has better score"
    assert_equal "prov_c", names[2], "prov_c has worse score"
  end

  def test_ordered_providers_skips_quota_paused_active
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_a", reset_time, reason: "rate_limited")
    ordered = selector.ordered_providers(auto_switch: false)
    names = ordered.map { |p| p["provider"] }
    refute_includes names, "prov_a", "quota-paused active provider should be excluded"
    assert_includes names, "prov_b"
    assert_includes names, "prov_c"
  end

  def test_ordered_providers_skips_quota_paused_active_with_auto_switch
    reset_time = Time.now.to_f + 300
    3.times { selector.update_metrics("prov_c", 0.5, 150.0) }
    selector.quota_pause!("prov_a", reset_time, reason: "rate_limited")
    ordered = selector.ordered_providers(auto_switch: true)
    names = ordered.map { |p| p["provider"] }
    refute_includes names, "prov_a", "quota-paused active provider should be excluded"
    assert_includes names, "prov_b"
    assert_includes names, "prov_c"
  end

  def test_quota_pause_takes_max_time
    t1 = Time.now.to_f + 300
    t2 = Time.now.to_f + 600
    selector.quota_pause!("prov_b", t1, reason: "rate_limited")
    assert selector.quota_paused?("prov_b")
    # Second pause with shorter time — should NOT shorten the pause
    selector.quota_pause!("prov_b", t1 - 100, reason: "rate_limited")
    qp = selector.instance_variable_get(:@quota_pauses)["prov_b"]
    assert_in_delta t1, qp.paused_until, 0.01, "shorter pause should not overwrite longer one"
    # Third pause with longer time — should extend
    selector.quota_pause!("prov_b", t2, reason: "payment_required")
    assert_in_delta t2, qp.paused_until, 0.01, "longer pause should overwrite shorter one"
  end

  def test_provider_stats_includes_quota_pause_info
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_b", reset_time, reason: "rate_limited")
    stats = selector.provider_stats
    assert stats["prov_b"][:quota_paused], "prov_b should show quota_paused=true in stats"
    refute_nil stats["prov_b"][:quota_pause_until]
    assert_equal "rate_limited", stats["prov_b"][:quota_pause_reason]
    refute stats["prov_a"][:quota_paused]
    assert_nil stats["prov_a"][:quota_pause_until]
  end

  def test_to_state_includes_quota_pauses
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_b", reset_time, reason: "rate_limited")
    state = selector.to_state
    qp = state[:quota_pauses]
    refute_nil qp
    assert_in_delta reset_time, qp["prov_b"]["paused_until"], 0.01
    assert_equal "rate_limited", qp["prov_b"]["reason"]
    assert_nil qp["prov_a"]["paused_until"]
  end

  def test_restore_state_restores_quota_pauses
    reset_time = Time.now.to_f + 300
    selector.quota_pause!("prov_b", reset_time, reason: "rate_limited")
    state = selector.to_state

    s2 = ProviderSelector.new("test-model", @providers, model_config: @model_config)
    s2.restore_state!(state)
    assert s2.quota_paused?("prov_b")
    refute s2.quota_paused?("prov_a")
  end

  def test_restore_state_skips_expired_quota_pauses
    past_time = Time.now.to_f - 100
    state = {
      "active_provider" => "prov_a",
      "samples" => {},
      "circuits" => {},
      "quota_pauses" => {
        "prov_b" => {"paused_until" => past_time, "reason" => "rate_limited"}
      },
      "request_count" => 0
    }
    s = ProviderSelector.new("test-model", @providers, model_config: @model_config)
    s.restore_state!(state)
    refute s.quota_paused?("prov_b"), "expired quota pause should not be restored"
  end
end

class TestFailureReasonQuotaExhausted < Minitest::Test
  def test_quota_exhausted_reason
    result = {status: 429, error: "Quota exhausted", quota_pause_until: Time.now.to_f + 60, quota_pause_reason: "rate_limited"}
    assert_equal "quota_exhausted", RequestHandler.failure_reason(result)
  end

  def test_rate_limited_still_detected_by_status
    result = {status: 429, error: "Too many requests"}
    assert_equal "rate_limited", RequestHandler.failure_reason(result)
  end

  def test_quota_exhausted_takes_priority_over_status
    result = {status: 429, error: "rate limited", quota_pause_until: Time.now.to_f + 60, quota_pause_reason: "rate_limited"}
    assert_equal "quota_exhausted", RequestHandler.failure_reason(result)
  end
end