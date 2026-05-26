# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/request_handler"

class TestRequestHandler < Minitest::Test
  def test_failure_reason_rate_limited_from_status
    assert_equal "rate_limited", RequestHandler.failure_reason({status: 429, error: "HTTP 429: too many"})
  end

  def test_failure_reason_server_error
    assert_equal "server_error", RequestHandler.failure_reason({status: 502, error: "HTTP 502: bad gateway"})
  end

  def test_failure_reason_client_error
    assert_equal "client_error", RequestHandler.failure_reason({status: 400, error: "bad request"})
  end

  def test_failure_reason_timeout
    assert_equal "timeout", RequestHandler.failure_reason({error: "Timeout after 3 attempts"})
  end

  def test_failure_reason_client_disconnect
    assert_equal "client_disconnect", RequestHandler.failure_reason({error: "Client disconnected"})
  end

  def test_failure_reason_connection_reset
    assert_equal "connection_reset", RequestHandler.failure_reason({error: "Connection reset after 2 attempts"})
  end

  def test_failure_reason_unknown_for_nil
    assert_equal "unknown", RequestHandler.failure_reason(nil)
  end

  def test_failure_reason_generic_error
    assert_equal "error", RequestHandler.failure_reason({error: "weird unexplained thing"})
  end

  class FakeHelper
    extend RequestHandler::ClassMethods if defined?(RequestHandler::ClassMethods)
    include RequestHandler

    attr_accessor :logs

    def initialize
      @logs = []
    end

    def settings
      logger = Object.new
      logs_ref = @logs
      logger.define_singleton_method(:info) { |m| logs_ref << [:info, m] }
      logger.define_singleton_method(:warn) { |m| logs_ref << [:warn, m] }
      logger.define_singleton_method(:error) { |m| logs_ref << [:error, m] }
      logger.define_singleton_method(:debug) { |m| logs_ref << [:debug, m] }
      Struct.new(:logger).new(logger)
    end
  end

  def test_build_failure_summary_aggregates_attempts
    h = FakeHelper.new
    attempts = [
      {provider: "p_a", status: 500, error: "boom", reason: "server_error"},
      {provider: "p_b", status: 429, error: "rate", reason: "rate_limited"}
    ]
    result = h.build_failure_summary(attempts, false)
    refute result[:success]
    assert_includes result[:error], "p_a: server_error"
    assert_includes result[:error], "p_b: rate_limited"
    assert_equal 429, result[:status], "last attempt status should be propagated"
    assert_equal attempts, result[:detail][:attempts]
    refute result[:detail][:deadline_hit]
  end

  def test_build_failure_summary_when_deadline_hit_before_attempts
    h = FakeHelper.new
    result = h.build_failure_summary([], true)
    assert_equal 503, result[:status]
    assert_includes result[:error], "deadline exceeded"
  end

  def test_build_failure_summary_falls_back_to_502_when_last_status_missing
    h = FakeHelper.new
    attempts = [{provider: "p_a", status: nil, error: "Timeout", reason: "timeout"}]
    result = h.build_failure_summary(attempts, false)
    assert_equal 502, result[:status]
  end
end
