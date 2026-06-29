# frozen_string_literal: true

class ProviderSelector
  TTFT_SATURATION = 4.0
  TPS_REFERENCE = 100.0
  TTFT_WEIGHT = 0.5
  TPS_WEIGHT = 0.5
  DEFAULT_SAMPLE_WINDOW = 180
  MAX_SAMPLES = 100
  MIN_SAMPLES = 2
  # Samples below this token count are excluded from median/p90 computation.
  # Short requests (5-15 tokens) produce TPS values dominated by TTFT/prefill
  # time, not decode throughput — they're noise that inflates the percentiles.
  # The token-weighted aggregate already downweights them; this fixes the
  # percentile computation which treats every sample equally.
  PERCENTILE_MIN_TOKENS = 50
  HYSTERESIS = 0.1

  CIRCUIT_FAILURE_THRESHOLD = 3
  CIRCUIT_COOLDOWN = 60

  CircuitState = Struct.new(:failures, :opened_at, keyword_init: true)
  QuotaPause = Struct.new(:paused_until, :reason, keyword_init: true)

  attr_reader :providers

  CONFIG_LOCK = Mutex.new

  def self.config_path
    defined?(ConfigStore) ? ConfigStore.config_path : File.join(__dir__, "config", "config.yaml")
  end

  def self.persist_active_provider(model_name, provider_index, logger: nil)
    CONFIG_LOCK.synchronize do
      raw = defined?(ConfigStore) ? ConfigStore.load_yaml_file(config_path) : YAML.safe_load_file(config_path, permitted_classes: [Symbol, Date, Time], aliases: true)
      model_entry = raw["models"].find { |m| m["name"] == model_name }
      return unless model_entry && model_entry["providers"]

      model_entry["providers"].each { |p| p.delete("primary") }
      model_entry["providers"][provider_index]["primary"] = true

      ConfigWatcher.expecting_write! if defined?(ConfigWatcher)
      tmp = "#{config_path}.tmp.#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC) do |f|
        f.write(YAML.dump(raw))
        f.fsync
      end
      File.rename(tmp, config_path)
    end
  rescue => e
    msg = "[#{model_name}] Failed to persist active provider: #{e.class}: #{e.message}"
    logger&.warn(msg)
    warn(msg) if logger.nil?
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
    @quota_pauses = providers.each_with_object({}) { |p, h| h[p["provider"]] = QuotaPause.new(paused_until: nil, reason: nil) }
    @error_counts = providers.each_with_object({}) { |p, h| h[p["provider"]] = 0 }
    @total_requests = providers.each_with_object({}) { |p, h| h[p["provider"]] = 0 }
    @last_success_at = providers.each_with_object({}) { |p, h| h[p["provider"]] = nil }
    @model_config = model_config
  end

  def active_provider_name
    @lock.synchronize { @providers[@active_index]["provider"] }
  end

  def ordered_providers(auto_switch: true)
    @lock.synchronize do
      @cached_ordered ||= begin
        active = @providers[@active_index]
        if check_circuit_open(active["provider"]) || check_quota_paused(active["provider"])
          available = @providers.reject { |p| check_circuit_open(p["provider"]) || check_quota_paused(p["provider"]) }
          available = available.sort_by { |p| -score_provider(p["provider"]) } if auto_switch && available.length > 1
          if available.empty?
            # Last resort: every provider is circuit-broken or quota-paused, but
            # there is no alternative. Return all providers (active first) so the
            # request loop keeps retrying instead of aborting with "No providers
            # available". Circuit/quota state is still tracked; this only avoids a
            # hard stop when there is nothing to fall back to.
            @providers.rotate(@active_index)
          else
            available
          end
        else
          others = @providers.reject.with_index { |_, i| i == @active_index }
            .reject { |p| check_circuit_open(p["provider"]) }
            .reject { |p| check_quota_paused(p["provider"]) }
          others = others.sort_by { |p| -score_provider(p["provider"]) } if auto_switch && others.length > 1
          [active, *others]
        end
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

  def update_metrics(provider_name, ttft, tps, tokens: nil)
    return unless ttft
    @lock.synchronize do
      now = Time.now.to_f
      samples = (@samples[provider_name] ||= [])
      prune_stale_samples!(samples, now)
      sample = {ttft: ttft.to_f, timestamp: now}
      sample[:tps] = tps.to_f if tps
      sample[:tokens] = tokens.to_i if tokens && tokens.to_i > 0
      samples << sample
      samples.shift if samples.length > MAX_SAMPLES
      @cached_ordered = nil
    end
  end

  def evaluate_and_select(logger, auto_switch: true)
    best_index = nil
    best_avg = nil
    active_avg = nil
    old_name = nil

    @lock.synchronize do
      scored = @providers.each_with_index.map do |p, i|
        next nil if check_quota_paused(p["provider"])
        avg = average_metrics(p["provider"])
        next nil unless avg && avg[:sample_count] >= MIN_SAMPLES
        [i, avg]
      end.compact

      return if scored.empty?

      best_index, best_avg = scored.max_by { |_, avg| score_from_avg(avg) }
      active_avg = average_metrics(@providers[@active_index]["provider"])

      if best_index != @active_index
        if active_avg && active_avg[:sample_count] >= MIN_SAMPLES
          active_score = score_from_avg(active_avg)
          best_score = score_from_avg(best_avg)
          return unless best_score > active_score * (1.0 + HYSTERESIS)
        end

        old_name = @providers[@active_index]["provider"]
        new_name = @providers[best_index]["provider"]

        if auto_switch
          @active_index = best_index
          @cached_ordered = nil
          logger.info("[#{@model_name}] Switched to #{new_name} (avg_ttft=#{best_avg[:avg_ttft].round(3)}s, avg_tps=#{best_avg[:avg_tps].round(1)}, n=#{best_avg[:sample_count]}) from #{old_name} (avg_ttft=#{active_avg&.dig(:avg_ttft)&.round(3)}s, avg_tps=#{active_avg&.dig(:avg_tps)&.round(1)}, n=#{active_avg&.dig(:sample_count)})")
          StatePersistence.save(logger: logger) if defined?(StatePersistence)
        else
          logger.info("[#{@model_name}] Suggest switch to #{new_name} (avg_ttft=#{best_avg[:avg_ttft].round(3)}s, avg_tps=#{best_avg[:avg_tps].round(1)}, n=#{best_avg[:sample_count]}) from #{old_name} (avg_ttft=#{active_avg&.dig(:avg_ttft)&.round(3)}s, avg_tps=#{active_avg&.dig(:avg_tps)&.round(1)}, n=#{active_avg&.dig(:sample_count)})")
        end
      end
    end
  end

  def persist_active_index(logger: nil)
    auto_switch, idx = @lock.synchronize do
      [@model_config&.dig("auto_switch") == true, @active_index]
    end
    return unless auto_switch

    self.class.persist_active_provider(@model_name, idx, logger: logger)
  end

  def record_failure(provider_name)
    @lock.synchronize do
      @error_counts[provider_name] = (@error_counts[provider_name] || 0) + 1
      circuit = @circuits[provider_name]
      return unless circuit
      circuit.failures += 1
      if circuit.failures >= @circuit_failure_threshold
        circuit.opened_at = Time.now.to_f
        @cached_ordered = nil
      end
    end
  end

  def quota_pause!(provider_name, paused_until, reason: nil)
    @lock.synchronize do
      qp = @quota_pauses[provider_name]
      return unless qp
      qp.paused_until = [qp.paused_until || 0, paused_until].max
      qp.reason = reason if reason
      @cached_ordered = nil
    end
  end

  def quota_paused?(provider_name)
    @lock.synchronize { check_quota_paused(provider_name) }
  end

  def clear_quota_pause(provider_name)
    @lock.synchronize do
      qp = @quota_pauses[provider_name]
      return unless qp
      qp.paused_until = nil
      qp.reason = nil
      @cached_ordered = nil
    end
  end

  def record_success(provider_name)
    @lock.synchronize do
      @total_requests[provider_name] = (@total_requests[provider_name] || 0) + 1
      @last_success_at[provider_name] = Time.now.to_f
      circuit = @circuits[provider_name]
      return unless circuit
      circuit.failures = 0
      circuit.opened_at = nil
    end
  end

  def realign_active_index!(model_config)
    new_idx = find_initial_active_index(model_config)
    @lock.synchronize do
      if new_idx != @active_index
        @active_index = new_idx
        @cached_ordered = nil
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
      {ttft: avg[:avg_ttft], tps: avg[:avg_tps], sample_count: avg[:sample_count]}
    end
  end

  # Token-weighted aggregate TPS over a rolling window. Each sample's
  # weight is its token count, so a 10-token request can't dominate a
  # 2000-token one. The aggregate, median, and p90 all derive from the
  # same per-sample TPS value, so they are directly comparable regardless
  # of which server-side timing source (vLLM total-time, Groq decode-only,
  # tokens_per_second, or the arrival-window fallback) produced it.
  #
  # Median and p90 exclude samples below PERCENTILE_MIN_TOKENS — short
  # requests (5-15 tokens) produce TPS values dominated by TTFT/prefill
  # time rather than decode throughput, which inflates the percentiles.
  # The token-weighted aggregate already downweights them naturally.
  # Returns nil when there are no usable samples.
  def rolling_tps(provider_name, window: 60)
    @lock.synchronize do
      now = Time.now.to_f
      cutoff = now - window
      samples = (@samples[provider_name] || []).select { |s| s[:timestamp] >= cutoff }
      next nil if samples.empty?

      # Percentiles computed only from samples with enough tokens that
      # the TPS value reflects decode throughput, not TTFT noise.
      percentile_samples = samples.select { |s| s[:tps] && (s[:tokens] || 0) >= PERCENTILE_MIN_TOKENS }
      tps_values = percentile_samples.filter_map { |s| s[:tps] }.sort
      median = percentile(tps_values, 0.5)
      p90 = percentile(tps_values, 0.9)

      weighted = samples.filter_map { |s| s[:tps] && s[:tokens] && s[:tokens] > 0 ? [s[:tps], s[:tokens]] : nil }
      aggregate = weighted.empty? ? nil : weighted.sum { |tps, tok| tps * tok } / weighted.sum { |_tps, tok| tok }

      total_tokens = samples.sum { |s| s[:tokens] || 0 }
      {aggregate: aggregate&.round(1), median: median&.round(1), p90: p90&.round(1),
       n: samples.length, total_tokens: total_tokens}
    end
  end

  # True if a provider has recorded at least one sample within the last
  # `window` seconds. Used by the periodic TPS logger to suppress idle
  # providers so the log isn't flooded with no-op lines.
  def tps_active?(provider_name, window: 10)
    @lock.synchronize do
      cutoff = Time.now.to_f - window
      (@samples[provider_name] || []).any? { |s| s[:timestamp] >= cutoff }
    end
  end

  def circuit_states
    @lock.synchronize do
      @circuits.transform_values do |c|
        {failures: c.failures, open: !c.opened_at.nil?}
      end
    end
  end

  def provider_stats
    @lock.synchronize do
      now = Time.now.to_f
      @providers.each_with_object({}) do |p, h|
        name = p["provider"]
        last = @last_success_at[name]
        qp = @quota_pauses[name]
        h[name] = {
          errors: @error_counts[name] || 0,
          successes: @total_requests[name] || 0,
          circuit_open: !@circuits[name]&.opened_at.nil?,
          last_success_at: last ? Time.at(last).iso8601 : nil,
          last_success_age_seconds: last ? (now - last).round(1) : nil,
          quota_paused: qp&.paused_until && now < qp.paused_until ? true : false,
          quota_pause_until: qp&.paused_until ? Time.at(qp.paused_until).iso8601 : nil,
          quota_pause_reason: qp&.reason
        }
      end
    end
  end

  def to_state
    @lock.synchronize do
      Time.now.to_f
      {
        active_provider: @providers[@active_index]["provider"],
        samples: @samples.transform_values do |arr|
          arr.map { |s| sample_to_hash(s) }
        end,
        circuits: @circuits.transform_values do |c|
          {"failures" => c.failures, "opened_at" => c.opened_at}
        end,
        quota_pauses: @quota_pauses.transform_values do |qp|
          {"paused_until" => qp.paused_until, "reason" => qp.reason}
        end,
        request_count: @request_count
      }
    end
  end

  def restore_state!(state)
    @lock.synchronize do
      now = Time.now.to_f
      if state.key?("active_provider")
        idx = @providers.index { |p| p["provider"] == state["active_provider"] }
        if idx
          @active_index = idx
          @cached_ordered = nil
        end
      end

      if state["samples"].is_a?(Hash)
        state["samples"].each do |p_name, arr|
          next unless arr.is_a?(Array)
          next unless @circuits.key?(p_name)
          restored = arr.filter_map { |h| hash_to_sample(h, now) }
          @samples[p_name] = restored unless restored.empty?
        end
      end

      if state["circuits"].is_a?(Hash)
        state["circuits"].each do |p_name, c|
          next unless c.is_a?(Hash)
          next unless @circuits.key?(p_name)
          circuit = @circuits[p_name]
          circuit.failures = begin
            Integer(c["failures"])
          rescue ArgumentError, TypeError
            0
          end
          opened_at = c["opened_at"]
          if opened_at && now - opened_at.to_f > @circuit_cooldown
            circuit.opened_at = nil
            circuit.failures = 0
          else
            circuit.opened_at = opened_at&.to_f
          end
        end
      end

      if state["request_count"]
        @request_count = begin
          Integer(state["request_count"])
        rescue ArgumentError, TypeError
          0
        end
      end

      if (qp_data = state["quota_pauses"] || state[:quota_pauses]).is_a?(Hash)
        qp_data.each do |p_name, qp|
          next unless qp.is_a?(Hash) && @quota_pauses.key?(p_name)
          paused_until = (qp["paused_until"] || qp[:paused_until])&.to_f
          reason = qp["reason"] || qp[:reason]
          next unless paused_until && paused_until > now
          @quota_pauses[p_name] = QuotaPause.new(paused_until: paused_until, reason: reason)
        end
      end

      @cached_ordered = nil
    end
  end

  private

  def sample_to_hash(sample)
    h = {"ttft" => sample[:ttft], "ts" => sample[:timestamp]}
    h["tps"] = sample[:tps] if sample[:tps]
    h["tokens"] = sample[:tokens] if sample[:tokens]
    h
  end

  def hash_to_sample(hash, now)
    return nil unless hash.is_a?(Hash) && hash["ttft"] && hash["ts"]
    ts = hash["ts"].to_f
    return nil if now - ts > @sample_window
    sample = {ttft: hash["ttft"].to_f, timestamp: ts}
    sample[:tps] = hash["tps"].to_f if hash["tps"]
    sample[:tokens] = hash["tokens"].to_i if hash["tokens"]
    sample
  end

  # CALLER MUST HOLD @lock. This method mutates circuit state to
  # auto-close after cooldown, so unsynchronized reads can race with
  # concurrent record_failure / record_success calls.
  def circuit_open?(provider_name)
    @lock.synchronize { check_circuit_open(provider_name) }
  end

  # CALLER MUST HOLD @lock. Auto-expires circuits past cooldown.
  def check_circuit_open(provider_name)
    circuit = @circuits[provider_name]
    return false unless circuit&.opened_at
    now = Time.now.to_f
    if now - circuit.opened_at > @circuit_cooldown
      circuit.opened_at = nil
      circuit.failures = 0
      false
    else
      true
    end
  end

  # CALLER MUST HOLD @lock. Auto-expires past pauses.
  def check_quota_paused(provider_name)
    qp = @quota_pauses[provider_name]
    return false unless qp&.paused_until
    now = Time.now.to_f
    if now >= qp.paused_until
      qp.paused_until = nil
      qp.reason = nil
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
    {avg_ttft: avg_ttft, avg_tps: avg_tps, sample_count: n}
  end

  def score_provider(provider_name)
    avg = average_metrics(provider_name)
    score_from_avg(avg)
  end

  def score_from_avg(avg)
    return -Float::INFINITY unless avg
    ttft = avg[:avg_ttft]
    tps = avg[:avg_tps] || 0

    ttft_score = (ttft > 0) ? [TTFT_SATURATION / ttft, 1.0].min : 0

    tps_score = [tps / TPS_REFERENCE, 3.0].min

    ttft_score * TTFT_WEIGHT + tps_score * TPS_WEIGHT
  end

  # Nearest-rank percentile of a pre-sorted array. Returns nil for empty
  # input. Uses ceil(n*p) so P50 of [1,2,3] picks index 1 (value 2), and
  # P90 of a 10-element array picks index 8 — conservative with small n.
  def percentile(sorted_values, p)
    return nil if sorted_values.empty?
    n = sorted_values.length
    rank = (n * p).ceil
    rank = 1 if rank < 1
    rank = n if rank > n
    sorted_values[rank - 1]
  end
end
