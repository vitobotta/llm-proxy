# frozen_string_literal: true

module ConfigValidator
  def self.validate!(config, log)
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

    warnings.each { |w| log.warn("Config warning: #{w}") }

    unless errors.empty?
      errors.each { |e| log.error("Config error: #{e}") }
      abort("Invalid configuration, exiting")
    end

    warnings
  end
end
