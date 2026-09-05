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
  end
end
