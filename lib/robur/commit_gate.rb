# frozen_string_literal: true

require "robur/paths"
require "robur/repo"
require "robur/sys"

module Robur
  # The loop owns the commit, so a turn can never land red even if the agent
  # forgets to commit. Ordering is load bearing: stage everything so the gate
  # scans the actual proposed commit, THEN un-stage runtime junk and the repo
  # conf, THEN the idempotent-turn skip (moved AHEAD of the gates, see #run), THEN
  # the tracker zero-task sanity check, THEN secret-scan, THEN the hard
  # VERIFY_CMD gate, THEN one commit.
  class CommitGate
    Result = Struct.new(:committed, :block_reason, :verify_cmd_empty, keyword_init: true)

    # An inline marker on a `+` line opts that line out of the secret scan.
    # The pre-rename spelling is still honoured so existing suppressions in
    # real repos keep working.
    ALLOW_MARKER = "robur:allow-secret"
    LEGACY_ALLOW_MARKER = "ratchet:allow-secret"

    # [pattern, reason], checked in this exact order — first hit wins, so the
    # most specific patterns come first.
    SECRET_CHECKS = [
      [/-----BEGIN ((RSA|EC|OPENSSH|DSA) )?PRIVATE KEY-----/i, "private key material in staged diff"],
      [/(^|[^A-Za-z0-9])(AKIA[0-9A-Z]{16})([^A-Za-z0-9]|$)/i, "AWS access key id in staged diff"],
      [/(sk-ant-[A-Za-z0-9_-]{20,})|(sk-[A-Za-z0-9]{20,})/i, "API key (sk-/sk-ant-) in staged diff"],
      [%r{(api[_-]?key|secret|passwd|password|token)["' ]*[:=][ ]*["' ]?[A-Za-z0-9/_+-]{16,}}i,
       "likely secret assignment in staged diff"],
      [/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, "JWT in staged diff"],
    ].freeze

    # emit: optional CLI-owned logger. The gate's lines are CLI prose, not
    # Observability::RENDER events, so they go through the injected sink.
    # loop_log: where to tail a failed VERIFY_CMD's last 40 lines, raw and
    # untimestamped so the output is still copy-pasteable.
    def initialize(dir, plan:, config:, repo: Repo.new(dir), proc: Sys::Proc.new,
                   emit: ->(_msg) {}, loop_log: nil)
      @dir = dir
      @plan = plan
      @config = config
      @repo = repo
      @proc = proc
      @emit = emit
      @loop_log = loop_log
    end

    # committed: true means one commit landed. block_reason set means the
    # turn needs repair (secret hit or a red VERIFY_CMD) — never a clean
    # success. committed false + block_reason nil is a clean no-op skip
    # (COMMIT_EACH_TURN off, no git repo, or nothing staged).
    #
    # task: the Task the loop dispatched this turn, passed through to
    # Plan#completed_task so a turn that staged no tracker diff still commits
    # under its own title instead of an unrelated task's.
    def run(turn:, model:, task: nil)
      clean_skip = Result.new(committed: false, block_reason: nil, verify_cmd_empty: false)
      return clean_skip unless @config["COMMIT_EACH_TURN"] == "1"
      return clean_skip unless File.directory?(File.join(@dir, ".git"))

      @repo.add_all
      exclude_globs.each { |g| @repo.reset(g) }
      @repo.reset(Paths::REPO_CONF)
      @repo.reset(Paths::LEGACY_REPO_CONF)

      # Nothing staged ⇒ nothing to scan or verify, so check BEFORE the secret
      # scan and the VERIFY_CMD gate. This ordering is deliberate: this repo's
      # VERIFY_CMD is the full test suite (measured 36.5s) and 66% of turns
      # stage nothing, so gating first would re-verify an unchanged tree for
      # most of a run. Skipping cannot change the outcome of a turn that DOES
      # stage (those still run every gate below). Verify never runs on this
      # path, so verify_cmd_empty stays false.
      if @repo.staged_diff.empty?
        @emit.call("  nothing staged to commit (idempotent turn).")
        return Result.new(committed: false, block_reason: nil, verify_cmd_empty: false)
      end

      # Tracker sanity: a STAGED tracker that parses to zero tasks looks
      # corrupt — a real "[IN PROGRESS" bracket-drop once made a task
      # invisible forever. Checked against the working tree (add_all just made
      # staged == working tree). Deliberate choice: skipped when @plan lacks
      # #counts (the existing tests' bare subject-only Struct) so legacy
      # callers are unaffected.
      tracker = @config["TRACKER_FILE"] || "PLAN.md"
      if @plan.respond_to?(:counts) && @repo.staged_files.include?(tracker)
        counts = @plan.counts
        if counts[:open] + counts[:in_progress] + counts[:done] == 0
          @emit.call("  BLOCKED: tracker parsed to zero tasks — refusing commit (staged tracker looks corrupt).")
          return Result.new(committed: false, block_reason: "tracker parsed to zero tasks", verify_cmd_empty: false)
        end
      end

      reason = secret_scan
      if reason
        @emit.call("  BLOCKED: secret scan — #{reason} — NOT committing.")
        @emit.call("  (install gitleaks for richer coverage; this is the builtin pattern check.)")
        return Result.new(committed: false, block_reason: reason, verify_cmd_empty: false)
      end

      verify_cmd_empty = false
      # What the commit body will CLAIM about the gate. The body used to say
      # "verify: green." unconditionally — including on the two paths that
      # ran no gate at all, one of which had just warned about exactly that.
      # A changelog built from these commits would inherit the lie.
      gate_note = "verify: skipped (COMMIT_VERIFY_GATE off)"
      if @config["COMMIT_VERIFY_GATE"] == "1"
        gate_note = "verify: green"
        verify_cmd = @config["VERIFY_CMD"]
        if verify_cmd.nil? || verify_cmd.empty?
          verify_cmd_empty = true
          gate_note = "verify: none (VERIFY_CMD empty)"
          @emit.call("  \e[31mWARNING: VERIFY_CMD is empty — committing with NO green gate " \
                     "(no-gate is loud by design; set VERIFY_CMD in #{Paths::REPO_CONF}).\e[0m")
        else
          @emit.call("  commit gate: running '#{verify_cmd}' \u2026")
          out, err, status = @proc.spawn_with_deadline(
            verify_cmd, deadline: @config["VERIFY_TIMEOUT"].to_i, chdir: @dir
          )
          captured = "#{out}#{err}"
          # The FULL verify output goes to last_verify.out beside loop.log,
          # on pass AND fail — a chatty
          # VERIFY_CMD would otherwise flood loop.log; only the last 40 lines
          # are tailed in on RED (below).
          unless @loop_log.nil?
            File.write(File.join(File.dirname(@loop_log), "last_verify.out"), captured)
          end
          unless status&.success?
            @emit.call("  commit gate RED — NOT committing; leaving work for next turn to repair.")
            tail_into_log(captured)
            return Result.new(committed: false, block_reason: "commit gate RED", verify_cmd_empty: false)
          end
        end
      end

      # Subject is changelog-grade: `<kind>(robur): <id> <title>`. The tier
      # tags are routing metadata and are dropped; turn and model are
      # debugging data and move to the body, where they no longer eat the
      # 72-char subject budget.
      completed = @plan.completed_task(task)
      subject = completed ? "#{completed.id} #{completed.text.gsub("**", "").strip}" : "step"
      kind = completed&.kind || "auto"
      committed = @repo.commit("#{kind}(#{Paths::COMMIT_SCOPE}): #{subject}",
                                "Autonomous loop turn #{turn}. #{gate_note}.\nmodel: #{model}")
      if committed
        @emit.call("  committed: #{subject}")
      else
        @emit.call("  git commit failed (see #{@loop_log}) — continuing.")
      end
      Result.new(committed: committed, block_reason: nil, verify_cmd_empty: verify_cmd_empty)
    end

    private

    # Raw append, no timestamp: the tail must stay copy-pasteable.
    def tail_into_log(text)
      return if @loop_log.nil?

      lines = text.each_line.to_a.last(40)
      File.write(@loop_log, lines.join, mode: "a") unless lines.empty?
    end

    def exclude_globs
      (@config["COMMIT_EXCLUDE_GLOBS"] || "").split
    end

    # ADDED lines only (leading '+', excluding the '+++' file header), minus
    # any line carrying the inline allowlist marker. Zero surviving lines is
    # CLEAN, not a hit — the inverted return here once dead-locked the loop.
    def secret_scan
      lines = @repo.staged_diff.each_line(chomp: true)
                   .select { |l| l.start_with?("+") && !l.start_with?("+++ ") }
                   .reject { |l| l.include?(ALLOW_MARKER) || l.include?(LEGACY_ALLOW_MARKER) }
      return nil if lines.empty?

      SECRET_CHECKS.each do |pattern, reason|
        return reason if lines.any? { |l| l.match?(pattern) }
      end

      return ".env file staged" if @repo.staged_files.any? { |f| f =~ %r{(^|/)\.env(\.|$)} }

      nil
    end
  end
end
