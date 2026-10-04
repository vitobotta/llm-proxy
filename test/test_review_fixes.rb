# frozen_string_literal: true

# Regression tests for the review-fix batch:
#  - partial-stream upstream disconnect must NOT fall back to other providers
#    or rounds (the client already holds a partial stream)
#  - client-shape 4xx must not trip the circuit breaker (auth 4xx still does)
#  - non-finite TTFT samples (probe Infinity) are clamped to a finite penalty
#  - evaluate_and_select never switches active to a circuit-broken provider
#  - duplicate provider names get per-entry state keys
#  - SIGUSR1 config reload works (trap-safe flag, no Mutex in trap context)
#  - Responses synthetic termination: delta + terminal event is "complete"
#    even without a usage block
#  - capped upstream body reads + forwardable response headers
#  - connection pool keeps the true connection age across check-ins

require_relative "test_helper"
require_relative "../lib/request_handler"
require_relative "../lib/config_store"
require_relative "../lib/metrics"
require_relative "../lib/streaming"
require_relative "../lib/http_support"
require_relative "../lib/config_watcher"
require_relative "../provider_selector"
require "json"

class ReviewFixesApp
  include RequestHandler
  include Streaming
  include HTTPSupport

  attr_accessor :request_id

  def initialize
    @request_id = "review-fix-req"
  end

  def settings
    @_logs ||= []
    logger = Object.new
    logs_ref = @_logs
    logger.define_singleton_method(:info) { |m| logs_ref << [:info, m] }
    logger.define_singleton_method(:warn) { |m| logs_ref << [:warn, m] }
    logger.define_singleton_method(:error) { |m| logs_ref << [:error, m] }
    logger.define_singleton_method(:debug) { |m| logs_ref << [:debug, m] }
    Struct.new(:logger, :max_attempts, :backoff_base, :max_rounds).new(logger, 2, 0, 3)
  end

  def sleep(_); end
end

class ReviewFixesSelector
  attr_reader :successes, :failures, :pauses
  attr_accessor :_providers

  def initialize
    @successes = []
    @failures = []
    @pauses = []
    @metrics_updates = []
    @_providers = []
    @paused_names = []
  end

  def name_of(provider)
    provider.is_a?(Hash) ? provider["provider"] : provider
  end

  def ordered_providers(auto_switch: false)
    @_providers.reject { |p| @paused_names.include?(p["provider"]) }
  end

  def record_success(provider) = @successes << name_of(provider)
  def record_failure(provider) = @failures << name_of(provider)

  def quota_pause!(provider, time, reason: nil)
    name = name_of(provider)
    @pauses << {name: name, time: time, reason: reason}
    @paused_names << name unless @paused_names.include?(name)
  end

  def update_metrics(provider, ttft, tps, tokens: nil); end

  def record_and_maybe_probe(_interval) = false
end

