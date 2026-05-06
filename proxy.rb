#!/usr/bin/env ruby
# frozen_string_literal: true

require "sinatra/base"
require "json"
require "yaml"
require "net/http"
require "uri"
require "logger"
require "securerandom"
require_relative "lib/streaming"
require_relative "lib/http_support"
require_relative "provider_selector"

MACOS = RUBY_PLATFORM.match?(/darwin/)

module Notifier
  def self.notify(title, message)
    return unless MACOS

    Thread.new do
      script = "display notification #{message.inspect} with title #{title.inspect}"
      system("osascript", "-e", script)
    end
  end
end

CONFIG = YAML.unsafe_load_file(File.join(__dir__, "config.yaml"))
CONFIG.freeze

class LLMProxy < Sinatra::Base
  helpers Streaming
  helpers HTTPSupport

  LOG_LEVELS = {
    "debug" => Logger::DEBUG,
    "info"  => Logger::INFO,
    "warn"  => Logger::WARN,
    "error" => Logger::ERROR
  }.freeze

  logger = Logger.new($stdout)
  logger.level = LOG_LEVELS.fetch(CONFIG.dig("logging", "level"), Logger::INFO)

  if CONFIG.dig("logging", "format") == "json"
    logger.formatter = proc do |severity, datetime, _progname, msg|
      { timestamp: datetime.iso8601, level: severity, message: msg }.to_json + "\n"
    end
  else
    logger.formatter = proc do |severity, datetime, _progname, msg|
      "[#{datetime.iso8601}] #{severity}: #{msg}\n"
    end
  end
  set :logger, logger

  PROVIDERS = (CONFIG["providers"] || {}).transform_values(&:freeze).freeze

  def self.validate_config!(config, log)
    errors = []
    errors << "Missing 'models' in config" unless config["models"]&.any?
    errors << "Missing 'providers' in config" unless config["providers"]&.any?

    (config["models"] || []).each do |m|
      unless m["name"]
        errors << "Model entry missing 'name'"
        next
      end
      unless m["providers"]&.any?
        errors << "Model '#{m['name']}' has no providers"
        next
      end
      m["providers"].each do |p|
        unless p["provider"]
          errors << "Model '#{m['name']}' has a provider entry missing 'provider' key"
        end
      end
    end

    unless errors.empty?
      errors.each { |e| log.error("Config error: #{e}") }
      abort("Invalid configuration, exiting")
    end
  end

  validate_config!(CONFIG, logger)

  def self.resolve_provider(provider_name, model_id, model_headers = nil)
    provider = PROVIDERS[provider_name]
    raise "Unknown provider '#{provider_name}'" unless provider

    {
      "provider" => provider_name,
      "base_url" => provider["base_url"],
      "api_key"  => provider["api_key"],
      "model"    => model_id,
      "headers"  => provider["headers"]&.merge(model_headers || {}) || model_headers || {}
    }.freeze
  end

  MODELS = {}
  SELECTORS = {}

  CONFIG["models"].each do |m|
    provider_list = m["providers"].map { |p| resolve_provider(p["provider"], p["model"], p["headers"]) }
    model_entry = { "name" => m["name"], "providers" => provider_list.freeze }.freeze
    MODELS[m["name"]] = model_entry
    SELECTORS[m["name"]] = ProviderSelector.new(m["name"], provider_list, model_config: m)
  end

  MODELS.freeze
  SELECTORS.freeze

  PROBING_ENABLED = CONFIG.dig("performance", "probing_enabled") != false

  AUTO_SWITCH = PROBING_ENABLED && CONFIG.dig("performance", "auto_switch") == true

  PROBE_INTERVAL = CONFIG.dig("performance", "probe_interval") || 3

  set :max_attempts, CONFIG.dig("retries", "max_attempts") || 3
  set :backoff_base, CONFIG.dig("retries", "backoff_base") || 2

  TIMEOUTS = {
    open:  CONFIG.dig("timeouts", "open")  || 30,
    read:  CONFIG.dig("timeouts", "read")  || 300,
    write: CONFIG.dig("timeouts", "write") || 60
  }.freeze

  TRACKING_ENABLED = CONFIG.dig("tracking", "enabled") != false

  MAX_BODY_SIZE = 10 * 1024 * 1024

  before do
    @request_id = SecureRandom.uuid[0..7]
    @request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    settings.logger.info("[#{@request_id}] #{request.request_method} #{request.path}")
  end

  after do
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @request_start
    settings.logger.info("[#{@request_id}] Completed #{response.status} in #{elapsed.round(3)}s")
  end

  def json_error(status:, message:, detail: nil)
    content_type :json
    body = { error: { message: message, type: "proxy_error" } }
    body[:error].merge!(detail: detail) if detail
    [status, body.to_json]
  end

  def parse_request(allowed_headers: ["Authorization", "OpenAI-Organization", "OpenAI-Beta"])
    body_raw = request.body.read
    if body_raw.bytesize > MAX_BODY_SIZE
      halt json_error(status: 413, message: "Request body too large (max 10MB)")
    end
    body = JSON.parse(body_raw)

    model_name = body["model"]
    halt json_error(status: 400, message: "Missing 'model' in request body") unless model_name

    model = MODELS[model_name]
    halt json_error(status: 404, message: "Model '#{model_name}' not found in configuration") unless model

    incoming_headers = {}
    allowed_headers.each do |h|
      env_key = "HTTP_#{h.upcase.tr('-', '_')}"
      incoming_headers[h] = request.env[env_key] if request.env[env_key]
    end

    { body: body, model: model, model_name: model_name, headers: incoming_headers }
  rescue JSON::ParserError
    halt json_error(status: 400, message: "Invalid JSON body")
  end

  # ---- Provider selection ----

  def with_auto_select(model:, model_name:, path:, body:, headers:)
    selector = SELECTORS[model_name]

    providers = PROBING_ENABLED ? selector.ordered_providers : selector.providers

    result = nil
    providers.each_with_index do |provider_config, i|
      p_name = provider_config["provider"]
      p_model = provider_config["model"]
      settings.logger.info("[#{@request_id}/#{model_name}] #{i == 0 ? 'Using' : 'Fallback to'} #{p_name} (#{p_model})")

      log_prefix = "[#{@request_id}/#{model_name}/#{p_name}]"
      result = yield(provider_config, path, body, p_model, headers, log_prefix)
      if result&.dig(:success)
        record_metrics(selector, p_name, result) if PROBING_ENABLED
        Notifier.notify("LLM Proxy Fallback", "#{model_name} \u2192 #{p_name}") if i > 0
        break
      end
    end

    if PROBING_ENABLED && selector.record_and_maybe_probe(PROBE_INTERVAL)
      launch_background_probe(selector, model_name, path, headers)
    end

    result || { success: false, error: "All providers failed" }
  end

  def record_metrics(selector, provider_name, result)
    selector.update_metrics(provider_name, result[:ttft], result[:content_tps]) if result[:ttft]
  end

  PROBE_BODY = {
    "messages" => [{ "role" => "user", "content" => "Write a brief paragraph about the weather" }],
    "max_tokens" => 100
  }.freeze

  def launch_background_probe(selector, model_name, path, headers)
    logger = settings.logger
    probe_id = SecureRandom.uuid[0..7]

    Thread.new do
      begin
        threads = []
        results = {}

        selector.other_providers.each do |provider_config|
          p_name = provider_config["provider"]
          threads << Thread.new do
            metrics = LLMProxy.probe_provider(provider_config, path, PROBE_BODY, provider_config["model"], headers, logger: logger)
            results[p_name] = metrics
          end
        end

        threads.each(&:join)

        results.each do |p_name, m|
          selector.update_metrics(p_name, m[:ttft], m[:tps])
          tps_str = m[:tps] ? m[:tps].to_s : "N/A"
          logger.info("[probe:#{probe_id}] #{model_name}/#{p_name}: ttft=#{m[:ttft]}s tps=#{tps_str}")
        end

        selector.evaluate_and_select(logger, auto_switch: AUTO_SWITCH)
      rescue => e
        logger.error("[probe:#{probe_id}] #{model_name} error: #{e.message}")
      ensure
        HTTPSupport.cleanup_thread_connections!
        selector.probe_finished
      end
    end
  end

  # ---- Probe provider (class method — runs outside request) ----

  def self.probe_provider(provider_config, path, body, body_model, incoming_headers, logger:)
    pname = provider_config["provider"]
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    begin
      http = HTTPSupport.create_http(uri, timeouts: TIMEOUTS)
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

  # ---- Request handlers ----

  def try_stream(provider_config, path, body, body_model, incoming_headers, out:, log_prefix:)
    uri, request = HTTPSupport.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    try_with_retries(log_prefix: log_prefix, body_model: body_model) do
      http = HTTPSupport.create_http(uri, timeouts: TIMEOUTS)
      http.start unless http.started?

      timers = {
        first_token: nil, first_thinking: nil, last_thinking: nil,
        first_content: nil, last_content: nil,
        thinking_detected: false, content_detected: false
      }
      usage_data = nil
      stream_result = nil
      accumulated = TRACKING_ENABLED ? +"" : nil

      http.request(request) do |response|
        if response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            begin
              out << chunk
            rescue Errno::EPIPE, IOError
              raise HTTPSupport::ClientDisconnected
            end

            if TRACKING_ENABLED
              accumulated << chunk if accumulated
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              cr = Streaming.parse_chunk(chunk)
              if cr.usage
                usage_data = cr.usage
                accumulated = nil
              end
              track_chunk!(cr, now, timers)
            end
          end

          if TRACKING_ENABLED
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
      http = HTTPSupport.create_http(uri, timeouts: TIMEOUTS)
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

  %w[chat/completions completions].each do |endpoint|
    post "/v1/#{endpoint}" do
      req = parse_request
      stream_requested = req[:body].key?("stream") ? req[:body].delete("stream") != false : true

      if stream_requested
        HTTPSupport::SSE_HEADERS.each { |k, v| headers[k] = v }

        stream do |out|
          result = with_auto_select(
            model: req[:model], model_name: req[:model_name],
            path: endpoint, body: req[:body], headers: req[:headers]
          ) { |pc, p, b, pm, h, lp| try_stream(pc, p, b, pm, h, out: out, log_prefix: lp) }
          handle_streaming_error(result, out)
        end
      else
        result = with_auto_select(
          model: req[:model], model_name: req[:model_name],
          path: endpoint, body: req[:body], headers: req[:headers]
        ) { |pc, p, b, pm, h, lp| try_single_request(pc, p, b, pm, h, log_prefix: lp) }
        handle_non_stream_result(result)
      end
    end
  end

  post "/v1/embeddings" do
    req = parse_request(allowed_headers: ["Authorization"])
    result = with_auto_select(
      model: req[:model], model_name: req[:model_name],
      path: "embeddings", body: req[:body], headers: req[:headers]
    ) { |pc, p, b, pm, h, lp| try_single_request(pc, p, b, pm, h, log_prefix: lp) }
    handle_non_stream_result(result)
  end

  get "/health" do
    content_type :json
    provider_status = {}
    SELECTORS.each do |name, selector|
      metrics = selector.active_metrics
      provider_status[name] = {
        active_provider: selector.active_provider_name,
        metrics: metrics
      }
    end
    { status: "ok", models: MODELS.keys, providers: provider_status, timestamp: Time.now.iso8601 }.to_json
  end

  get "/v1/models" do
    content_type :json
    {
      object: "list",
      data: MODELS.keys.map { |name| { id: name, object: "model", owned_by: "proxy" } }
    }.to_json
  end

  get "/v1/models/:name" do
    content_type :json
    model = MODELS[params[:name]]
    return json_error(status: 404, message: "Model '#{params[:name]}' not found") unless model

    {
      id: model["name"],
      object: "model",
      owned_by: "proxy",
      providers: model["providers"].map { |p| { provider: p["provider"], model: p["model"] } }
    }.to_json
  end

  error do
    e = env["sinatra.error"]
    settings.logger.error("[#{@request_id}] Unhandled error: #{e.class}: #{e.message}")
    settings.logger.error(e.backtrace[0..10].join("\n")) if e.backtrace
    json_error(status: 500, message: "Internal server error", detail: e.message)
  end
end

HTTPSupport.prewarm_connections!(CONFIG, LLMProxy::PROVIDERS, LLMProxy.settings.logger, timeouts: LLMProxy::TIMEOUTS)
HTTPSupport.setup_graceful_shutdown!(LLMProxy.settings.logger, LLMProxy::SELECTORS)

LLMProxy.run! if __FILE__ == $PROGRAM_NAME
