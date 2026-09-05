# frozen_string_literal: true

require "robur/state"

module Robur
  class Lifecycle
    def initialize(dir)
      @dir = dir
      @signals = 0
    end

    def level
      file = Robur::State.read_stop(@dir)
      from_file = file.nil? ? 0 : (file.match?(/\A(now|abort)/) ? 2 : 1)
      [@signals, from_file].max
    end

    def stop_requested? = level.positive?
    def abort? = level >= 2

    def install!
      @start_level = level
      trap("INT") { @signals += 1 }
      trap("TERM") { @signals += 1 }
      self
    end

    def sleep(seconds, sleep_it: Kernel.method(:sleep))
      remaining = seconds.to_f
      start = level
      while remaining.positive?
        slice = remaining > 1 ? 1 : remaining
        sleep_it.call(slice)
        return :interrupted if level > start
        remaining -= slice
      end
      :slept
    end
  end
end
