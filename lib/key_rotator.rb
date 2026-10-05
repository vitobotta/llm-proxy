# frozen_string_literal: true

# Ordered rotation over multiple API keys belonging to a single provider
# (account). Each key is an independent subscription with its own rate limits,
# so when one key is rate-limited the next is tried instead of failing over to
# a whole different provider.
#
# Selection is "first available key in order": the proxy sticks to the first
# key until it is rate-limited, then moves to the second, and so on — matching
# the provider-level rotation semantics. When a paused key's reset time passes
# it becomes eligible again and, being earlier in order, is preferred.
#
# Rotators are shared per provider account (provider name + base_url) across
# every model that references that provider, because the rate limit is a
# property of the account/keys, not of an individual model entry.
class KeyRotator
  REGISTRY = {}
  REGISTRY_LOCK = Mutex.new

  # Returns the shared rotator for a provider entry's resolved config,
  # building (or reusing) it as needed. If the key list changes (config
  # reload), a fresh rotator replaces the old one so stale pause state is
  # never applied to a different set of keys.
  def self.for(provider_config)
    name = "#{provider_config["provider"]}@#{provider_config["base_url"]}"
    keys = extract_keys(provider_config)
    REGISTRY_LOCK.synchronize do
      rot = REGISTRY[name]
      if rot.nil? || rot.keys != keys
        rot = new(keys)
        REGISTRY[name] = rot
      end
      rot
    end
  end

  # The ordered key list for a provider definition. `api_keys` (an ordered list
  # of strings) is canonical; `api_key` is the single-key shorthand. Only
  # non-empty String entries are kept (a non-array `api_keys` is ignored and
  # falls back to `api_key`), blanks are dropped and duplicates collapsed,
  # preserving first-seen order.
  def self.extract_keys(provider_config)
    raw = provider_config["api_keys"]
    list = raw.is_a?(Array) ? raw : []
    list = list.select { |k| k.is_a?(String) }.map(&:strip).reject(&:empty?).uniq
    return list unless list.empty?
    single = provider_config["api_key"].to_s.strip
    single.empty? ? [] : [single]
  end

  # Test hook: forget all rotators (and their pause state).
  def self.reset!
    REGISTRY_LOCK.synchronize { REGISTRY.clear }
  end

  attr_reader :keys

  def initialize(keys)
    @keys = keys.dup.freeze
    @paused_until = Array.new(@keys.size) # nil = not paused
    @lock = Mutex.new
  end

  def multiple?
    @keys.size > 1
  end

  # Returns the first non-paused key in order, or nil when every key is
  # rate-limited. `exclude` skips one key or a collection of keys the caller
  # has already exhausted this round, regardless of their pause state.
  def acquire(exclude: nil)
    excl = Array(exclude)
    @lock.synchronize do
      now = Time.now.to_f
      @keys.each_with_index do |k, i|
        next if excl.include?(k)
        pu = @paused_until[i]
        next if pu && now < pu
        return k
      end
      nil
    end
  end

  # Marks `key` rate-limited until `until_time` (absolute). Keeps the longest
  # pause when a key is paused repeatedly.
  def pause(key, until_time)
    @lock.synchronize do
      i = @keys.index(key)
      return unless i
      return if until_time.nil?
      @paused_until[i] = [until_time.to_f, @paused_until[i] || 0].max
    end
  end

  # Clears any pause on `key` (used when a request succeeds on it).
  def resume(key)
    @lock.synchronize do
      i = @keys.index(key)
      @paused_until[i] = nil if i
    end
  end

  # The soonest any key becomes available, used to pause the whole provider
  # when every key is exhausted. Returns nil when no key is paused.
  def resume_time
    @lock.synchronize do
      future = @paused_until.compact.select { |t| t > Time.now.to_f }
      future.empty? ? nil : future.min
    end
  end

  def paused_count
    @lock.synchronize do
      now = Time.now.to_f
      @paused_until.count { |t| t && now < t }
    end
  end
end
