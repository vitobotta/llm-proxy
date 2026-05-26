# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/metrics"

class TestMetrics < Minitest::Test
  def setup
    Metrics.reset!
  end

  def test_counter_increments_and_emits_total_with_type_help
    Metrics.increment(:requests_total, labels: {status: 200})
    Metrics.increment(:requests_total, labels: {status: 200})
    Metrics.increment(:requests_total, labels: {status: 500})

    out = Metrics.to_prometheus

    assert_includes out, "# TYPE llm_proxy_requests_total counter"
    assert_includes out, "# HELP llm_proxy_requests_total"
    assert_match %r{llm_proxy_requests_total\{status="200"\} 2}, out
    assert_match %r{llm_proxy_requests_total\{status="500"\} 1}, out
  end

  def test_histogram_emits_cumulative_buckets_with_le_inf
    [0.05, 0.4, 0.7, 2.0, 8.0, 50.0].each { |v| Metrics.observe(:request_duration_seconds, v) }

    out = Metrics.to_prometheus

    assert_includes out, "# TYPE llm_proxy_request_duration_seconds histogram"
    assert_includes out, %(llm_proxy_request_duration_seconds_bucket{le="+Inf"} 6)
    assert_includes out, "llm_proxy_request_duration_seconds_count 6"
    assert_includes out, "llm_proxy_request_duration_seconds_sum"

    # 0.05 -> all 8 buckets (everything is >= 0.05)
    # 0.1 bucket: count of values <= 0.1 = 1 (0.05)
    assert_match %r{llm_proxy_request_duration_seconds_bucket\{le="0\.1"\} 1}, out
    # 0.5 bucket: 0.05, 0.4 -> 2
    assert_match %r{llm_proxy_request_duration_seconds_bucket\{le="0\.5"\} 2}, out
    # 1 bucket: 0.05, 0.4, 0.7 -> 3
    assert_match %r{llm_proxy_request_duration_seconds_bucket\{le="1"\} 3}, out
    # 5 bucket: + 2.0 -> 4
    assert_match %r{llm_proxy_request_duration_seconds_bucket\{le="5"\} 4}, out
    # 10 bucket: + 8.0 -> 5
    assert_match %r{llm_proxy_request_duration_seconds_bucket\{le="10"\} 5}, out
    # 60+ contains 50.0 too
    assert_match %r{llm_proxy_request_duration_seconds_bucket\{le="60"\} 6}, out
  end

  def test_buckets_cumulative_invariant
    [0.2, 0.6, 1.5, 7].each { |v| Metrics.observe(:request_duration_seconds, v) }
    out = Metrics.to_prometheus

    counts = out.scan(/llm_proxy_request_duration_seconds_bucket\{le="([^"]+)"\} (\d+)/).map { |le, c| [le, c.to_i] }
    # Cumulative: counts must be monotonically non-decreasing.
    refute_empty counts
    counts.each_cons(2) do |(_, a), (_, b)|
      assert b >= a, "buckets must be cumulative: #{counts}"
    end
    # Final (+Inf) must equal _count
    inf_count = counts.last[1]
    count_line = out[/llm_proxy_request_duration_seconds_count (\d+)/, 1].to_i
    assert_equal count_line, inf_count
  end

  def test_concurrent_increments_are_lossless
    n_threads = 50
    incs_per_thread = 200
    threads = n_threads.times.map do
      Thread.new do
        incs_per_thread.times { Metrics.increment(:requests_total, labels: {status: 200}) }
      end
    end
    threads.each(&:join)
    out = Metrics.to_prometheus
    expected = n_threads * incs_per_thread
    assert_match %r{llm_proxy_requests_total\{status="200"\} #{expected}}, out
  end

  def test_upstream_ttft_histogram_emits_with_provider_label
    Metrics.observe(:upstream_ttft_seconds, 0.3, labels: {provider: "wafer", model: "glm-5"})
    Metrics.observe(:upstream_ttft_seconds, 1.5, labels: {provider: "wafer", model: "glm-5"})
    out = Metrics.to_prometheus
    assert_includes out, "# TYPE llm_proxy_upstream_ttft_seconds histogram"
    assert_includes out, %(llm_proxy_upstream_ttft_seconds_count{provider="wafer",model="glm-5"} 2)
    assert_match(/llm_proxy_upstream_ttft_seconds_bucket\{provider="wafer",model="glm-5",le="0\.5"\} 1/, out)
  end

  def test_provider_failure_reason_label
    Metrics.increment(:provider_failure, labels: {provider: "wafer", model: "glm-5", reason: "rate_limited"})
    Metrics.increment(:provider_failure, labels: {provider: "wafer", model: "glm-5", reason: "timeout"})
    out = Metrics.to_prometheus
    assert_match(/provider_failure_total\{[^}]*reason="rate_limited"\} 1/, out)
    assert_match(/provider_failure_total\{[^}]*reason="timeout"\} 1/, out)
  end

  def test_label_values_are_escaped
    Metrics.increment(:provider_failure, labels: {provider: %(weird"value\nwith\\backslash)})
    out = Metrics.to_prometheus
    assert_includes out, %(provider="weird\\"value\\nwith\\\\backslash")
  end
end
