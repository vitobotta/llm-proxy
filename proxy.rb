#!/usr/bin/env ruby
# frozen_string_literal: true

require "sinatra/base"
require "json"
require "yaml"
require "net/http"
require "uri"
require "logger"
require "securerandom"
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

CONFIG = YAML.load_file(File.join(__dir__, "config.yaml"))
CONFIG.freeze

class RetryableError < StandardError; end

ChunkResult = Struct.new(:usage, :has_thinking, :has_content, :has_tool_call)

class LLMProxy < Sinatra::Base
  set :show_exceptions, false
  set :raise_errors, false
  set :port, (ENV["PORT"] || CONFIG.dig("server", "port") || 4567).to_i
  set :bind, ENV["BIND"] || CONFIG.dig("server", "bind") || "0.0.0.0"

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

  MAX_ATTEMPTS = CONFIG.dig("retries", "max_attempts") || 3
  BACKOFF_BASE = CONFIG.dig("retries", "backoff_base") || 2

  TIMEOUT_OPEN   = CONFIG.dig("timeouts", "open")   || 30
  TIMEOUT_READ   = CONFIG.dig("timeouts", "read")   || 300
  TIMEOUT_WRITE  = CONFIG.dig("timeouts", "write")  || 60

  TIMEOUT_EXCEPTIONS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze

  AUTH_STRATEGIES = {
    "anthropic" => ->(req, key) { req["x-api-key"] = key }
  }.freeze
  DEFAULT_AUTH = ->(req, key) { req["Authorization"] = "Bearer #{key}" }

  # Simple hash+mutex URI cache — sufficient for this concurrency level
  URI_CACHE = {}
  URI_CACHE_LOCK = Mutex.new

  SSE_HEADERS = {
    "Content-Type" => "text/event-stream",
    "Cache-Control" => "no-cache",
    "X-Accel-Buffering" => "no",
    "Connection" => "keep-alive"
  }.freeze

  PROTECTED_HEADERS = %w[host authorization x-api-key api-key].freeze

  THINKING_STRINGS = %w["reasoning_content" "thinking" "reasoning"].map { |k| "\"#{k}\"" }.freeze
  CONTENT_STRINGS = ['"content"', '"text"'].freeze
  TOOL_CALL_STRING = '"tool_calls"'
  USAGE_STRING = '"usage"'

  TRACKING_ENABLED = CONFIG.dig("tracking", "enabled") != false

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

  def backoff(attempt)
    sleep(BACKOFF_BASE * (2**attempt))
  end

  def parse_request(allowed_headers: ["Authorization", "OpenAI-Organization", "OpenAI-Beta"])
    body = JSON.parse(request.body.read)

    if body["messages"]
      body["messages"].reject! do |m|
        next false if m["role"] == "assistant" && m["tool_calls"].is_a?(Array) && !m["tool_calls"].empty?
        m["content"].nil? || m["content"].to_s.strip.empty?
      end

      halt json_error(status: 400, message: "Validation error: message content cannot be empty") if body["messages"].empty?
    end

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

  # ---- URI helpers ----

  def self.cached_uri(base, path)
    key = "#{base}/#{path}"
    URI_CACHE_LOCK.synchronize do
      return URI_CACHE[key] if URI_CACHE.key?(key)
      b = base.end_with?("/") ? base : base + "/"
      URI_CACHE[key] = URI.join(b, path)
    end
  end

  # ---- Request / HTTP helpers ----

  def self.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)
    uri = cached_uri(provider_config["base_url"], path)

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"

    (AUTH_STRATEGIES[provider_config["provider"]] || DEFAULT_AUTH).call(request, provider_config["api_key"])

    provider_config["headers"]&.each { |k, v| request[k] = v }

    incoming_headers&.each do |key, value|
      next if PROTECTED_HEADERS.include?(key.downcase)
      request[key] = value
    end

    request_body = body.dup
    request_body["model"] = body_model if body_model
    request_body["stream"] = stream
    request_body["stream_options"] = { "include_usage" => true } if stream
    request.body = request_body.to_json

    [uri, request]
  end

  def self.create_http(uri)
    key = "#{uri.scheme}://#{uri.host}:#{uri.port}"
    thread_pool = (Thread.current[:http_connections] ||= {})

    if (http = thread_pool[key])
      return http if http.started?
      thread_pool.delete(key)
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = TIMEOUT_OPEN
    http.read_timeout = TIMEOUT_READ
    http.write_timeout = TIMEOUT_WRITE
    http.keep_alive_timeout = 30
    thread_pool[key] = http
  end

  def self.cleanup_thread_connections!
    thread_pool = Thread.current[:http_connections]
    return unless thread_pool

    thread_pool.each_value do |http|
      http.finish if http.started?
    rescue StandardError
      nil
    end
    thread_pool.clear
  end

  def streaming_error(message, detail: nil)
    "data: #{ { error: { message: message, detail: detail } }.to_json }\n\n"
  end

  # ---- Retry logic ----

  def maybe_retry(attempts)
    return false unless attempts < MAX_ATTEMPTS
    backoff(attempts - 1)
    true
  end

  def retry_or_fail(log_prefix, error_label:, detail: nil)
    settings.logger.error("#{log_prefix} All #{MAX_ATTEMPTS} attempts failed")
    result = { success: false, error: "#{error_label} after #{MAX_ATTEMPTS} attempts" }
    result[:detail] = detail if detail
    result
  end

  def try_with_retries(log_prefix:, body_model:, &block)
    attempts = 0
    eof_retries = 0

    loop do
      attempts += 1
      settings.logger.info("#{log_prefix} Attempt #{attempts}/#{MAX_ATTEMPTS} (model: #{body_model})")

      begin
        return block.call
      rescue RetryableError => e
        return retry_or_fail(log_prefix, error_label: "Failed", detail: e.message) unless maybe_retry(attempts)
      rescue EOFError
        eof_retries += 1
        if eof_retries <= 2
          settings.logger.warn("#{log_prefix} EOF on stale connection (retry #{eof_retries}/2, not counting against attempts)")
          flush_stale_connections
          next
        end
        settings.logger.warn("#{log_prefix} EOF persisted after #{eof_retries} retries, counting as attempt failure")
        return retry_or_fail(log_prefix, error_label: "Connection reset") unless maybe_retry(attempts)
      rescue *TIMEOUT_EXCEPTIONS => e
        settings.logger.warn("#{log_prefix} Timeout: #{e.message}")
        return retry_or_fail(log_prefix, error_label: "Timeout") unless maybe_retry(attempts)
      rescue StandardError => e
        settings.logger.warn("#{log_prefix} Error: #{e.message}")
        return retry_or_fail(log_prefix, error_label: "Error", detail: e.message) unless maybe_retry(attempts)
      end
    end
  end

  def flush_stale_connections
    thread_pool = Thread.current[:http_connections]
    return unless thread_pool
    thread_pool.delete_if { |_, http| !http.started? }
  end

  # ---- Chunk parsing ----

  def self.parse_chunk(chunk)
    result = ChunkResult.new(nil, false, false, false)

    if chunk.include?(USAGE_STRING)
      chunk.scan(/^data:\s*(.+)$/).each do |raw|
        line = raw.first.strip
        next if line == "[DONE]" || line.empty?
        begin
          data = JSON.parse(line)
          if data.key?("usage")
            result.usage = data["usage"]
            break
          end
        rescue JSON::ParserError
          next
        end
      end
    end

    result.has_thinking = true if !result.has_thinking && THINKING_STRINGS.any? { |s| chunk.include?(s) }

    if chunk.include?(TOOL_CALL_STRING)
      result.has_tool_call = true
      result.has_content = true
    elsif !result.has_content
      result.has_content = true if CONTENT_STRINGS.any? { |s| chunk.include?(s) }
    end

    result
  end

  # ---- Streaming metrics ----

  def record_metrics(selector, provider_name, result)
    selector.update_metrics(provider_name, result[:ttft], result[:content_tps]) if result[:ttft]
  end

  def track_chunk!(chunk_result, now, timers)
    if chunk_result.has_thinking
      timers[:last_thinking] = now
      if !timers[:thinking_detected]
        timers[:thinking_detected] = true
        timers[:first_thinking] ||= now
        timers[:first_token] ||= now
      end
    end

    if chunk_result.has_content
      timers[:last_content] = now
      if !timers[:content_detected]
        timers[:content_detected] = true
        timers[:first_content] ||= now
        timers[:first_token] ||= now
      end
    end
  end

  def build_stream_result(log_prefix, timers, usage_data)
    ttft = timers[:first_token] ? (timers[:first_token] - @request_start).round(3) : nil

    if usage_data
      tokens = self.class.extract_token_counts(usage_data)
      content_tps = self.class.compute_tps(tokens[:content], timers[:first_content], timers[:last_content])
      thinking_tps = self.class.compute_tps(tokens[:thinking], timers[:first_thinking], timers[:last_thinking])

      log_parts = []
      log_parts << "content=#{tokens[:content]}" if tokens[:content]&.positive?
      log_parts << "thinking=#{tokens[:thinking]}" if tokens[:thinking]&.positive?
      log_parts << "ttft=#{ttft}s"
      log_parts << "content_tps=#{content_tps}" if content_tps&.positive?
      log_parts << "thinking_tps=#{thinking_tps}" if thinking_tps&.positive?

      settings.logger.info("#{log_prefix} Success | #{log_parts.join(' ')}")
      { success: true, content_tokens: tokens[:content], thinking_tokens: tokens[:thinking], ttft: ttft, content_tps: content_tps, thinking_tps: thinking_tps }
    else
      settings.logger.info("#{log_prefix} Success | ttft=#{ttft}s (no usage data from provider)")
      { success: true, content_tokens: nil, thinking_tokens: nil, ttft: ttft, content_tps: nil, thinking_tps: nil }
    end
  end

  # ---- Provider selection ----

  def with_auto_select(model:, model_name:, path:, body:, headers:)
    selector = SELECTORS[model_name]

    providers = PROBING_ENABLED ? selector.ordered_providers : selector.providers

    result = nil
    providers.each_with_index do |provider_config, i|
      p_name = provider_config["provider"]
      p_model = provider_config["model"]
      settings.logger.info("[#{model_name}] #{i == 0 ? 'Using' : 'Fallback to'} #{p_name} (#{p_model})")

      log_prefix = "[#{model_name}/#{p_name}]"
      result = yield(provider_config, path, body, p_model, headers, log_prefix)
      if result&.dig(:success)
        record_metrics(selector, p_name, result) if PROBING_ENABLED
        Notifier.notify("LLM Proxy Fallback", "#{model_name} → #{p_name}") if i > 0
        break
      end
    end

    if PROBING_ENABLED && selector.record_and_maybe_probe(PROBE_INTERVAL)
      launch_background_probe(selector, model_name, path, headers)
    end

    result || { success: false, error: "All providers failed" }
  end

  PROBE_BODY = {
    "messages" => [{ "role" => "user", "content" => "Tell me a short story in 300 words" }],
    "max_tokens" => 512
  }.freeze

  def launch_background_probe(selector, model_name, path, headers)
    logger = settings.logger

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
          logger.info("[#{model_name}] Probe #{p_name}: ttft=#{m[:ttft]}s tps=#{tps_str}")
        end

        selector.evaluate_and_select(logger, auto_switch: AUTO_SWITCH)
      rescue => e
        logger.error("[#{model_name}] Background probe error: #{e.message}")
      ensure
        self.class.cleanup_thread_connections!
        selector.probe_finished
      end
    end
  end

  # ---- Token / TPS helpers ----

  def self.extract_sse_content(accumulated)
    content_len = 0
    thinking_len = 0

    accumulated.scan(/^data:\s*(.+)$/).each do |raw|
      line = raw.first.strip
      next if line == "[DONE]" || line.empty?
      begin
        data = JSON.parse(line)
        delta = data.dig("choices", 0, "delta")
        next unless delta
        content_len += delta["content"].to_s.length if delta["content"]
        thinking_len += delta["reasoning_content"].to_s.length if delta["reasoning_content"]
      rescue JSON::ParserError
        next
      end
    end

    { content_len: content_len, thinking_len: thinking_len }
  end

  def self.extract_token_counts(usage_data)
    completion = usage_data.dig("completion_tokens") || usage_data.dig("output_tokens")
    thinking = usage_data.dig("completion_tokens_details", "reasoning_tokens") ||
               usage_data.dig("output_tokens_details", "reasoning_tokens") || 0
    content = completion ? completion - thinking : nil
    { completion: completion, thinking: thinking, content: content }
  end

  def self.compute_tps(token_count, first_time, last_time)
    return nil unless token_count && token_count > 0 && first_time && last_time
    elapsed = last_time - first_time
    elapsed > 0 ? (token_count / elapsed).round(1) : nil
  end

  # ---- Probe provider (class method — runs outside request) ----

  def self.stream_response(http, request, request_start, on_chunk: nil)
    first_token_time = nil
    first_thinking_time = nil
    last_thinking_time = nil
    first_content_time = nil
    last_content_time = nil
    last_any_token_time = nil
    usage_data = nil
    error = nil

    http.request(request) do |response|
      unless response.is_a?(Net::HTTPSuccess)
        error = "HTTP #{response.code}: #{response.body}"
        next
      end

      response.read_body do |chunk|
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cr = parse_chunk(chunk)

        usage_data = cr.usage if cr.usage

        if cr.has_thinking
          last_thinking_time = now
          last_any_token_time = now
          first_thinking_time ||= now
          first_token_time ||= now
        end

        if cr.has_content
          last_content_time = now
          last_any_token_time = now
          first_content_time ||= now
          first_token_time ||= now
        end

        on_chunk&.call(chunk, cr, now)
      end
    end

    if error
      { error: error }
    else
      {
        first_token_time: first_token_time,
        first_thinking_time: first_thinking_time,
        last_thinking_time: last_thinking_time,
        first_content_time: first_content_time,
        last_content_time: last_content_time,
        last_any_token_time: last_any_token_time,
        usage_data: usage_data,
        request_start: request_start
      }
    end
  end

  def self.probe_provider(provider_config, path, body, body_model, incoming_headers, logger:)
    pname = provider_config["provider"]
    uri, request = build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    begin
      http = create_http(uri)
      http.start unless http.started?

      request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = stream_response(http, request, request_start)
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

      tokens = extract_token_counts(result[:usage_data])
      completion_tokens = tokens[:completion] || 0

      tps = compute_tps(tokens[:content], result[:first_content_time], result[:last_content_time])

      if tps.nil?
        tps = compute_tps(completion_tokens, result[:first_token_time], result[:last_any_token_time])
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

  def handle_upstream_error(response, log_prefix)
    error_msg = "HTTP #{response.code}: #{response.body}"
    settings.logger.warn("#{log_prefix} Failed: #{error_msg}")
    raise RetryableError, error_msg
  end

  def handle_streaming_error(result, out)
    return if result[:success]
    out << streaming_error(result[:error], detail: result[:detail])
    out << "data: [DONE]\n\n"
  end

  # ---- Request handlers ----

  def try_stream(provider_config, path, body, body_model, incoming_headers, out:, log_prefix:)
    uri, request = self.class.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)

    try_with_retries(log_prefix: log_prefix, body_model: body_model) do
      http = self.class.create_http(uri)
      http.start unless http.started?

      timers = {
        first_token: nil, first_thinking: nil, last_thinking: nil,
        first_content: nil, last_content: nil,
        thinking_detected: false, content_detected: false
      }
      usage_data = nil
      stream_result = nil
      accumulated = +""

      http.request(request) do |response|
        if response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            out << chunk
            accumulated << chunk if accumulated

            if TRACKING_ENABLED
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              cr = self.class.parse_chunk(chunk)
              usage_data = cr.usage if cr.usage
              track_chunk!(cr, now, timers)
            end
          end

          unless usage_data
            fallback = self.class.parse_chunk(accumulated)
            usage_data = fallback.usage if fallback.usage
          end

          unless usage_data
            counts = self.class.extract_sse_content(accumulated)
            total = counts[:content_len] + counts[:thinking_len]
            if total > 0
              usage_data = {
                "completion_tokens" => total,
                "completion_tokens_details" => { "reasoning_tokens" => counts[:thinking_len] }
              }
            end
          end

          stream_result = build_stream_result(log_prefix, timers, usage_data)
        else
          handle_upstream_error(response, log_prefix)
        end
      end
      stream_result
    end
  end

  def try_single_request(provider_config, path, body, body_model, incoming_headers, log_prefix:)
    uri, request = self.class.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: false)

    try_with_retries(log_prefix: log_prefix, body_model: body_model) do
      http = self.class.create_http(uri)
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
        SSE_HEADERS.each { |k, v| headers[k] = v }

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
    { status: "ok", models: MODELS.keys, timestamp: Time.now.iso8601 }.to_json
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

  def self.prewarm_connections!
    return unless CONFIG.dig("performance", "prewarm_connections") != false

    Thread.new do
      settings.logger.info("Pre-warming HTTP connections to providers...")
      PROVIDERS.values.map { |p| p["base_url"] }.uniq.each do |base_url|
        begin
          uri = URI.parse(base_url)
          http = create_http(uri)
          http.start unless http.started?
          http.finish
          settings.logger.info("  ✓ #{base_url}")
        rescue StandardError => e
          settings.logger.warn("  ✗ #{base_url} (#{e.class}: #{e.message})")
        end
      end
    end
  end

  def self.setup_graceful_shutdown!
    %w[INT TERM].each do |sig|
      Signal.trap(sig) do
        settings.logger.info("\nShutting down gracefully...")
        cleanup_thread_connections!
        exit(0)
      end
    end

    at_exit { cleanup_thread_connections! }
  end
end

LLMProxy.prewarm_connections!
LLMProxy.setup_graceful_shutdown!

LLMProxy.run! if __FILE__ == $PROGRAM_NAME
