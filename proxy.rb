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
require_relative "lib/config_validator"
require_relative "lib/config_store"
require_relative "lib/config_watcher"
require_relative "lib/probe_manager"
require_relative "lib/request_handler"
require_relative "lib/metrics"
require_relative "provider_selector"

CONFIG_PATH = ENV.fetch("CONFIG_FILE", File.join(__dir__, "config", "config.yaml"))
RAW_CONFIG = YAML.unsafe_load_file(CONFIG_PATH)

BOOT_LOGGER = Logger.new($stdout)
LOG_LEVELS = {
  "debug" => Logger::DEBUG,
  "info"  => Logger::INFO,
  "warn"  => Logger::WARN,
  "error" => Logger::ERROR
}.freeze
BOOT_LOGGER.level = LOG_LEVELS.fetch(RAW_CONFIG.dig("logging", "level"), Logger::INFO)

if RAW_CONFIG.dig("logging", "format") == "json"
  BOOT_LOGGER.formatter = proc do |severity, datetime, _progname, msg|
    { timestamp: datetime.iso8601, level: severity, message: msg }.to_json + "\n"
  end
else
  BOOT_LOGGER.formatter = proc do |severity, datetime, _progname, msg|
    "[#{datetime.iso8601}] #{severity}: #{msg}\n"
  end
end

class LLMProxy < Sinatra::Base
  helpers Streaming
  helpers HTTPSupport
  helpers RequestHandler

  set :logger, BOOT_LOGGER

  ConfigStore.load!(RAW_CONFIG, logger: BOOT_LOGGER)

  set :max_attempts, ConfigStore.max_attempts
  set :backoff_base, ConfigStore.backoff_base

  before do
    @request_id = SecureRandom.uuid[0..7]
    @request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    settings.logger.info("[#{@request_id}] #{request.request_method} #{request.path}")

    auth_token = ConfigStore.auth_token
    if auth_token
      auth_header = request.env["HTTP_AUTHORIZATION"].to_s
      token = auth_header.start_with?("Bearer ") ? auth_header[7..] : auth_header
      unless token && token == auth_token
        halt json_error(status: 401, message: "Unauthorized", type: "authentication_error")
      end
    end
  end

  after do
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @request_start
    settings.logger.info("[#{@request_id}] Completed #{response.status} in #{elapsed.round(3)}s")
    Metrics.increment(:requests_total, labels: { status: response.status })
    Metrics.observe(:request_duration_seconds, elapsed)
  end

  def json_error(status:, message:, detail: nil, type: "proxy_error")
    content_type :json
    body = { error: { message: message, type: type } }
    body[:error].merge!(detail: detail) if detail
    [status, body.to_json]
  end

  def parse_request(allowed_headers: ["Authorization", "OpenAI-Organization", "OpenAI-Beta"])
    max_body_size = ConfigStore.max_body_size
    body_raw = request.body.read
    if body_raw.bytesize > max_body_size
      halt json_error(status: 413, message: "Request body too large (max #{max_body_size / 1024 / 1024}MB)", type: "request_too_large")
    end
    body = JSON.parse(body_raw)

    model_name = body["model"]
    halt json_error(status: 400, message: "Missing 'model' in request body", type: "invalid_request") unless model_name

    model = ConfigStore.model(model_name)
    halt json_error(status: 404, message: "Model '#{model_name}' not found in configuration", type: "model_not_found") unless model

    incoming_headers = {}
    allowed_headers.each do |h|
      env_key = "HTTP_#{h.upcase.tr('-', '_')}"
      incoming_headers[h] = request.env[env_key] if request.env[env_key]
    end

    { body: body, model: model, model_name: model_name, headers: incoming_headers }
  rescue JSON::ParserError
    halt json_error(status: 400, message: "Invalid JSON body", type: "invalid_request")
  end

  %w[chat/completions completions].each do |endpoint|
    post "/v1/#{endpoint}" do
      req = parse_request
      stream_requested = req[:body].key?("stream") ? req[:body]["stream"] != false : true

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
    ConfigStore.selectors.each do |name, selector|
      metrics = selector.active_metrics
      provider_status[name] = {
        active_provider: selector.active_provider_name,
        metrics: metrics,
        providers: selector.provider_stats
      }
    end
    { status: "ok", models: ConfigStore.models.keys, providers: provider_status, timestamp: Time.now.iso8601 }.to_json
  end

  get "/metrics" do
    content_type "text/plain; version=0.0.4"
    Metrics.to_prometheus
  end

  get "/v1/models" do
    content_type :json
    models = ConfigStore.models
    {
      object: "list",
      data: models.keys.map { |name| { id: name, object: "model", owned_by: "proxy", context_length: models[name]["context_length"] }.compact }
    }.to_json
  end

  get "/v1/models/:name" do
    content_type :json
    model = ConfigStore.model(params[:name])
    halt json_error(status: 404, message: "Model '#{params[:name]}' not found", type: "model_not_found") unless model

    {
      id: model["name"],
      object: "model",
      owned_by: "proxy",
      context_length: model["context_length"],
      providers: model["providers"].map { |p| { provider: p["provider"], model: p["model"] } }
    }.compact.to_json
  end

  error do
    e = env["sinatra.error"]
    settings.logger.error("[#{@request_id}] Unhandled error: #{e.class}: #{e.message}")
    settings.logger.error(e.backtrace[0..10].join("\n")) if e.backtrace
    json_error(status: 500, message: "Internal server error", detail: e.message, type: "internal_error")
  end
end

HTTPSupport.prewarm_connections!(ConfigStore.config, ConfigStore.providers, LLMProxy.settings.logger, timeouts: ConfigStore.timeouts)
HTTPSupport.setup_graceful_shutdown!(LLMProxy.settings.logger, ConfigStore.selectors)

poll_interval = RAW_CONFIG.dig("performance", "config_poll_interval") || 2
ConfigWatcher.start!(logger: LLMProxy.settings.logger, poll_interval: poll_interval) if poll_interval > 0

LLMProxy.run! if __FILE__ == $PROGRAM_NAME
