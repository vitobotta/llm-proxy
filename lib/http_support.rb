# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"
require "securerandom"

module HTTPSupport
  class RetryableError < StandardError; end
  class ClientDisconnected < StandardError; end

  class QuotaExhaustedError < StandardError
    attr_reader :reset_time, :status, :reason

    def initialize(reset_time:, status:, reason: "quota_exhausted")
      @reset_time = reset_time
      @status = status
      @reason = reason
      super("Quota exhausted (#{reason}), resume at #{Time.at(reset_time).utc.iso8601}")
    end
  end

  RETRYABLE_CODES = [500, 502, 503, 504].freeze

  QUOTA_BODY_PATTERNS = [
    /insufficient_quota/i,
    /billing\s*(limit|exceeded|issue)/i,
    /credit\s*(balance|limit|exhausted|insufficient)/i,
    /payment/i,
    /plan\s*(limit|exceeded)/i,
    /usage\s*limit/i,
    /quota\s*(exceeded|reached|limit)/i
  ].freeze

  QUOTA_STATUS_CODES = [402].freeze

  DEFAULT_QUOTA_PAUSE_SECONDS = 60

  TIMEOUT_EXCEPTIONS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze

  MAX_EOF_RETRIES = 2
  MAX_RETRY_AFTER = 60
  KEEP_ALIVE_TIMEOUT = 30
  MAX_UPSTREAM_BODY_SIZE = 5 * 1024 * 1024
  JITTER_FACTOR = 0.5

  SSE_HEADERS = {
    "Content-Type" => "text/event-stream",
    "Cache-Control" => "no-cache",
    "X-Accel-Buffering" => "no",
    "Connection" => "keep-alive"
  }.freeze

  PROTECTED_HEADERS = %w[host authorization x-api-key api-key].freeze

  URI_CACHE = {}
  URI_CACHE_LOCK = Mutex.new
  MAX_URI_CACHE_SIZE = 1024

  POOL_MAX_AGE = 300
  POOL_MAX_IDLE = 60
  CONNECTION_POOL = {}
  POOL_LOCK = Mutex.new

  AUTH_STRATEGIES = {
    "anthropic" => ->(req, key) { req["x-api-key"] = key }
  }.freeze
  DEFAULT_AUTH = ->(req, key) { req["Authorization"] = "Bearer #{key}" }

  # Reads an upstream error response body, capping memory use.
  # If Content-Length advertises an oversized body, we skip the read
  # entirely so a buggy or hostile upstream can't force a multi-GB allocation.
  def self.read_capped_error_body(response)
    cl = response["Content-Length"]&.to_i
    if cl && cl > MAX_UPSTREAM_BODY_SIZE
      return "[upstream error body of #{cl} bytes exceeds #{MAX_UPSTREAM_BODY_SIZE}-byte cap, suppressed]"
    end

    body = begin
      response.body
    rescue => e
      "[failed to read upstream body: #{e.class}: #{e.message}]"
    end

    return body if body.nil? || body.bytesize <= MAX_UPSTREAM_BODY_SIZE
    body.byteslice(0, MAX_UPSTREAM_BODY_SIZE) + "... (truncated)"
  end

  # Parses an RFC 7231 Retry-After value (either a delta-seconds integer
  # or an HTTP-date) into a Float number of seconds from now.
  # Returns 0.0 if the value can't be parsed.
  def self.parse_retry_after(value, now: Time.now)
    return 0.0 if value.nil? || value.to_s.strip.empty?
    stripped = value.to_s.strip
    if /\A\d+(\.\d+)?\z/.match?(stripped)
      stripped.to_f
    else
      begin
        (Time.httpdate(stripped) - now).to_f
      rescue ArgumentError
        0.0
      end
    end
  end

  def self.quota_exhausted?(status, body)
    return true if QUOTA_STATUS_CODES.include?(status)
    return true if status == 429
    return false unless status == 403
    body ||= ""
    QUOTA_BODY_PATTERNS.any? { |pat| pat.match?(body) }
  end

  def self.extract_reset_time(response, body, status, default_seconds:)
    ra = parse_retry_after(response["Retry-After"])
    if ra > 0
      delay = [ra, MAX_RETRY_AFTER].min
      return Time.now.to_f + delay
    end

    %w[x-ratelimit-reset-requests x-ratelimit-reset-tokens].each do |hdr|
      val = response[hdr]
      next unless val
      begin
        t = Float(val)
        return t if t > Time.now.to_f
      rescue ArgumentError
        nil
    end
    end

    extract_reset_time_from_body(body, default_seconds: default_seconds)
  end

  def self.extract_reset_time_from_error(error_str, status, default_seconds:)
    body = error_str.sub(/\AHTTP \d{3}:\s*/, "")
    extract_reset_time_from_body(body, default_seconds: default_seconds)
  end

  def self.extract_reset_time_from_body(body, default_seconds:)
    parsed = nil
    begin
      parsed = JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end

    if parsed.is_a?(Hash)
      reset_fields = %w[reset reset_time reset_at]
      ms_fields = %w[retry_after_ms]

      reset_fields.each do |key|
        if parsed.key?(key)
          v = parsed[key]
          return v.to_f if v.respond_to?(:to_f) && v.to_f > Time.now.to_f
        end
      end

      ms_fields.each do |key|
        if parsed.key?(key)
          v = parsed[key]
          return Time.now.to_f + v.to_f / 1000.0 if v.respond_to?(:to_f)
        end
      end

      err = parsed["error"]
      if err.is_a?(Hash)
        reset_fields.each do |key|
          if err.key?(key)
            v = err[key]
            return v.to_f if v.respond_to?(:to_f) && v.to_f > Time.now.to_f
          end
        end

        ms_fields.each do |key|
          if err.key?(key)
            v = err[key]
            return Time.now.to_f + v.to_f / 1000.0 if v.respond_to?(:to_f)
          end
        end
      end
    end

    Time.now.to_f + default_seconds
  end
  def self.cached_uri(base, path)
    key = "#{base}/#{path}"
    URI_CACHE_LOCK.synchronize do
      return URI_CACHE[key] if URI_CACHE.key?(key)
      # FIFO eviction. Hash preserves insertion order in Ruby; first key is oldest.
      URI_CACHE.shift if URI_CACHE.size >= MAX_URI_CACHE_SIZE
      b = base.end_with?("/") ? base : base + "/"
      URI_CACHE[key] = URI.join(b, path)
    end
  end

  def self.clear_uri_cache!
    URI_CACHE_LOCK.synchronize { URI_CACHE.clear }
  end

  def self.build_upstream_request(provider_config, path, body, body_model, incoming_headers, stream: true)
    uri = cached_uri(provider_config["base_url"], path)

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"

    (AUTH_STRATEGIES[provider_config["provider"]] || DEFAULT_AUTH).call(request, provider_config["api_key"])

    provider_config["headers"]&.each do |k, v|
      # PROTECTED_HEADERS are stripped from provider config too so a fat-fingered
      # `Authorization:` or `Host:` in config can't override the auth strategy.
      next if PROTECTED_HEADERS.include?(k.to_s.downcase)
      request[k] = v
    end

    incoming_headers&.each do |key, value|
      next if PROTECTED_HEADERS.include?(key.downcase)
      request[key] = value
    end

    request_body = body.dup
    request_body["model"] = body_model if body_model
    request_body["stream"] = stream
    request_body["stream_options"] = {"include_usage" => true} if stream
    request_body["perf_metrics_in_response"] = true if stream && provider_config["provider"] == "fireworks"
    request.body = request_body.to_json

    [uri, request]
  end

  def self.create_http(uri, timeouts:)
    http = checkout_http(uri)
    return http if http
    fresh_http(uri, timeouts: timeouts)
  end

  def self.fresh_http(uri, timeouts:)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = timeouts[:open]
    http.read_timeout = timeouts[:read]
    http.write_timeout = timeouts[:write]
    http.keep_alive_timeout = KEEP_ALIVE_TIMEOUT
    http
  end

  def self.checkout_http(uri)
    key = "#{uri.host}:#{uri.port}"
    POOL_LOCK.synchronize do
      entries = CONNECTION_POOL[key]
      return nil unless entries
      now = Time.now.to_f
      while (entry = entries.pop)
        next if now - entry[:created] > POOL_MAX_AGE
        next if now - entry[:last_used] > POOL_MAX_IDLE
        if entry[:http].started?
          entry[:http].instance_variable_set(:@last_used_at, now)
          return entry[:http]
        end
      end
      nil
    end
  end

  def self.checkin_http(uri, http)
    return unless http
    key = "#{uri.host}:#{uri.port}"
    now = Time.now.to_f
    POOL_LOCK.synchronize do
      entries = (CONNECTION_POOL[key] ||= [])
      # Evict stale entries
      entries.reject! { |e| now - e[:created] > POOL_MAX_AGE || now - e[:last_used] > POOL_MAX_IDLE }
      entries << {http: http, created: now, last_used: now}
    end
  rescue
    # If checkin fails, just let http get GC'd
    nil
  end

  def self.discard_http(http)
    return unless http
    begin
      http.finish if http.started?
    rescue
      nil
    end
  end

  def self.flush_pool!
    POOL_LOCK.synchronize do
      CONNECTION_POOL.each do |_, entries|
        entries.each do |entry|
          begin
            entry[:http].finish if entry[:http].started?
          rescue
            nil
          end
        end
      end
      CONNECTION_POOL.clear
    end
  end

  def self.prewarm_connections!(config, providers, logger, timeouts:)
    return unless config.dig("performance", "prewarm_connections") != false

    Thread.new do
      logger.info("Pre-warming HTTP connections to providers...")
      providers.values.map { |p| p["base_url"] }.uniq.each do |base_url|
        uri = URI.parse(base_url)
        http = fresh_http(uri, timeouts: timeouts)
        http.start
        checkin_http(uri, http)
        logger.info("  \u2713 #{base_url}")
      rescue => e
        logger.warn("  \u2717 #{base_url} (#{e.class}: #{e.message})")
      end
    end
  end

  def self.setup_graceful_shutdown!(logger, selectors)
    @shutting_down = false

    %w[INT TERM].each do |sig|
      Signal.trap(sig) do
        next if @shutting_down
        @shutting_down = true
        logger.info("\nShutting down gracefully...")
        Thread.new do
          begin
            flush_pool!
            TpsReporter.stop! if defined?(TpsReporter)
            selectors.each { |_, s| s.persist_active_index(logger: logger) }
            StatePersistence.save(logger: logger) if defined?(StatePersistence)
          rescue => e
            logger.error("Shutdown error: #{e.class}: #{e.message}")
          end
          exit(0)
        end
      end
    end

    at_exit do
      begin
        TpsReporter.stop! if defined?(TpsReporter) && !$ERROR_INFO.is_a?(SystemExit)
        flush_pool!
        StatePersistence.save(logger: logger) if defined?(StatePersistence) && !$ERROR_INFO.is_a?(SystemExit)
      rescue => e
        logger&.error("at_exit save error: #{e.class}: #{e.message}")
      end
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
    result = {success: false, error: "#{error_label} after #{settings.max_attempts} attempts"}
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
      rescue QuotaExhaustedError => e
        settings.logger.warn("#{log_prefix} Quota exhausted (#{e.reason}), pausing provider until #{Time.at(e.reset_time).utc.iso8601}")
        return {success: false, error: e.message, status: e.status, quota_pause_until: e.reset_time, quota_pause_reason: e.reason}
      rescue RetryableError => e
        return retry_or_fail(log_prefix, error_label: "Failed", detail: e.message) unless maybe_retry(attempts)
      rescue ClientDisconnected
        settings.logger.info("#{log_prefix} Client disconnected")
        return {success: false, error: "Client disconnected"}
      rescue EOFError
        eof_retries += 1
        if eof_retries <= MAX_EOF_RETRIES
          settings.logger.warn("#{log_prefix} EOF on stale connection (retry #{eof_retries}/2, not counting against attempts)")
          next
        end
        settings.logger.warn("#{log_prefix} EOF persisted after #{eof_retries} retries, counting as attempt failure")
        return retry_or_fail(log_prefix, error_label: "Connection reset") unless maybe_retry(attempts)
      rescue *TIMEOUT_EXCEPTIONS => e
        settings.logger.warn("#{log_prefix} Timeout: #{e.message}")
        return retry_or_fail(log_prefix, error_label: "Timeout") unless maybe_retry(attempts)
      rescue => e
        settings.logger.warn("#{log_prefix} Error: #{e.message}")
        return retry_or_fail(log_prefix, error_label: "Error", detail: e.message) unless maybe_retry(attempts)
      end
    end
  end


  def handle_upstream_error(response, log_prefix)
    code = response.code.to_i
    error_body = HTTPSupport.read_capped_error_body(response)
    error_msg = "HTTP #{code}: #{error_body}"
    settings.logger.warn("#{log_prefix} Failed: #{error_msg}")

    if code == 429 || HTTPSupport.quota_exhausted?(code, error_body)
      reason = if code == 402
                 "payment_required"
               elsif code == 429
                 "rate_limited"
               else
                 "quota_exhausted"
               end
      default_secs = (defined?(ConfigStore) ? ConfigStore.quota_pause_default_seconds : nil) || HTTPSupport::DEFAULT_QUOTA_PAUSE_SECONDS
      reset_time = HTTPSupport.extract_reset_time(response, error_body, code,
        default_seconds: default_secs)
      settings.logger.warn("#{log_prefix} Quota paused (#{reason}), resume at #{Time.at(reset_time).utc.iso8601}")
      raise QuotaExhaustedError.new(reset_time: reset_time, status: code, reason: reason)
    end

    if RETRYABLE_CODES.include?(code)
      raise RetryableError, error_msg
    end

    {success: false, error: error_msg, status: code}
  end
end