class ReviewFallbackStopTest < Minitest::Test
  def setup
    @app = ReviewFixesApp.new
    @selector = ReviewFixesSelector.new
    @model_entry = {"name" => "test-model", "probing_enabled" => false, "auto_switch" => false}
    ConfigStore.instance_variable_set(:@data, {
      selectors: {"test-model" => @selector},
      models: {"test-model" => @model_entry},
      probe_interval: 60,
      probe_max_per_minute: 2,
      timeouts: {open: 1, read: 1, write: 1},
      tracking_enabled: true,
      quota_pause_default_seconds: 60
    })
    @selector._providers = [
      {"provider" => "openai", "model" => "gpt-4", "base_url" => "https://api.openai.com/v1", "api_key" => "k"},
      {"provider" => "anthropic", "model" => "claude-3", "base_url" => "https://api.anthropic.com/v1", "api_key" => "k2"}
    ]
  end

  def test_upstream_disconnect_does_not_fall_back_to_next_provider
    calls = []
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "chat/completions", body: {}, headers: {}) do |pc, *_|
      calls << pc["provider"]
      if pc["provider"] == "openai"
        {success: false, error: "Upstream disconnect after partial stream"}
      else
        {success: true, ttft: 0.1}
      end
    end

    assert_equal ["openai"], calls,
      "partial-stream disconnect must stop the fallback walk — the next provider would concatenate a garbled stream"
    refute result[:success]
    assert_equal ["openai"], @selector.failures, "upstream disconnect SHOULD count toward the circuit breaker"
  end

  def test_upstream_disconnect_breaks_rounds_loop
    calls = 0
    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "chat/completions", body: {}, headers: {}) do
      calls += 1
      {success: false, error: "Upstream disconnect after partial stream"}
    end

    assert_equal 1, calls, "no retries across rounds after a partial-stream disconnect"
    refute result[:success]
  end

  def test_client_error_does_not_trip_circuit_breaker
    @selector._providers = [@selector._providers.first]
    @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "chat/completions", body: {}, headers: {}) do
      {success: false, status: 400, error: "bad request"}
    end

    assert_empty @selector.failures, "client-shape 4xx must NOT record_failure (bad client requests evict healthy providers)"
  end

  def test_auth_error_trips_circuit_breaker
    @selector._providers = [@selector._providers.first]
    @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "chat/completions", body: {}, headers: {}) do
      {success: false, status: 401, error: "invalid api key"}
    end

    assert_includes @selector.failures, "openai", "401 (provider refusing our credentials) SHOULD record_failure"
  end

  def test_failure_reason_auth_error_mapping
    assert_equal "auth_error", RequestHandler.failure_reason({status: 401, error: "x"})
    assert_equal "auth_error", RequestHandler.failure_reason({status: 403, error: "x"})
    assert_equal "client_error", RequestHandler.failure_reason({status: 400, error: "x"})
    assert_equal "client_error", RequestHandler.failure_reason({status: 404, error: "x"})
  end

  def test_missing_selector_after_reload_returns_503_not_500
    ConfigStore.instance_variable_set(:@data, {
      selectors: {},
      models: {"test-model" => @model_entry},
      probe_interval: 60, probe_max_per_minute: 2,
      timeouts: {open: 1, read: 1, write: 1},
      tracking_enabled: true, quota_pause_default_seconds: 60
    })

    result = @app.with_auto_select(model: @model_entry, model_name: "test-model", path: "chat/completions", body: {}, headers: {}) do
      flunk "should not attempt any provider"
    end

    refute result[:success]
    assert_equal 503, result[:status]
    assert_includes result[:error], "no longer configured"
  end
end

