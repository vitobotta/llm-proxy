# frozen_string_literal: true

module ConfigValidator
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

  private

  def self.run_checks(config)
    errors = []
    warnings = []

    errors << "Missing 'models' in config" unless config["models"]&.any?
    errors << "Missing 'providers' in config" unless config["providers"]&.any?

    (config["models"] || []).each do |m|
      unless m["name"]
        errors << "Model entry missing 'name'"
        next
      end
      if m.key?("context_length") && (!m["context_length"].is_a?(Integer) || m["context_length"] <= 0)
        errors << "Model '#{m['name']}' has invalid context_length (must be positive integer)"
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
      if m.key?("probing_enabled") && ![true, false].include?(m["probing_enabled"])
        errors << "Model '#{m['name']}' has invalid probing_enabled (must be true or false)"
      end
      if m.key?("auto_switch") && ![true, false].include?(m["auto_switch"])
        errors << "Model '#{m['name']}' has invalid auto_switch (must be true or false)"
      end
      if m.key?("probe_interval") && (!m["probe_interval"].is_a?(Integer) || m["probe_interval"] <= 0)
        errors << "Model '#{m['name']}' has invalid probe_interval (must be positive integer)"
      end
    end

    unless config["providers"]&.any?
      warnings << "No providers defined"
    end

    if config.dig("auth", "token")
      warnings << "Incoming request auth is enabled — clients must send Authorization: Bearer <token>"
    end

    if config.dig("retries", "max_attempts") && config.dig("retries", "max_attempts") > 5
      warnings << "max_attempts > 5 may cause long retry loops"
    end

    [errors, warnings]
  end
end
