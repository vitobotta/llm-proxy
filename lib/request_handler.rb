# frozen_string_literal: true

require_relative "key_rotator"

module RequestHandler
  # Failure reasons after which the provider/round walk must stop instead of
  # falling back: the client is gone (client_disconnect), or chunks have
  # already been forwarded to the client so any further provider would
  # concatenate a garbled duplicate stream onto the output
  # (upstream_disconnect / StreamPartiallySent).
  TERMINAL_FALLBACK_REASONS = %w[client_disconnect upstream_disconnect].freeze

  def with_auto_select(model:, model_name:, path:, body:, headers:)
    snap = ConfigStore.snapshot
    selector = snap[:selectors][model_name]
    model_entry = snap[:models][model_name] || model

    unless selector
      # The model vanished between parse_request and here (a config reload
      # raced the request) — fail cleanly instead of NoMethodError → 500.
      settings.logger.warn("[#{@request_id}/#{model_name}] Model no longer configured (config reload mid-request), aborting")
      return {success: false, error: "Model '#{model_name}' is no longer configured", status: 503}
    end

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
          record_metrics(selector, provider_config, result)
          selector.record_success(provider_config)
          Metrics.increment(:provider_success, labels: {provider: p_name, model: model_name})
          if result[:ttft]
            Metrics.observe(:upstream_ttft_seconds, result[:ttft], labels: {provider: p_name, model: model_name})
          end
          break
        else
          reason = RequestHandler.failure_reason(result)
          attempts << {provider: p_name, status: result.is_a?(Hash) ? result[:status] : nil, error: result.is_a?(Hash) ? result[:error] : nil, reason: reason}
          if result.is_a?(Hash) && result[:quota_pause_until]
            selector.quota_pause!(provider_config, result[:quota_pause_until], reason: result[:quota_pause_reason])
            Metrics.increment(:provider_quota_paused, labels: {provider: p_name, model: model_name, reason: result[:quota_pause_reason] || "unknown"})
          elsif reason != "client_disconnect" && reason != "client_error"
            # Client-shape 4xx (bad request, not found, ...) is the caller's
            # fault — counting it toward the circuit breaker lets a stream of
            # bad client requests evict a healthy provider. Auth errors
            # (401/403) and everything upstream-side still count.
            selector.record_failure(provider_config)
          end
          Metrics.increment(:provider_failure, labels: {provider: p_name, model: model_name, reason: reason})
          # client_disconnect: the client is gone — no point trying the next
          # provider (it will also fail to write).
          # upstream_disconnect: chunks were already forwarded — the next
          # provider would concatenate a garbled duplicate stream.
          break if TERMINAL_FALLBACK_REASONS.include?(reason)
        end
      end

      break if result&.dig(:success)
      break if deadline_hit
      # client_disconnect / upstream_disconnect also break the rounds loop —
      # retrying across rounds is pointless when the client is already gone
      # or the client already holds a partial stream.
      break if result.is_a?(Hash) && TERMINAL_FALLBACK_REASONS.include?(RequestHandler.failure_reason(result))
    end

    if probing && selector.record_and_maybe_probe(probe_interval)
      # Probes always measure chat/completions — probe latency ranks providers
      # model-wide, independent of the request's API format.
      ProbeManager.launch(selector, model_name, "chat/completions", headers,
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

  def record_metrics(selector, provider, result)
    tps = result[:total_tps]
    # Only fall back to content_tps when the generation is long enough that
    # the arrival-window estimate is meaningful. For short generations
    # (< MIN_ARRIVAL_TPS_TOKENS), total_tps is intentionally nil and
    # content_tps is equally noisy — don't leak it to the scorer.
    if tps.nil? && (result[:completion_tokens] || 0) >= Streaming::MIN_ARRIVAL_TPS_TOKENS
      tps = result[:content_tps]
    end
    selector.update_metrics(provider, result[:ttft], tps,
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
      # 401/403 (non-quota) = misconfigured credentials or refused access at
      # the provider — a provider-side fault worth circuit-breaking. Other
      # 4xx are client-shape errors and must not penalise the provider.
      return "auth_error" if status == 401 || status == 403
      return "client_error" if status >= 400 && status < 500
      return "server_error" if status >= 500
    end
    return "timeout" if err.include?("Timeout")
    return "ttft_timeout" if err.include?("TTFT")
    return "client_disconnect" if err == "Client disconnected"
    return "upstream_disconnect" if err.include?("Upstream disconnect after partial stream")
    return "rate_limited" if err.include?("Rate limited")
    return "connection_reset" if err.include?("Connection reset")
    "error"
  end

  MAX_ACCUMULATED_SIZE = 512 * 1024
  ACCUMULATED_TAIL_SIZE = 64 * 1024
  REQUEST_DEADLINE = 600
  def try_stream(provider_config, path, body, body_model, incoming_headers, out:, log_prefix:, deadline_remaining: nil, responses_api: false, model_name: nil)
    rotator = KeyRotator.for(provider_config)

    try_with_retries(log_prefix: log_prefix, body_model: body_model, rotator: rotator) do |attempt_key|
      uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true, responses_api: responses_api, api_key: attempt_key)
      attempt_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
      # Responses-mode latch flags re-parse the accumulated tail at stream
      # end, so a bounded buffer is kept even when metrics tracking is off.
      accumulated = (tracking || responses_api) ? +"" : nil

      is_responses = false
      always_responses_delta = false
      responses_evidence = false
      responses_terminal = false
      pending_chunk = nil
      pending_cr = nil
      out_chunk = lambda do |chunk, cr|
        forward_chunk_to_client(out, chunk)
        streamed_any = true
        is_responses ||= cr.is_responses
        always_responses_delta ||= cr.has_responses_delta
        responses_evidence ||= cr.responses_evidence
        responses_terminal ||= cr.has_responses_terminal
        if accumulated
          accumulated << chunk
          if accumulated.bytesize > MAX_ACCUMULATED_SIZE
            accumulated = accumulated.byteslice(-ACCUMULATED_TAIL_SIZE, ACCUMULATED_TAIL_SIZE)
          end
        end
        # The accumulated tail doubles as the split-event recovery buffer in
        # Responses mode, so it must survive until the stream-end re-parse.
        # Chat mode keeps the pre-existing early-nil optimisation.
        accumulated = nil if cr.usage && !responses_api
      end
      # TTFT timeout: consume_stream uses a two-layer approach to catch
      # providers that never start generating within ttft_timeout seconds
      # (per-attempt deadline from attempt_start). Measuring from
      # attempt_start — not the overall request start — ensures prior
      # retries and provider fallbacks don't consume the TTFT budget.
      #
      # Layer 1 (proactive): a background timer thread closes the http
      # connection after ttft_timeout seconds if no first token has arrived.
      # This breaks read_body out of its blocking wait when the provider
      # sends nothing at all — the application-level check alone can only
      # fire when a chunk arrives, which never happens in that case.
      # The timer is cancelled as soon as first_token is set.
      #
      # Layer 2 (reactive): the application-level check inside read_body
      # catches providers that send keep-alive pings or empty deltas but
      # no actual content/thinking tokens.
      #
      # Stale pooled connections still fail fast with EOFError because the
      # timer only fires on genuinely slow connections (socket alive, no
      # data for ttft_timeout seconds). read_timeout is NOT lowered.
      # Requires tracking enabled — chunk parsing is needed to detect the
      # first token. When tracking is off the feature is skipped.
      # Per-model ttft_timeout overrides the global timeouts.ttft value
      # (false disables the gate for one model); models without the key fall
      # back to the global default. Resolved per attempt like timeouts above.
      ttft_timeout = tracking && ConfigStore.ttft_timeout_for(model_name)
      # In Responses mode the first-token gate only sees reasoning deltas
      # when RESPONSES_ENABLE_THINKING_TRACKING is enabled; without it the
      # TTFT timer would kill healthy long-reasoning streams whose content
      # deltas arrive after the timeout.
      ttft_timeout = nil if responses_api && ENV["RESPONSES_ENABLE_THINKING_TRACKING"] != "1"
      begin
        http.request(request) do |response|
          if response.is_a?(Net::HTTPSuccess)
            if tracking
              usage_data, perf_metrics, server_duration = Streaming.consume_stream(response,
                tracker: timers, ttft_timeout: ttft_timeout, request_start: attempt_start, http: http) do |chunk, cr, _now|
                if responses_api
                  if pending_chunk
                    out_chunk.call(pending_chunk, pending_cr)
                  end
                  pending_chunk = chunk
                  pending_cr = cr
                else
                  out_chunk.call(chunk, cr)
                end
              end
            else
              response.read_body do |chunk|
                if responses_api
                  cr = Streaming.parse_chunk(chunk)
                  if pending_chunk
                    out_chunk.call(pending_chunk, pending_cr)
                  end
                  pending_chunk = chunk
                  pending_cr = cr
                else
                  forward_chunk_to_client(out, chunk)
                  streamed_any = true
                end
              end
            end

            if responses_api && pending_chunk
              is_responses ||= pending_cr.is_responses
              always_responses_delta ||= pending_cr.has_responses_delta
              responses_evidence ||= pending_cr.responses_evidence
              responses_terminal ||= pending_cr.has_responses_terminal
              # Strip a trailing `data: [DONE]` line (LF or CRLF — SSE
              # permits both) so synthetic events always precede it and the
              # stream ends with exactly one [DONE], regardless of the
              # provider's own termination.
              non_done = pending_chunk.sub(/data: \[DONE\][\r\n]*\z/, "")
              out_chunk.call(non_done, pending_cr) unless non_done.empty?
              # Some providers split single SSE events (notably the big
              # terminal payloads) across network chunks. Re-parse the
              # concatenated tail — bounded to the window where stray
              # events can actually hide — so split deltas, split usage
              # blocks, and perf fields feed the classification and the
              # metrics harvest below.
              tail_cr = nil
              if accumulated && !accumulated.empty?
                tail = accumulated.end_with?("\n\n") ? accumulated : accumulated + "\n\n"
                if tail.bytesize > ACCUMULATED_TAIL_SIZE
                  tail = tail.byteslice(-ACCUMULATED_TAIL_SIZE, ACCUMULATED_TAIL_SIZE)
                end
                tail_cr = Streaming.parse_chunk(tail)
                is_responses ||= tail_cr.is_responses
                always_responses_delta ||= tail_cr.has_responses_delta
                responses_evidence ||= tail_cr.responses_evidence
                responses_terminal ||= tail_cr.has_responses_terminal
              end
              # Synthetic termination: something was streamed but the stream
              # never produced a complete output exchange — no deltas at all
              # (containers/announce events only, or an empty terminal), or
              # deltas cut off before any terminal event. A stream carrying
              # BOTH delta evidence and a terminal event (response.completed /
              # failed / incomplete — with or without a usage block) is
              # considered complete and is left untouched, so providers that
              # omit usage don't get a spurious failure appended to every
              # otherwise healthy stream.
              if streamed_any && (responses_evidence || always_responses_delta || is_responses) &&
                 !(always_responses_delta && responses_terminal)
                if is_responses
                  synthetic = "data: " + {"type" => "response.failed", "response" => {}, "error" => {"code" => "upstream_stopped", "message" => "The upstream provider ended the stream before responding. No retries are possible on a partially-streamed response."}}.to_json + "\n\n"
                else
                  synthetic = "data: " + {"type" => "response.not_found", "code" => "upstream_stopped", "message" => "The upstream provider ended the stream before responding. No retries are possible on a partially-streamed response."}.to_json + "\n\n"
                end
                forward_chunk_to_client(out, synthetic)
              end
              forward_chunk_to_client(out, "data: [DONE]\n\n")
            end

            if tracking
              # Responses mode reuses the tail parse already done for the
              # latch flags; chat mode parses the fresh accumulated tail.
              unless usage_data
                fallback = tail_cr || (Streaming.parse_chunk(accumulated.to_s) if accumulated)
                usage_data = fallback.usage if fallback&.usage
                perf_metrics = fallback.perf_metrics if fallback&.perf_metrics
                server_duration = fallback.server_duration if fallback&.server_duration
              end

              stream_result = build_stream_result(log_prefix, timers, usage_data, perf_metrics: perf_metrics, server_duration: server_duration, request_start: attempt_start)
            else
              stream_result = {success: true}
            end
          else
            stream_result = handle_upstream_error(response, log_prefix)
          end
        end
      rescue HTTPSupport::TTFTTimeoutError
        pooled = false
        # Safe to retry: TTFTTimeoutError fires only when no first token
        # (thinking or content) has arrived, so no content was forwarded
        # to the client. Keep-alive pings may have been forwarded but
        # SSE clients ignore comment lines.
        raise
      rescue HTTPSupport::ClientDisconnected
        # Client went away (EPIPE/IOError/Puma::ConnectionError from
        # forward_chunk_to_client or handle_streaming_error). Don't
        # retry — the client is gone. This is NOT an upstream failure.
        pooled = false
        raise
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IOError, EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError
        pooled = false
        # Upstream error (connection drop, read timeout, etc.).
        # If we've already streamed data to the client, we can't retry —
        # the client would receive a garbled duplicate stream. Wrap in
        # StreamPartiallySent so it's classified as an upstream failure,
        # not a client disconnect.
        raise HTTPSupport::StreamPartiallySent.new($!) if streamed_any
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

  def try_single_request(provider_config, path, body, body_model, incoming_headers, log_prefix:, deadline_remaining: nil, responses_api: false)
    rotator = KeyRotator.for(provider_config)

    try_with_retries(log_prefix: log_prefix, body_model: body_model, rotator: rotator) do |attempt_key|
      uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: false, responses_api: responses_api, api_key: attempt_key)
      timeouts = ConfigStore.timeouts
      if deadline_remaining
        timeouts = timeouts.merge(read: [timeouts[:read], deadline_remaining].min)
      end
      http = HTTPSupport.create_http(uri, timeouts: timeouts)
      http.start unless http.started?
      pooled = true
      begin
        result = nil
        # Block form: the body is streamed through a bounded reader instead
        # of being buffered unbounded by Net::HTTP#body, and upstream
        # response headers can be forwarded to the client.
        http.request(request) do |response|
          if response.is_a?(Net::HTTPSuccess)
            body_str, truncated = HTTPSupport.read_body_capped(response, HTTPSupport::MAX_UPSTREAM_RESPONSE_BODY)
            if truncated
              # Never forward a truncated body — the client would receive
              # invalid JSON. Fail the attempt so fallback/retry applies.
              result = {success: false, error: "Upstream response body exceeded #{HTTPSupport::MAX_UPSTREAM_RESPONSE_BODY} bytes", status: 502}
            else
              settings.logger.info("#{log_prefix} Success")
              result = {success: true, response: [response.code.to_i, HTTPSupport.forwardable_response_headers(response), [body_str]]}
            end
          else
            result = handle_upstream_error(response, log_prefix)
          end
        end
        result
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

  def handle_streaming_error(result, out, is_responses: false)
    return if result[:success]
    if is_responses
      out << streaming_responses_error(result[:error], detail: result[:detail])
    else
      out << streaming_error(result[:error], detail: result[:detail])
    end
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