class ReviewSelectorFixesTest < Minitest::Test
  def setup
    @providers = [
      {"provider" => "prov_a", "model" => "m-a", "base_url" => "https://a.example.com/v1", "api_key" => "ka"}.freeze,
      {"provider" => "prov_b", "model" => "m-b", "base_url" => "https://b.example.com/v1", "api_key" => "kb"}.freeze
    ].freeze
    @model_config = {"name" => "test-model", "providers" => [
      {"provider" => "prov_a", "model" => "m-a", "primary" => true},
      {"provider" => "prov_b", "model" => "m-b"}
    ]}
  end

  def selector
    @selector ||= ProviderSelector.new("test-model", @providers, model_config: @model_config)
  end

  def test_update_metrics_clamps_infinite_ttft
    selector.update_metrics("prov_a", Float::INFINITY, nil)
    selector.update_metrics("prov_a", 0.5, 50.0, tokens: 100)

    samples = selector.instance_variable_get(:@samples)["prov_a"]
    assert samples.all? { |s| s[:ttft].finite? }, "non-finite ttft must never reach the sample pool"
    assert_includes samples.map { |s| s[:ttft] }, ProviderSelector::FAILED_PROBE_TTFT

    # The whole state must stay JSON-serializable (health/detail + state file).
    assert_kind_of String, JSON.generate(selector.to_state)
    metrics = selector.active_metrics
    assert_kind_of String, JSON.generate(metrics)
    assert metrics[:ttft].finite?
  end

  def test_update_metrics_drops_non_finite_tps
    selector.update_metrics("prov_a", 1.0, Float::INFINITY)
    samples = selector.instance_variable_get(:@samples)["prov_a"]
    assert samples.none? { |s| s[:tps] }, "non-finite tps must be dropped"
  end

  def test_evaluate_and_select_never_switches_to_circuit_open_provider
    3.times { selector.update_metrics("prov_a", 5.0, 10.0) }
    3.times { selector.update_metrics("prov_b", 0.1, 200.0) }
    3.times { selector.record_failure("prov_b") } # opens prov_b's circuit

    selector.evaluate_and_select(NullLogger.new, auto_switch: true)

    assert_equal "prov_a", selector.active_provider_name,
      "a circuit-broken provider must not become active regardless of its samples"
  end

  def test_duplicate_provider_names_get_distinct_state
    providers = [
      {"provider" => "openai", "model" => "gpt-4", "base_url" => "https://api.openai.com/v1", "api_key" => "k"},
      {"provider" => "openai", "model" => "gpt-4o-mini", "base_url" => "https://api.openai.com/v1", "api_key" => "k"}
    ]
    s = ProviderSelector.new("dup-model", providers,
      model_config: {"providers" => [{"provider" => "openai", "model" => "gpt-4", "primary" => true}, {"provider" => "openai", "model" => "gpt-4o-mini"}]})

    3.times { s.record_failure(providers[1]) }
    assert s.circuit_open?(providers[1]), "the failing entry's circuit must open"
    refute s.circuit_open?(providers[0]), "the sibling entry must keep its own circuit state"

    s.update_metrics(providers[0], 0.5, 100.0, tokens: 500)
    s.update_metrics(providers[1], 0.5, 100.0, tokens: 500)
    refute_equal s.instance_variable_get(:@samples).values[0].object_id,
      s.instance_variable_get(:@samples).values[1].object_id,
      "duplicate provider names must not share a sample pool"
  end

  def test_state_key_resolves_hash_and_name
    assert_equal "prov_a", selector.state_key(@providers[0])
    assert_equal "prov_a", selector.state_key("prov_a")
    assert_equal "prov_b", selector.state_key("prov_b")
  end

  def test_realign_active_index_refreshes_model_config
    new_config = {"name" => "test-model", "auto_switch" => true, "providers" => [
      {"provider" => "prov_a", "model" => "m-a"},
      {"provider" => "prov_b", "model" => "m-b", "primary" => true}
    ]}
    selector.realign_active_index!(new_config)
    assert_equal new_config, selector.instance_variable_get(:@model_config),
      "realign must track the latest model config (persist_active_index reads auto_switch from it)"
  end
end

