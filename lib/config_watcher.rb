# frozen_string_literal: true

require "digest"

module ConfigWatcher
  DEFAULT_POLL_INTERVAL = 2

  @lock = Mutex.new
  @last_hash = nil
  @expected_hash = nil
  @running = false
  @logger = nil

  def self.start!(logger:, poll_interval: DEFAULT_POLL_INTERVAL)
    @logger = logger
    @last_hash = file_hash
    @running = true
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
      @expected_hash = file_hash
    end
  end

  private

  def self.file_hash
    Digest::SHA256.file(ConfigStore.config_path).hexdigest
  rescue Errno::ENOENT
    @last_hash
  end

  def self.check_and_reload
    current_hash = file_hash
    return if current_hash == @last_hash

    @lock.synchronize do
      if @expected_hash && current_hash == @expected_hash
        @last_hash = current_hash
        @expected_hash = nil
        return
      end
    end

    @last_hash = current_hash
    trigger_reload("file change")
  end

  def self.trigger_reload(source)
    @logger.info("ConfigWatcher: reload triggered (#{source})")
    ConfigStore.reload!(logger: @logger)
  rescue => e
    @logger&.error("ConfigWatcher reload error: #{e.message}")
  end
end
