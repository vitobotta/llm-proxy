# frozen_string_literal: true

require "securerandom"

module ProbeManager
  PROBE_BODY = {
    "messages" => [{ "role" => "user", "content" => "Write a brief paragraph about the weather" }],
    "max_tokens" => 100
  }.freeze

  def self.launch(selector, model_name, path, headers, timeouts:, auto_switch:, logger:)
    probe_id = SecureRandom.uuid[0..7]

    Thread.new do
      begin
        threads = []
        results = {}

        selector.other_providers.each do |provider_config|
          p_name = provider_config["provider"]
          threads << Thread.new do
            metrics = probe_provider(provider_config, path, PROBE_BODY, provider_config["model"], headers, timeouts: timeouts, logger: logger)
            results[p_name] = metrics
          end
        end

        threads.each(&:join)

        results.each do |p_name, m|
          selector.update_metrics(p_name, m[:ttft], m[:tps])
          tps_str = m[:tps] ? m[:tps].to_s : "N/A"
          logger.info("[probe:#{probe_id}] #{model_name}/#{p_name}: ttft=#{m[:ttft]}s tps=#{tps_str}")
        end

        selector.evaluate_and_select(logger, auto_switch: auto_switch)
      rescue => e
        logger.error("[probe:#{probe_id}] #{model_name} error: #{e.message}")
      ensure
        HTTPSupport.cleanup_thread_connections!
        selector.probe_finished
      end
    end
  end

  def self.probe_provider(provider_config, path, body, body_model, incoming_headers, timeouts:, logger:)
    pname = provider_config["provider"]
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    begin
      http = HTTPSupport.create_http(uri, timeouts: timeouts)
      http.start unless http.started?

      request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Streaming.stream_response(http, request, request_start)
      stream_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if result[:error]
        logger.warn("[probe] #{pname}: #{result[:error]}")
        return { ttft: Float::INFINITY, tps: nil }
      end

      ttft = result[:first_token_time] ? (result[:first_token_time] - request_start).round(3) : Float::INFINITY

      unless result[:usage_data]
        logger.debug("[probe] #{pname}: usage_data absent (provider ignored stream_options)")
        return { ttft: ttft, tps: nil }
      end

      tokens = Streaming.extract_token_counts(result[:usage_data])
      completion_tokens = tokens[:completion] || 0

      tps = Streaming.compute_tps(tokens[:content], result[:first_content_time], result[:last_content_time])

      if tps.nil?
        tps = Streaming.compute_tps(completion_tokens, result[:first_token_time], result[:last_any_token_time])
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

      { ttft: ttft, tps: tps }
    rescue => e
      logger.debug("[probe] #{pname}: #{e.message}")
      { ttft: Float::INFINITY, tps: nil }
    end
  end
end
