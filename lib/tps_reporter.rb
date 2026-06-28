# frozen_string_literal: true

module TpsReporter
  DEFAULT_INTERVAL = 5
  DEFAULT_ACTIVITY_WINDOW = 10
  DEFAULT_EVAL_WINDOW = 60

  @running = false
  @thread = nil
  @logger = nil
  @stop_signal = nil

  def self.start!(logger:, interval: DEFAULT_INTERVAL, activity_window: DEFAULT_ACTIVITY_WINDOW, eval_window: DEFAULT_EVAL_WINDOW)
    return if @running || interval.nil? || interval <= 0

    @logger = logger
    @stop_signal = Queue.new
    @running = true

    @thread = Thread.new do
      Thread.current.report_on_exception = false
      loop do
        msg = @stop_signal.pop(timeout: interval)
        break if msg == :stop
        report(activity_window: activity_window, eval_window: eval_window)
      rescue => e
        @logger&.error("[tps] Reporter error: #{e.class}: #{e.message}")
      end
    end

    @logger&.info("[tps] Periodic TPS reporter started (every #{interval}s, eval window #{eval_window}s, activity gate #{activity_window}s)")
  end

  def self.stop!
    return unless @running

    @stop_signal << :stop if @stop_signal
    @thread&.join(2)
  ensure
    @running = false
    @thread = nil
    @stop_signal = nil
  end

  def self.running?
    @running
  end

  def self.report(activity_window:, eval_window:)
    return unless defined?(ConfigStore)

    selectors = ConfigStore.selectors
    models = ConfigStore.models

    selectors.each do |model_name, selector|
      report_model(model_name, selector, models[model_name], activity_window, eval_window)
    end
  end

  def self.report_model(model_name, selector, model_entry, activity_window, eval_window)
    return unless model_entry

    selector.providers.each do |provider_config|
      p_name = provider_config["provider"]
      next unless selector.tps_active?(p_name, window: activity_window)

      m = selector.rolling_tps(p_name, window: eval_window)
      next unless m && m[:n].positive?

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
