# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/routes/completions"

class TestCompletionRoutes < Minitest::Test
  def test_streaming_is_disabled_when_stream_is_omitted
    refute Routes::Completions.stream_requested?({})
  end

  def test_streaming_is_disabled_when_stream_is_false
    refute Routes::Completions.stream_requested?({"stream" => false})
  end

  def test_streaming_is_enabled_when_stream_is_true
    assert Routes::Completions.stream_requested?({"stream" => true})
  end
end
