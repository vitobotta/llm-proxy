# frozen_string_literal: true

module TpsReporter
  DEFAULT_INTERVAL = 5
  DEFAULT_ACTIVITY_WINDOW = 10
  DEFAULT_EVAL_WINDOW = 60
  DEFAULT_MIN_TOKENS = 500

  @running = false
  @thread = nil
  @logger = nil
  @stop_signal = nil
  @stop_lock = Mutex.new

  def self.start!(logger:, interval: DEFAULT_INTERVAL, activity_window: DEFAULT_ACTIVITY_WINDOW, eval_window: DEFAULT_EVAL_WINDOW, min_tokens: DEFAULT_MIN_TOKENS)
    return if @running || interval.nil? || interval <= 0

    @logger = logger
    @stop_signal = Queue.new
    @running = true

    @thread = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        msg = @stop_signal.pop(timeout: interval)
        break if msg == :stop
        report(activity_window: activity_window, eval_window: eval_window, min_tokens: min_tokens)
      rescue => e
        @logger&.error("[tps] Reporter error: #{e.class}: #{e.message}")
      end
    end

    @logger&.info("[tps] Periodic TPS reporter started (every #{interval}s, eval window #{eval_window}s, activity gate #{activity_window}s, min tokens #{min_tokens})")
  end

  def self.stop!
    @stop_lock.synchronize do
      return unless @running
      @running = false
      @stop_signal << :stop if @stop_signal
      @thread&.join(2)
      @thread = nil
      @stop_signal = nil
    end
  end

  def self.running?
    @running
  end

  def self.report(activity_window:, eval_window:, min_tokens: DEFAULT_MIN_TOKENS)
    return unless defined?(ConfigStore)

    snap = ConfigStore.snapshot
    selectors = snap[:selectors]
    models = snap[:models]

    selectors.each do |model_name, selector|
      report_model(model_name, selector, models[model_name], activity_window, eval_window, min_tokens)
    end
  end

  def self.report_model(model_name, selector, model_entry, activity_window, eval_window, min_tokens)
    return unless model_entry

    selector.providers.each do |provider_config|
      p_name = provider_config["provider"]
      next unless selector.tps_active?(p_name, window: activity_window)

      m = selector.rolling_tps(p_name, window: eval_window)
      next unless m && m[:n].positive?
      # Suppress log lines until enough tokens have accumulated that the
      # TPS values reflect real generation throughput, not TTFT noise from
      # a handful of short chatty requests.
      next if (m[:total_tokens] || 0) < min_tokens

      log_line(model_name, p_name, m)
    end
  end
  private_class_method :report_model

  def self.log_line(model_name, provider_name, m)
    headline = m[:aggregate] || m[:median]
    return unless headline

    parts = ["tps=#{headline}#{m[:aggregate] ? '' : '*'}"]
    parts << "p50=#{m[:median]}" if m[:median]
    parts << "p90=#{m[:p90]}" if m[:p90]
    parts << "n=#{m[:n]}"
    parts << "tokens=#{m[:total_tokens]}" if m[:total_tokens]&.positive?
    @logger&.info("[tps] #{model_name}/#{provider_name} #{parts.join(' ')}")
  end
  private_class_method :log_line
end
