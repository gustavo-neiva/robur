# frozen_string_literal: true

module Robur
  # Per-task attempt ceiling, keyed by task id, for the life of ONE run.
  # Unlike ModelHealth (whose bench/strike state reset_all deliberately
  # clears every all-benched cycle) and ProgressGuard (whose stall count an
  # occasional committed turn resets), this counter is monotonic: nothing in
  # the loop's control flow may clear it.
  #
  # Production case (T7.1, 2026-09-02): MAX_TRANSIENT benches a model, the
  # chain rotates, all models end up benched, the backoff ladder fires,
  # reset_all clears ModelHealth's strikes, and the identical cycle repeats
  # on the SAME task — 1,296 turns over 10 hours, 1,099 of them classified
  # "transient". Nothing upstream of this class was monotonic; this is.
  class TaskAttempts
    def initialize(ceiling)
      @ceiling = ceiling
      @counts = Hash.new(0)
    end

    # Record one attempt on task_id (a turn actually dispatched against it);
    # returns true once that attempt pushes the count past the ceiling.
    def attempt!(task_id)
      @counts[task_id] += 1
      exceeded?(task_id)
    end

    def count(task_id)
      @counts[task_id]
    end

    def exceeded?(task_id)
      @counts[task_id] > @ceiling
    end
  end
end
