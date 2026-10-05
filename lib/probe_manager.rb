require "securerandom"
require "timeout"
require_relative "key_rotator"
module ProbeManager
  PROBE_BODY = {
    "messages" => [{"role" => "user", "content" => "Write a brief paragraph about the weather"}],
    "max_tokens" => 100
  }.freeze

  # Hard upper bound on a single probe so a half-open or hung provider
  # cannot keep @probing latched and block all future probes for a model.
  PROBE_DEADLINE_SECONDS = 30

  # Global probe rate limiter — tracks recent probe launches across all
  # models so a misconfigured probe_interval (or many models all probing)
  # can't burn through tokens at $/req scale.
  RECENT_PROBES = []
  RATE_LOCK = Mutex.new

  def self.reset_rate_limiter!
    RATE_LOCK.synchronize { RECENT_PROBES.clear }
  end

  def self.allow_probe?(max_per_minute)
    return true if max_per_minute.nil? || max_per_minute <= 0
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    RATE_LOCK.synchronize do
      cutoff = now - 60.0
      RECENT_PROBES.shift while RECENT_PROBES.first && RECENT_PROBES.first < cutoff
      return false if RECENT_PROBES.size >= max_per_minute
      RECENT_PROBES << now
      true
    end
  end

  def self.launch(selector, model_name, path, headers, timeouts:, auto_switch:, logger:, deadline_seconds: PROBE_DEADLINE_SECONDS, max_per_minute: nil)
    unless allow_probe?(max_per_minute)
      logger.info("[probe] skipped #{model_name} — global rate (#{max_per_minute}/min) reached")
      selector.probe_finished
      return nil
    end

    probe_id = SecureRandom.uuid[0..7]

    Thread.new do
      named_threads = selector.other_providers.filter_map do |provider_config|
        p_name = provider_config["provider"]
        if selector.quota_paused?(provider_config)
          logger.debug("[probe:#{probe_id}] Skipping quota-paused provider #{p_name}")
          next
        end
        if selector.circuit_open?(provider_config)
          logger.debug("[probe:#{probe_id}] Skipping circuit-broken provider #{p_name}")
          next
        end
        thread = Thread.new do
          Thread.current.report_on_exception = false
          begin
            Timeout.timeout(deadline_seconds) do
              metrics = probe_provider(provider_config, path, PROBE_BODY, provider_config["model"], headers, timeouts: timeouts, logger: logger, selector: selector)
              [provider_config, metrics]
            end
          rescue Timeout::Error
            logger.warn("[probe:#{probe_id}] #{p_name} exceeded #{deadline_seconds}s deadline")
            [provider_config, {ttft: Float::INFINITY, tps: nil}]
          rescue => e
            logger.error("[probe:#{probe_id}] #{p_name} thread error: #{e.class}: #{e.message}")
            [provider_config, {ttft: Float::INFINITY, tps: nil}]
          end
        end
        [p_name, provider_config, thread]
      end

      results = named_threads.map { |_p_name, provider_config, t| [provider_config, t.value[1]] }

      results.each do |provider_config, m|
        selector.update_metrics(provider_config, m[:ttft], m[:tps])
        tps_str = m[:tps] ? m[:tps].to_s : "N/A"
        logger.info("[probe:#{probe_id}] #{model_name}/#{provider_config["provider"]}: ttft=#{m[:ttft]}s tps=#{tps_str}")
      end

      selector.evaluate_and_select(logger, auto_switch: auto_switch)
    rescue => e
      logger.error("[probe:#{probe_id}] #{model_name} error: #{e.message}")
    ensure
      selector.probe_finished
    end
  end

  def self.probe_provider(provider_config, path, body, body_model, incoming_headers, timeouts:, logger:, selector: nil)
    pname = provider_config["provider"]
    rotator = KeyRotator.for(provider_config)
    probe_key = rotator.acquire
    if probe_key.nil?
      # Every key for this account is currently rate-limited — possibly by
      # another model sharing the account. Don't fall back to the default key
      # (it is one of the paused ones); propagate the shared cooldown to this
      # model's selector so it stops probing/trying until the earliest reset.
      resume = rotator.resume_time
      logger.debug("[probe] #{pname}: all API keys rate-limited, skipping probe")
      if selector && resume
        selector.quota_pause!(provider_config, resume, reason: "rate_limited")
        Metrics.increment(:provider_quota_paused, labels: {provider: pname, model: provider_config["model"], reason: "rate_limited"})
      end
      return {ttft: Float::INFINITY, tps: nil}
    end
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true, api_key: probe_key)

    http = nil
    pooled = false
    begin
      http = HTTPSupport.create_http(uri, timeouts: timeouts)
      http.start unless http.started?
      pooled = true

      request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Streaming.stream_response(http, request, request_start)

      if result[:error]
        error_str = result[:error]
        status_match = /\AHTTP (\d{3})/.match(error_str)
        status_code = status_match ? status_match[1].to_i : nil
        error_body = error_str.sub(/\AHTTP \d{3}:\s*/, "")

        if status_code && HTTPSupport.quota_exhausted?(status_code, error_body)
          reason = status_code == 402 ? "payment_required" : (status_code == 429 ? "rate_limited" : "quota_exhausted")
          default_secs = (defined?(ConfigStore) ? ConfigStore.quota_pause_default_seconds : nil) || HTTPSupport::DEFAULT_QUOTA_PAUSE_SECONDS
          reset_time = HTTPSupport.extract_reset_time_from_error(error_str, status_code, default_seconds: default_secs)
          # Pause the key that was just rate-limited. Only pause the whole
          # provider once no key remains available — single-key providers pause
          # immediately, matching prior behaviour. With multiple keys the next
          # probe/request simply rotates to the next key.
          rotator.pause(probe_key, reset_time) if probe_key
          keys_exhausted = !rotator.multiple? || rotator.acquire.nil?
          if selector && keys_exhausted
            # Pause the provider only until the SOONEST key reset (not this
            # key's), so it recovers as early as any key frees up.
            provider_resume = rotator.resume_time || reset_time
            selector.quota_pause!(provider_config, provider_resume, reason: reason)
            Metrics.increment(:provider_quota_paused, labels: {provider: pname, model: provider_config["model"], reason: reason})
            logger.warn("[probe] #{pname}: Quota exhausted (#{reason}), all keys down — pausing provider until #{Time.at(provider_resume).utc.iso8601}")
          else
            logger.warn("[probe] #{pname}: Quota exhausted (#{reason}) on current key — rotating to next")
          end
        end

        logger.warn("[probe] #{pname}: #{error_str}")
        return {ttft: Float::INFINITY, tps: nil}
      end

      # Prefer server-side TTFT (matches provider dashboards) when available;
      # fall back to the arrival-window estimate.
      ttft = result[:first_token_time] ? (result[:first_token_time] - request_start).round(3) : Float::INFINITY

      unless result[:usage_data]
        logger.debug("[probe] #{pname}: usage_data absent (provider ignored stream_options)")
        return {ttft: ttft, tps: nil}
      end

      tokens = Streaming.extract_token_counts(result[:usage_data], perf_metrics: result[:perf_metrics], server_duration: result[:server_duration])
      completion_tokens = tokens[:completion] || 0

      # Override arrival TTFT with server-side timing when the provider reports it.
      ttft = tokens[:server_ttft] || ttft
      # Use server-side TPS when the provider reports it. Probes no longer
      # emit arrival-window TPS — the tiny-payload probe's arrival TPS is the
      # noisiest case and would skew the scorer's average.
      tps = tokens[:server_tps]

      if tps.nil? || tps == 0
        diag = []
        diag << "completion_tokens=#{completion_tokens}"
        diag << "content_tokens=#{tokens[:content]}"
        diag << "first_token_time=#{result[:first_token_time] ? format("%.3f", result[:first_token_time]) : "nil"}"
        diag << "last_any=#{result[:last_any_token_time] ? format("%.3f", result[:last_any_token_time]) : "nil"}"
        logger.debug("[probe] #{pname}: TPS=nil diag: #{diag.join(", ")}")
      end

      {ttft: ttft, tps: tps}
    rescue => e
      pooled = false
      logger.debug("[probe] #{pname}: #{e.message}")
      {ttft: Float::INFINITY, tps: nil}
    ensure
      if http
        if pooled
          HTTPSupport.checkin_http(uri, http)
        else
          HTTPSupport.discard_http(http)
        end
      end
    end
  end
end
