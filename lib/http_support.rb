# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"
require "securerandom"

module HTTPSupport
  class RetryableError < StandardError
    attr_reader :retry_after
    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
  class ClientDisconnected < StandardError; end
  class TTFTTimeoutError < StandardError; end

  # Raised when an upstream error occurs after chunks have already been
  # forwarded to the client. The stream cannot be retried (the client would
  # receive a garbled duplicate), but unlike ClientDisconnected this is an
  # upstream failure, not a client-side disconnect. The original exception
  # is preserved for logging and diagnostics.
  class StreamPartiallySent < StandardError
    attr_reader :original

    def initialize(original)
      @original = original
      super("Upstream disconnect after partial stream: #{original.class}")
    end
  end

  class QuotaExhaustedError < StandardError
    attr_reader :reset_time, :status, :reason

    def initialize(reset_time:, status:, reason: "quota_exhausted")
      @reset_time = reset_time
      @status = status
      @reason = reason
      super("Quota exhausted (#{reason}), resume at #{Time.at(reset_time).utc.iso8601}")
    end
  end

  RETRYABLE_CODES = [408, 500, 502, 503, 504].freeze

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
  MAX_RETRY_AFTER = 86400
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
  MAX_POOL_SIZE = 32
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

  # Parses an x-ratelimit-reset-* header value. OpenAI sends duration
  # strings like "6s", "1m", "500ms"; some providers send plain seconds
  # or absolute Unix timestamps. Returns an absolute resume time (Float)
  # or nil if the value can't be parsed.
  def self.parse_ratelimit_reset(val)
    stripped = val.to_s.strip
    return nil if stripped.empty?

    # Pure number: small values are relative seconds, large values are
    # absolute Unix timestamps.
    if /\A\d+(\.\d+)?\z/.match?(stripped)
      num = stripped.to_f
      return num > 86400 ? num : Time.now.to_f + [num, MAX_RETRY_AFTER].min
    end

    # Duration string: "6s", "1m", "500ms", "1h", "2d"
    if (m = stripped.match(/\A(\d+(?:\.\d+)?)(ms|s|m|h|d)\z/i))
      num = m[1].to_f
      unit = m[2].downcase
      multiplier = {"ms" => 0.001, "s" => 1, "m" => 60, "h" => 3600, "d" => 86400}
      return Time.now.to_f + [num * multiplier[unit], MAX_RETRY_AFTER].min
    end

    nil
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
      reset = parse_ratelimit_reset(val)
      next unless reset
      return [reset, Time.now.to_f + MAX_RETRY_AFTER].min if reset > Time.now.to_f
    end

    extract_reset_time_from_body(body, default_seconds: default_seconds)
  end

  def self.extract_reset_time_from_error(error_str, status, default_seconds:)
    body = error_str.sub(/\AHTTP \d{3}:\s*/, "")
    extract_reset_time_from_body(body, default_seconds: default_seconds)
  end

  RESET_TEXT_PATTERNS = [
    /resets?\s+in\s+(\d+(?:\.\d+)?)\s*(days?|hours?|hrs?|minutes?|mins?|seconds?|secs?|d|h|m|s)\b/i,
    /retry\s+in\s+(\d+(?:\.\d+)?)\s*(days?|hours?|hrs?|minutes?|mins?|seconds?|secs?|d|h|m|s)\b/i,
    /try\s+again\s+in\s+(\d+(?:\.\d+)?)\s*(days?|hours?|hrs?|minutes?|mins?|seconds?|secs?|d|h|m|s)\b/i,
    /available\s+in\s+(\d+(?:\.\d+)?)\s*(days?|hours?|hrs?|minutes?|mins?|seconds?|secs?|d|h|m|s)\b/i
  ].freeze

  RESET_UNIT_SECONDS = {
    "second" => 1, "seconds" => 1, "sec" => 1, "secs" => 1, "s" => 1,
    "minute" => 60, "minutes" => 60, "min" => 60, "mins" => 60, "m" => 60,
    "hour" => 3600, "hours" => 3600, "hr" => 3600, "hrs" => 3600, "h" => 3600,
    "day" => 86400, "days" => 86400, "d" => 86400
  }.freeze

  # Parse a human-readable duration from an error message (e.g. "Resets
  # in 1 day", "retry in 30 minutes"). Returns the delay in seconds, or
  # nil if no pattern matches. Provider rate-limit messages often embed
  # the reset time in prose rather than a structured JSON field.
  def self.parse_duration_from_text(text)
    return nil unless text
    RESET_TEXT_PATTERNS.each do |pat|
      m = text.match(pat)
      return m[1].to_f * RESET_UNIT_SECONDS[m[2].downcase] if m && RESET_UNIT_SECONDS[m[2].downcase]
    end
    nil
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

        # Parse human-readable duration from error message text.
        # Many providers embed the reset time in the message string
        # rather than a structured field: "Monthly usage limit reached.
        # Resets in 1 day."
        msg = err["message"]
        if msg.is_a?(String)
          delay = parse_duration_from_text(msg)
          return Time.now.to_f + delay if delay && delay > 0
        end
      end

      top_msg = parsed["message"]
      if top_msg.is_a?(String)
        delay = parse_duration_from_text(top_msg)
        return Time.now.to_f + delay if delay && delay > 0
      end
    end

    text_delay = parse_duration_from_text(body.to_s)
    return Time.now.to_f + text_delay if text_delay && text_delay > 0

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
        if now - entry[:created] > POOL_MAX_AGE || now - entry[:last_used] > POOL_MAX_IDLE
          begin; entry[:http].finish if entry[:http].started?; rescue; nil; end
          next
        end
        if entry[:http].started?
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
      entries << {http: http, created: now, last_used: now} if entries.size < MAX_POOL_SIZE
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

  @shutting_down = false
  @in_flight = 0
  @in_flight_lock = Mutex.new
  SHUTDOWN_DRAIN_SECONDS = 30

  def self.in_flight_increment!
    @in_flight_lock.synchronize { @in_flight += 1 }
  end

  def self.in_flight_decrement!
    @in_flight_lock.synchronize { @in_flight -= 1 }
  end

  def self.shutting_down?
    @shutting_down
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
            # Drain: wait for in-flight requests to complete (up to deadline).
            deadline = Time.now.to_f + SHUTDOWN_DRAIN_SECONDS
            loop do
              count = @in_flight_lock.synchronize { @in_flight }
              break if count == 0
              break if Time.now.to_f > deadline
              sleep(0.5)
            end
            count = @in_flight_lock.synchronize { @in_flight }
            logger.info("Shutdown: #{count} in-flight request(s) still running") if count > 0

            flush_pool!
            TpsReporter.stop! if defined?(TpsReporter)
            # Re-read selectors at exit time so models added via hot-reload
            # are persisted (the boot-captured closure only has the original set).
            current_selectors = defined?(ConfigStore) ? ConfigStore.selectors : selectors
            current_selectors.each { |_, s| s.persist_active_index(logger: logger) }
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

  def maybe_retry(attempts, retry_after: nil)
    return false unless attempts < settings.max_attempts
    if retry_after && retry_after > 0
      sleep([retry_after, MAX_RETRY_AFTER].min)
    else
      backoff(attempts - 1)
    end
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
        return retry_or_fail(log_prefix, error_label: "Failed", detail: e.message) unless maybe_retry(attempts, retry_after: e.retry_after)
      rescue ClientDisconnected
        settings.logger.info("#{log_prefix} Client disconnected")
        return {success: false, error: "Client disconnected"}
      rescue StreamPartiallySent => e
        settings.logger.warn("#{log_prefix} Upstream error after partial stream: #{e.original.class}: #{e.original.message}")
        return {success: false, error: "Upstream disconnect after partial stream"}
      rescue TTFTTimeoutError => e
        settings.logger.warn("#{log_prefix} TTFT timeout: #{e.message}")
        return retry_or_fail(log_prefix, error_label: "TTFT timeout", detail: e.message) unless maybe_retry(attempts)
      rescue EOFError
        eof_retries += 1
        if eof_retries <= MAX_EOF_RETRIES
          settings.logger.warn("#{log_prefix} EOF on stale connection (retry #{eof_retries}/2, not counting against attempts)")
          attempts -= 1
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
      ra = HTTPSupport.parse_retry_after(response["Retry-After"])
      raise RetryableError.new(error_msg, retry_after: ra > 0 ? ra : nil)
    end

    # Return a sanitized message to the client; the full upstream body is
    # logged above for operator debugging but not exposed to callers.
    {success: false, error: "Upstream returned HTTP #{code}", status: code}
  end
end
