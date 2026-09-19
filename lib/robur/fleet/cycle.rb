# frozen_string_literal: true

require "fileutils"
require "rbconfig"

require_relative "../paths"
require_relative "../sys"
require_relative "gate"
require_relative "planner"

module Robur
  module Fleet
    # Executes a planner's cycle_plan (PLAN.fleet.md M3): it makes no
    # decisions of its own — the ONE decision path is Planner (constraint 5).
    # A separate process is still the right isolation boundary (one repo
    # crashing must not take the fleet down), but the child binary is
    # RESOLVED, never SEARCHED (constraint 6): shelling out to the bare name
    # `robur` gave three multi-day outages (2026-09-04..07) where launchd's
    # PATH resolved the shebang to system Ruby 2.6, and each was wrongly
    # charged to every repo as a run failure.
    class Cycle
      # The program is built from the LIVE process, not $0/$PROGRAM_NAME:
      # those differ under symlinks, binstubs and shims. This exact
      # expression is the one line design constraint 6 rests on.
      EXE = File.expand_path("../../../exe/robur", __dir__)

      # `system` returns NIL when the child never started and FALSE when it
      # ran and failed; only the nil case maps to the distinct sentinel
      # :spawn_error (T3.3 must not charge an environment fault to a repo).
      DEFAULT_SPAWNER = lambda do |argv|
        ran = system(*argv)
        ran.nil? ? nil : $?.exitstatus
      end

      # The Cycle holds the PLANNER's base, not a planner: both run passes
      # build their own fresh Planner (T3.4) so every pass re-reads the world
      # through the gate factory — a lambda that news a Gate per call, never
      # a cached verdict. spawner and notifier are injected so no test ever
      # launches a real turn or spawns NOTIFY_CMD.
      def initialize(roster:, gate_for:, budget:, clock:, paused: false,
                     spawner: DEFAULT_SPAWNER, lock: Lock,
                     notifier: nil, http: nil, out: $stdout)
        @roster = roster
        @gate_for = gate_for
        @budget = budget
        @clock = clock
        @paused = paused
        @spawner = spawner
        @lock = lock
        @notifier = notifier
        @http = http || Sys::Http.new
        @out = out
        @status = 0
        @human_skipped = []
        @lock_skipped = []
      end

      # Launch one child turn for repo as
      # [RbConfig.ruby, EXE, *argv] — interpreter and program from this
      # process, never a name lookup. Returns the child's exit status, or
      # the sentinel :spawn_error when it could not be started at all.
      def spawn(repo, *argv)
        status = @spawner.([RbConfig.ruby, EXE, *argv])
        status.nil? ? :spawn_error : status
      end

      attr_reader :status, :human_skipped

      # The outcome policy (ported from harbor runner._run_repo): the
      # stop_reason the child left behind decides the repo's ladder.
      #   done          -> clear the backoff
      #   human_blocked -> repo is off for the rest of the cycle + notify
      #   stopped       -> neither bump nor clear: a human ran `robur stop`,
      #                    that is an instruction, not a failure — backing
      #                    off for it silently costs the next beat too
      #   gate_red / progress_stalled / review_exceeded -> bump
      #   anything else -> a real nonzero exit bumps; exit 0 changes nothing
      #   :spawn_error  -> bump NOTHING and fail the whole cycle loudly: a
      #                    child that never started is a property of this
      #                    machine, not of any repo
      # Returns one of :environment, :skipped, :cleared, :bumped, :no_change.
      def record_outcome(repo, exit_status)
        return fail_cycle(repo) if exit_status == :spawn_error

        reason = Gate.new(repo).stop_reason
        # human_blocked is deliberately NOT gated on a zero exit: the loop
        # itself exits 1 for it, so reason must win over exit status here.
        case reason
        when "human_blocked"
          @human_skipped << repo
          notify(repo, "human_blocked", "#{repo}: blocked on a human answer — off for this cycle")
          :skipped
        when "done", "stopped"
          # Trusted only on exit 0 — the loop exits 0 for exactly these, so
          # a real nonzero exit means the reason on disk is stale or merely
          # Gate's derived fallback, and the crash must bump, never clear
          # (a derived "done") and never cost nothing (a derived "stopped").
          if exit_status.zero?
            reason == "done" && Backoff.new(repo).clear! ? :cleared : :no_change
          else
            bump(repo)
          end
        when "gate_red"
          notify(repo, "gate_red", "#{repo}: gate red — backing off")
          bump(repo)
        when "progress_stalled", "review_exceeded"
          bump(repo)
        else
          # Unknown reason (stale "running" after a kill, "crashed"):
          # exit 0 changes nothing, a real nonzero exit bumps.
          exit_status.zero? ? :no_change : bump(repo)
        end
      end

      # The cycle (T3.4), in harbor's load-bearing order: run pass, plan
      # top-up, run pass AGAIN. EXACTLY two run passes, never three — a plan
      # turn only ADDS tasks, so a third finds nothing a second could not.
      # The second pass is a NEW Planner over the same roster and budget with
      # `already_ran:` set to the pass-one runs (the planner reads that as
      # :skip :once_per_cycle); its fresh gates see the tasks the plan turns
      # added. Returns 0 when every child exited 0, else the LAST nonzero
      # status.
      def run
        ping_start
        first = planner_for.cycle_plan
        ran = []
        first[:runs].each { |d| ran << d.repo if run_repo(d.repo, "run", d.repo) }
        first[:plans].each { |d| run_plan(d.repo) }
        planner_for(already_ran: ran).cycle_plan[:runs].each do |d|
          next if @lock_skipped.include?(d.repo)

          run_repo(d.repo, "run", d.repo)
        end
        ping_end
        @status
      end

      private

      # T5.2 dead-man pair, ported from harbor runner.run_cycle: /start FIRST
      # thing (before the pause check — a deliberate pause is not a dead
      # schedule), then the bare URL closes the pair on a green cycle and
      # /fail on a red one. The pair is the point: a start-only ping cannot
      # tell a healthy cycle from one that HANGS. A failed ping is logged and
      # never fails the cycle — losing the watcher must not become the outage.
      def ping_start
        url = @budget.healthcheck_url
        if url.to_s.empty?
          # Not a routine line: 2026-09-05..07 harbor ran blind for two days
          # because this switch was silently off after a path change, and the
          # switch was the only thing watching.
          @out.puts "WARNING: HEALTHCHECK_URL unset (set it in #{Paths.global_conf} or ENV) — "\
                    "dead-man switch OFF; a hung or failing fleet cycle cannot alert anyone"
          return
        end
        ping("#{url}/start", "healthcheck /start pinged (schedule alive)")
      end

      def ping_end
        url = @budget.healthcheck_url
        return if url.to_s.empty?

        green = @status.zero?
        ping(green ? url : "#{url}/fail",
             green ? "healthcheck pinged (cycle green)" : "healthcheck /fail pinged (cycle red)")
      end

      def ping(url, ok_msg)
        @http.get(url)
        @out.puts ok_msg
      rescue StandardError => e
        @out.puts "WARN: healthcheck ping failed (#{e.class}: #{e.message}) — cycle outcome unaffected"
      end

      # T3.5: the autoplan stamp is written only after a spawn that
      # happened — a lock-skipped (or raising) repo never spawns, so it
      # keeps its next rate-limit window. :spawn_error returns the sentinel,
      # not an Integer, so an environment fault stamps nothing either. An
      # empty plan (still 0 open after the turn) is a CORRECT outcome for a
      # caught-up repo: log it plainly, touch nothing else — record_outcome
      # already leaves exit 0 unbumped.
      def run_plan(repo)
        status = run_repo(repo, "plan", "--auto", repo)
        return unless status.is_a?(Integer)

        path = State.state_path(repo, "autoplan.stamp")
        FileUtils.mkdir_p(File.dirname(path))
        FileUtils.touch(path)
        @out.puts "#{repo}: plan produced no open tasks — caught up" if Gate.new(repo).open_tasks.zero?
      end

      # A fresh Planner per pass: decisions come from the ONE decision path
      # (design constraint 5); the second instance only carries the set.
      def planner_for(already_ran: [])
        Planner.new(roster: @roster, gate_for: @gate_for, budget: @budget,
                    clock: @clock, paused: @paused, already_ran: already_ran)
      end

      # One repo, one lease, one child. A nil lease means someone else owns
      # the checkout: log the holder pid and skip the repo FOR THE CYCLE
      # (the set also filters the second run pass — harbor kept the same
      # lock_skipped set). The lease is released in an ensure, always. A
      # raise in one repo is recorded as a failure (@status = 1) and the
      # cycle carries on. Returns the child's status (Integer or
      # :spawn_error), or nil when the repo was skipped.
      def run_repo(repo, *argv)
        lease = @lock.acquire(repo)
        unless lease
          @lock_skipped << repo
          @out.puts "#{repo}: lock held by pid #{@lock.holder_pid(repo) || '?'} — skipped for this cycle"
          return nil
        end
        begin
          status = spawn(repo, *argv)
          @status = status if status.is_a?(Integer) && !status.zero?
          record_outcome(repo, status)
          status
        rescue StandardError => e
          @status = 1
          @out.puts "ERROR: #{repo}: #{e.class}: #{e.message} — recorded as a failure, cycle continues"
          nil
        ensure
          lease.release
        end
      end

      def bump(repo)
        Backoff.new(repo).bump!
        :bumped
      end

      # T5.3: the dedupe key is "<task_id>\t<reason>" — a new task or a new
      # reason must always notify (Notifier holds the 24h half). "?" matches
      # Gate's missing-id shape.
      def notify(repo, reason, msg)
        task_id = State.read_last_task(repo)&.first || "?"
        @notifier&.notify_once(repo, "#{task_id}\t#{reason}", msg)
      end

      # A child that never started is this machine's fault (missing
      # interpreter or exe): charged to no repo's ladder, and loud.
      def fail_cycle(repo)
        @status = 1
        @out.puts "FATAL: #{repo}: child never started (:spawn_error) — "\
                  "environment fault, cycle failed, no repo backed off"
        :environment
      end
    end
  end
end
