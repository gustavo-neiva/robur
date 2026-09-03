# frozen_string_literal: true

module Robur
  # Counts consecutive no-progress turns (no commit AND no tracker mtime
  # change) and escalates once per stall-run. The motivating production
  # failure: one loop did 1,549 consecutive no-progress turns on a single
  # task and nothing noticed. The caller wires the returned verdicts to
  # actions (bench / context injection / task block / loop stop).
  class ProgressGuard
    attr_reader :stalls

    def initialize(tracker_path, bench_at: 3, context_at: 6, block_at: 10, stop_at: 15,
                   mtime: ->(p) { File.exist?(p) ? File.mtime(p) : nil })
      @tracker_path = tracker_path
      @bench_at = bench_at
      @context_at = context_at
      @block_at = block_at
      @stop_at = stop_at
      @mtime = mtime
      @stalls = 0
      @prev_mtime = nil
      @have_baseline = false
    end

    # -> :ok | :bench | :inject_context | :block_task | :stop
    def record(committed:)
      now = @mtime.call(@tracker_path)
      progressed = committed || (@have_baseline && now != @prev_mtime)
      @prev_mtime = now
      @have_baseline = true
      if progressed
        @stalls = 0
        return :ok
      end

      @stalls += 1
      # Severity order; thresholds are injectable, so ordering is not assumed.
      # Equality fires each threshold at most once per stall-run by construction
      # (stalls passes each value once); :stop is >= and repeats until progress.
      # If two thresholds collide on one value, the more severe wins.
      return :stop if @stalls >= @stop_at
      return :block_task if @stalls == @block_at
      return :inject_context if @stalls == @context_at
      return :bench if @stalls == @bench_at

      :ok
    end

    def reset
      @stalls = 0
    end
  end
end