class ReviewStreamTerminationTest < Minitest::Test
  OUTPUT_TEXT_DELTA = JSON.generate("type" => "response.output_text.delta", "delta" => "Hello")
  COMPLETED_NO_USAGE = 'data: {"type":"response.completed","response":{"id":"r1"}}' + "\n\n"

  def setup
    @app = ReviewFixesApp.new
    @orig_data = ConfigStore.instance_variable_get(:@data)
    ConfigStore.instance_variable_set(:@data, {
      selectors: {}, models: {}, probe_interval: 60, probe_max_per_minute: 2,
      timeouts: {open: 1, read: 60, write: 60}, tracking_enabled: true,
      quota_pause_default_seconds: 60
    })
    @orig_create = HTTPSupport.method(:create_http)
    @orig_discard = HTTPSupport.method(:discard_http)
    @orig_checkin = HTTPSupport.method(:checkin_http)
    @orig_build = HTTPSupport.method(:build_upstream_request)
  end

  def teardown
    HTTPSupport.define_singleton_method(:create_http, @orig_create)
    HTTPSupport.define_singleton_method(:discard_http, @orig_discard)
    HTTPSupport.define_singleton_method(:checkin_http, @orig_checkin)
    HTTPSupport.define_singleton_method(:build_upstream_request, @orig_build)
    ConfigStore.instance_variable_set(:@data, @orig_data)
  end

  class SseResponse < Net::HTTPSuccess
    def initialize(*chunks)
      super("1.1", "200", "OK")
      @chunks = chunks
    end

    def read_body
      @chunks.each { |c| yield c }
    end

    def [](_key) = nil
    def body = ""
  end

  class MockHTTP
    attr_accessor :started, :response

    def initialize = @started = false
    def start = @started = true
    def started? = @started

    def request(_req)
      yield @response
    end
  end

  def run_stream(chunks)
    mock = MockHTTP.new
    mock.response = SseResponse.new(*chunks)
    HTTPSupport.define_singleton_method(:create_http) { |*a, **kw| mock }
    HTTPSupport.define_singleton_method(:discard_http) { |*a| }
    HTTPSupport.define_singleton_method(:checkin_http) { |*a| }
    HTTPSupport.define_singleton_method(:build_upstream_request) { |*a, **kw| [URI.parse("https://upstream.example.com/v1"), Object.new] }
    out = []
    result = @app.try_stream(
      {"base_url" => "https://upstream.example.com/v1", "api_key" => "k"},
      "responses", {}, "m", {}, out: out, log_prefix: "[review]", responses_api: true
    )
    [result, out.join]
  end

  def test_delta_plus_usageless_terminal_is_complete_no_injection
    _result, full = run_stream([
      "data: #{OUTPUT_TEXT_DELTA}\n\n",
      COMPLETED_NO_USAGE,
      "data: [DONE]\n\n"
    ])

    refute_includes full, "response.failed", "delta + terminal event is a complete stream even without usage"
    refute_includes full, "response.not_found", "delta + terminal event is a complete stream even without usage"
    assert_equal 1, full.scan(/data: \[DONE\]/).length
  end

  def test_usageless_terminal_without_delta_still_injects
    _result, full = run_stream([
      COMPLETED_NO_USAGE,
      "data: [DONE]\n\n"
    ])

    refute_nil full.index('"type":"response.not_found"'), "no delta = nothing was delivered = synthetic end event"
  end
end

