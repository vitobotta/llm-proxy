# frozen_string_literal: true

module Notifier
  MACOS = RUBY_PLATFORM.match?(/darwin/)

  def self.notify(title, message)
    return unless MACOS

    Thread.new do
      script = "display notification #{message.inspect} with title #{title.inspect}"
      system("osascript", "-e", script)
    end
  end
end
