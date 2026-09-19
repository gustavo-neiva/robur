# frozen_string_literal: true

module Robur
  module Fleet
    # T5.1: the perpetual beat behind `robur fleet --every 15m`. Run one
    # cycle, sleep the interval, repeat — until a stop is requested. A cycle
    # that RAISES is rescued and logged and the next beat still runs: the
    # supervisor's whole job is to outlive a bad night. The sleep goes through
    # the lifecycle's INTERRUPTIBLE #sleep (NEVER Kernel.sleep) so a Ctrl-C
    # during a 15-minute beat is felt in ~1s, not 15 minutes: one interrupt
    # lets the current cycle finish and exits, a second raises the level to
    # abort.
    class Supervisor
      # "900" | "15m" | "2h" -> seconds. Anything else (including 0, which
      # would busy-loop) raises: a typo'd "15m" becoming 15s beats 900x too
      # fast, so this must fail loud, not fall back.
      def self.parse_interval(spec)
        m = /\A(\d+)(m|h)?\z/.match(spec.to_s.strip)
        secs = m && Integer(m[1], 10) * { nil => 1, "m" => 60, "h" => 3600 }[m[2]]
        raise ArgumentError, "bad --every interval #{spec.inspect} (use 900, 15m, 2h)" unless secs&.positive?

        secs
      end

      # interval: seconds between beats; nil falls back to Fleet.budget.interval
      # (the FLEET_INTERVAL global). cycle: the Fleet::Cycle runner object.
      # lifecycle: a Robur::Lifecycle (the fleet has no repo dir, so the CLI
      # builds it against Paths.fleet_log_dir). clock: injected for tests.
      def initialize(interval: nil, cycle:, lifecycle:, clock: nil)
        @interval = interval || Fleet.budget.interval
        @cycle = cycle
        @lifecycle = lifecycle
        @clock = clock
      end

      def run(out: $stdout)
        loop do
          begin
            @cycle.run
          rescue StandardError => e
            out.puts "fleet cycle raised: #{e.class}: #{e.message} — next beat in #{@interval}s"
          end
          break if @lifecycle.stop_requested?
          @lifecycle.sleep(@interval)
          break if @lifecycle.stop_requested?
        end
        0
      end
    end
  end
end