class ReviewHttpSupportFixesTest < Minitest::Test
  class ChunkedResponse
    def initialize(chunks, content_length: nil)
      @chunks = chunks
      @headers = {}
      @headers["Content-Length"] = content_length.to_s if content_length
      @read = false
    end

    def [](k) = @headers[k]

    def read_body
      raise IOError, "read_body called twice" if @read
      @read = true
      @chunks.each { |c| yield c }
    end

    def body = raise(IOError, "body() must not be used for streaming reads")
  end

  class HeaderedResponse
    def initialize(headers) = @headers = headers
    def each_header(&blk) = @headers.each(&blk)
  end

  def test_read_body_capped_truncates_but_drains_stream
    chunks = ["x" * 100, "y" * 100, "z" * 100]
    body, truncated = HTTPSupport.read_body_capped(ChunkedResponse.new(chunks), 150)

    assert truncated
    assert_equal 150, body.bytesize, "body must be capped at max"
  end

  def test_read_body_capped_under_cap_not_truncated
    body, truncated = HTTPSupport.read_body_capped(ChunkedResponse.new(["hello ", "world"]), 100)

    refute truncated
    assert_equal "hello world", body
  end

  def test_read_body_capped_uses_buffered_body_when_already_consumed
    fake = ChunkedResponse.new([])
    fake.define_singleton_method(:read_body) { |*| raise IOError, "read_body called twice" }
    fake.define_singleton_method(:body) { "buffered" }

    body, truncated = HTTPSupport.read_body_capped(fake, 100)
    refute truncated
    assert_equal "buffered", body
  end

  def test_forwardable_response_headers_filters_hop_by_hop
    resp = HeaderedResponse.new(
      "content-type" => "application/json; charset=utf-8",
      "x-ratelimit-reset-requests" => "1s",
      "content-length" => "42",
      "transfer-encoding" => "chunked",
      "connection" => "keep-alive",
      "set-cookie" => "session=abc"
    )

    headers = HTTPSupport.forwardable_response_headers(resp)
    assert_equal "application/json; charset=utf-8", headers["Content-Type"]
    assert_equal "1s", headers["X-Ratelimit-Reset-Requests"]
    refute headers.key?("Content-Length"), "framing headers must not be relayed"
    refute headers.key?("Transfer-Encoding")
    refute headers.key?("Connection")
    refute headers.key?("Set-Cookie"), "upstream cookies must not leak to the client"
  end

  class AgeMockHttp
    attr_accessor :started
    alias_method :started?, :started
    def initialize = @started = true
    def finish = @started = false
  end

  def test_checkin_http_preserves_connection_age
    uri = URI.parse("https://example.com")
    mock = AgeMockHttp.new
    old_created = Time.now.to_f - HTTPSupport::POOL_MAX_AGE - 10
    mock.instance_variable_set(:@llm_proxy_created_at, old_created)

    HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL.clear }
    HTTPSupport.checkin_http(uri, mock)

    key = "#{uri.host}:#{uri.port}"
    entry = HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL[key].first }
    assert_in_delta old_created, entry[:created], 0.01,
      "check-in must keep the connection's true age (created must not be re-stamped)"

    # A connection checked in past POOL_MAX_AGE is evicted at the next check-in
    HTTPSupport.checkin_http(uri, AgeMockHttp.new)
    entries = HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL[key] }
    assert_equal 1, entries.size, "stale-age connection must be evicted"
    HTTPSupport::POOL_LOCK.synchronize { HTTPSupport::CONNECTION_POOL.clear }
  end
end

class ReviewConfigWatcherSigusr1Test < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_path = File.join(@tmpdir, "config.yaml")
    File.write(@config_path, YAML.dump(MOCK_CONFIG))
    ConfigStore.instance_variable_set(:@config_path, @config_path)
    ConfigStore.instance_variable_set(:@data, {})
    ConfigStore.load!(MOCK_CONFIG, logger: NullLogger.new)
    ConfigWatcher.instance_variable_set(:@logger, NullLogger.new)
    ConfigWatcher.instance_variable_set(:@last_hash, ConfigWatcher.send(:file_hash))
    ConfigWatcher.instance_variable_set(:@expected_hash, nil)

    @reload_counter = []
    counter = @reload_counter
    ConfigStore.singleton_class.class_eval do
      alias_method :__orig_reload_rf, :reload!
      define_method(:reload!) do |**_kw|
        counter << :called
        true
      end
    end
    @old_trap = Signal.trap("USR1", "IGNORE")
  end

  def teardown
    ConfigWatcher.stop! rescue nil
    sleep 0.05
    Signal.trap("USR1", @old_trap || "DEFAULT") rescue nil
    ConfigStore.singleton_class.class_eval do
      if method_defined?(:__orig_reload_rf) || private_method_defined?(:__orig_reload_rf)
        alias_method :reload!, :__orig_reload_rf
        remove_method :__orig_reload_rf
      end
    end
    FileUtils.remove_entry(@tmpdir) rescue nil
  end

  def test_sigusr1_triggers_reload_via_trap_safe_flag
    before_count = @reload_counter.size
    ConfigWatcher.start!(logger: NullLogger.new, poll_interval: 5)

    # Old implementation raised ThreadError ("can't be called from trap
    # context") from Mutex#synchronize inside the handler and never reloaded.
    Process.kill("USR1", Process.pid)

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while @reload_counter.size == before_count &&
      Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep 0.05
    end

    assert_operator @reload_counter.size, :>, before_count,
      "SIGUSR1 must trigger a config reload"
  ensure
    ConfigWatcher.stop! rescue nil
  end
end
