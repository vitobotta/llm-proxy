# frozen_string_literal: true

module Metrics
  LOCK = Mutex.new
  COUNTERS = {}
  HISTOGRAMS = {}

  def self.increment(name, labels: {})
    LOCK.synchronize do
      key = [name, labels]
      COUNTERS[key] = (COUNTERS[key] || 0) + 1
    end
  end

  def self.observe(name, value, labels: {})
    LOCK.synchronize do
      key = [name, labels]
      hist = (HISTOGRAMS[key] ||= { count: 0, sum: 0.0, buckets: {} })
      hist[:count] += 1
      hist[:sum] += value
      bucket = value < 0.1 ? "0.1" : value < 0.5 ? "0.5" : value < 1 ? "1" : value < 5 ? "5" : "+Inf"
      hist[:buckets][bucket] = (hist[:buckets][bucket] || 0) + 1
    end
  end

  def self.to_prometheus
    lines = []

    LOCK.synchronize do
      COUNTERS.each do |(name, labels), value|
        label_str = labels.empty? ? "" : "{#{labels.map { |k, v| "#{k}=\"#{v}\"" }.join(",")}}"
        lines << "llm_proxy_#{name}_total#{label_str} #{value}"
      end

      HISTOGRAMS.each do |(name, labels), hist|
        label_str = labels.empty? ? "" : "{#{labels.map { |k, v| "#{k}=\"#{v}\"" }.join(",")}}"
        lines << "llm_proxy_#{name}_count#{label_str} #{hist[:count]}"
        lines << "llm_proxy_#{name}_sum#{label_str} #{hist[:sum].round(3)}"
      end
    end

    lines.join("\n") + "\n"
  end
end
