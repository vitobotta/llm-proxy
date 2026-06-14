# frozen_string_literal: true

require_relative "test_helper"

Dir.glob(File.join(__dir__, "test_*.rb")).each { |f| require f }
