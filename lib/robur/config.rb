# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

require_relative "paths"

module Robur
  # Config resolution: repo .robur.conf + global ~/.robur/conf (both fall
  # back to their legacy .ratchet names — see Robur::Paths).
  #
  # TRUST BOUNDARY (recorded here and in AGENTS.md):
  # - The repo .robur.conf is NEVER evaluated — only parsed against the
  #   allowlist. Reason: the loop later `eval`s VERIFY_CMD and an autonomous
  #   agent can write repo files; if this file were sourced, anything landing
  #   in the repo could execute arbitrary code outside any agent permission
  #   model. Unknown keys are errors (doctor), never assigned.
  # - The global ~/.robur/conf is trusted exactly as much as it is in the
  #   bash ratchet today: it is human-owned, not agent-writable, and it is
  #   bash-SOURCED. It contains shell expansion (`export PATH="$ASDF_DATA_DIR/shims:$PATH"`),
  #   so robur consumes it by running bash once for a baseline (env + declared
  #   variables) and once after sourcing the file, then taking the delta:
  #   exported variables become the environment handed to spawned turns,
  #   plain assignments become config values.
  module Config
    # The complete allowlist — frozen contract (ratchet/lib/contract.sh).
    ALLOWLIST = %w[
      MODELS TURN_TIMEOUT STALL_TIMEOUT SHORT_SLEEP MAX_TRANSIENT COOLDOWN BOTH_WAIT
      STEP_TOKEN DONE_TOKEN AGENT_CMD COMMIT_EACH_TURN COMMIT_VERIFY_GATE VERIFY_CMD
      PUSH_ON_DONE OPEN_PR APPROVE_UI COMMIT_EXCLUDE_GLOBS ALLOWED_PROVIDERS THINKING
      RESUME_SESSION CACHE_RETENTION SANITIZE_THINKING QUIET TAIL_LINES HEARTBEAT
      STREAM_AGENT TRACKER_FILE ROBUR_PROTOCOL RATCHET_PROTOCOL PLAN_MODELS BUILD_MODELS LIGHT_MODELS
      THINKING_PLAN THINKING_BUILD THINKING_LIGHT FANOUT REQUIRED_TOOLS REVIEW_MODELS
      THINKING_REVIEW AUTOPLAN_MODELS THINKING_AUTOPLAN
      MODEL_RANK MAX_REVIEW_CYCLES PR_CADENCE MERGE_POLL_SECS
      MERGE_WAIT_TIMEOUT PR_SOFT_MAX_LINES PARALLEL FANOUT_MAX MAX_TASK_ATTEMPTS
    ].freeze

    # Keys that reach robur ONLY through the process environment, and that a
    # repo conf may never set — they are deliberately absent from ALLOWLIST
    # above, so parse_repo rejects them with a doctor error.
    #
    # They need bridging because nothing in the chain puts the global conf in
    # this process's environment. `load_global` sources it in a SUBPROCESS and
    # diffs snapshots, so not even an `export` in that file reaches the parent
    # Ruby; and the bash `money-loop.sh` that used to source the conf before
    # exec'ing ratchet was ported into harbor's in-process runner, which spawns
    # `robur` with an inherited env nobody seeded. Measured 2026-09-06:
    # NOTIFY_CMD present in load_global's `values`, nil in `ENV` — so all
    # eleven `notify_human` call sites returned early and the loop had never
    # once been able to ask for help.
    #
    # Bridging only from load_global's own result keeps the security property
    # in `Observability#notify_human` intact: the value can come from the
    # trusted, shell-sourced global conf and from nowhere else.
    GLOBAL_ONLY_ENV = %w[NOTIFY_CMD].freeze

    NUMERIC_KEYS = %w[
      TURN_TIMEOUT STALL_TIMEOUT SHORT_SLEEP MAX_TRANSIENT COOLDOWN BOTH_WAIT TAIL_LINES
      HEARTBEAT COMMIT_EACH_TURN COMMIT_VERIFY_GATE PUSH_ON_DONE OPEN_PR APPROVE_UI
      RESUME_SESSION SANITIZE_THINKING QUIET STREAM_AGENT ROBUR_PROTOCOL RATCHET_PROTOCOL
      MAX_REVIEW_CYCLES MERGE_POLL_SECS MERGE_WAIT_TIMEOUT PR_SOFT_MAX_LINES PARALLEL
      FANOUT_MAX MAX_TASK_ATTEMPTS
    ].freeze

    # Neutral built-in defaults, ported from ratchet/lib/common.sh. Each default
    # is declared exactly ONCE here; no call site carries an inline fallback.
    # VERIFY_CMD defaults EMPTY so a missing gate is a loud warning, never a
    # silent skip. Runtime slots the bash arg parser fills (REPO_DIR, LOOP_LOG,
    # COMMAND…) are not config and live elsewhere.
    DEFAULTS = {
      "MODELS" => "",
      "TURN_TIMEOUT" => "1800",
      "STALL_TIMEOUT" => "120",
      "SHORT_SLEEP" => "2",
      "POLL_INTERVAL" => "3",
      "MAX_TRANSIENT" => "3",
      "MAX_DONE_GATE_FAILS" => "3",
      # Per-task attempt ceiling, for the life of ONE run, that nothing else
      # (reset_all, the all-benched backoff ladder, a model-chain rotation)
      # can clear. Production case (T7.1, 2026-09-02): MAX_TRANSIENT benches
      # a model, the chain rotates, all-benched triggers the ladder,
      # reset_all clears strikes, and the identical cycle restarts —
      # 1,296 turns over 10 hours on ONE task, 1,099 of them "transient".
      "MAX_TASK_ATTEMPTS" => "20",
      "PR_SOFT_MAX_LINES" => "400",
      "COOLDOWN" => "14400",
      "BOTH_WAIT" => "14400",
      "STEP_TOKEN" => "STEP_COMPLETE",
      "DONE_TOKEN" => "ALL_DONE",
      "HUMAN_TOKEN" => "HUMAN_BLOCKED",
      "AGENT_CMD" => "pi",
      "COMMIT_EACH_TURN" => "1",
      "COMMIT_VERIFY_GATE" => "1",
      "VERIFY_CMD" => "",
      "PUSH_ON_DONE" => "0",
      "OPEN_PR" => "0",
      "APPROVE_UI" => "0",
      "COMMIT_EXCLUDE_GLOBS" => "",
      "ALLOWED_PROVIDERS" => "",
      "THINKING" => "",
      "MODEL_RANK" => "",
      "PLAN_MODELS" => "",
      "BUILD_MODELS" => "",
      "LIGHT_MODELS" => "",
      "THINKING_PLAN" => "",
      "THINKING_BUILD" => "",
      "THINKING_LIGHT" => "",
      "REVIEW_MODELS" => "",
      "THINKING_REVIEW" => "",
      "AUTOPLAN_MODELS" => "",
      "THINKING_AUTOPLAN" => "",
      "AUTO_PLAN" => "0",
      "FANOUT" => "",
      "PARALLEL" => "0",
      "FANOUT_MAX" => "4",
      "RESUME_SESSION" => "0",
      "CACHE_RETENTION" => "long",
      "SANITIZE_THINKING" => "1",
      "QUIET" => "0",
      "CHEAP_MODE" => "0",
      "TAIL_LINES" => "12",
      "SUMMARY_LINES" => "4",
      "HEARTBEAT" => "15",
      "STREAM_AGENT" => "0"
    }.freeze

    module_function

    def key_allowed?(key)
      return true if ALLOWLIST.include?(key)
      # COOLDOWN_<PROVIDER> per-provider overrides are allowed by prefix.
      key =~ /\ACOOLDOWN_[A-Z0-9]/
    end

