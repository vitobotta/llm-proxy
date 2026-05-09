# frozen_string_literal: true

module ConfigWatcher
  CONFIG_PATH = File.join(File.dirname(__dir__), "config.yaml")
  DEFAULT_POLL_INTERVAL = 2

  @lock = Mutex.new
  @last_mtime = nil
  @expected_mtime = nil
  @running = false
  @logger = nil

  def self.start!(logger:, poll_interval: DEFAULT_POLL_INTERVAL)
    @logger = logger
    @last_mtime = File.mtime(CONFIG_PATH)
    @running = true

    Thread.new do
      loop do
        sleep(poll_interval)
        break unless @running
        check_and_reload
      rescue => e
        @logger&.error("ConfigWatcher error: #{e.message}")
      end
    end

    begin
      Signal.trap("USR1") do
        Thread.new { trigger_reload("SIGUSR1") }
      end
    rescue ArgumentError
      @logger.debug("SIGUSR1 not available on this platform")
    end

    @logger.info("ConfigWatcher started (polling every #{poll_interval}s, SIGUSR1 to force reload)")
  end

  def self.stop!
    @running = false
  end

  def self.expecting_write!
    @lock.synchronize do
      @expected_mtime = File.mtime(CONFIG_PATH)
    end
  end

  private

  def self.check_and_reload
    current_mtime = File.mtime(CONFIG_PATH)
    return if current_mtime == @last_mtime

    @lock.synchronize do
      if @expected_mtime && current_mtime == @expected_mtime
        @last_mtime = current_mtime
        @expected_mtime = nil
        return
      end
    end

    @last_mtime = current_mtime
    trigger_reload("file change")
  end

  def self.trigger_reload(source)
    @logger.info("ConfigWatcher: reload triggered (#{source})")
    ConfigStore.reload!(logger: @logger)
  rescue => e
    @logger&.error("ConfigWatcher reload error: #{e.message}")
  end
end
