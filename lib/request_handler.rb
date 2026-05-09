# frozen_string_literal: true

module RequestHandler
  def with_auto_select(model:, model_name:, path:, body:, headers:)
    selector = self.class::SELECTORS[model_name]

    providers = self.class::PROBING_ENABLED ? selector.ordered_providers : selector.providers

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REQUEST_DEADLINE

    result = nil
    providers.each_with_index do |provider_config, i|
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        settings.logger.warn("[#{@request_id}/#{model_name}] Request deadline exceeded, aborting")
        break
      end
      p_name = provider_config["provider"]
      p_model = provider_config["model"]
      settings.logger.info("[#{@request_id}/#{model_name}] #{i == 0 ? 'Using' : 'Fallback to'} #{p_name} (#{p_model})")

      log_prefix = "[#{@request_id}/#{model_name}/#{p_name}]"
      result = yield(provider_config, path, body, p_model, headers, log_prefix)
      if result&.dig(:success)
        record_metrics(selector, p_name, result) if self.class::PROBING_ENABLED
        selector.record_success(p_name)
        Metrics.increment(:provider_success, labels: { provider: p_name, model: model_name })
        Notifier.notify("LLM Proxy Fallback", "#{model_name} \u2192 #{p_name}") if i > 0
        break
      else
        selector.record_failure(p_name)
        Metrics.increment(:provider_failure, labels: { provider: p_name, model: model_name })
      end
    end

    if self.class::PROBING_ENABLED && selector.record_and_maybe_probe(self.class::PROBE_INTERVAL)
      ProbeManager.launch(selector, model_name, path, headers, timeouts: self.class::TIMEOUTS, auto_switch: self.class::AUTO_SWITCH, logger: settings.logger)
    end

    result || { success: false, error: "All providers failed" }
  end

  def record_metrics(selector, provider_name, result)
    selector.update_metrics(provider_name, result[:ttft], result[:content_tps]) if result[:ttft]
  end

  MAX_ACCUMULATED_SIZE = 512 * 1024
  REQUEST_DEADLINE = 600

  def try_stream(provider_config, path, body, body_model, incoming_headers, out:, log_prefix:)
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    try_with_retries(log_prefix: log_prefix, body_model: body_model) do
      http = HTTPSupport.create_http(uri, timeouts: self.class::TIMEOUTS)
      http.start unless http.started?

      timers = Streaming::TimerTracker.new
      usage_data = nil
      stream_result = nil
      accumulated = self.class::TRACKING_ENABLED ? +"" : nil

      http.request(request) do |response|
        if response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            begin
              out << chunk
            rescue Errno::EPIPE, IOError
              raise HTTPSupport::ClientDisconnected
            end

            if self.class::TRACKING_ENABLED
              if accumulated
                accumulated << chunk
                if accumulated.bytesize > MAX_ACCUMULATED_SIZE
                  accumulated = nil
                end
              end
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              cr = Streaming.parse_chunk(chunk)
              if cr.usage
                usage_data = cr.usage
                accumulated = nil
              end
              track_chunk!(cr, now, timers)
            end
          end

          if self.class::TRACKING_ENABLED
            unless usage_data
              fallback = Streaming.parse_chunk(accumulated.to_s) if accumulated
              usage_data = fallback.usage if fallback&.usage
            end

            unless usage_data
              if accumulated
                counts = Streaming.extract_sse_content(accumulated.to_s)
                total = counts[:content_len] + counts[:thinking_len]
                if total > 0
                  usage_data = {
                    "completion_tokens" => total,
                    "completion_tokens_details" => { "reasoning_tokens" => counts[:thinking_len] }
                  }
                end
              end
            end

            stream_result = build_stream_result(log_prefix, timers, usage_data)
          else
            stream_result = { success: true }
          end
        else
          stream_result = handle_upstream_error(response, log_prefix)
        end
      end
      stream_result
    end
  end

  def try_single_request(provider_config, path, body, body_model, incoming_headers, log_prefix:)
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: false)

    try_with_retries(log_prefix: log_prefix, body_model: body_model) do
      http = HTTPSupport.create_http(uri, timeouts: self.class::TIMEOUTS)
      http.start unless http.started?
      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        settings.logger.info("#{log_prefix} Success")
        { success: true, response: [response.code.to_i, { "Content-Type" => "application/json" }, [response.body]] }
      else
        handle_upstream_error(response, log_prefix)
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
  end
end
