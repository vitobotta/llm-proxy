# frozen_string_literal: true

require_relative "config_validator"

module ConfigStore
  CONFIG_PATH = File.join(File.dirname(__dir__), "config.yaml")

  @lock = Mutex.new
  @data = {}

  def self.load!(raw_config, logger:)
    new_data = build_data(raw_config, logger)
    @lock.synchronize do
      old_data = @data
      @data = new_data
      merge_selectors!(old_data, new_data)
    end
    self
  end

  def self.reload!(logger:)
    raw = YAML.unsafe_load_file(CONFIG_PATH)
    errors, warnings = ConfigValidator.validate(raw, logger)
    unless errors.empty?
      errors.each { |e| logger.error("Config reload error: #{e}") }
      logger.warn("Config reload skipped — keeping last good configuration")
      return false
    end
    warnings.each { |w| logger.warn("Config warning: #{w}") }

    old_providers = providers
    load!(raw, logger: logger)
    new_provider_keys = providers.keys - old_providers.keys
    unless new_provider_keys.empty?
      HTTPSupport.prewarm_connections!(raw, providers, logger, timeouts: timeouts)
    end
    update_logger_level!(raw, logger)
    logger.info("Configuration reloaded from config.yaml")
    true
  rescue => e
    logger.error("Config reload failed: #{e.class}: #{e.message}")
    false
  end

  def self.config = @lock.synchronize { @data[:config] }
  def self.providers = @lock.synchronize { @data[:providers] }
  def self.models = @lock.synchronize { @data[:models] }
  def self.selectors = @lock.synchronize { @data[:selectors] }
  def self.timeouts = @lock.synchronize { @data[:timeouts] }
  def self.auth_token = @lock.synchronize { @data[:auth_token] }
  def self.max_body_size = @lock.synchronize { @data[:max_body_size] }
  def self.tracking_enabled = @lock.synchronize { @data[:tracking_enabled] }
  def self.probing_enabled = @lock.synchronize { @data[:probing_enabled] }
  def self.auto_switch = @lock.synchronize { @data[:auto_switch] }
  def self.probe_interval = @lock.synchronize { @data[:probe_interval] }
  def self.sample_window = @lock.synchronize { @data[:sample_window] }
  def self.max_attempts = @lock.synchronize { @data[:max_attempts] }
  def self.backoff_base = @lock.synchronize { @data[:backoff_base] }

  def self.model(name) = @lock.synchronize { @data[:models][name] }
  def self.selector(name) = @lock.synchronize { @data[:selectors][name] }

  def self.update_settings!(app)
    @lock.synchronize do
      app.set :max_attempts, @data[:max_attempts]
      app.set :backoff_base, @data[:backoff_base]
    end
  end

  private

  def self.build_data(raw, logger)
    providers = (raw["providers"] || {}).transform_values(&:freeze).freeze
    ConfigValidator.validate!(raw, logger) if @data.empty?

    sample_window = raw.dig("performance", "sample_window") || ProviderSelector::DEFAULT_SAMPLE_WINDOW
    tracking_enabled = raw.dig("tracking", "enabled") != false
    probing_enabled = raw.dig("performance", "probing_enabled") != false
    auto_switch = probing_enabled && raw.dig("performance", "auto_switch") == true
    probe_interval = raw.dig("performance", "probe_interval") || 3

    models = {}
    selectors = {}
    raw["models"].each do |m|
      provider_list = m["providers"].map { |p| resolve_provider(providers, p["provider"], p["model"], p["headers"]) }
      model_entry = { "name" => m["name"], "providers" => provider_list.freeze, "context_length" => m["context_length"] }.compact.freeze
      models[m["name"]] = model_entry
      selectors[m["name"]] = ProviderSelector.new(m["name"], provider_list, model_config: m, sample_window: sample_window)
    end

    {
      config: raw,
      providers: providers,
      models: models.freeze,
      selectors: selectors,
      timeouts: {
        open:  raw.dig("timeouts", "open")  || 30,
        read:  raw.dig("timeouts", "read")  || 300,
        write: raw.dig("timeouts", "write") || 60
      }.freeze,
      auth_token: raw.dig("auth", "token"),
      max_body_size: raw.dig("limits", "max_request_body") || 10 * 1024 * 1024,
      tracking_enabled: tracking_enabled,
      probing_enabled: probing_enabled,
      auto_switch: auto_switch,
      probe_interval: probe_interval,
      sample_window: sample_window,
      max_attempts: raw.dig("retries", "max_attempts") || 3,
      backoff_base: raw.dig("retries", "backoff_base") || 2
    }
  end

  def self.merge_selectors!(old_data, new_data)
    old_selectors = old_data[:selectors] || {}
    new_selectors = new_data[:selectors]
    new_selectors.each do |model_name, new_sel|
      old_sel = old_selectors[model_name]
      next unless old_sel
      next unless provider_lists_match?(old_sel.providers, new_sel.providers)
      new_selectors[model_name] = old_sel
    end
    new_data[:selectors] = new_selectors
  end

  def self.provider_lists_match?(old_providers, new_providers)
    return false unless old_providers.length == new_providers.length
    old_providers.zip(new_providers).all? do |o, n|
      o["provider"] == n["provider"] &&
        o["base_url"] == n["base_url"] &&
        o["model"] == n["model"] &&
        o["api_key"] == n["api_key"]
    end
  end

  def self.resolve_provider(providers, provider_name, model_id, model_headers = nil)
    provider = providers[provider_name]
    raise "Unknown provider '#{provider_name}'" unless provider

    {
      "provider" => provider_name,
      "base_url" => provider["base_url"],
      "api_key"  => provider["api_key"],
      "model"    => model_id,
      "headers"  => provider["headers"]&.merge(model_headers || {}) || model_headers || {}
    }.freeze
  end

  def self.update_logger_level!(raw, logger)
    levels = { "debug" => Logger::DEBUG, "info" => Logger::INFO, "warn" => Logger::WARN, "error" => Logger::ERROR }
    logger.level = levels.fetch(raw.dig("logging", "level"), Logger::INFO)
  end
end