# conf_hash port (ratchet/lib/contract.sh): SHA-256 hex of the file, or
    # the literal 'none' when the file is missing. Doctor pins this against
    # .ratchet/conf.hash so repo-contract tampering is detected.
    def conf_hash(path)
      return "none" unless File.file?(path)
      Digest::SHA256.file(path).hexdigest
    end

    def read_conf_hash(repo_dir)
      File.read(Paths.state_file(repo_dir, "conf.hash")).strip
    end

    # One-line format, identical to `conf_hash "$repo/.ratchet.conf" > .ratchet/conf.hash`.
    def write_conf_hash(repo_dir)
      Paths.ensure_state_dir!(repo_dir)
      File.write(Paths.state_file(repo_dir, "conf.hash"), "#{conf_hash(Paths.repo_conf(repo_dir))}\n")
    end

    def numeric?(key)
      NUMERIC_KEYS.include?(key) || key =~ /\ACOOLDOWN_[A-Z0-9]/
    end

    # parse_repo_conf port: returns [values(hash of String=>String), errors(array)].
    # Byte-compatible with the bash parser: truncate at the first '#', skip
    # space-only lines, require an uppercase/underscore first char before '=',
    # strip ONE layer of matching surrounding quotes, coerce numeric keys.
    def parse_repo(text)
      values = {}
      errors = []
      text.each_line(chomp: true).with_index(1) do |raw, lineno|
        line = raw.include?("#") ? raw[0, raw.index("#")] : raw
        next if line.delete(" ").empty?
        if line =~ /\A([A-Z_][^=]*)=(.*)\z/m
          key = Regexp.last_match(1)
          val = Regexp.last_match(2)
          unless key_allowed?(key)
            errors << "  line #{lineno}: unknown key '#{key}' (not in allowlist)"
            next
          end
          if val.length >= 2 && %w[" '].include?(val[0]) && val.end_with?(val[0])
            val = val[1..-2]
          end
          val = val.gsub(/[^0-9]/, "").tap { |v| v.replace("0") if v.empty? } if numeric?(key)
          values[key] = val
        else
          errors << "  line #{lineno}: not a KEY=value line: '#{line}'"
        end
      end
      [values, errors]
    end

    # Snapshot of env (NUL-separated k=v) and all shell variables.
    SNAPSHOT = 'env -0; printf "\0--V--\0"; for k in $(compgen -A variable); do printf "%s=%s\0" "$k" "${!k}"; done'

    def snapshot
      out, = Open3.capture3("bash", "-c", SNAPSHOT)
      env, vars = out.split("\0--V--\0", 2).map { |seg| parse_pairs(seg) }
      [env, vars]
    end

    def parse_pairs(blob)
      blob.split("\0").reject(&:empty?).each_with_object({}) do |pair, h|
        k, v = pair.split("=", 2)
        h[k] = v
      end
    end

    # Sources the global conf via bash and returns { values:, env:, errors: }.
    def load_global(path)
      # one bash process for both snapshots, so SHLVL-style per-process noise never shows up as a delta
      script = %(#{SNAPSHOT}; printf "\\0--S--\\0"; . "$1"; printf "\\0--S--\\0"; #{SNAPSHOT})
      out, err, _st = Open3.capture3("bash", "-c", script, "ratchet", path)
      return { values: {}, env: {}, errors: [err.strip] } unless err.strip.empty?
      before_env, before_vars, after_env, after_vars =
        out.split("\0--S--\0").flat_map { |seg| seg.split("\0--V--\0", 2).map { |s| parse_pairs(s) } }
      env = after_env.select { |k, v| before_env[k] != v }
      values = after_vars.select { |k, v| before_vars[k] != v }
      { values: values, env: env, errors: [] }
    end

    Result = Struct.new(:values, :env, :errors)

    # Put GLOBAL_ONLY_ENV keys from the trusted global conf into this process's
    # ENV, so `export FOO=` and plain `FOO=` behave the same — both are the
    # same human-owned, shell-sourced file. An inherited value wins: if the
    # operator already exported it in the launching shell, that is the more
    # immediate intent and is left alone.
    def bridge_global_env!(global)
      GLOBAL_ONLY_ENV.each do |k|
        next unless ENV[k].to_s.empty?

        v = global[:env][k] || global[:values][k]
        ENV[k] = v unless v.to_s.empty?
      end
    end

    # Full resolution: CLI flags > repo conf (parsed) > global conf (sourced,
    # trusted) > defaults. `cli` is a hash of already-validated flag values.
    def load(repo_dir, cli = {})
      values, env, errors = DEFAULTS.dup, {}, []
      if File.file?(Paths.global_conf)
        g = load_global(Paths.global_conf)
        values.update(g[:values])
        env.update(g[:env])
        errors.concat(g[:errors])
        bridge_global_env!(g)
      end
      repo = Paths.repo_conf(repo_dir)
      if File.file?(repo)
        rv, rerrors = parse_repo(File.read(repo))
        values.update(rv)
        errors.concat(rerrors)
      end
      values.update(cli)
      Result.new(values, env, errors)
    end
  end
end
