# frozen_string_literal: true

require "json"
require "fileutils"

module StatePersistence
  STATE_VERSION = 1
  DEFAULT_STATE_DIR = File.join(File.dirname(__dir__), "data")
  DEFAULT_STATE_FILE = "provider_state.json"

  WRITE_LOCK = Mutex.new

  def self.state_dir
    dir = ENV.fetch("STATE_DIR", DEFAULT_STATE_DIR)
    FileUtils.mkdir_p(dir)
    dir
  end

  def self.state_file
    File.join(state_dir, DEFAULT_STATE_FILE)
  end

  def self.save(logger: nil)
    WRITE_LOCK.synchronize do
      state = build_state
      tmp = "#{state_file}.tmp.#{Process.pid}"
      File.write(tmp, JSON.generate(state))
      File.rename(tmp, state_file)
      logger&.debug("[StatePersistence] Saved state to #{state_file}")
    end
  rescue => e
    logger&.error("[StatePersistence] Failed to save state: #{e.class}: #{e.message}")
    begin
      File.delete(tmp) if tmp && File.exist?(tmp)
    rescue StandardError
      nil
    end
  end

  def self.restore!(logger: nil)
    state = load
    return unless state

    selectors = ConfigStore.selectors
    models = state["models"] || {}
    restored = 0

    models.each do |model_name, model_state|
      selector = selectors[model_name]
      unless selector
        logger&.debug("[StatePersistence] Skipping unknown model: #{model_name}")
        next
      end
      begin
        selector.restore_state!(model_state)
        restored += 1
      rescue => e
        logger&.warn("[StatePersistence] Failed to restore state for #{model_name}: #{e.class}: #{e.message}")
      end
    end

    ConfigStore.models.each do |model_name, model_config|
      selector = selectors[model_name]
      selector&.realign_active_index!(model_config)
    end

    logger&.info("[StatePersistence] Restored state for #{restored} model(s) from #{state_file}")
  end

  def self.build_state
    models_state = {}
    ConfigStore.selectors.each do |model_name, selector|
      models_state[model_name] = selector.to_state
    end
    {
      version: STATE_VERSION,
      saved_at: Time.now.to_f,
      models: models_state
    }
  end

  def self.load
    return nil unless File.exist?(state_file)

    raw = File.read(state_file)
    state = JSON.parse(raw)
    unless state.is_a?(Hash) && state["version"] == STATE_VERSION
      return nil
    end
    state
  rescue => e
    nil
  end
end
