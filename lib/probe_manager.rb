require "securerandom"
require "timeout"
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
        if selector.quota_paused?(p_name)
          logger.debug("[probe:#{probe_id}] Skipping quota-paused provider #{p_name}")
          next
        end
        if selector.circuit_open?(p_name)
          logger.debug("[probe:#{probe_id}] Skipping circuit-broken provider #{p_name}")
          next
        end
        thread = Thread.new do
          Thread.current.report_on_exception = false
          begin
            Timeout.timeout(deadline_seconds) do
              metrics = probe_provider(provider_config, path, PROBE_BODY, provider_config["model"], headers, timeouts: timeouts, logger: logger, selector: selector)
              [p_name, metrics]
            end
          rescue Timeout::Error
            logger.warn("[probe:#{probe_id}] #{p_name} exceeded #{deadline_seconds}s deadline")
            [p_name, {ttft: Float::INFINITY, tps: nil}]
          rescue => e
            logger.error("[probe:#{probe_id}] #{p_name} thread error: #{e.class}: #{e.message}")
            [p_name, {ttft: Float::INFINITY, tps: nil}]
          end
        end
        [p_name, thread]
      end

      results = named_threads.map { |p_name, t| t.value }

      results.each do |p_name, m|
        selector.update_metrics(p_name, m[:ttft], m[:tps])
        tps_str = m[:tps] ? m[:tps].to_s : "N/A"
        logger.info("[probe:#{probe_id}] #{model_name}/#{p_name}: ttft=#{m[:ttft]}s tps=#{tps_str}")
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
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    http = nil
    pooled = false
    begin
      http = HTTPSupport.create_http(uri, timeouts: timeouts)
      http.start unless http.started?
      pooled = true

      request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Streaming.stream_response(http, request, request_start)
      stream_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if result[:error]
        error_str = result[:error]
        status_match = /\AHTTP (\d{3})/.match(error_str)
        status_code = status_match ? status_match[1].to_i : nil
        error_body = error_str.sub(/\AHTTP \d{3}:\s*/, "")

        if status_code && HTTPSupport.quota_exhausted?(status_code, error_body)
          reason = status_code == 402 ? "payment_required" : (status_code == 429 ? "rate_limited" : "quota_exhausted")
          reset_time = HTTPSupport.extract_reset_time_from_error(error_str, status_code,
            default_seconds: (defined?(ConfigStore) ? ConfigStore.quota_pause_default_seconds : HTTPSupport::DEFAULT_QUOTA_PAUSE_SECONDS))
          logger.warn("[probe] #{pname}: Quota exhausted (#{reason}), pausing until #{Time.at(reset_time).utc.iso8601}")
          if selector
            selector.quota_pause!(pname, reset_time, reason: reason)
            Metrics.increment(:provider_quota_paused, labels: {provider: pname, model: provider_config["model"], reason: reason})
          end
        end

        logger.warn("[probe] #{pname}: #{error_str}")
        return {ttft: Float::INFINITY, tps: nil}
      end

      ttft = result[:first_token_time] ? (result[:first_token_time] - request_start).round(3) : Float::INFINITY

      unless result[:usage_data]
        logger.debug("[probe] #{pname}: usage_data absent (provider ignored stream_options)")
        return {ttft: ttft, tps: nil}
      end

      tokens = Streaming.extract_token_counts(result[:usage_data])
      completion_tokens = tokens[:completion] || 0

      tps = Streaming.compute_tps(completion_tokens, result[:first_token_time], result[:last_any_token_time])

      if tps.nil?
        tps = Streaming.compute_tps(tokens[:content], result[:first_content_time], result[:last_content_time])
      end

      if tps.nil? && result[:first_token_time]
        elapsed = stream_end - result[:first_token_time]
        if elapsed > 0 && completion_tokens > 0
          tps = (completion_tokens / elapsed).round(1)
        end
      end

      if tps.nil? || tps == 0
        diag = []
        diag << "completion_tokens=#{completion_tokens}"
        diag << "content_tokens=#{tokens[:content]}"
        diag << "first_token_time=#{result[:first_token_time] ? format("%.3f", result[:first_token_time]) : "nil"}"
        diag << "last_any=#{result[:last_any_token_time] ? format("%.3f", result[:last_any_token_time]) : "nil"}"
        diag << "stream_end=#{format("%.3f", stream_end)}"
        logger.debug("[probe] #{pname}: TPS=0 diag: #{diag.join(", ")}")
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
