# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "yaml"

$LOAD_PATH.unshift File.join(__dir__, "..")
require_relative "../lib/streaming"
require_relative "../lib/http_support"
require_relative "../provider_selector"

class NullLogger
  def info(_msg); end
  def warn(_msg); end
  def error(_msg); end
  def debug(_msg); end
end

MOCK_CONFIG = {
  "providers" => {
    "prov_a" => { "base_url" => "https://a.example.com/v1", "api_key" => "key_a" },
    "prov_b" => { "base_url" => "https://b.example.com/v1", "api_key" => "key_b" }
  },
  "models" => [
    { "name" => "test-model", "providers" => [
      { "provider" => "prov_a", "model" => "model-a", "primary" => true },
      { "provider" => "prov_b", "model" => "model-b" }
    ]}
  ],
  "retries" => { "max_attempts" => 2, "backoff_base" => 1 },
  "timeouts" => { "open" => 5, "read" => 10, "write" => 5 },
  "logging" => { "level" => "error" },
  "tracking" => { "enabled" => true },
  "performance" => { "probing_enabled" => false }
}.freeze
