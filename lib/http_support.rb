# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "securerandom"

module HTTPSupport
  class RetryableError < StandardError; end
  class ClientDisconnected < StandardError; end
  class RateLimitedError < RetryableError
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("Rate limited, Retry-After: #{retry_after}s")
    end
  end

  RETRYABLE_CODES = [429, 500, 502, 503, 504].freeze

  TIMEOUT_EXCEPTIONS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze

  MAX_EOF_RETRIES = 2
  MAX_RETRY_AFTER = 60
  KEEP_ALIVE_TIMEOUT = 30
  MAX_UPSTREAM_BODY_SIZE = 5 * 1024 * 1024
  JITTER_FACTOR = 0.5
  MAX_CONNECTION_AGE = 300
  CONNECTION_IDLE_TIMEOUT = 60

  PoolEntry = Struct.new(:http, :created_at, :last_used_at, keyword_init: true)

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
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    ALL_POOLS_LOCK.synchronize do
      ALL_CONNECTION_POOLS << thread_pool unless ALL_CONNECTION_POOLS.include?(thread_pool)
    end

    if (entry = thread_pool[key])
      age = now - entry.created_at
      idle = now - entry.last_used_at
      if entry.http.started? && age < MAX_CONNECTION_AGE && idle < CONNECTION_IDLE_TIMEOUT
        entry.last_used_at = now
        return entry.http
      end
      begin
        entry.http.finish if entry.http.started?
      rescue StandardError
        nil
      end
      thread_pool.delete(key)
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = timeouts[:open]
    http.read_timeout = timeouts[:read]
    http.write_timeout = timeouts[:write]
    http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT
    thread_pool[key] = PoolEntry.new(http: http, created_at: now, last_used_at: now)
    http
  end

  def self.cleanup_thread_connections!
    thread_pool = Thread.current[:http_connections]
    return unless thread_pool

    thread_pool.each_value do |entry|
      http = entry.is_a?(PoolEntry) ? entry.http : entry
      http.finish if http.started?
    rescue StandardError
      nil
    end
    thread_pool.clear
  end

  def self.cleanup_all_connections!
    ALL_POOLS_LOCK.synchronize do
      ALL_CONNECTION_POOLS.each do |pool|
        pool.each_value do |entry|
          http = entry.is_a?(PoolEntry) ? entry.http : entry
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
        Thread.new do
          cleanup_all_connections!
          selectors.each { |_, s| s.persist_active_index }
          StatePersistence.save(logger: logger) if defined?(StatePersistence)
          exit(0)
        end
      end
    end

    at_exit do
      cleanup_all_connections!
      StatePersistence.save(logger: logger) if defined?(StatePersistence) && !$ERROR_INFO.is_a?(SystemExit)
    end
  end

  def backoff(attempt)
    base = settings.backoff_base * (2**attempt)
    sleep(base * (JITTER_FACTOR + rand * JITTER_FACTOR))
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
        if e.is_a?(RateLimitedError)
          settings.logger.info("#{log_prefix} Waiting #{e.retry_after}s before retry...")
          sleep(e.retry_after)
        end
        return retry_or_fail(log_prefix, error_label: "Failed", detail: e.message) unless maybe_retry(attempts)
      rescue ClientDisconnected
        settings.logger.info("#{log_prefix} Client disconnected")
        return { success: false, error: "Client disconnected" }
      rescue EOFError
        eof_retries += 1
        if eof_retries <= MAX_EOF_RETRIES
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
    thread_pool.delete_if do |_, entry|
      http = entry.is_a?(PoolEntry) ? entry.http : entry
      !http.started?
    end
  end

  def handle_upstream_error(response, log_prefix)
    code = response.code.to_i
    error_body = response.body
    if error_body && error_body.bytesize > MAX_UPSTREAM_BODY_SIZE
      error_body = error_body.byteslice(0, MAX_UPSTREAM_BODY_SIZE) + "... (truncated)"
    end
    error_msg = "HTTP #{code}: #{error_body}"
    settings.logger.warn("#{log_prefix} Failed: #{error_msg}")

    if RETRYABLE_CODES.include?(code)
      if code == 429 && response["Retry-After"]
        delay = [response["Retry-After"].to_f, MAX_RETRY_AFTER].min
        settings.logger.warn("#{log_prefix} Rate limited, Retry-After: #{delay}s")
        raise RateLimitedError.new(delay)
      end
      raise RetryableError, error_msg
    end

    { success: false, error: error_msg, status: code }
  end
end
