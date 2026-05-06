# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "securerandom"

module HTTPSupport
  class RetryableError < StandardError; end
  class ClientDisconnected < StandardError; end

  RETRYABLE_CODES = [429, 500, 502, 503, 504].freeze

  TIMEOUT_EXCEPTIONS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze

  SSE_HEADERS = {
    "Content-Type" => "text/event-stream",
    "Cache-Control" => "no-cache",
    "X-Accel-Buffering" => "no",
    "Connection" => "keep-alive"
  }.freeze

  PROTECTED_HEADERS = %w[host authorization x-api-key api-key].freeze

  URI_CACHE = {}
  URI_CACHE_LOCK = Mutex.new

  ALL_CONNECTION_POOLS = []
  ALL_POOLS_LOCK = Mutex.new

  AUTH_STRATEGIES = {
    "anthropic" => ->(req, key) { req["x-api-key"] = key }
  }.freeze
  DEFAULT_AUTH = ->(req, key) { req["Authorization"] = "Bearer #{key}" }

  def self.cached_uri(base, path)
    key = "#{base}/#{path}"
    URI_CACHE_LOCK.synchronize do
      return URI_CACHE[key] if URI_CACHE.key?(key)
      b = base.end_with?("/") ? base : base + "/"
      URI_CACHE[key] = URI.join(b, path)
    end
  end

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

  def self.create_http(uri, timeouts:)
    key = "#{uri.scheme}://#{uri.host}:#{uri.port}"
    thread_pool = (Thread.current[:http_connections] ||= {})

    ALL_POOLS_LOCK.synchronize do
      ALL_CONNECTION_POOLS << thread_pool unless ALL_CONNECTION_POOLS.include?(thread_pool)
    end

    if (http = thread_pool[key])
      return http if http.started?
      thread_pool.delete(key)
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = timeouts[:open]
    http.read_timeout = timeouts[:read]
    http.write_timeout = timeouts[:write]
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

  def self.cleanup_all_connections!
    ALL_POOLS_LOCK.synchronize do
      ALL_CONNECTION_POOLS.each do |pool|
        pool.each_value do |http|
          http.finish if http.started?
        rescue StandardError
          nil
        end
        pool.clear
      end
    end
  end

  def self.prewarm_connections!(config, providers, logger, timeouts:)
    return unless config.dig("performance", "prewarm_connections") != false

    Thread.new do
      logger.info("Pre-warming HTTP connections to providers...")
      providers.values.map { |p| p["base_url"] }.uniq.each do |base_url|
        begin
          uri = URI.parse(base_url)
          http = create_http(uri, timeouts: timeouts)
          http.start unless http.started?
          http.finish
          logger.info("  \u2713 #{base_url}")
        rescue StandardError => e
          logger.warn("  \u2717 #{base_url} (#{e.class}: #{e.message})")
        end
      end
    end
  end

  def self.setup_graceful_shutdown!(logger, selectors)
    %w[INT TERM].each do |sig|
      Signal.trap(sig) do
        logger.info("\nShutting down gracefully...")
        cleanup_all_connections!
        selectors.each { |_, s| s.persist_active_index }
        exit(0)
      end
    end

    at_exit { cleanup_all_connections! }
  end

  def backoff(attempt)
    base = settings.backoff_base * (2**attempt)
    sleep(base * (0.5 + rand))
  end

  def maybe_retry(attempts)
    return false unless attempts < settings.max_attempts
    backoff(attempts - 1)
    true
  end

  def retry_or_fail(log_prefix, error_label:, detail: nil)
    settings.logger.error("#{log_prefix} All #{settings.max_attempts} attempts failed")
    result = { success: false, error: "#{error_label} after #{settings.max_attempts} attempts" }
    result[:detail] = detail if detail
    result
  end

  def try_with_retries(log_prefix:, body_model:, &block)
    attempts = 0
    eof_retries = 0

    loop do
      attempts += 1
      settings.logger.info("#{log_prefix} Attempt #{attempts}/#{settings.max_attempts} (model: #{body_model})")

      begin
        return block.call
      rescue RetryableError => e
        return retry_or_fail(log_prefix, error_label: "Failed", detail: e.message) unless maybe_retry(attempts)
      rescue ClientDisconnected
        settings.logger.info("#{log_prefix} Client disconnected")
        return { success: false, error: "Client disconnected" }
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

  def handle_upstream_error(response, log_prefix)
    code = response.code.to_i
    error_msg = "HTTP #{code}: #{response.body}"
    settings.logger.warn("#{log_prefix} Failed: #{error_msg}")

    if RETRYABLE_CODES.include?(code)
      if code == 429 && response["Retry-After"]
        delay = response["Retry-After"].to_f
        settings.logger.warn("#{log_prefix} Rate limited, Retry-After: #{delay}s")
        sleep(delay)
      end
      raise RetryableError, error_msg
    end

    { success: false, error: error_msg, status: code }
  end

  def handle_streaming_error(result, out)
    return if result[:success]
    out << streaming_error(result[:error], detail: result[:detail])
    out << "data: [DONE]\n\n"
  end
end
