# frozen_string_literal: true

require_relative "../fleet"
require_relative "../plan"
require_relative "../config"
require_relative "../paths"
require_relative "../state"
require_relative "backoff"

module Robur
  module Fleet
    # One repo's verdict inputs: PURE reads, no decisions, no writes.
    class Gate
      REASONS = { no_conf: "not robur-initialized", caught_up: "no open tasks",
                  backoff: "backed off after a failure",
                  human_block: "waiting on a human answer",
                  class_gate: "HUMAN plan awaiting approval",
                  runnable: "ready to run" }.freeze
      def initialize(repo)
        @repo = repo
      end

      def initialized? = File.file?(Paths.repo_conf(@repo))

      # open + IN PROGRESS. Counting `[ ]` alone is the divergence that made
      # harbor's board report `0 open` for repos its own runner considered
      # runnable (../harbor/harbor/loop/tracker.py:5).
      def open_tasks = plan.counts[:open] + plan.counts[:in_progress]

      # A caught-up repo is autoplan-eligible only if it has a tracker to
      # top up (T2.2); a missing tracker counts 0 open and would otherwise
      # read as caught-up.
      def tracker? = File.file?(tracker_path)

      # Per-repo autoplan rate limit (T2.2): due when no stamp exists (never
      # planned) or the stamp is at least min_secs old at `now`. Reads mtime
      # so the planner stays pure; the stamp is WRITTEN only after a real
      # plan turn (T3.5) — stamping at decision time would rate-limit
      # nothing.
      def autoplan_due?(min_secs, now)
        path = State.state_path(@repo, "autoplan.stamp")
        return true unless File.file?(path)

        now - File.mtime(path) >= min_secs
      end

      # A human_blocked stop_reason is per-run state: re-checked against the
      # tracker every beat or a 15-minute loop re-fires the same unanswered
      # question forever (harbor measured 246 re-runs from one question).
      # Blocked only while the task is still dispatchable — a `[HUMAN]` parked
      # or `[x]` done line clears the block with no unblock command to
      # remember. Missing or "?" task id means still blocked.
      def human_blocked?
        return false unless State.read_stop_reason(@repo) == "human_blocked"

        task_id = State.read_last_task(@repo)&.first
        return true if task_id.nil? || task_id == "?"

        re = %r{^\s*- \[( |IN PROGRESS)\] #{Regexp.escape(task_id)}( |$)}
        return false unless File.file?(tracker_path)

        File.foreach(tracker_path) { |line| return true if line =~ re }
        false
      end

      # A class HUMAN plan runs only after a human approves it: money,
      # strategy or outward-facing work must not run unattended. Marker is
      # read by Plan#class_marker (first line only — prose never gates); a
      # MACHINE marker or no marker is not gated. Approval is a marker file
      # the human (or the parked-task turn) drops in .robur/.
      def class_gated? = plan.class_marker&.upcase == "HUMAN" && !approved?

      # One reason, most actionable first: backoff beats class_gate because
      # backoff expires on its own while an approval cannot (task T1.4).
      def verdict
        return :no_conf unless initialized?
        return :caught_up if open_tasks.zero?
        return :backoff if Backoff.new(@repo).active?
        return :human_block if human_blocked?
        return :class_gate if class_gated?

        :runnable
      end

      # The loop's own last word, or a derived fallback when it never ran.
      def stop_reason
        State.read_stop_reason(@repo) || (open_tasks.zero? ? "done" : "stopped")
      end

      private

      def approved? = File.file?(State.state_path(@repo, "plan-approved"))

      # Gate OWNS the tracker path and resolves it through the conf, never a
      # literal: TRACKER_FILE is an allowlisted repo key with NO entry in
      # Config::DEFAULTS, so hardcoding PLAN.md makes a repo that renamed its
      # tracker read as 0 open forever.
      def tracker_path
        @tracker_path ||= File.join(@repo, Config.load(@repo).values["TRACKER_FILE"] || "PLAN.md")
      end

      def plan
        @plan ||= Plan.new(tracker_path)
      end
    end
  end
end
