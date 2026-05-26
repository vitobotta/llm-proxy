# frozen_string_literal: true

module Metrics
  LOCK = Mutex.new
  COUNTERS = {}
  HISTOGRAMS = {}

  HISTOGRAM_BUCKETS = [0.1, 0.5, 1, 5, 10, 30, 60, 300].freeze

  COUNTER_HELP = {
    requests_total:      "Total HTTP requests received",
    provider_success:    "Successful upstream responses by provider/model",
    provider_failure:    "Failed upstream attempts by provider/model"
  }.freeze

  HISTOGRAM_HELP = {
    request_duration_seconds: "End-to-end request duration in seconds",
    upstream_ttft_seconds: "Per-provider time-to-first-token in seconds"
  }.freeze

  def self.increment(name, labels: {})
    LOCK.synchronize do
      key = [name, labels]
      COUNTERS[key] = (COUNTERS[key] || 0) + 1
    end
  end

  def self.observe(name, value, labels: {})
    LOCK.synchronize do
      key = [name, labels]
      hist = (HISTOGRAMS[key] ||= { count: 0, sum: 0.0, buckets: Hash.new(0) })
      hist[:count] += 1
      hist[:sum] += value
      HISTOGRAM_BUCKETS.each do |le|
        hist[:buckets][le] += 1 if value <= le
      end
    end
  end

  def self.reset!
    LOCK.synchronize do
      COUNTERS.clear
      HISTOGRAMS.clear
    end
  end

  def self.to_prometheus
    lines = []

    LOCK.synchronize do
      counters_by_name = COUNTERS.group_by { |(name, _labels), _| name }
      counters_by_name.each do |name, entries|
        metric = counter_metric_name(name)
        lines << "# HELP #{metric} #{COUNTER_HELP[name] || name.to_s}"
        lines << "# TYPE #{metric} counter"
        entries.each do |(_, labels), value|
          lines << "#{metric}#{format_labels(labels)} #{value}"
        end
      end

      histograms_by_name = HISTOGRAMS.group_by { |(name, _labels), _| name }
      histograms_by_name.each do |name, entries|
        metric = "llm_proxy_#{name}"
        lines << "# HELP #{metric} #{HISTOGRAM_HELP[name] || name.to_s}"
        lines << "# TYPE #{metric} histogram"
        entries.each do |(_, labels), hist|
          HISTOGRAM_BUCKETS.each do |le|
            bucket_labels = labels.merge(le: format_le(le))
            lines << "#{metric}_bucket#{format_labels(bucket_labels)} #{hist[:buckets][le]}"
          end
          inf_labels = labels.merge(le: "+Inf")
          lines << "#{metric}_bucket#{format_labels(inf_labels)} #{hist[:count]}"
          lines << "#{metric}_sum#{format_labels(labels)} #{hist[:sum].round(6)}"
          lines << "#{metric}_count#{format_labels(labels)} #{hist[:count]}"
        end
      end
    end

    lines.join("\n") + "\n"
  end

  def self.counter_metric_name(name)
    base = "llm_proxy_#{name}"
    base.end_with?("_total") ? base : "#{base}_total"
  end

  def self.format_labels(labels)
    return "" if labels.empty?
    parts = labels.map { |k, v| %(#{k}="#{escape_label_value(v.to_s)}") }
    "{#{parts.join(",")}}"
  end

  def self.escape_label_value(v)
    v.gsub(/[\\\n"]/) do |m|
      case m
      when "\\" then "\\\\"
      when "\"" then "\\\""
      when "\n" then "\\n"
      end
    end
  end

  def self.format_le(le)
    le == le.to_i ? le.to_i.to_s : le.to_s
  end
end
