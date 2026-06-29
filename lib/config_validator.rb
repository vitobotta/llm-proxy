# frozen_string_literal: true

module ConfigValidator
  MAX_MAX_ATTEMPTS = 10
  MAX_MAX_ROUNDS = 10
  MAX_PROBE_INTERVAL = 100_000
  MAX_SAMPLE_WINDOW = 86_400      # 1 day
  MAX_BACKOFF_BASE = 60
  MAX_MAX_REQUEST_BODY = 100 * 1024 * 1024  # 100 MB

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
      api_key = p["api_key"]
      if api_key.nil? || api_key.to_s.strip.empty?
        errors << "Provider '#{name}' has no api_key (set api_key to a non-empty string)"
      end
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

  private_class_method :run_checks
end
