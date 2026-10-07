# frozen_string_literal: true

require "date"
require_relative "key_rotator"

module ConfigValidator
  MAX_MAX_ATTEMPTS = 10
  MAX_MAX_ROUNDS = 10
  MAX_PROBE_INTERVAL = 100_000
  MAX_SAMPLE_WINDOW = 86_400      # 1 day
  MAX_BACKOFF_BASE = 60
  MAX_MAX_REQUEST_BODY = 100 * 1024 * 1024  # 100 MB
  # Headers the proxy sets itself; configuring them has no effect because
  # build_upstream_request strips them to keep auth strategy authoritative.
  PROTECTED_HEADER_NAMES = %w[authorization x-api-key api-key host].freeze

  def self.validate!(config, log)
    errors, warnings = run_checks(config)

    warnings.each { |w| log.warn("Config warning: #{w}") }

    unless errors.empty?
      errors.each { |e| log.error("Config error: #{e}") }
      abort("Invalid configuration, exiting")
    end

    warnings
  end

  def self.validate(config, log)
    errors, warnings = run_checks(config)
    warnings.each { |w| log.warn("Config warning: #{w}") }
    [errors, warnings]
  end

  # `private` on `def self.x` in a module is a no-op — see private_class_method below.

  def self.run_checks(config)
    errors = []
    warnings = []

    errors << "Missing 'models' in config" unless config["models"]&.any?
    errors << "Missing 'providers' in config" unless config["providers"]&.any?

    provider_keys = (config["providers"] || {}).keys

    (config["providers"] || {}).each do |name, p|
      next unless p.is_a?(Hash)
      api_keys = p["api_keys"]
      if !api_keys.nil? && !api_keys.is_a?(Array)
        errors << "Provider '#{name}' api_keys must be a list of non-empty strings"
      elsif api_keys.is_a?(Array)
        # Require real non-empty strings before any normalisation, so a
        # boolean/mapping/number can never silently become a credential.
        if api_keys.any? { |k| !k.is_a?(String) || k.strip.empty? }
          errors << "Provider '#{name}' api_keys entries must be non-empty strings"
        elsif api_keys.any? && p["api_key"].to_s.strip != ""
          warnings << "Provider '#{name}' sets both api_key and api_keys — api_keys takes precedence"
        end
      end
      if KeyRotator.extract_keys(p).empty?
        errors << "Provider '#{name}' has no api_key (set api_key or a non-empty api_keys list)"
      end
      errors.concat(validate_headers(p["headers"], "Provider '#{name}'"))
      warnings.concat(warn_protected_headers(p["headers"], "Provider '#{name}'"))
      if p["base_url"].nil? || p["base_url"].to_s.strip.empty?
        errors << "Provider '#{name}' has no base_url"
      elsif p["base_url"].is_a?(String)
        begin
          uri = URI.parse(p["base_url"].strip)
          unless uri.scheme&.match?(/\Ahttps?\z/)
            errors << "Provider '#{name}' base_url must use http or https scheme"
          end
          host = uri.host.to_s
          if host.match?(/\A(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)/i)
            warnings << "Provider '#{name}' base_url points to a private/loopback address (#{host}) — ensure this is intentional"
          end
        rescue URI::InvalidURIError
          errors << "Provider '#{name}' base_url is not a valid URI"
        end
      end
    end

    (config["models"] || []).each do |m|
      unless m["name"]
        errors << "Model entry missing 'name'"
        next
      end
      if m.key?("context_length") && (!m["context_length"].is_a?(Integer) || m["context_length"] <= 0)
        errors << "Model '#{m["name"]}' has invalid context_length (must be positive integer)"
      end
      unless m["providers"]&.any?
        errors << "Model '#{m["name"]}' has no providers"
        next
      end
      m["providers"].each do |p|
        unless p["provider"]
          errors << "Model '#{m["name"]}' has a provider entry missing 'provider' key"
          next
        end
        unless provider_keys.include?(p["provider"])
          errors << "Model '#{m["name"]}' references unknown provider '#{p["provider"]}' (define it under 'providers')"
        end
        errors.concat(validate_headers(p["headers"], "Model '#{m["name"]}' provider '#{p["provider"]}'"))
        warnings.concat(warn_protected_headers(p["headers"], "Model '#{m["name"]}' provider '#{p["provider"]}'"))
      end
      if m.key?("probing_enabled") && ![true, false].include?(m["probing_enabled"])
        errors << "Model '#{m["name"]}' has invalid probing_enabled (must be true or false)"
      end
      if m.key?("auto_switch") && ![true, false].include?(m["auto_switch"])
        errors << "Model '#{m["name"]}' has invalid auto_switch (must be true or false)"
      end
      if m.key?("probe_interval") && (!m["probe_interval"].is_a?(Integer) || m["probe_interval"] <= 0)
        errors << "Model '#{m["name"]}' has invalid probe_interval (must be positive integer)"
      end
      if m.key?("ttft_timeout") && !m["ttft_timeout"].nil? && m["ttft_timeout"] != false
        n = m["ttft_timeout"]
        unless n.is_a?(Numeric) && n >= 1 && n <= 86_400
          errors << "Model '#{m["name"]}' has invalid ttft_timeout (must be 1..86400 seconds, or false to disable)"
        end
      end
    end

    unless config["providers"]&.any?
      warnings << "No providers defined"
    end

    if config.dig("auth", "token")
      warnings << "Incoming request auth is enabled — clients must send Authorization: Bearer <token>"
    end

    if (n = config.dig("retries", "max_attempts"))
      if !n.is_a?(Integer) || n < 1
        errors << "retries.max_attempts must be a positive integer (got #{n.inspect})"
      elsif n > MAX_MAX_ATTEMPTS
        errors << "retries.max_attempts is #{n}, refusing (>#{MAX_MAX_ATTEMPTS}). Reduce to keep request latency bounded."
      elsif n > 5
        warnings << "max_attempts > 5 may cause long retry loops"
      end
    end

    if (n = config.dig("retries", "backoff_base"))
      if !n.is_a?(Numeric) || n <= 0 || n > MAX_BACKOFF_BASE
        errors << "retries.backoff_base must be between 0 and #{MAX_BACKOFF_BASE} seconds (got #{n.inspect})"
      end
    end

    if (n = config.dig("retries", "max_rounds"))
      if !n.is_a?(Integer) || n < 1
        errors << "retries.max_rounds must be a positive integer (got #{n.inspect})"
      elsif n > MAX_MAX_ROUNDS
        errors << "retries.max_rounds is #{n}, refusing (>#{MAX_MAX_ROUNDS}). Reduce to keep request latency bounded."
      elsif n > 5
        warnings << "max_rounds > 5 may cause long retry loops"
      end
    end

    if (n = config.dig("performance", "probe_interval"))
      if !n.is_a?(Integer) || n < 1 || n > MAX_PROBE_INTERVAL
        errors << "performance.probe_interval must be 1..#{MAX_PROBE_INTERVAL} (got #{n.inspect})"
      end
    end

    if (n = config.dig("performance", "probe_max_per_minute"))
      if !n.is_a?(Integer) || n < 1 || n > 10_000
        errors << "performance.probe_max_per_minute must be 1..10000 (got #{n.inspect})"
      end
    end

    if (n = config.dig("performance", "sample_window"))
      if !n.is_a?(Integer) || n < 1 || n > MAX_SAMPLE_WINDOW
        errors << "performance.sample_window must be 1..#{MAX_SAMPLE_WINDOW} seconds (got #{n.inspect})"
      end
    end

    if (n = config.dig("limits", "max_request_body"))
      if !n.is_a?(Integer) || n < 1024 || n > MAX_MAX_REQUEST_BODY
        errors << "limits.max_request_body must be 1024..#{MAX_MAX_REQUEST_BODY} bytes (got #{n.inspect})"
      end
    end

    %w[open read write].each do |kind|
      if (n = config.dig("timeouts", kind))
        if !n.is_a?(Numeric) || n < 1 || n > 86_400
          errors << "timeouts.#{kind} must be 1..86400 seconds (got #{n.inspect})"
        end
      end
    end

    if (n = config.dig("timeouts", "ttft"))
      if !n.is_a?(Numeric) || n < 1 || n > 86_400
        errors << "timeouts.ttft must be 1..86400 seconds (got #{n.inspect})"
      end
    end

    if (n = config.dig("metrics", "tps_log", "interval"))
      if !n.is_a?(Integer) || n < 0 || n > 3600
        errors << "metrics.tps_log.interval must be 0..3600 seconds (got #{n.inspect})"
      end
    end
    if (n = config.dig("metrics", "tps_log", "activity_window"))
      if !n.is_a?(Integer) || n < 1 || n > 3600
        errors << "metrics.tps_log.activity_window must be 1..3600 seconds (got #{n.inspect})"
      end
    end
    if (n = config.dig("metrics", "tps_log", "eval_window"))
      if !n.is_a?(Integer) || n < 1 || n > 86_400
        errors << "metrics.tps_log.eval_window must be 1..86400 seconds (got #{n.inspect})"
      end
    end
    if (n = config.dig("metrics", "tps_log", "min_tokens"))
      if !n.is_a?(Integer) || n < 0 || n > 1_000_000
        errors << "metrics.tps_log.min_tokens must be 0..1000000 (got #{n.inspect})"
      end
    end

    [errors, warnings]
  end

  # Header values may be any YAML scalar — strings, numbers, booleans, and
  # Date/Time (e.g. an unquoted `anthropic-version: 2023-06-01`). They are
  # stringified when the upstream request is built. nil and containers
  # (Hash/Array) are rejected.
  def self.validate_headers(headers, where)
    return [] if headers.nil?
    return ["#{where} headers must be a mapping of header name to value"] unless headers.is_a?(Hash)
    headers.each_with_object([]) do |(hk, hv), errs|
      scalar = hv.is_a?(String) || hv.is_a?(Numeric) || hv == true || hv == false ||
        hv.is_a?(Date) || hv.is_a?(Time) || hv.is_a?(Symbol)
      errs << "#{where} header '#{hk}' value must be a scalar" unless scalar
    end
  end

  def self.warn_protected_headers(headers, where)
    return [] unless headers.is_a?(Hash)
    headers.keys
      .select { |hk| PROTECTED_HEADER_NAMES.include?(hk.to_s.downcase) }
      .map { |hk| "#{where} header '#{hk}' is managed by the proxy and will be ignored" }
  end

  private_class_method :run_checks, :validate_headers, :warn_protected_headers
end
