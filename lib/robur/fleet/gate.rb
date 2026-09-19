# frozen_string_literal: true

require_relative "../fleet"
require_relative "../plan"
require_relative "../config"
require_relative "../paths"

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

      private

      # Gate OWNS the tracker path and resolves it through the conf, never a
      # literal: TRACKER_FILE is an allowlisted repo key with NO entry in
      # Config::DEFAULTS, so hardcoding PLAN.md makes a repo that renamed its
      # tracker read as 0 open forever.
      def plan
        @plan ||= Plan.new(File.join(@repo, Config.load(@repo).values["TRACKER_FILE"] || "PLAN.md"))
      end
    end
  end
end
