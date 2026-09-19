# frozen_string_literal: true

require_relative "../fleet"
require_relative "../plan"
require_relative "../config"
require_relative "../paths"
require_relative "../state"

module Robur
  module Fleet
    # One repo's verdict inputs: PURE reads, no decisions, no writes.
    class Gate
      def initialize(repo)
        @repo = repo
      end

      def initialized? = File.file?(Paths.repo_conf(@repo))

      # open + IN PROGRESS. Counting `[ ]` alone is the divergence that made
      # harbor's board report `0 open` for repos its own runner considered
      # runnable (../harbor/harbor/loop/tracker.py:5).
      def open_tasks = plan.counts[:open] + plan.counts[:in_progress]

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

      private

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
