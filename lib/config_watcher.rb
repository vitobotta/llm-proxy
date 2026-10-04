# frozen_string_literal: true

require "digest"

module ConfigWatcher
  DEFAULT_POLL_INTERVAL = 2

  @lock = Mutex.new
  @last_hash = nil
  @expected_hash = nil
  @last_mtime = nil
  @running = false
  @usr1_requested = false
  @logger = nil
  @thread = nil

  def self.start!(logger:, poll_interval: DEFAULT_POLL_INTERVAL)
    @logger = logger
    @last_hash = file_hash
    @last_mtime = begin; File.mtime(ConfigStore.config_path); rescue Errno::ENOENT; nil; end
    @usr1_requested = false
    @running = true

    @thread = Thread.new do
      loop do
        sleep_interruptible(poll_interval)
        break unless @running
        if @usr1_requested
          @usr1_requested = false
          trigger_reload("SIGUSR1")
          @last_hash = file_hash
          @last_mtime = begin; File.mtime(ConfigStore.config_path); rescue Errno::ENOENT; nil; end
          next
        end
        check_and_reload
      rescue => e
        @logger&.error("ConfigWatcher error: #{e.message}")
      end
    end
    begin
      # Trap context is extremely restricted: Mutex#synchronize raises
      # ThreadError ("can't be called from trap context"), which used to
      # kill the handler and silently disable SIGUSR1 reloads. The handler
      # now only flips a plain flag; the poller thread acts on it.
      Signal.trap("USR1") { @usr1_requested = true }
    rescue ArgumentError
      @logger.debug("SIGUSR1 not available on this platform")
    end

    @logger.info("ConfigWatcher started (polling every #{poll_interval}s, SIGUSR1 to force reload)")
  end

  # Sleeps up to `seconds`, waking early to notice a pending SIGUSR1 flag.
  def self.sleep_interruptible(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while (remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)) > 0
      break if @usr1_requested
      sleep([remaining, 0.1].min)
    end
  end

  def self.stop!
    @running = false
    @thread&.join(5)
    @thread = nil
  end

  def self.expecting_write!(content = nil)
    @lock.synchronize do
      @expected_hash = if content
        Digest::SHA256.hexdigest(content)
      else
        file_hash
      end
    end
  end

  # `private` on `def self.x` in a module is a no-op — see private_class_method below.

  def self.file_hash
    Digest::SHA256.file(ConfigStore.config_path).hexdigest
  rescue Errno::ENOENT
    @last_hash
  end

  def self.check_and_reload
    path = ConfigStore.config_path
    begin
      current_mtime = File.mtime(path)
    rescue Errno::ENOENT
      return
    end
    return if @last_mtime && current_mtime == @last_mtime
    @last_mtime = current_mtime

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

  private_class_method :file_hash, :check_and_reload, :trigger_reload, :sleep_interruptible
end
