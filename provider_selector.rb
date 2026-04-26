# frozen_string_literal: true

class ProviderSelector
  TTFT_THRESHOLD = 4.0
  TPS_WEIGHT = 0.005
  SAMPLE_WINDOW = 600
  MAX_SAMPLES = 100
  MIN_SAMPLES = 2
  HYSTERESIS = 0.1

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

      File.write(CONFIG_PATH, YAML.dump(raw))
    end
  rescue => e
    nil
  end

  def initialize(model_name, providers, model_config:)
    @model_name = model_name
    @providers = providers
    @active_index = find_initial_active_index(model_config)
    @request_count = 0
    @samples = {}
    @lock = Mutex.new
    @probing = false
  end

  def active_provider_name
    @lock.synchronize { @providers[@active_index]["provider"] }
  end

  def ordered_providers
    @lock.synchronize do
      active = @providers[@active_index]
      others = @providers.reject.with_index { |_, i| i == @active_index }
                         .sort_by { |p| -score_provider(p["provider"]) }
      [active, *others]
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
    @lock.synchronize { @probing = false }
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
    end
  end

  def evaluate_and_select(logger, auto_switch: true)
    scored = @lock.synchronize do
      @providers.each_with_index.map do |p, i|
        avg = average_metrics(p["provider"])
        next nil unless avg && avg[:sample_count] >= MIN_SAMPLES
        meets_ttft = avg[:avg_ttft] <= TTFT_THRESHOLD
        [i, avg, meets_ttft]
      end.compact
    end

    ttft_eligible = scored.select { |_, _, meets| meets }
    candidate_pool = ttft_eligible.empty? ? scored : ttft_eligible

    return if candidate_pool.empty?

    best_index, best_avg, = candidate_pool.max_by { |_, avg, _| score_from_avg(avg) }

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
          logger.info("[#{@model_name}] Switched to #{new_name} (avg_ttft=#{best_avg[:avg_ttft].round(3)}s, avg_tps=#{best_avg[:avg_tps].round(1)}, n=#{best_avg[:sample_count]}) from #{old_name} (avg_ttft=#{active_avg&.dig(:avg_ttft)&.round(3)}s, avg_tps=#{active_avg&.dig(:avg_tps)&.round(1)}, n=#{active_avg&.dig(:sample_count)})")
          Notifier.notify("LLM Proxy Switch", "#{@model_name}: #{old_name} \u2192 #{new_name}")
        end
        self.class.persist_active_provider(@model_name, best_index)
      else
        logger.info("[#{@model_name}] Suggest switch to #{new_name} (avg_ttft=#{best_avg[:avg_ttft].round(3)}s, avg_tps=#{best_avg[:avg_tps].round(1)}, n=#{best_avg[:sample_count]}) from #{old_name} (avg_ttft=#{active_avg&.dig(:avg_ttft)&.round(3)}s, avg_tps=#{active_avg&.dig(:avg_tps)&.round(1)}, n=#{active_avg&.dig(:sample_count)})")
      end
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

  private

  def find_initial_active_index(model_config)
    return 0 unless model_config && model_config["providers"]
    idx = model_config["providers"].index { |p| p["primary"] == true }
    idx || 0
  end

  def prune_stale_samples!(samples, now)
    samples.delete_if { |s| now - s[:timestamp] > SAMPLE_WINDOW }
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
    ttft_score = avg[:avg_ttft] > 0 ? (1.0 / avg[:avg_ttft]) : 0
    tps_score = avg[:avg_tps] || 0
    (ttft_score * 0.5) + (tps_score * TPS_WEIGHT)
  end
end
