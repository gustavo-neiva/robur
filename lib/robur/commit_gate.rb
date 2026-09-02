# frozen_string_literal: true

require "robur/repo"
require "robur/sys"

module Robur
  # The loop owns the commit, so a turn can never land red even if the agent
  # forgets to commit (port of ratchet/lib/commit-gate.sh). Ordering is load
  # bearing: stage everything so the gate scans the actual proposed commit,
  # THEN un-stage runtime junk and .ratchet.conf, THEN secret-scan, THEN the
  # hard VERIFY_CMD gate, THEN the idempotent-turn skip, THEN one commit.
  class CommitGate
    Result = Struct.new(:committed, :block_reason, :verify_cmd_empty, keyword_init: true)

    ALLOW_MARKER = "ratchet:allow-secret"

    # [pattern, reason], checked in this exact order (bash's elif chain).
    SECRET_CHECKS = [
      [/-----BEGIN ((RSA|EC|OPENSSH|DSA) )?PRIVATE KEY-----/i, "private key material in staged diff"],
      [/(^|[^A-Za-z0-9])(AKIA[0-9A-Z]{16})([^A-Za-z0-9]|$)/i, "AWS access key id in staged diff"],
      [/(sk-ant-[A-Za-z0-9_-]{20,})|(sk-[A-Za-z0-9]{20,})/i, "API key (sk-/sk-ant-) in staged diff"],
      [%r{(api[_-]?key|secret|passwd|password|token)["' ]*[:=][ ]*["' ]?[A-Za-z0-9/_+-]{16,}}i,
       "likely secret assignment in staged diff"],
      [/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, "JWT in staged diff"],
    ].freeze

    # emit: optional CLI-owned logger (Observability's rendered-line home is
    # loop.log, but commit-gate.sh's own lines aren't in Observability::RENDER
    # — they're CLI prose, same as bash's inline `emit` calls). loop_log: where
    # to tail a failed VERIFY_CMD's last 40 lines raw (bash: no timestamp).
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
    def run(turn:, model:)
      clean_skip = Result.new(committed: false, block_reason: nil, verify_cmd_empty: false)
      return clean_skip unless @config["COMMIT_EACH_TURN"] == "1"
      return clean_skip unless File.directory?(File.join(@dir, ".git"))

      @repo.add_all
      exclude_globs.each { |g| @repo.reset(g) }
      @repo.reset(".ratchet.conf")

      reason = secret_scan
      if reason
        @emit.call("  BLOCKED: secret scan — #{reason} — NOT committing.")
        @emit.call("  (install gitleaks for richer coverage; this is the builtin pattern check.)")
        return Result.new(committed: false, block_reason: reason, verify_cmd_empty: false)
      end

      verify_cmd_empty = false
      if @config["COMMIT_VERIFY_GATE"] == "1"
        verify_cmd = @config["VERIFY_CMD"]
        if verify_cmd.nil? || verify_cmd.empty?
          verify_cmd_empty = true
          @emit.call("  \e[31mWARNING: VERIFY_CMD is empty — committing with NO green gate " \
                     "(no-gate is loud by design; set VERIFY_CMD in .ratchet.conf).\e[0m")
        else
          @emit.call("  commit gate: running '#{verify_cmd}' \u2026")
          out, err, status = @proc.capture(verify_cmd, chdir: @dir)
          unless status&.success?
            @emit.call("  commit gate RED — NOT committing; leaving work for next turn to repair.")
            tail_into_log("#{out}#{err}")
            return Result.new(committed: false, block_reason: "commit gate RED", verify_cmd_empty: false)
          end
        end
      end

      if @repo.staged_diff.empty?
        @emit.call("  nothing staged to commit (idempotent turn).")
        return Result.new(committed: false, block_reason: nil, verify_cmd_empty: verify_cmd_empty)
      end

      subject = @plan.completed_subject
      committed = @repo.commit("auto(ratchet): turn #{turn} #{model} \u2014 #{subject}",
                                "Autonomous loop turn #{turn}. verify: green.")
      if committed
        @emit.call("  committed: #{subject}")
      else
        @emit.call("  git commit failed (see #{@loop_log}) — continuing.")
      end
      Result.new(committed: committed, block_reason: nil, verify_cmd_empty: verify_cmd_empty)
    end

    private

    # Raw append, no timestamp — matches bash's `tail -n 40 "$_vout" >>"$LOOP_LOG"`.
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
                   .reject { |l| l.include?(ALLOW_MARKER) }
      return nil if lines.empty?

      SECRET_CHECKS.each do |pattern, reason|
        return reason if lines.any? { |l| l.match?(pattern) }
      end

      return ".env file staged" if @repo.staged_files.any? { |f| f =~ %r{(^|/)\.env(\.|$)} }

      nil
    end
  end
end
