# frozen_string_literal: true

require_relative "../state"
require_relative "../sys"

module Robur
  module Fleet
    # A failed repo backs off on a doubling ladder capped below a day. The
    # cap must stay under the fleet beat interval: a cap above it means a
    # long enough silence that no new information is ever produced and
    # nothing can clear the backoff (the lesson harbor paid for,
    # ../harbor/harbor/loop/runner.py:35).
    class Backoff
      BASE_DEFAULT = 3600
      CAP_DEFAULT  = 14_400

      def initialize(repo, base: BASE_DEFAULT, cap: CAP_DEFAULT, clock: Sys::Clock.new)
        @repo = repo
        @base = base
        @cap = cap
        @clock = clock
      end

      def active?
        remaining_secs.positive?
      end

      # Seconds until the backoff lifts, 0 when none is active. `now` is
      # injectable so a status render is testable without sleeping (T6.1).
      def remaining_secs(now = @clock.now.to_i)
        record = State.read_loop_backoff(@repo)
        record && now < record[1] ? record[1] - now : 0
      end

      # Doubles from base per consecutive failure, clamps at cap, persists
      # [count, now + delay], returns [count, delay].
      def bump!
        count = (State.read_loop_backoff(@repo) || [0, 0])[0]
        delay = [@base * 2**count, @cap].min
        count += 1
        State.write_loop_backoff(@repo, count, @clock.now.to_i + delay)
        [count, delay]
      end

      # True when a backoff file was deleted, false when there was none —
      # callers count the truthy returns to report how many repos cleared.
      def clear!
        !!State.clear_loop_backoff(@repo)
      end
    end
  end
end
