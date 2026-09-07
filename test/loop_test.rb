# frozen_string_literal: true

require "test_helper"
require "robur/loop"
require "robur/cli"
require "robur/paths"
require "fileutils"
require "json"

# Integration tests: the full `run` cycle against the fake-agent fixture stub.
# fake-agent ticks ONE task per invocation (python3-based, portable), which is
# exactly the done-criterion: three tasks -> three turns -> three commits.
class LoopTest < Minitest::Test
  AGENT = File.expand_path("fixtures/fake-agent", __dir__)

  def setup
    @home = Dir.mktmpdir("robur-home")
    @old_home = ENV[Robur::Paths::HOME_ENV]
    ENV[Robur::Paths::HOME_ENV] = @home
    # Without this the watchdog polls at the 3s default while fake-agent
    # finishes in ~150ms — three turns per test, ~9.5s of pure sleeping.
    # POLL_INTERVAL is an ENV knob, not a conf key: the conf ALLOWLIST is a
    # frozen contract and doctor rejects unknown keys. The read site does
    # `.to_i`, so this polls at 0 (a spin) — fine against a 150ms agent.
    @old_poll = ENV["POLL_INTERVAL"]
    ENV["POLL_INTERVAL"] = "0.1"
  end

  def teardown
    if @old_home
      ENV[Robur::Paths::HOME_ENV] = @old_home
    else
      ENV.delete(Robur::Paths::HOME_ENV)
    end
    @old_poll ? ENV["POLL_INTERVAL"] = @old_poll : ENV.delete("POLL_INTERVAL")
    # Robur::CLI.@loop_log/@quiet are module-level globals Loop.run points at
    # @home; clear them before the dir is gone or a LATER test's CLI.emit/die
    # ENOENTs writing to a deleted path.
    Robur::CLI.instance_variable_set(:@loop_log, nil)
    Robur::CLI.instance_variable_set(:@quiet, nil)
    FileUtils.rm_rf(@home)
  end

  DEFAULT_PLAN = <<~PLAN
    # Plan

    ## M1
    - [ ] T1.1 (trivial) first task
    - [ ] T1.2 (trivial) second task
    - [ ] T1.3 (trivial) third task
  PLAN

  def make_repo(extra_conf: "", plan: DEFAULT_PLAN)
    repo = Dir.mktmpdir
    File.write(File.join(repo, "PLAN.md"), plan)
    File.write(File.join(repo, Robur::Paths::REPO_CONF), <<~CONF)
      MODELS="stub/stub-1"
      AGENT_CMD="#{AGENT}"
      VERIFY_CMD="true"
      TURN_TIMEOUT="30"
      SHORT_SLEEP="0"
      QUIET="1"
      COMMIT_EACH_TURN="1"
      COMMIT_VERIFY_GATE="1"
      #{extra_conf}
    CONF
    git repo, "init", "-q"
    git repo, "add", "-A"
    git repo, "commit", "-q", "-m", "seed"
    git repo, "reset", "-q", "--", Robur::Paths::REPO_CONF
    repo
  end

  def git(repo, *args)
    Open3.capture3("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@e.c",
                   "-c", "commit.gpgsign=false", *args)
  end

  def commits(repo)
    git(repo, "log", "--format=%s")[0].lines.map(&:strip)
  end

  # T2.2: a turn killed before its commit gate leaves files staged; the next
  # run must NAME them in loop.log and leave them staged (no reset/checkout).
  def test_unclean_start_reports_staged_files_and_leaves_them
    repo = make_repo
    File.write(File.join(repo, "leftover_a.txt"), "a")
    File.write(File.join(repo, "leftover_b.txt"), "b")
    git repo, "add", "leftover_a.txt", "leftover_b.txt"

    code = Robur::Loop.run(repo, sleep_it: ->(_s) {})

    assert_equal 0, code
    log = File.read(File.join(@home, "logs", Robur::CLI.project_slug(repo), "loop.log"))
    assert_match(/2 staged file/, log)
    # still staged at report time (never reset): the first turn's commit gate
    # ingests them, so they must appear in the T1.1 commit, not vanish.
    t11_commit = git(repo, "log", "--format=%H %s")[0].lines.find { |l| l.include?("T1.1") }.split.first
    stat = git(repo, "show", "--stat", "--format=", t11_commit)[0]
    assert_includes stat, "leftover_a.txt"
    assert_includes stat, "leftover_b.txt"
    # first turn proceeded normally despite the staged leftovers
    assert commits(repo).any? { |s| s.include?("T1.1") }
  end

  # Quota kill mid-task: the partial work must survive uncommitted in the
  # tree, and last_turn.note must tell the next turn (next model, maybe next
  # RUN) the dirty tree is WIP to continue — not broken code to revert.
  def test_exhausted_turn_saves_partial_work_and_notes_quota_kill
    repo = make_repo(extra_conf: "VERIFY_CMD=\"false\"")
    ENV["FAKE_AGENT_MODE"] = "quota"

    code = Robur::Loop.run(repo, once: true, sleep_it: ->(_s) {})

    assert_equal 0, code
    assert_equal "partial work\n", File.read(File.join(repo, "partial_work.txt"))
    refute commits(repo).any? { |s| s.include?("T1.1") }
    note = File.read(File.join(@home, "logs", Robur::CLI.project_slug(repo), "last_turn.note"))
    assert_match(/quota\/rate-limit/, note)
    assert_match(/partial work/, note)
  ensure
    ENV.delete("FAKE_AGENT_MODE")
  end

  def test_run_completes_three_tasks_then_stops_done
    repo = make_repo
    code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
    assert_equal 0, code
    subjects = commits(repo) # newest first: seed is last
    assert_equal 4, subjects.size # seed + one commit per task
    assert_includes subjects[2], "T1.1"
    assert_includes subjects[1], "T1.2"
    assert_includes subjects[0], "T1.3"
    assert_equal 3, File.read(File.join(repo, "PLAN.md")).scan("[x]").size
    assert_equal "done\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))
  end

  # Regression guard for the audit's largest observability finding: NO
  # events.jsonl existed anywhere under the logs tree across 244 log
  # directories and 2,227 production turns, so every structured record the
  # Observability layer computes (tokens, gate_result, model_selected) was
  # being discarded and `stats` silently reported through the legacy
  # loop.log regex path. A real run must leave the structured log behind.
  def test_run_writes_structured_events_jsonl_alongside_loop_log
    repo = make_repo
    Robur::Loop.run(repo, sleep_it: ->(_s) {})

    log_dir = File.join(@home, "logs", Robur::CLI.project_slug(repo))
    events = File.join(log_dir, "events.jsonl")
    assert File.file?(events), "run left no events.jsonl in #{log_dir}"

    records = File.readlines(events).map { |l| JSON.parse(l) }
    kinds = records.map { |r| r["kind"] }
    assert_includes kinds, "run_start"
    assert_includes kinds, "turn_start"
    assert_includes kinds, "turn_end"
    assert_includes kinds, "tokens"
    assert_includes kinds, "run_end"

    # every record is one parseable object carrying its kind and timestamp
    records.each do |r|
      assert r["kind"], "record without kind: #{r.inspect}"
      assert_match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/, r["ts"])
    end

    # every record of this run carries the SAME run_id. (The "two sequential
    # runs get distinct run_ids" half of this regression is covered at the
    # Observability unit level — test/observability_test.rb
    # test_two_sequential_runs_in_the_same_log_dir_get_distinct_run_ids —
    # rather than by calling Loop.run twice into one repo here: loop.pid's
    # flock is released by the KERNEL on process death (loop.rb:95), so two
    # in-process Loop.run calls race the first call's file descriptor being
    # GC'd and can spuriously trip the "another loop holds the lock" guard.)
    run_ids = records.map { |r| r["run_id"] }
    refute_nil run_ids.first
    assert_equal 1, run_ids.uniq.size, "one run must not mix run_ids: #{run_ids}"
  end

  # `robur once` (cli.rb#run_once_loop) is the OTHER caller that builds an
  # Observability and must leave the same structured trail behind — it had
  # no test coverage at all before this.
  def test_once_writes_structured_events_jsonl_alongside_loop_log
    repo = make_repo
    capture_io { assert_equal 0, Robur::CLI.run(["once", "-d", repo]) }

    log_dir = File.join(@home, "logs", Robur::CLI.project_slug(repo))
    events = File.readlines(File.join(log_dir, "events.jsonl")).map { |l| JSON.parse(l) }
    kinds = events.map { |e| e["kind"] }
    assert_includes kinds, "run_start"
    assert_includes kinds, "turn_start"
    assert_includes kinds, "turn_end"
    assert_includes kinds, "run_end"

    run_ids = events.map { |e| e["run_id"] }
    refute_nil run_ids.first
    assert_equal 1, run_ids.uniq.size, "one once-run must not mix run_ids: #{run_ids}"
  ensure
    Robur::CLI.instance_variable_set(:@quiet, nil)
    Robur::CLI.instance_variable_set(:@loop_log, nil)
  end

  # Same regression as test_unexpected_exception_records_crashed_and_still_propagates,
  # for `robur once`: run_once_loop shipped with NO epilogue at all, so a
  # turn that raised (an agent crash, a bug in run_single_turn) left
  # events.jsonl holding only run_start — indistinguishable from a run that
  # never got past preflight. Audit finding: events.jsonl existed in only 2
  # of 1250 production log dirs; an unguarded --once crash is one way that
  # happens even after the file starts being written at all.
  def test_once_unexpected_exception_records_crashed_and_still_propagates
    repo = make_repo
    error = assert_raises(RuntimeError) do
      with_turn_run(->(**_kw) { raise "boom" }) do
        capture_io { Robur::CLI.run(["once", "-d", repo]) }
      end
    end
    assert_equal "boom", error.message
    assert_equal "crashed\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))

    log_dir = File.join(@home, "logs", Robur::CLI.project_slug(repo))
    events = File.readlines(File.join(log_dir, "events.jsonl")).map { |l| JSON.parse(l) }
    kinds = events.map { |e| e["kind"] }
    assert_includes kinds, "run_start"
    assert_includes kinds, "stopped"
    assert_includes kinds, "run_end"
    stopped = events.find { |e| e["kind"] == "stopped" }
    assert_equal "crashed", stopped["reason"]

    run_rows = File.readlines(File.join(@home, "metrics.tsv"))
                    .map { |l| l.chomp.split("\t", -1) }
                    .select { |r| r[2] == "run" }
    assert_equal 1, run_rows.size
    assert_equal "crashed", run_rows[0][6]
  ensure
    Robur::CLI.instance_variable_set(:@quiet, nil)
    Robur::CLI.instance_variable_set(:@loop_log, nil)
  end

  # The token-efficiency fields the metrics row cannot carry.
  def test_tokens_events_carry_fresh_in_and_round_trip_count
    repo = make_repo
    Robur::Loop.run(repo, sleep_it: ->(_s) {})

    log_dir = File.join(@home, "logs", Robur::CLI.project_slug(repo))
    tokens = File.readlines(File.join(log_dir, "events.jsonl"))
                 .map { |l| JSON.parse(l) }.select { |r| r["kind"] == "tokens" }
    refute_empty tokens
    tokens.each do |t|
      %w[input output cache_read cache_write fresh_in tin messages runaway].each do |k|
        assert t.key?(k), "tokens event missing #{k}: #{t.inspect}"
      end
      assert_equal t["input"] + t["cache_write"], t["fresh_in"]
      assert_equal t["fresh_in"] + t["cache_read"], t["tin"]
      refute t["runaway"] # the fixture agent makes no model round-trips
    end
  end

  # Columns 13-15 ride past the frozen 12 on turn rows; run rows keep the
  # bare 12 so the bash-comparable surface is unchanged.
  def test_turn_metrics_rows_carry_the_extension_columns
    repo = make_repo
    Robur::Loop.run(repo, sleep_it: ->(_s) {})

    rows = File.readlines(File.join(@home, "metrics.tsv")).map { |l| l.chomp.split("\t", -1) }
    turns = rows.select { |c| c[2] == "turn" }
    runs  = rows.select { |c| c[2] == "run" }
    refute_empty turns
    refute_empty runs

    turns.each do |c|
      assert_equal 15, c.size, "turn row is not 15 columns: #{c.inspect}"
      # tin (col 10) must stay reconstructible from the extension
      assert_equal c[9].to_i, c[12].to_i + c[13].to_i
    end
    runs.each { |c| assert_equal 12, c.size, "run row must stay 12 columns: #{c.inspect}" }
  end

  def test_done_turn_red_at_gate_stops_gate_red_and_notifies
    # An empty tracker (no tasks at all) skips the all-done fast path (which
    # requires count(:done) > 0) and, with open?/in_progress? both false, the
    # ALL_DONE sanity-gate downgrade never fires either — so every turn hits
    # the `done` dispatch branch and can accumulate gate failures.
    no_tasks = "# Plan\n\n## M1\nnothing tracked yet.\n"
    repo = make_repo(plan: no_tasks)
    # Stub: writes a secret + ALL_DONE. The secret-scan blocks the commit ->
    # every done turn is RED at the gate until MAX_DONE_GATE_FAILS is hit.
    agent = File.join(repo, "red-agent")
    File.write(agent, <<~SH)
      #!/bin/bash
      echo 'AWS_KEY=AKIAABCDEFGHIJKLMNOP' > conf.txt # robur:allow-secret
      echo "ALL_DONE"
    SH
    FileUtils.chmod(0o755, agent)
    conf = File.join(repo, Robur::Paths::REPO_CONF)
    File.write(conf, File.read(conf).sub(AGENT, agent))

    notified = []
    stub_notify(notified) do
      code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
      assert_equal 1, code
    end
    assert_equal "gate_red\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))
    assert notified.any? { |m| m.include?("gate RED after ALL_DONE") }
  end

  # BUG A regression. This branch used to `emit "HUMAN NEEDED: ..."` and break,
  # never calling notify_human — so a human-blocked repo wrote the line into
  # loop.log, recorded ZERO `"kind":"human"` events, and sent no DM. A
  # production repo sat blocked for 21h that way. The stop itself already
  # worked; only the asking-for-help did not.
  def test_human_stop_calls_notify_human
    repo = human_blocked_repo
    notified = []
    stub_notify(notified) { Robur::Loop.run(repo, sleep_it: ->(_s) {}) }

    assert_equal "human_blocked\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))
    refute_empty notified, "a human-gate stop must push, not just log"
    assert notified.first.to_s.include?("T1.1"), "the push must name the blocking task, got #{notified.inspect}"
  end

  # Same stop with the real notify_human (NOTIFY_CMD empty, so nothing spawns):
  # it must still produce the log line the old `emit` produced — the change is
  # additive — and the :human event that downstream ingest counts.
  def test_human_stop_logs_and_emits_the_human_event
    repo = human_blocked_repo
    saved = ENV.delete("NOTIFY_CMD")
    begin
      Robur::Loop.run(repo, sleep_it: ->(_s) {})
    ensure
      ENV["NOTIFY_CMD"] = saved if saved
    end

    log_dir = File.join(@home, "logs", Robur::CLI.project_slug(repo))
    assert_includes File.read(File.join(log_dir, "loop.log")), "HUMAN NEEDED:"
    events = File.readlines(File.join(log_dir, "events.jsonl")).map { |l| JSON.parse(l) }
    assert events.any? { |e| e["kind"] == "human" },
           "the :human event is what downstream ingest counts; it was always 0"
  end

  def human_blocked_repo
    repo = make_repo
    agent = File.join(repo, "human-agent")
    File.write(agent, "#!/bin/bash\necho \"HUMAN_BLOCKED\"\n")
    FileUtils.chmod(0o755, agent)
    conf = File.join(repo, Robur::Paths::REPO_CONF)
    File.write(conf, File.read(conf).sub(AGENT, agent))
    repo
  end

  # HUMAN_PARK_TOKEN: unlike HUMAN_BLOCKED, this must NOT stop the repo — it
  # parks the current task and the loop keeps going. Parks T1.1 on the first
  # turn (leaves it untouched), then falls through to the real fake-agent
  # once T1.1 is no longer `[ ]` so T1.2/T1.3 finish normally.
  def human_park_repo
    repo = make_repo
    agent = File.join(repo, "human-park-agent")
    File.write(agent, <<~SH)
      #!/bin/bash
      if grep -q '\\[ \\] T1\\.1' PLAN.md; then
        echo "HUMAN_PARKED which account has the real balance?"
      else
        exec #{AGENT} "$@"
      fi
    SH
    FileUtils.chmod(0o755, agent)
    conf = File.join(repo, Robur::Paths::REPO_CONF)
    File.write(conf, File.read(conf).sub(AGENT, agent))
    repo
  end

  def test_human_park_parks_task_and_continues_to_done
    repo = human_park_repo
    notified = []
    stub_notify(notified) { Robur::Loop.run(repo, sleep_it: ->(_s) {}) }

    assert_equal "done\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))
    plan = Robur::Plan.new(File.join(repo, "PLAN.md"))
    assert_equal :parked, plan.next_task(:parked).status
    assert_equal "T1.1", plan.next_task(:parked).id
    refute plan.open?, "the parked task must not be picked up as open again"
    assert_includes commits(repo), "loop(robur): task T1.1 PARKED \u2014 needs human"
    assert notified.any? { |m| m.include?("T1.1") && m.include?("account has the real balance") },
           "the park must notify with the task and the extracted question, got #{notified.inspect}"
  end

  def test_park_current_task_writes_human_marker_and_commits
    repo = make_repo
    conf = Robur::Config.load(repo, {}).values
    task = Robur::Plan.new(File.join(repo, "PLAN.md")).next_task(:open)

    Robur::Loop.park_current_task(repo, conf, task, "which account balance?")

    line = File.readlines(File.join(repo, "PLAN.md"))[task.lineno - 1]
    assert_match(/\A- \[HUMAN\] T1\.1/, line)
    assert_includes line, "PARKED, needs human: which account balance?"
    assert_equal :parked, Robur::Plan.new(File.join(repo, "PLAN.md")).next_task(:parked).status
    assert_includes commits(repo), "loop(robur): task T1.1 PARKED \u2014 needs human"
  end

  def test_all_benched_backoff_ladder
    conf = { "COOLDOWN" => "100", "MAX_TRANSIENT" => "3", "SHORT_SLEEP" => "0" }
    health = Robur::ModelHealth.new(conf)
    health.bench!("a")
    health.bench!("b")
    assert_nil health.pick(%w[a b])
    assert_equal [900, 3600, 14_400], Robur::Loop::BACKOFF_LADDER
    health.reset_all
    assert_equal "a", health.pick(%w[a b])
  end

  # T7.1 (b), isolated from benching (MAX_TRANSIENT set high so the model
  # never benches): a task that never progresses must stop the run once
  # attempts exceed MAX_TASK_ATTEMPTS rather than spin forever.
  def test_task_attempt_ceiling_stops_a_transient_spin
    repo = make_repo(extra_conf: %(MAX_TASK_ATTEMPTS="3"\nMAX_TRANSIENT="100"))
    with_turn_run(lambda { |**kw, &_blk|
      File.write(kw[:turn_file], "no recognized token, just noise\n")
      system("true")
      Robur::Turn::Result.new(status: $?, kill_reason: nil, elapsed: 0)
    }) do
      code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
      assert_equal 0, code
    end

    assert_equal "task_attempts_exceeded\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))

    log_dir = File.join(@home, "logs", Robur::CLI.project_slug(repo))
    events = File.readlines(File.join(log_dir, "events.jsonl")).map { |l| JSON.parse(l) }
    exceeded = events.find { |e| e["kind"] == "task_attempts_exceeded" }
    refute_nil exceeded, "the ceiling must record why it stopped"
    assert_equal "T1.1", exceeded["task"]
    assert_equal 4, exceeded["attempts"] # ceiling 3, the 4th attempt trips it
    assert_equal 3, exceeded["ceiling"]

    log = File.read(File.join(log_dir, "loop.log"))
    assert_includes log, "exceeded MAX_TASK_ATTEMPTS=3"
  end

  # T7.1 full repro, both halves of the fix together: MAX_TRANSIENT benches
  # a model after one strike, the (single-model) chain goes all-benched, the
  # backoff ladder fires, reset_all clears ModelHealth's strikes — and every
  # one of those turns is ALSO runaway (production case: the flag alone
  # changed nothing). The model must get struck for the runaway turns, and
  # the loop must still stop once the ceiling is exceeded across bench
  # cycles that reset_all cannot touch.
  def test_runaway_strikes_the_model_and_the_ceiling_survives_reset_all
    repo = make_repo(extra_conf: %(MAX_TASK_ATTEMPTS="1"\nMAX_TRANSIENT="1"\nCOOLDOWN="900"))
    old_threshold = ENV["ROBUR_RUNAWAY_MESSAGES"]
    ENV["ROBUR_RUNAWAY_MESSAGES"] = "1"
    with_turn_run(lambda { |**kw, &_blk|
      usage = JSON.generate({ "id" => "m1", "message" => { "usage" => { "input" => 1, "output" => 1, "cost" => { "total" => 0.0 } } } })
      File.write(kw[:turn_file], "#{usage}\n")
      system("true")
      Robur::Turn::Result.new(status: $?, kill_reason: nil, elapsed: 0)
    }) do
      code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
      assert_equal 0, code
    end

    log_dir = File.join(@home, "logs", Robur::CLI.project_slug(repo))
    events = File.readlines(File.join(log_dir, "events.jsonl")).map { |l| JSON.parse(l) }

    strikes = events.select { |e| e["kind"] == "model_strike" && e["reason"] == "runaway" }
    refute_empty strikes, "a runaway turn must strike the model"

    exceeded = events.find { |e| e["kind"] == "task_attempts_exceeded" }
    refute_nil exceeded, "reset_all must not let the runaway/bench/backoff cycle spin forever"
    assert_equal "task_attempts_exceeded\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))

    log = File.read(File.join(log_dir, "loop.log"))
    assert_includes log, "RUNAWAY: turn"
    assert_includes log, "ALL models benched"
    assert_includes log, "exceeded MAX_TASK_ATTEMPTS=1"
  ensure
    old_threshold ? ENV["ROBUR_RUNAWAY_MESSAGES"] = old_threshold : ENV.delete("ROBUR_RUNAWAY_MESSAGES")
  end

  # Backward compatibility: agents, hooks and wrapper scripts across the
  # estate branch on RATCHET_LOOP to tell "inside a loop turn" from "a human
  # typing". Both names are exported for every spawned turn so neither an
  # updated nor an un-updated consumer goes blind.
  def test_spawned_turns_get_both_loop_env_markers
    repo = make_repo
    probe = File.join(repo, "env-probe")
    # Records the two markers, then hands the turn to the real fixture agent
    # so the run still terminates the normal way.
    agent = File.join(repo, "env-agent")
    File.write(agent, <<~SH)
      #!/bin/bash
      printf '%s=%s\\n' ROBUR_LOOP "$ROBUR_LOOP" RATCHET_LOOP "$RATCHET_LOOP" >> #{probe}
      exec #{AGENT} "$@"
    SH
    FileUtils.chmod(0o755, agent)
    conf = File.join(repo, Robur::Paths::REPO_CONF)
    File.write(conf, File.read(conf).sub(AGENT, agent))

    Robur::Loop.run(repo, sleep_it: ->(_s) {})

    seen = File.readlines(probe, chomp: true)

    assert_includes seen, "ROBUR_LOOP=1"
    assert_includes seen, "RATCHET_LOOP=1"
  end

  def test_run_prints_turn_header_block
    repo = make_repo(extra_conf: 'QUIET="0"') # header is terminal-only; Loop.run re-reads QUIET from conf
    out, = capture_io do
      Robur::Loop.run(repo, sleep_it: ->(_s) {})
    end
    assert_includes out, "Step 0/3"
    assert_match(/\u25B6 T1\.1/, out) # task id leads the live header line
    assert_includes out, "stub/stub-1" # model is named per turn
  ensure
    Robur::CLI.instance_variable_set(:@quiet, nil)
    Robur::CLI.instance_variable_set(:@loop_log, nil)
  end

  # T0.4: an unexpected exception inside the turn loop must still leave the
  # supervisor-facing epilogue behind (run_end event, stop_reason, metrics
  # run row) and record the crash honestly, while the exception propagates.
  def test_unexpected_exception_records_crashed_and_still_propagates
    repo = make_repo
    error = assert_raises(RuntimeError) do
      with_turn_run(->(**_kw) { raise "boom" }) do
        Robur::Loop.run(repo, sleep_it: ->(_s) {})
      end
    end
    assert_equal "boom", error.message
    assert_equal "crashed\n", File.read(Robur::Paths.state_file(repo, "stop_reason"))
    run_rows = File.readlines(File.join(@home, "metrics.tsv"))
                    .map { |l| l.chomp.split("\t", -1) }
                    .select { |r| r[2] == "run" }
    assert_equal 1, run_rows.size
    assert_equal "crashed", run_rows[0][6]
  end

  # T0.4: a fresh run must clear a STALE verdict from an earlier run before
  # the first turn is spawned — a SIGKILLed loop would otherwise leave the
  # old word standing forever and the supervisor would skip a healthy repo.
  def test_startup_overwrites_stale_stop_reason_with_running
    repo = make_repo
    Robur::Paths.ensure_state_dir!(repo)
    File.write(Robur::Paths.state_file(repo, "stop_reason"), "human_blocked\n")
    seen_at_first_turn = nil
    with_turn_run(lambda { |**kw, &blk|
      seen_at_first_turn ||= File.read(Robur::Paths.state_file(repo, "stop_reason")).strip
      @turn_run_orig.call(**kw, &blk)
    }) do
      code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
      assert_equal 0, code
    end
    assert_equal "running", seen_at_first_turn
    assert_equal "done", File.read(Robur::Paths.state_file(repo, "stop_reason")).strip
  end

  # T1.2: a stop file written BETWEEN two turns must stop the loop at the
  # top of the next iteration — no new agent spawned, the supervisor-facing
  # epilogue (stop_reason "stopped", metrics run row) still runs, exit 0.
  def test_stop_file_between_turns_drains_without_starting_a_new_turn
    repo = make_repo
    spawn_count = 0
    with_turn_run(lambda { |**kw, &blk|
      spawn_count += 1
      Robur::State.write_stop(repo, "drain") if spawn_count == 1
      @turn_run_orig.call(**kw, &blk)
    }) do
      code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
      assert_equal 0, code
    end
    assert_equal 1, spawn_count, "a drain must not start a new turn"
    assert_equal "stopped", File.read(Robur::Paths.state_file(repo, "stop_reason")).strip
    run_rows = File.readlines(File.join(@home, "metrics.tsv"))
                   .map { |l| l.chomp.split("\t", -1) }
                   .select { |r| r[2] == "run" }
    assert_equal 1, run_rows.size
  end

  # T1.3: a stop file containing "now" seen WHILE a turn is running makes
  # the watchdog kill the agent child; the salvage arm commits any green
  # work (one gate run), stops with reason "stopped", and — the whole point
  # — never strikes/benches/records against the model's health.
  def test_stop_file_mid_turn_aborts_without_punishing_the_model
    repo = make_repo
    spawn_count = 0
    health = nil
    with_turn_run(lambda { |**kw, &blk|
      spawn_count += 1
      Robur::State.write_stop(repo, "now") if spawn_count == 1
      assert_kind_of Proc, kw[:stop_check], "loop must pass stop_check to Turn.run"
      @turn_run_orig.call(**kw, &blk)
    }) do
      health = with_health_capture do
        code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
        assert_equal 0, code
      end
    end
    assert_equal 1, spawn_count, "killed turn must not be followed by a new spawn"
    assert_equal "stopped", File.read(Robur::Paths.state_file(repo, "stop_reason")).strip
    log = File.join(@home, "logs", Robur::CLI.project_slug(repo), "loop.log")
    assert_equal 1, File.read(log).scan("stop requested mid-turn").size,
                 "salvage arm must run exactly once"
    # .robur state is staged, so the salvage gate runs VERIFY_CMD once.
    assert_equal 1, File.read(log).scan("commit gate: running").size,
                 "salvage arm must run the commit gate exactly once"
    assert_equal 3, File.read(File.join(repo, "PLAN.md")).scan("- [ ]").size,
                 "agent was killed mid-turn — no task may be ticked"
    assert_equal({}, health.snapshot, "no strike, bench or record! may touch model health")
  end

  # T1.2: a stop file left over from a PREVIOUS session is cleared at
  # startup, so the first turn runs normally instead of being killed
  # before it starts.
  def test_stop_file_present_before_run_is_cleared_and_first_turn_runs
    repo = make_repo
    Robur::Paths.ensure_state_dir!(repo)
    Robur::State.write_stop(repo, "drain")
    spawn_count = 0
    with_turn_run(lambda { |**kw, &blk|
      spawn_count += 1
      @turn_run_orig.call(**kw, &blk)
    }) do
      code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
      assert_equal 0, code
    end
    assert_nil Robur::State.read_stop(repo), "stale stop file must be cleared at startup"
    assert_operator spawn_count, :>=, 1, "first turn must run normally"
  end

  # T1.4: the all-models-benched backoff (BACKOFF_LADDER up to 14400s) must
  # not sit on a stop request — a stop file arriving mid-sleep interrupts
  # within one second and the loop drains with stop_reason "stopped".
  def test_stop_file_interrupts_all_benched_backoff
    repo = make_repo
    # Empty-output agent: :empty benches the model immediately, so turn 2
    # hits the all-benched ladder backoff (900s on rung 1).
    agent = File.join(repo, "empty-agent")
    File.write(agent, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, agent)
    conf = File.join(repo, Robur::Paths::REPO_CONF)
    File.write(conf, File.read(conf).sub(AGENT, agent))

    slept = []
    sleep_it = lambda do |s|
      slept << s
      # SHORT_SLEEP=0 never reaches sleep_it (life.sleep(0) is a no-op), so
      # the first >=1s slice IS the first ladder rung — write the stop there.
      Robur::State.write_stop(repo, "drain") if s >= 1
    end
    code = Robur::Loop.run(repo, sleep_it: sleep_it)

    assert_equal 0, code
    assert_equal "stopped", File.read(Robur::Paths.state_file(repo, "stop_reason")).strip
    assert_equal [1], slept, "backoff must be sliced at 1s and abandoned on the first slice, not slept whole"
    log = File.join(@home, "logs", Robur::CLI.project_slug(repo), "loop.log")
    assert_includes File.read(log), "ALL models benched"
  end

  # T1.4: wait_for_merge polls with poll_secs defaulting to 300 — a stop
  # request must return 4 at the top of the next poll check, never after
  # waiting out a full interval.
  def test_wait_for_merge_returns_4_when_stop_requested
    dir = Dir.mktmpdir
    Robur::Paths.ensure_state_dir!(dir)
    life = Robur::Lifecycle.new(dir).install!
    repo = Object.new
    repo.define_singleton_method(:remote?) { |_name| true }
    repo.define_singleton_method(:default_branch) { "main" }
    polls = 0
    slept = []
    pr = lambda do |_sys, _branch|
      polls += 1
      "OPEN"
    end
    stop_it = ->(s) {
      slept << s
      # The stop arrives DURING the first 1s slice of the 300s poll sleep.
      Robur::State.write_stop(dir, "drain") if s >= 1
    }
    stub_notify([]) do
      with_smethod_stub(Robur::CLI, :on_path?, ->(_cmd) { true }) do
        with_smethod_stub(Robur::Loop, :pr_state, pr) do
          rc = Robur::Loop.wait_for_merge("b", dir, {}, repo: repo, sys: nil,
                                          sleep_it: stop_it, life: life)
          assert_equal 4, rc
        end
      end
    end
    assert_equal 1, polls, "stop must be honored before the second poll"
    assert_equal [1], slept, "poll sleep must be sliced at 1s, not the full 300s interval"
  ensure
    FileUtils.rm_rf(dir)
  end

  private

  # Replace Robur::Turn.run for the block; the original stays reachable as
  # @turn_run_orig (same alias/restore pattern as stub_notify below).
  def with_turn_run(replacement)
    Robur::Turn.singleton_class.send(:alias_method, :turn_run_orig, :run)
    @turn_run_orig = Robur::Turn.method(:turn_run_orig)
    Robur::Turn.singleton_class.send(:define_method, :run) { |**kw, &blk| replacement.call(**kw, &blk) }
    yield
  ensure
    Robur::Turn.singleton_class.send(:alias_method, :run, :turn_run_orig)
    Robur::Turn.singleton_class.send(:remove_method, :turn_run_orig)
  end

  # Capture the ModelHealth instance the loop builds (alias/restore of .new,
  # same pattern as with_turn_run) so tests can assert its snapshot is
  # unchanged after a run.
  def with_health_capture
    captured = nil
    Robur::ModelHealth.singleton_class.send(:alias_method, :mh_new_orig, :new)
    Robur::ModelHealth.singleton_class.send(:define_method, :new) do |*args, **kw, &blk|
      captured = mh_new_orig(*args, **kw, &blk)
    end
    yield
    captured
  ensure
    Robur::ModelHealth.singleton_class.send(:alias_method, :new, :mh_new_orig)
    Robur::ModelHealth.singleton_class.send(:remove_method, :mh_new_orig)
  end

  # Alias/restore a module (singleton) method — same pattern as stub_notify,
  # for module_function-style methods like CLI.on_path? and Loop.pr_state.
  def with_smethod_stub(owner, name, replacement)
    backup = "#{name}_t14_orig".to_sym
    owner.singleton_class.send(:alias_method, backup, name)
    owner.singleton_class.send(:define_method, name) { |*args, **kw, &blk| replacement.call(*args, **kw, &blk) }
    yield
  ensure
    owner.singleton_class.send(:alias_method, name, backup)
    owner.singleton_class.send(:remove_method, backup)
  end

  # Captures a human push from EITHER implementation. Loop.notify_human logs
  # and spawns; Observability#notify_human also records the :human event, and
  # the human-gate stop routes through that one so the event is not lost. A
  # helper that knew only about the first would go quietly blind the moment a
  # call site moved between them — which is the class of bug this stop had.
  def stub_notify(collector)
    Robur::Loop.singleton_class.send(:alias_method, :notify_human_orig, :notify_human)
    Robur::Loop.singleton_class.send(:define_method, :notify_human) do |msg, *_|
      collector << msg
      nil
    end
    Robur::Observability.send(:alias_method, :notify_human_orig, :notify_human)
    Robur::Observability.send(:define_method, :notify_human) do |msg, *_|
      collector << msg
      nil
    end
    yield
  ensure
    Robur::Loop.singleton_class.send(:alias_method, :notify_human, :notify_human_orig)
    Robur::Loop.singleton_class.send(:remove_method, :notify_human_orig)
    Robur::Observability.send(:alias_method, :notify_human, :notify_human_orig)
    Robur::Observability.send(:remove_method, :notify_human_orig)
  end
end
