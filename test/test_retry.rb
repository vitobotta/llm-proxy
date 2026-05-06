# frozen_string_literal: true

require_relative "test_helper"

class NullLogger
  def info(_msg); end
  def warn(_msg); end
  def error(_msg); end
  def debug(_msg); end
end

class TestRetryLogic < Minitest::Test
  class MockApp
    include HTTPSupport

    attr_reader :slept

    def initialize(max_attempts: 3, backoff_base: 1)
      @max_attempts = max_attempts
      @backoff_base = backoff_base
      @slept = []
    end

    def settings
      Struct.new(:max_attempts, :backoff_base, :logger).new(@max_attempts, @backoff_base, NullLogger.new)
    end

    def sleep(duration)
      @slept << duration
    end
  end

  def test_successful_first_attempt
    app = MockApp.new
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      { success: true }
    end

    assert result[:success]
  end

  def test_retries_on_retryable_error_then_succeeds
    app = MockApp.new(max_attempts: 3)
    call_count = 0
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      call_count += 1
      if call_count < 2
        raise HTTPSupport::RetryableError, "temporary failure"
      end
      { success: true }
    end

    assert result[:success]
    assert_equal 2, call_count
  end

  def test_returns_failure_after_max_attempts
    app = MockApp.new(max_attempts: 2)
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      raise HTTPSupport::RetryableError, "persistent failure"
    end

    refute result[:success]
    assert_match(/Failed after 2 attempts/, result[:error])
    assert_match(/persistent failure/, result[:detail])
  end

  def test_client_disconnected_returns_immediately
    app = MockApp.new
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      raise HTTPSupport::ClientDisconnected
    end

    refute result[:success]
    assert_equal "Client disconnected", result[:error]
  end

  def test_eof_retries_dont_count_against_attempts
    app = MockApp.new(max_attempts: 2)
    eof_count = 0
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      eof_count += 1
      if eof_count <= 1
        raise EOFError
      end
      { success: true }
    end

    assert result[:success]
  end

  def test_eof_persistent_counts_as_attempt
    app = MockApp.new(max_attempts: 2)
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      raise EOFError
    end

    refute result[:success]
  end

  def test_timeout_retries
    app = MockApp.new(max_attempts: 2)
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      raise Net::ReadTimeout
    end

    refute result[:success]
  end

  def test_backoff_includes_jitter
    app = MockApp.new(backoff_base: 2)
    durations = []
    20.times do
      app = MockApp.new(backoff_base: 2)
      app.backoff(0)
      durations << app.slept.first
    end

    unique = durations.uniq
    assert unique.length > 1, "Backoff durations should vary due to jitter"
  end

  def test_generic_error_retries
    app = MockApp.new(max_attempts: 2)
    result = app.try_with_retries(log_prefix: "[test]", body_model: "m") do
      raise StandardError, "something broke"
    end

    refute result[:success]
    assert_match(/something broke/, result[:detail])
  end
end
