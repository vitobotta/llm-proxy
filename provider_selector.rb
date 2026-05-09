# frozen_string_literal: true

class ProviderSelector
  TTFT_SATURATION = 4.0
  TPS_REFERENCE   = 100.0
  TTFT_WEIGHT = 0.5
  TPS_WEIGHT  = 0.5
  DEFAULT_SAMPLE_WINDOW = 300
  MAX_SAMPLES = 100
  MIN_SAMPLES = 2
  HYSTERESIS = 0.1

  CIRCUIT_FAILURE_THRESHOLD = 3
  CIRCUIT_COOLDOWN = 60

  CircuitState = Struct.new(:failures, :opened_at, keyword_init: true)

  attr_reader :providers

  CONFIG_PATH = File.join(__dir__, "config.yaml")
  CONFIG_LOCK = Mutex.new

  def self.persist_active_provider(model_name, provider_index)
    CONFIG_LOCK.synchronize do
      raw = YAML.unsafe_load_file(CONFIG_PATH)
      model_entry = raw["models"].find { |m| m["name"] == model_name }
      return unless model_entry && model_entry["providers"]

      model_entry["providers"].each { |p| p.delete("primary") }
      model_entry["providers"][provider_index]["primary"] = true

      ConfigWatcher.expecting_write! if defined?(ConfigWatcher)
      File.write(CONFIG_PATH, YAML.dump(raw))
    end
  rescue => e
    nil
  end

  def initialize(model_name, providers, model_config:, sample_window: DEFAULT_SAMPLE_WINDOW,
                 circuit_failure_threshold: CIRCUIT_FAILURE_THRESHOLD, circuit_cooldown: CIRCUIT_COOLDOWN)
    @model_name = model_name
    @providers = providers
    @active_index = find_initial_active_index(model_config)
    @request_count = 0
    @samples = {}
    @lock = Mutex.new
    @probing = false
    @cached_ordered = nil
    @sample_window = sample_window
    @circuit_failure_threshold = circuit_failure_threshold
    @circuit_cooldown = circuit_cooldown
    @circuits = providers.each_with_object({}) { |p, h| h[p["provider"]] = CircuitState.new(failures: 0, opened_at: nil) }
    @error_counts = providers.each_with_object({}) { |p, h| h[p["provider"]] = 0 }
    @total_requests = providers.each_with_object({}) { |p, h| h[p["provider"]] = 0 }
  end

  def active_provider_name
    @lock.synchronize { @providers[@active_index]["provider"] }
  end

  def ordered_providers
    @lock.synchronize do
      @cached_ordered ||= begin
        active = @providers[@active_index]
        others = @providers.reject.with_index { |_, i| i == @active_index }
                          .reject { |p| circuit_open?(p["provider"]) }
                          .sort_by { |p| -score_provider(p["provider"]) }
        [active, *others]
      end
    end
  end

  def record_and_maybe_probe(request_count)
    should_probe = false
    @lock.synchronize do
      @request_count += 1
      should_probe = @request_count >= request_count && !@probing && @providers.length > 1
      if should_probe
        @probing = true
        @request_count = 0
      end
    end
    should_probe
  end

  def probe_finished
    @lock.synchronize do
      @probing = false
      @cached_ordered = nil
    end
  end

  def update_metrics(provider_name, ttft, tps)
    return unless ttft
    @lock.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      samples = (@samples[provider_name] ||= [])
      prune_stale_samples!(samples, now)
      sample = { ttft: ttft.to_f, timestamp: now }
      sample[:tps] = tps.to_f if tps
      samples << sample
      samples.shift if samples.length > MAX_SAMPLES
      @cached_ordered = nil
    end
  end

  def evaluate_and_select(logger, auto_switch: true)
    scored = @lock.synchronize do
      @providers.each_with_index.map do |p, i|
        avg = average_metrics(p["provider"])
        next nil unless avg && avg[:sample_count] >= MIN_SAMPLES
        [i, avg]
      end.compact
    end

    return if scored.empty?

    best_index, best_avg = scored.max_by { |_, avg| score_from_avg(avg) }

    active_avg = @lock.synchronize { average_metrics(@providers[@active_index]["provider"]) }

    if best_index != @active_index
      if active_avg && active_avg[:sample_count] >= MIN_SAMPLES
        active_score = score_from_avg(active_avg)
        best_score = score_from_avg(best_avg)
        return unless best_score > active_score * (1.0 + HYSTERESIS)
      end

      old_name = @lock.synchronize { @providers[@active_index]["provider"] }
      new_name = @providers[best_index]["provider"]

      if auto_switch
        @lock.synchronize do
          @active_index = best_index
          @cached_ordered = nil
          logger.info("[#{@model_name}] Switched to #{new_name} (avg_ttft=#{best_avg[:avg_ttft].round(3)}s, avg_tps=#{best_avg[:avg_tps].round(1)}, n=#{best_avg[:sample_count]}) from #{old_name} (avg_ttft=#{active_avg&.dig(:avg_ttft)&.round(3)}s, avg_tps=#{active_avg&.dig(:avg_tps)&.round(1)}, n=#{active_avg&.dig(:sample_count)})")
          if defined?(Notifier) && Notifier.respond_to?(:notify)
            Notifier.notify("LLM Proxy Switch", "#{@model_name}: #{old_name} \u2192 #{new_name}")
          end
        end
      else
        logger.info("[#{@model_name}] Suggest switch to #{new_name} (avg_ttft=#{best_avg[:avg_ttft].round(3)}s, avg_tps=#{best_avg[:avg_tps].round(1)}, n=#{best_avg[:sample_count]}) from #{old_name} (avg_ttft=#{active_avg&.dig(:avg_ttft)&.round(3)}s, avg_tps=#{active_avg&.dig(:avg_tps)&.round(1)}, n=#{active_avg&.dig(:sample_count)})")
      end
    end
  end

  def persist_active_index
    idx = @lock.synchronize { @active_index }
    self.class.persist_active_provider(@model_name, idx)
  end

  def record_failure(provider_name)
    @lock.synchronize do
      @error_counts[provider_name] = (@error_counts[provider_name] || 0) + 1
      circuit = @circuits[provider_name]
      return unless circuit
      circuit.failures += 1
      if circuit.failures >= @circuit_failure_threshold
        circuit.opened_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @cached_ordered = nil
      end
    end
  end

  def record_success(provider_name)
    @lock.synchronize do
      @total_requests[provider_name] = (@total_requests[provider_name] || 0) + 1
      circuit = @circuits[provider_name]
      return unless circuit
      circuit.failures = 0
      circuit.opened_at = nil
    end
  end

  def other_providers
    @lock.synchronize { @providers.reject.with_index { |_, i| i == @active_index } }
  end

  def active_metrics
    @lock.synchronize do
      avg = average_metrics(@providers[@active_index]["provider"])
      return nil unless avg
      { ttft: avg[:avg_ttft], tps: avg[:avg_tps], sample_count: avg[:sample_count] }
    end
  end

  def circuit_states
    @lock.synchronize do
      @circuits.transform_values do |c|
        { failures: c.failures, open: !c.opened_at.nil? }
      end
    end
  end

  def provider_stats
    @lock.synchronize do
      @providers.each_with_object({}) do |p, h|
        name = p["provider"]
        h[name] = {
          errors: @error_counts[name] || 0,
          successes: @total_requests[name] || 0,
          circuit_open: !@circuits[name]&.opened_at.nil?
        }
      end
    end
  end

  private

  def circuit_open?(provider_name)
    circuit = @circuits[provider_name]
    return false unless circuit&.opened_at
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if now - circuit.opened_at > @circuit_cooldown
      circuit.opened_at = nil
      circuit.failures = 0
      false
    else
      true
    end
  end

  def find_initial_active_index(model_config)
    return 0 unless model_config && model_config["providers"]
    idx = model_config["providers"].index { |p| p["primary"] == true }
    idx || 0
  end

  def prune_stale_samples!(samples, now)
    samples.delete_if { |s| now - s[:timestamp] > @sample_window }
  end

  def average_metrics(provider_name)
    samples = @samples[provider_name]
    return nil unless samples && !samples.empty?
    n = samples.length
    avg_ttft = samples.sum { |s| s[:ttft] } / n
    tps_samples = samples.select { |s| s[:tps] }
    avg_tps = tps_samples.empty? ? 0.0 : tps_samples.sum { |s| s[:tps] } / tps_samples.length
    { avg_ttft: avg_ttft, avg_tps: avg_tps, sample_count: n }
  end

  def score_provider(provider_name)
    avg = average_metrics(provider_name)
    score_from_avg(avg)
  end

  def score_from_avg(avg)
    return -Float::INFINITY unless avg
    ttft = avg[:avg_ttft]
    tps  = avg[:avg_tps] || 0

    ttft_score = ttft > 0 ? [TTFT_SATURATION / ttft, 1.0].min : 0

    tps_score = [tps / TPS_REFERENCE, 3.0].min

    ttft_score * TTFT_WEIGHT + tps_score * TPS_WEIGHT
  end
end
