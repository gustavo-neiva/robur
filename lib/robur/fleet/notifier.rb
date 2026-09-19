# frozen_string_literal: true

require "fileutils"

require_relative "../observability"
require_relative "../paths"
require_relative "../state"

module Robur
  module Fleet
    # T5.3: a repo blocked on a human nudges DAILY, not every beat (96/day
    # at the 15-minute beat) and not once ever — harbor measured an
    # unanswered block sitting 46 hours against a 6-hour assumption because
    # the single notification scrolled away (runner.py:_notify_once). BOTH
    # halves are load-bearing: the key (`"<task_id>\t<reason>"`) makes a new
    # task or reason send at once, and RENOTIFY_SECS re-sends the same key
    # a day later. Delivery goes through Observability#notify_human —
    # NOTIFY_CMD spawns detached, never raises, never blocks the cycle —
    # this class never spawns anything itself.
    class Notifier
      RENOTIFY_SECS = 86_400

      def initialize(clock:, log_dir: Paths.fleet_log_dir)
        @clock = clock
        @obs = Observability.new(log_dir, clock: clock)
      end

      # Send MSG for REPO unless the last_notified marker already holds KEY
      # and is less than RENOTIFY_SECS old. The marker is written either
      # way, but a suppressing write must not refresh its mtime: with a
      # 15-minute beat a sliding window never expires and the daily nudge
      # would never fire.
      def notify_once(repo, key, msg)
        path = State.state_path(repo, "last_notified")
        FileUtils.mkdir_p(File.dirname(path))
        prev = File.file?(path) ? File.mtime(path) : nil
        fresh = !prev.nil? && File.read(path) == key && @clock.now - prev < RENOTIFY_SECS
        File.write(path, key)
        if fresh
          File.utime(prev, prev, path)
          return
        end

        @obs.notify_human(msg)
        nil
      end
    end
  end
end
