# frozen_string_literal: true

require "logger"
require "yaml"
require "date"
require_relative "config_validator"
require_relative "tps_reporter"

module ConfigStore
  DEFAULT_CONFIG_PATH = File.join(File.dirname(__dir__), "config", "config.yaml")

  # Permitted classes for YAML parsing. Config schema is strings, integers,
  # floats, booleans, hashes, arrays — nothing exotic. Keeping this strict
  # means a malicious config (e.g. from a compromised host volume) can't
  # trigger Ruby object deserialization.
  YAML_PERMITTED_CLASSES = [Symbol, Date, Time].freeze

  def self.load_yaml_file(path)
    YAML.safe_load_file(path, permitted_classes: YAML_PERMITTED_CLASSES, aliases: true)
  end

  # Writer-side lock: only serializes concurrent load!/reload! callers.
  # READS DO NOT TAKE THIS LOCK.
  #
  # @data is replaced with a fully-built snapshot via a single assignment.
  # Under MRI's GVL, ivar assignment is atomic — readers always see either
  # the old snapshot or the new one, never a torn read. Writers must compute
  # the new snapshot (including merge_selectors!) in full before swapping.
  @lock = Mutex.new
  @data = {}
  @config_path = ENV.fetch("CONFIG_FILE", DEFAULT_CONFIG_PATH)
  @app_ref = nil
  @last_added_provider_keys = [].freeze

  def self.load!(raw_config, logger:)
    new_data = build_data(raw_config, logger)
    @lock.synchronize do
      old_data = @data
      old_provider_keys = (old_data[:providers] || {}).keys
      # Mutate new_data into final form (carry over preserved selectors)
      # BEFORE swapping so readers never observe an in-progress merge.
      merge_selectors!(old_data, new_data)
      added = (new_data[:providers] || {}).keys - old_provider_keys
      @last_added_provider_keys = added.freeze
      @data = new_data
    end
    self
  end

  def self.last_added_provider_keys
    (@last_added_provider_keys || []).dup
  end

  def self.register_app!(app)
    @app_ref = app
    update_settings!(app)
  end

  def self.config_path = @config_path

  def self.reload!(logger:)
    raw = load_yaml_file(config_path)
    errors, warnings = ConfigValidator.validate(raw, logger)
    unless errors.empty?
      errors.each { |e| logger.error("Config reload error: #{e}") }
      logger.warn("Config reload skipped — keeping last good configuration")
      return false
    end
    warnings.each { |w| logger.warn("Config warning: #{w}") }

    load!(raw, logger: logger)
    HTTPSupport.clear_uri_cache! if defined?(HTTPSupport)
    new_provider_keys = last_added_provider_keys
    unless new_provider_keys.empty?
      HTTPSupport.prewarm_connections!(raw, providers, logger, timeouts: timeouts)
    end
    update_logger_level!(raw, logger)
    update_settings!(@app_ref) if @app_ref
    logger.info("Configuration reloaded from config.yaml")
    true
  rescue => e
    logger.error("Config reload failed: #{e.class}: #{e.message}")
    false
  end

  # All accessors below are LOCK-FREE — they perform a single ivar read
  # plus a hash lookup. Safe under MRI's GVL; see the @data comment above.
  def self.config = @data[:config]
  def self.providers = @data[:providers]
  def self.models = @data[:models]
  def self.selectors = @data[:selectors]
  def self.timeouts = @data[:timeouts]
  def self.auth_token = @data[:auth_token]
  def self.metrics_token = @data[:metrics_token]
  def self.max_body_size = @data[:max_body_size]
  def self.tracking_enabled = @data[:tracking_enabled]
  def self.probing_enabled = @data[:probing_enabled]
  def self.auto_switch = @data[:auto_switch]
  def self.probe_interval = @data[:probe_interval]
  def self.probe_max_per_minute = @data[:probe_max_per_minute]
  def self.sample_window = @data[:sample_window]
  def self.max_attempts = @data[:max_attempts]
  def self.backoff_base = @data[:backoff_base]
  def self.max_rounds = @data[:max_rounds]
  def self.quota_pause_default_seconds = @data[:quota_pause_default_seconds]
  def self.tps_log_interval = @data[:tps_log_interval]
  def self.tps_log_activity_window = @data[:tps_log_activity_window]
  def self.tps_log_eval_window = @data[:tps_log_eval_window]
  def self.tps_log_min_tokens = @data[:tps_log_min_tokens]

  def self.model(name) = @data[:models][name]
  def self.selector(name) = @data[:selectors][name]
  def self.update_settings!(app)
    snapshot = @data
    app.set :max_attempts, snapshot[:max_attempts]
    app.set :backoff_base, snapshot[:backoff_base]
    app.set :max_rounds, snapshot[:max_rounds]
  end

  # `private` is a no-op on `def self.foo` definitions in modules; use
  # `private_class_method` (at the bottom) instead. These are conceptually
  # private — internal helpers, not part of the public ConfigStore API.

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
      provider_list = m["providers"].map { |p| resolve_provider(providers, p["provider"], p["model"], p["headers"], primary: p["primary"]) }
      m_probing = m.key?("probing_enabled") ? (m["probing_enabled"] != false) : probing_enabled
      m_auto_switch = m_probing && (m.key?("auto_switch") ? m["auto_switch"] == true : auto_switch)
      m_probe_interval = m["probe_interval"] || probe_interval
      model_entry = {
        "name" => m["name"],
        "providers" => provider_list.freeze,
        "context_length" => m["context_length"],
        "probing_enabled" => m_probing,
        "auto_switch" => m_auto_switch,
        "probe_interval" => m_probe_interval
      }.compact.freeze
      models[m["name"]] = model_entry
      selectors[m["name"]] = ProviderSelector.new(m["name"], provider_list, model_config: m, sample_window: sample_window)
    end

    {
      config: raw,
      providers: providers,
      models: models.freeze,
      selectors: selectors,
      timeouts: {
        open: raw.dig("timeouts", "open") || 30,
        read: raw.dig("timeouts", "read") || 300,
        write: raw.dig("timeouts", "write") || 60
      }.freeze,
      auth_token: raw.dig("auth", "token"),
      metrics_token: raw.dig("auth", "metrics_token"),
      max_body_size: raw.dig("limits", "max_request_body") || 10 * 1024 * 1024,
      tracking_enabled: tracking_enabled,
      probing_enabled: probing_enabled,
      auto_switch: auto_switch,
      probe_interval: probe_interval,
      probe_max_per_minute: raw.dig("performance", "probe_max_per_minute"),
      sample_window: sample_window,
      max_attempts: raw.dig("retries", "max_attempts") || 3,
      backoff_base: raw.dig("retries", "backoff_base") || 2,
      max_rounds: raw.dig("retries", "max_rounds") || 3,
      tps_log_interval: raw.dig("metrics", "tps_log", "interval") || TpsReporter::DEFAULT_INTERVAL,
      tps_log_activity_window: raw.dig("metrics", "tps_log", "activity_window") || TpsReporter::DEFAULT_ACTIVITY_WINDOW,
      tps_log_eval_window: raw.dig("metrics", "tps_log", "eval_window") || TpsReporter::DEFAULT_EVAL_WINDOW,
      tps_log_min_tokens: raw.dig("metrics", "tps_log", "min_tokens") || TpsReporter::DEFAULT_MIN_TOKENS,
    }
  end

  def self.merge_selectors!(old_data, new_data)
    old_selectors = old_data[:selectors] || {}
    new_selectors = new_data[:selectors]
    new_models = new_data[:models]
    new_selectors.each do |model_name, new_sel|
      old_sel = old_selectors[model_name]
      next unless old_sel
      next unless provider_lists_match?(old_sel.providers, new_sel.providers)
      old_sel.realign_active_index!(new_models[model_name])
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

  def self.resolve_provider(providers, provider_name, model_id, model_headers = nil, primary: nil)
    provider = providers[provider_name]
    raise "Unknown provider '#{provider_name}'" unless provider

    {
      "provider" => provider_name,
      "base_url" => provider["base_url"],
      "api_key" => provider["api_key"],
      "model" => model_id,
      "headers" => provider["headers"]&.merge(model_headers || {}) || model_headers || {},
      "primary" => primary
    }.compact.freeze
  end

  def self.update_logger_level!(raw, logger)
    levels = {"debug" => Logger::DEBUG, "info" => Logger::INFO, "warn" => Logger::WARN, "error" => Logger::ERROR}
    logger.level = levels.fetch(raw.dig("logging", "level"), Logger::INFO)
  end

  private_class_method :build_data, :merge_selectors!, :provider_lists_match?, :resolve_provider, :update_logger_level!
end
