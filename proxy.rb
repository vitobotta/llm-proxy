#!/usr/bin/env ruby
# frozen_string_literal: true

require "sinatra/base"
require "rack/utils"
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
require_relative "lib/state_persistence"
require_relative "lib/probe_manager"
require_relative "lib/request_handler"
require_relative "lib/metrics"
require_relative "provider_selector"
require_relative "lib/routes/completions"
require_relative "lib/routes/admin"

CONFIG_PATH = ENV.fetch("CONFIG_FILE", File.join(__dir__, "config", "config.yaml"))

def self.load_raw_config!(path)
  ConfigStore.load_yaml_file(path)
rescue Errno::ENOENT
  warn("[BOOT] Config file not found at #{path}.")
  warn("[BOOT] Set CONFIG_FILE or copy config/config.yaml.example to #{path} and edit it.")
  exit(78) # EX_CONFIG
rescue Errno::EACCES => e
  warn("[BOOT] Cannot read config file at #{path}: #{e.message}")
  exit(78)
rescue Psych::SyntaxError, Psych::DisallowedClass => e
  warn("[BOOT] Config file at #{path} has invalid YAML: #{e.message}")
  exit(78)
rescue => e
  warn("[BOOT] Failed to load config file at #{path}: #{e.class}: #{e.message}")
  exit(78)
end

RAW_CONFIG = load_raw_config!(CONFIG_PATH)

BOOT_LOGGER = Logger.new($stdout)
LOG_LEVELS = {
  "debug" => Logger::DEBUG,
  "info" => Logger::INFO,
  "warn" => Logger::WARN,
  "error" => Logger::ERROR
}.freeze
BOOT_LOGGER.level = LOG_LEVELS.fetch(RAW_CONFIG.dig("logging", "level"), Logger::INFO)

BOOT_LOGGER.formatter = if RAW_CONFIG.dig("logging", "format") == "json"
  # JSON formatter: caller can pass a String (becomes `message` field) or a
  # Hash (fields spread into the JSON record). Thread-local request_id is
  # included automatically when set by the before-hook.
  proc do |severity, datetime, _progname, msg|
    record = {timestamp: datetime.iso8601, level: severity}
    rid = Thread.current[:request_id]
    record[:request_id] = rid if rid
    if msg.is_a?(Hash)
      record.merge!(msg)
    else
      record[:message] = msg.to_s
    end
    record.to_json + "\n"
  end
else
  proc do |severity, datetime, _progname, msg|
    if msg.is_a?(Hash)
      pairs = msg.map { |k, v| "#{k}=#{(v.is_a?(String) && v.include?(" ")) ? v.inspect : v}" }
      "[#{datetime.iso8601}] #{severity}: #{pairs.join(" ")}\n"
    else
      "[#{datetime.iso8601}] #{severity}: #{msg}\n"
    end
  end
end

class LLMProxy < Sinatra::Base
  helpers Streaming
  helpers HTTPSupport
  helpers RequestHandler

  set :logger, BOOT_LOGGER

  ConfigStore.load!(RAW_CONFIG, logger: BOOT_LOGGER)
  ConfigStore.register_app!(self)

  begin
    StatePersistence.restore!(logger: BOOT_LOGGER)
  rescue => e
    BOOT_LOGGER.warn("State restoration failed (starting fresh): #{e.class}: #{e.message}")
  end

  before do
    @request_id = SecureRandom.hex(8)
    @request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @client_ip = request.ip
    Thread.current[:request_id] = @request_id
    settings.logger.info("[#{@request_id}] #{request.request_method} #{request.path} from #{@client_ip}")

    auth_token = ConfigStore.auth_token
    if auth_token && requires_auth?(request.path)
      auth_header = request.env["HTTP_AUTHORIZATION"].to_s
      token = auth_header.start_with?("Bearer ") ? auth_header[7..] : auth_header
      unless token && Rack::Utils.secure_compare(token, auth_token)
        halt json_error(status: 401, message: "Unauthorized", type: "authentication_error")
      end
    end
  end

  def requires_auth?(path)
    # /health is always public so load balancers can probe.
    # /metrics is public by default; if auth.metrics_token is set,
    # it is gated separately below via metrics_token_required!
    return false if path == "/health"
    return false if path == "/metrics"
    true
  end

  def metrics_token_required!
    token = ConfigStore.metrics_token
    return unless token
    auth_header = request.env["HTTP_AUTHORIZATION"].to_s
    provided = auth_header.start_with?("Bearer ") ? auth_header[7..] : auth_header
    unless provided && Rack::Utils.secure_compare(provided, token)
      halt json_error(status: 401, message: "Unauthorized", type: "authentication_error")
    end
  end

  after do
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @request_start
    settings.logger.info("[#{@request_id}] Completed #{response.status} in #{elapsed.round(3)}s")
    Metrics.increment(:requests_total, labels: {status: response.status})
    Metrics.observe(:request_duration_seconds, elapsed)
    Thread.current[:request_id] = nil
  end

  def json_error(status:, message:, detail: nil, type: "proxy_error")
    content_type :json
    body = {error: {message: message, type: type}}
    body[:error][:detail] = detail if detail
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
      env_key = "HTTP_#{h.upcase.tr("-", "_")}"
      incoming_headers[h] = request.env[env_key] if request.env[env_key]
    end

    {body: body, model: model, model_name: model_name, headers: incoming_headers}
  rescue JSON::ParserError
    halt json_error(status: 400, message: "Invalid JSON body", type: "invalid_request")
  end

  register Routes::Completions
  register Routes::Admin

  not_found do
    json_error(status: 404, message: "Not Found", detail: request.path, type: "not_found")
  end

  error do
    e = env["sinatra.error"]
    settings.logger.error("[#{@request_id}] Unhandled error: #{e.class}: #{e.message}")
    if e.backtrace
      settings.logger.error(e.backtrace.first(20).join("\n"))
      settings.logger.debug(e.backtrace.join("\n"))
    end
    json_error(status: 500, message: "Internal server error", detail: e.message, type: "internal_error")
  end
end

HTTPSupport.prewarm_connections!(ConfigStore.config, ConfigStore.providers, LLMProxy.settings.logger, timeouts: ConfigStore.timeouts)
HTTPSupport.setup_graceful_shutdown!(LLMProxy.settings.logger, ConfigStore.selectors)

poll_interval = RAW_CONFIG.dig("performance", "config_poll_interval") || 2
ConfigWatcher.start!(logger: LLMProxy.settings.logger, poll_interval: poll_interval) if poll_interval > 0

LLMProxy.run! if __FILE__ == $PROGRAM_NAME
