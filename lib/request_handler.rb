# frozen_string_literal: true

module RequestHandler
  def with_auto_select(model:, model_name:, path:, body:, headers:)
    snap = ConfigStore.snapshot
    selector = snap[:selectors][model_name]
    model_entry = snap[:models][model_name]

    probing = model_entry&.dig("probing_enabled") != false
    auto_switch = model_entry&.dig("auto_switch") == true
    probe_interval = model_entry&.dig("probe_interval") || snap[:probe_interval] || 3

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REQUEST_DEADLINE
    max_rounds = settings.max_rounds || 3

    result = nil
    attempts = []
    deadline_hit = false

    max_rounds.times do |round|
      # Re-evaluate the provider list each round. record_failure and
      # quota_pause! invalidate @cached_ordered, so providers that opened
      # their circuit or hit quota in a prior round are excluded here.
      providers = selector.ordered_providers(auto_switch: auto_switch)

      if providers.empty?
        settings.logger.warn("[#{@request_id}/#{model_name}] No providers configured for model, aborting")
        break
      end

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        deadline_hit = true
        settings.logger.warn("[#{@request_id}/#{model_name}] Request deadline exceeded after trying #{attempts.size} provider(s), aborting")
        break
      end

      # Exponential backoff between rounds (delay between groups of retries).
      # Round 0 starts immediately; subsequent rounds sleep backoff_base * 2^(round-1)
      # with the same jitter factor used by per-attempt backoff.
      if round > 0
        delay_base = settings.backoff_base * (2 ** (round - 1))
        sleep(delay_base * (0.5 + rand * 0.5))
        settings.logger.info("[#{@request_id}/#{model_name}] Round #{round + 1}/#{max_rounds} after backoff")
      else
        settings.logger.info("[#{@request_id}/#{model_name}] Round 1/#{max_rounds}")
      end

      providers.each_with_index do |provider_config, i|
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          deadline_hit = true
          settings.logger.warn("[#{@request_id}/#{model_name}] Request deadline exceeded after trying #{attempts.size} provider(s), aborting")
          break
        end
        p_name = provider_config["provider"]
        p_model = provider_config["model"]
        if round == 0 && i == 0
          settings.logger.info("[#{@request_id}/#{model_name}] Using #{p_name} (#{p_model})")
        else
          prev = attempts.last
          prev_reason = prev ? "#{prev[:provider]} #{prev[:reason]}#{" (status=#{prev[:status]})" if prev[:status]}" : "previous failure"
          settings.logger.info("[#{@request_id}/#{model_name}] Fallback to #{p_name} (#{p_model}) because #{prev_reason}")
        end

        log_prefix = "[#{@request_id}/#{model_name}/#{p_name}]"
        remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 1].max
        result = yield(provider_config, path, body, p_model, headers, log_prefix, remaining)
        if result&.dig(:success)
          record_metrics(selector, p_name, result)
          selector.record_success(p_name)
          Metrics.increment(:provider_success, labels: {provider: p_name, model: model_name})
          if result[:ttft]
            Metrics.observe(:upstream_ttft_seconds, result[:ttft], labels: {provider: p_name, model: model_name})
          end
          break
        else
          reason = RequestHandler.failure_reason(result)
          attempts << {provider: p_name, status: result.is_a?(Hash) ? result[:status] : nil, error: result.is_a?(Hash) ? result[:error] : nil, reason: reason}
          if result.is_a?(Hash) && result[:quota_pause_until]
            selector.quota_pause!(p_name, result[:quota_pause_until], reason: result[:quota_pause_reason])
            Metrics.increment(:provider_quota_paused, labels: {provider: p_name, model: model_name, reason: result[:quota_pause_reason] || "unknown"})
          else
            selector.record_failure(p_name)
          end
          Metrics.increment(:provider_failure, labels: {provider: p_name, model: model_name, reason: reason})
        end
      end

      break if result&.dig(:success)
      break if deadline_hit
    end

    if probing && selector.record_and_maybe_probe(probe_interval)
      ProbeManager.launch(selector, model_name, path, headers,
        timeouts: ConfigStore.timeouts, auto_switch: auto_switch, logger: settings.logger,
        max_per_minute: ConfigStore.probe_max_per_minute)
    end

    return result if result&.dig(:success)

    # All providers failed (or deadline hit). Synthesize a final result that
    # carries enough context for operators to debug from the response alone.
    failure_summary = build_failure_summary(attempts, deadline_hit)
    settings.logger.warn("[#{@request_id}/#{model_name}] #{failure_summary[:error]}")
    failure_summary
  end

  def build_failure_summary(attempts, deadline_hit)
    if attempts.empty?
      return {success: false, error: deadline_hit ? "Request deadline exceeded before any provider attempted" : "No providers available", status: 503}
    end

    summary_lines = attempts.map { |a| "#{a[:provider]}: #{a[:reason]}#{" (status=#{a[:status]})" if a[:status]}" }
    last_status = attempts.last[:status]
    fallback_status = (last_status && last_status >= 400 && last_status < 600) ? last_status : 502

    msg = deadline_hit ? "All providers failed (request deadline exceeded)" : "All providers failed"
    {
      success: false,
      error: "#{msg}: #{summary_lines.join("; ")}",
      detail: {attempts: attempts.map { |a| {provider: a[:provider], status: a[:status], reason: a[:reason]} }, deadline_hit: deadline_hit},
      status: fallback_status
    }
  end

  def record_metrics(selector, provider_name, result)
    tps = result[:total_tps] || result[:content_tps]
    selector.update_metrics(provider_name, result[:ttft], tps,
      tokens: result[:completion_tokens]) if result[:ttft]
  end

  # Categorize a failure result into a stable Prometheus label.
  # Keep cardinality bounded — don't use raw exception messages.
  def self.failure_reason(result)
    return "unknown" unless result.is_a?(Hash)
    status = result[:status]
    err = result[:error].to_s
    return "quota_exhausted" if result[:quota_pause_until]
    if status
      return "rate_limited" if status == 429
      return "client_error" if status >= 400 && status < 500
      return "server_error" if status >= 500
    end
    return "timeout" if err.include?("Timeout")
    return "client_disconnect" if err == "Client disconnected"
    return "rate_limited" if err.include?("Rate limited")
    return "connection_reset" if err.include?("Connection reset")
    "error"
  end

  MAX_ACCUMULATED_SIZE = 512 * 1024
  ACCUMULATED_TAIL_SIZE = 64 * 1024
  REQUEST_DEADLINE = 600
  def try_stream(provider_config, path, body, body_model, incoming_headers, out:, log_prefix:, deadline_remaining: nil)
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    try_with_retries(log_prefix: log_prefix, body_model: body_model) do
      timeouts = ConfigStore.timeouts
      if deadline_remaining
        timeouts = timeouts.merge(read: [timeouts[:read], deadline_remaining].min)
      end
      http = HTTPSupport.create_http(uri, timeouts: timeouts)
      http.start unless http.started?
      pooled = true
      streamed_any = false

      timers = Streaming::TimerTracker.new
      usage_data = nil
      perf_metrics = nil
      server_duration = nil
      stream_result = nil
      tracking = ConfigStore.tracking_enabled
      accumulated = tracking ? +"" : nil

      begin
        http.request(request) do |response|
          if response.is_a?(Net::HTTPSuccess)
            if tracking
              usage_data, perf_metrics, server_duration = Streaming.consume_stream(response, tracker: timers) do |chunk, cr, _now|
                forward_chunk_to_client(out, chunk)
                streamed_any = true
                if accumulated
                  accumulated << chunk
                  if accumulated.bytesize > MAX_ACCUMULATED_SIZE
                    accumulated = accumulated.byteslice(-ACCUMULATED_TAIL_SIZE, ACCUMULATED_TAIL_SIZE)
                  end
                end
                accumulated = nil if cr.usage
              end
            else
              response.read_body do |chunk|
                forward_chunk_to_client(out, chunk)
                streamed_any = true
              end
            end

            if tracking
              unless usage_data
                fallback = Streaming.parse_chunk(accumulated.to_s) if accumulated
                usage_data = fallback.usage if fallback&.usage
                perf_metrics = fallback.perf_metrics if fallback&.perf_metrics
                server_duration = fallback.server_duration if fallback&.server_duration
              end

              stream_result = build_stream_result(log_prefix, timers, usage_data, perf_metrics: perf_metrics, server_duration: server_duration)
            else
              stream_result = {success: true}
            end
          else
            stream_result = handle_upstream_error(response, log_prefix)
          end
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IOError, EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, HTTPSupport::ClientDisconnected
        pooled = false
        # If we've already streamed data to the client, we can't retry —
        # the client would receive a garbled duplicate stream.
        raise HTTPSupport::ClientDisconnected if streamed_any
        raise
      ensure
        if pooled
          HTTPSupport.checkin_http(uri, http)
        else
          HTTPSupport.discard_http(http)
        end
      end
      stream_result
    end
  end

  def try_single_request(provider_config, path, body, body_model, incoming_headers, log_prefix:, deadline_remaining: nil)
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: false)

    try_with_retries(log_prefix: log_prefix, body_model: body_model) do
      timeouts = ConfigStore.timeouts
      if deadline_remaining
        timeouts = timeouts.merge(read: [timeouts[:read], deadline_remaining].min)
      end
      http = HTTPSupport.create_http(uri, timeouts: timeouts)
      http.start unless http.started?
      pooled = true
      begin
        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          settings.logger.info("#{log_prefix} Success")
          {success: true, response: [response.code.to_i, {"Content-Type" => "application/json"}, [response.body]]}
        else
          handle_upstream_error(response, log_prefix)
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IOError, EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, HTTPSupport::ClientDisconnected
        pooled = false
        raise
      ensure
        if pooled
          HTTPSupport.checkin_http(uri, http)
        else
          HTTPSupport.discard_http(http)
        end
      end
    end
  end

  def handle_non_stream_result(result)
    if result[:success]
      status result[:response][0]
      result[:response][1].each { |k, v| headers[k] = v }
      result[:response][2].first
    else
      err_status = result[:status] || 502
      status err_status
      json_error(status: err_status, message: result[:error], detail: result[:detail])
    end
  end

  def handle_streaming_error(result, out)
    return if result[:success]
    out << streaming_error(result[:error], detail: result[:detail])
    out << "data: [DONE]\n\n"
  rescue Errno::EPIPE, IOError, Puma::ConnectionError
    raise HTTPSupport::ClientDisconnected
  end

  def forward_chunk_to_client(out, chunk)
    out << chunk
  rescue Errno::EPIPE, IOError, Puma::ConnectionError
    raise HTTPSupport::ClientDisconnected
  end
end
