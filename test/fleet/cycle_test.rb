# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/cycle"
require "robur/state"
require "tmpdir"
require "fileutils"
require "stringio"

class FleetCycleTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("robur-cycle")
    @repo = make_repo("r")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # A real on-disk repo: conf + MACHINE tracker with `open` tasks. open: 0
  # reads as caught-up, the autoplan-eligible shape (T2.2).
  def make_repo(name, open: 1)
    dir = File.join(@root, name)
    Dir.mkdir(dir)
    File.write(File.join(dir, ".robur.conf"), "VERIFY_CMD=true\n")
    lines = ["<!-- class: MACHINE -->", "# PLAN"]
    (1..open).each { |i| lines << "- [ ] T#{i} open task #{i}" }
    File.write(File.join(dir, "PLAN.md"), lines.join("\n").concat("\n"))
    dir
  end

  # A real Roster over a real fleet.conf — the one parser, not a stub.
  def roster(*repos)
    conf = File.join(@root, "fleet.conf")
    File.write(conf, repos.join("\n").concat("\n"))
    Robur::Fleet::Roster.new(conf)
  end

  ClockStub = Struct.new(:now)

  # Records the URLs it was handed, in order — the dead-man pair is an
  # ORDERED pair, so the stub must be order-true.
  HttpStub = Struct.new(:calls) do
    def get(uri, _headers: {})
      calls << uri
      Net::HTTPOK
    end
  end

  HttpRaiser = Class.new do
    def get(*)
      raise Errno::ECONNREFUSED
    end
  end

  def cycle(spawner:, roster: [], notifier: nil, out: $stdout, http: nil, obs: nil,
            healthcheck: "", paused: false, clock: ClockStub.new(Time.at(0)))
    Robur::Fleet::Cycle.new(
      roster: roster,
      gate_for: ->(repo) { Robur::Fleet::Gate.new(repo) },
      budget: Robur::Fleet::Budget.new(max_runs: 4, max_plans: 4,
                                       autoplan_min_secs: 0, backoff_base: 1,
                                       backoff_cap: 2, interval: 3,
                                       healthcheck_url: healthcheck),
      clock: clock,
      spawner: spawner, notifier: notifier, http: http, obs: obs, out: out,
      paused: paused
    )
  end

  # The pause flag (T5.4) is Paths.home-relative; swap the real home for
  # this test's root for the block's duration, as config_test does.
  def with_pause_home
    old = ENV["ROBUR_HOME"]
    ENV["ROBUR_HOME"] = @root
    yield
  ensure
    old ? ENV["ROBUR_HOME"] = old : ENV.delete("ROBUR_HOME")
  end

  # Acceptance: the exe resolved from the live process is a real,
  # executable file — this is the check that would have caught the
  # launchd/system-Ruby-2.6 outages.
  def test_exe_exists_and_is_executable
    assert File.executable?(Robur::Fleet::Cycle::EXE), Robur::Fleet::Cycle::EXE
  end

  # Acceptance: argv[0] is RbConfig.ruby and argv[1] the existing exe —
  # built in Cycle#spawn, so an injected spawner sees the exact argv with
  # no process launched.
  def test_spawn_builds_command_from_the_live_process
    seen = []
    status = cycle(spawner: ->(argv) { seen << argv; 0 }).spawn(@repo, "run", @repo)
    assert_equal 0, status
    assert_equal [RbConfig.ruby, Robur::Fleet::Cycle::EXE, "run", @repo], seen.first
  end

  # Acceptance: a child that cannot be started yields :spawn_error, not an
  # exit code — nil is reserved for the environment fault (T3.3).
  def test_child_that_never_started_yields_spawn_error
    assert_equal :spawn_error, cycle(spawner: ->(_argv) { nil }).spawn(@repo, "run")
  end

  def test_nonzero_exit_passes_through
    assert_equal 3, cycle(spawner: ->(_argv) { 3 }).spawn(@repo, "run")
  end

  # The DEFAULT spawner's own mapping: system's true/false both carry an
  # exit status, its nil (never started) must stay nil. A real process is
  # launched here, but only `ruby -e exit` — never a turn.
  def test_default_spawner_maps_system_results
    spawner = Robur::Fleet::Cycle::DEFAULT_SPAWNER
    assert_equal 3, spawner.([RbConfig.ruby, "-e", "exit 3"])
    assert_nil spawner.(["/nonexistent/robur-spawn-probe"])
  end

  # --- record_outcome: the policy table (T3.3) ---------------------------

  # NOT `private`: Minitest collects PUBLIC test_* methods only, so a
  # `private` here silently hid the 26 tests below it — the whole policy
  # table reported as passing by never running at all. A helper among them
  # is harmless; it does not match /^test_/.
  def spy_notifier
    calls = []
    notifier = Object.new
    notifier.define_singleton_method(:notify_once) { |*args| calls << args }
    [notifier, calls]
  end

  # Acceptance: with stop_reason "done" an existing backoff file is removed.
  def test_done_clears_an_existing_backoff
    Robur::State.write_loop_backoff(@repo, 2, Time.now.to_i + 9_999)
    Robur::State.write_stop_reason(@repo, "done")
    assert_equal :cleared, cycle(spawner: ->(_a) { 0 }).record_outcome(@repo, 0)
    assert_nil Robur::State.read_loop_backoff(@repo)
  end

  # Acceptance: exit 0 + "stopped" — the loop-backoff file is neither
  # created nor modified. A human ran `robur stop`; that is an instruction,
  # not a failure, and backing off for it costs the next beat too.
  def test_stopped_neither_creates_nor_modifies_backoff
    cyc = cycle(spawner: ->(_a) { 0 })
    Robur::State.write_stop_reason(@repo, "stopped")
    assert_equal :no_change, cyc.record_outcome(@repo, 0)
    assert_nil Robur::State.read_loop_backoff(@repo)

    until_epoch = Time.now.to_i + 9_999
    Robur::State.write_loop_backoff(@repo, 1, until_epoch)
    cyc.record_outcome(@repo, 0)
    assert_equal [1, until_epoch], Robur::State.read_loop_backoff(@repo)
  end

  # Acceptance: with stop_reason "gate_red" the backoff count increments by
  # one. The real child exits 1 for gate_red. The T5.3 notify key carries
  # the task id too.
  def test_gate_red_bumps_the_ladder_by_one
    notifier, calls = spy_notifier
    cyc = cycle(spawner: ->(_a) { 1 }, notifier: notifier)
    Robur::State.write_stop_reason(@repo, "gate_red")
    Robur::State.write_last_task(@repo, "T9", "running")
    assert_equal :bumped, cyc.record_outcome(@repo, 1)
    assert_equal 1, Robur::State.read_loop_backoff(@repo)[0]
    assert_equal "T9\tgate_red", calls.first[1]
    cyc.record_outcome(@repo, 1)
    assert_equal 2, Robur::State.read_loop_backoff(@repo)[0]
  end

  # human_blocked: the repo is skipped for the rest of the cycle and the
  # notifier hook fires with the T5.3 key "<task_id>\t<reason>" — a changed
  # task id re-notifies immediately (Notifier holds the 24h half).
  def test_human_blocked_skips_the_repo_for_the_cycle_and_notifies
    notifier, calls = spy_notifier
    cyc = cycle(spawner: ->(_a) { 1 }, notifier: notifier)
    Robur::State.write_stop_reason(@repo, "human_blocked")
    Robur::State.write_last_task(@repo, "T3.1", "running")
    assert_equal :skipped, cyc.record_outcome(@repo, 1)
    assert_equal [@repo], cyc.human_skipped
    assert_equal 1, calls.size
    assert_equal @repo, calls.first[0]
    assert_equal "T3.1\thuman_blocked", calls.first[1]
  end

  def test_progress_stalled_and_review_exceeded_bump
    cyc = cycle(spawner: ->(_a) { 0 })
    Robur::State.write_stop_reason(@repo, "progress_stalled")
    assert_equal :bumped, cyc.record_outcome(@repo, 0)
    assert_equal 1, Robur::State.read_loop_backoff(@repo)[0]
    Robur::State.write_stop_reason(@repo, "review_exceeded")
    assert_equal :bumped, cyc.record_outcome(@repo, 0)
    assert_equal 2, Robur::State.read_loop_backoff(@repo)[0]
  end

  # A real nonzero exit bumps even with NO stop_reason file: Gate's derived
  # fallback ("done"/"stopped") must never turn a crash into a clear or a
  # no-op.
  def test_real_nonzero_exit_bumps_with_no_stop_reason_file
    cyc = cycle(spawner: ->(_a) { 7 })
    assert_equal :bumped, cyc.record_outcome(@repo, 7)
    assert_equal 1, Robur::State.read_loop_backoff(@repo)[0]
  end

  # Acceptance: with :spawn_error across a 3-repo roster no repo's backoff
  # file is touched and the cycle is red — a child that never started is a
  # property of this machine, not of any repo.
  def test_spawn_error_fails_the_cycle_and_backs_off_no_repo
    repos = [@repo, make_repo("r2"), make_repo("r3")]
    cyc = cycle(spawner: ->(_a) { nil })
    results = repos.map { |r| cyc.record_outcome(r, :spawn_error) }
    assert_equal %i[environment environment environment], results
    refute_equal 0, cyc.status
    repos.each { |r| assert_nil Robur::State.read_loop_backoff(r) }
  end

  # --- Cycle#run: the three-phase cycle (T3.4) ---------------------------

  # Acceptance, verbatim: two runnable repos, an injected spawner returning
  # 0 then 1 — both repos were spawned and the exit status is 1. The second
  # run pass skips both (:once_per_cycle), so exactly two spawns happened.
  def test_cycle_runs_both_repos_and_returns_the_last_nonzero_status
    a = make_repo("a")
    b = make_repo("b")
    seen = []
    n = 0
    spawner = lambda do |argv|
      seen << argv.last
      (n += 1) == 1 ? 0 : 1
    end
    assert_equal 1, cycle(spawner: spawner, roster: roster(a, b)).run
    assert_equal [a, b], seen
  end

  # The three phases in order: run pass, plan top-up (`plan --auto`), run
  # pass again. Repo c is caught up in pass one; its plan turn (the injected
  # spawner) ADDS a task, the fresh gates of pass three see it, and c runs —
  # while a and b, already run, are never spawned again. Exactly two run
  # passes: the plan turn could give a third pass nothing new.
  def test_full_cycle_run_plan_run_again_in_order
    a = make_repo("a")
    b = make_repo("b")
    c = make_repo("c", open: 0)
    calls = []
    spawner = lambda do |argv|
      calls << argv[2..]
      if argv[2] == "plan"
        File.write(File.join(argv.last, "PLAN.md"),
                   "<!-- class: MACHINE -->\n# PLAN\n- [ ] T9 planned task\n")
      end
      0
    end
    assert_equal 0, cycle(spawner: spawner, roster: roster(a, b, c)).run
    assert_equal [["run", a], ["run", b], ["plan", "--auto", c], ["run", c]], calls
  end

  # A nil lease logs the holder pid and the repo never spawns — not in pass
  # one, and the lock-skipped set keeps pass three off it too.
  def test_lock_held_repo_is_skipped_without_spawning_for_the_cycle
    a = make_repo("a")
    b = make_repo("b")
    lease = Robur::Fleet::Lock.acquire(b)
    refute_nil lease
    calls = []
    out = StringIO.new
    status = cycle(spawner: ->(argv) { calls << argv.last; 0 },
                   roster: roster(a, b), out: out).run
    assert_equal 0, status
    assert_equal [a], calls
    assert_includes out.string, "lock held by pid #{Process.pid}"
  ensure
    lease&.release
  end

  # --- autoplan stamp (T3.5) ---------------------------------------------

  # Acceptance: a caught-up repo whose plan turn spawned and exited 0
  # producing no tasks — the stamp exists with an advanced mtime and no
  # backoff was recorded: an honest empty plan is not a failure.
  def test_plan_spawn_touches_the_autoplan_stamp_and_records_no_failure
    c = make_repo("c", open: 0)
    stamp = Robur::State.state_path(c, "autoplan.stamp")
    FileUtils.mkdir_p(File.dirname(stamp))
    FileUtils.touch(stamp, mtime: Time.at(0))
    out = StringIO.new
    plans = []
    assert_equal 0, cycle(spawner: ->(argv) { plans << argv[2] if argv[2] == "plan"; 0 },
                          roster: roster(c), out: out).run
    assert_equal 1, plans.size # rate limit: exactly one plan turn
    assert File.file?(stamp)
    refute_equal Time.at(0), File.mtime(stamp)
    assert_nil Robur::State.read_loop_backoff(c)
    assert_includes out.string, "no open tasks"
  end

  # Acceptance: a repo skipped for lock contention never spawns, so no
  # stamp is written — stamping a skip would silence its next six hours of
  # planning for work never attempted.
  def test_lock_skipped_repo_gets_no_autoplan_stamp
    c = make_repo("c", open: 0)
    lease = Robur::Fleet::Lock.acquire(c)
    calls = []
    out = StringIO.new
    assert_equal 0, cycle(spawner: ->(argv) { calls << argv.last; 0 },
                          roster: roster(c), out: out).run
    assert_empty calls
    refute File.file?(Robur::State.state_path(c, "autoplan.stamp"))
  ensure
    lease&.release
  end

  # --- paused-fleet reminder (T5.4) --------------------------------------

  # Acceptance: a 9-day-old pause flag notifies once naming the age, and
  # the cycle still skips — no repo ever spawns, the cycle stays green.
  def test_nine_day_old_pause_notifies_once_and_the_cycle_still_skips
    with_pause_home do
      FileUtils.touch(File.join(@root, "fleet.paused"),
                      mtime: Time.now - 9 * 86_400)
      notifier, calls = spy_notifier
      seen = []
      out = StringIO.new
      c = cycle(spawner: ->(argv) { seen << argv.last; 0 },
                roster: roster(@repo), notifier: notifier,
                clock: ClockStub.new(Time.now), paused: true, out: out)
      assert_equal 0, c.run
      assert_empty seen
      assert_equal 1, calls.size
      assert_includes calls.first[2], "paused 9 days"
      assert_includes out.string, "paused 9 days"
    end
  end

  # The throttle is Notifier's key expiry (proved in notifier_test), so
  # what Cycle owes it is ONE STABLE KEY: a key that moved with the clock
  # would re-send every beat and there would be no throttle to have.
  def test_reminder_reuses_one_key_so_the_notifier_can_throttle_it
    with_pause_home do
      FileUtils.touch(File.join(@root, "fleet.paused"),
                      mtime: Time.now - 9 * 86_400)
      notifier, calls = spy_notifier
      opts = { spawner: ->(_argv) { 0 }, roster: roster(@repo),
               notifier: notifier, clock: ClockStub.new(Time.now),
               paused: true }
      cycle(**opts).run
      clock = opts[:clock]
      clock.now += 3_600
      cycle(**opts).run
      assert_equal 2, calls.size # the spy has no throttle; the real Notifier does
      assert_equal calls.first[1], calls.last[1]
      assert_equal "fleet\tpaused", calls.first[1]
    end
  end

  # Acceptance: a 2-day-old pause is under the threshold — nothing at all.
  def test_two_day_old_pause_sends_nothing
    with_pause_home do
      FileUtils.touch(File.join(@root, "fleet.paused"),
                      mtime: Time.now - 2 * 86_400)
      notifier, calls = spy_notifier
      c = cycle(spawner: ->(_argv) { 0 }, roster: roster(@repo),
                notifier: notifier, clock: ClockStub.new(Time.now),
                paused: true)
      assert_equal 0, c.run
      assert_empty calls
    end
  end

  # One repo raising must not abort the cycle: the raise is recorded as a
  # failure (cycle status 1) and the next repo still runs.
  def test_a_raising_repo_is_recorded_and_the_cycle_carries_on
    a = make_repo("a")
    b = make_repo("b")
    calls = []
    spawner = lambda do |argv|
      raise "boom" if argv.last == a

      calls << argv.last
      0
    end
    out = StringIO.new
    assert_equal 1, cycle(spawner: spawner, roster: roster(a, b), out: out).run
    assert_equal [b], calls
    assert_includes out.string, "boom"
  end

  # T5.2 acceptance: green cycle closes the pair with the bare URL, in
  # order — /start first, bare URL second.
  def test_healthcheck_pair_on_green_cycle
    http = HttpStub.new([])
    out = StringIO.new
    c = cycle(spawner: ->(_argv) { 0 }, roster: roster(@repo),
              http: http, healthcheck: "https://hc.example/hook", out: out)
    assert_equal 0, c.run
    assert_equal ["https://hc.example/hook/start", "https://hc.example/hook"], http.calls
    assert_includes out.string, "healthcheck"
  end

  # A red cycle closes the pair with /fail instead.
  def test_healthcheck_fail_variant_on_red_cycle
    http = HttpStub.new([])
    c = cycle(spawner: ->(_argv) { 1 }, roster: roster(@repo),
              http: http, healthcheck: "https://hc.example/hook")
    assert_equal 1, c.run
    assert_equal ["https://hc.example/hook/start", "https://hc.example/hook/fail"], http.calls
  end

  # Unset key = the two-days-blind failure mode: a LOUD warning naming the
  # global conf, not a routine line.
  def test_unset_healthcheck_url_warns_loudly_naming_global_conf
    out = StringIO.new
    cycle(spawner: ->(_argv) { 0 }, roster: roster(@repo), out: out).run
    assert_includes out.string, "WARNING"
    assert_includes out.string, "HEALTHCHECK_URL"
    assert_includes out.string, Robur::Paths.global_conf
  end

  # The watcher must never become the outage: an Http raise is logged and
  # the cycle's outcome is untouched.
  def test_raising_http_does_not_fail_the_cycle
    out = StringIO.new
    c = cycle(spawner: ->(_argv) { 0 }, roster: roster(@repo),
              http: HttpRaiser.new, healthcheck: "https://hc.example/hook", out: out)
    assert_equal 0, c.run
    assert_includes out.string, "WARN: healthcheck ping failed"
  end

  # --- fleet telemetry (T6.2) --------------------------------------------

  # Observability appends, it does not mkdir: the real wiring creates the
  # dir in Fleet.cycle_runner (Paths.ensure_state_dir!), so a test that
  # builds its own writer has to do the same.
  def obs_dir
    @obs_dir ||= File.join(@root, "fleetlog").tap { |d| FileUtils.mkdir_p(d) }
  end

  def read_events(dir = obs_dir)
    File.readlines(File.join(dir, "events.jsonl")).map { |l| JSON.parse(l) }
  end

  # Acceptance, verbatim: a cycle over two repos, one run and one skipped
  # for backoff — events.jsonl holds fleet_start, two fleet_decision
  # records, one fleet_spawn, one fleet_exit and one fleet_end, all under
  # one run id; loop.log holds one rendered human line per event, none
  # blank. A missing RENDER lambda would KeyError, be swallowed by the
  # best-effort rescue, and show up here as missing events.
  def test_cycle_emits_the_full_event_sequence
    a = make_repo("a")
    b = make_repo("b")
    Robur::State.write_loop_backoff(b, 1, Time.now.to_i + 9_999)
    clock = ClockStub.new(Time.at(0))
    obs = Robur::Observability.new(obs_dir, clock: clock)
    assert_equal 0, cycle(spawner: ->(_argv) { 0 }, roster: roster(a, b),
                          obs: obs, clock: clock).run
    events = read_events
    assert_equal %w[fleet_start fleet_decision fleet_decision fleet_spawn
                    fleet_exit fleet_end], events.map { |e| e["kind"] }
    run_ids = events.map { |e| e["run_id"] }
    refute_nil run_ids.uniq.first
    assert_equal 1, run_ids.uniq.size
    start, = events
    assert_equal 2, start["roster"]
    assert_equal 4, start["budgets"]["max_runs"]
    d1, d2 = events.select { |e| e["kind"] == "fleet_decision" }
    assert_equal [a, "run", "runnable"], d1.values_at("repo", "action", "reason")
    assert_equal [b, "skip", "backoff"], d2.values_at("repo", "action", "reason")
    spawn, = events.select { |e| e["kind"] == "fleet_spawn" }
    assert_equal [a, ["run", a]], spawn.values_at("repo", "argv")
    exit_ev, = events.select { |e| e["kind"] == "fleet_exit" }
    # The stub spawner writes no stop file, so this is Gate's DERIVED
    # fallback for a repo that still has open tasks.
    assert_equal [a, 0, "stopped"], exit_ev.values_at("repo", "status", "stop_reason")
    end_ev, = events.select { |e| e["kind"] == "fleet_end" }
    assert_equal [0, 1, 0, 1], end_ev.values_at("status", "runs", "plans", "skips")
    lines = File.readlines(File.join(obs_dir, "loop.log"), chomp: true)
    assert_equal events.size, lines.size
    lines.each { |l| refute l.strip.empty?, "blank rendered line" }
  end

  # Every fleet kind must resolve in RENDER (no KeyError) and render at
  # least one non-blank human line — the contract the loop.log reader and
  # a later observability project both lean on.
  def test_every_fleet_kind_resolves_in_render_with_a_non_blank_line
    obs = Robur::Observability.new(obs_dir, clock: ClockStub.new(Time.at(0)))
    cases = {
      fleet_start: { roster: 2, budgets: { max_runs: 4 } },
      fleet_decision: { repo: @repo, action: :run, reason: :runnable },
      fleet_spawn: { repo: @repo, argv: ["run", @repo] },
      fleet_exit: { repo: @repo, status: 0, stop_reason: "done" },
      fleet_end: { status: 0, runs: 1, plans: 0, skips: 1 },
    }
    cases.each do |kind, fields|
      before = File.foreach(File.join(obs_dir, "loop.log")).count
    rescue Errno::ENOENT
      before = 0
    ensure
      obs.emit(kind, **fields) # KeyError here = missing RENDER lambda
      lines = File.readlines(File.join(obs_dir, "loop.log"), chomp: true)
      assert lines.size > before, "#{kind} rendered no line"
      assert lines[before..].all? { |l| !l.strip.empty? }
    end
  end

  # Acceptance: an emit that raises does not change the cycle's exit
  # status — telemetry is best-effort, the failure is logged.
  def test_a_raising_emit_does_not_change_the_cycles_exit_status
    raiser = Object.new
    raiser.define_singleton_method(:emit) { |*| raise "telemetry down" }
    out = StringIO.new
    c = cycle(spawner: ->(_argv) { 0 }, roster: roster(@repo), obs: raiser, out: out)
    assert_equal 0, c.run
    assert_includes out.string, "WARN: fleet telemetry failed"
    assert_includes out.string, "telemetry down"
  end

  # MAX_RUNS_PER_CYCLE bounds the CYCLE, not one pass. Six runnable repos
  # against max_runs 4: the second pass must spend only what the first
  # left, or a fresh planner silently authorizes 8 turns a beat.
  def test_max_runs_is_a_cycle_cap_not_a_per_pass_cap
    repos = (1..6).map { |i| make_repo("m#{i}") }
    seen = []
    c = cycle(spawner: ->(argv) { seen << argv.last; 0 }, roster: roster(*repos), out: StringIO.new)
    c.run
    assert_equal 4, seen.size, seen.map { |p| File.basename(p) }.inspect
  end

  # BACKOFF_BASE/BACKOFF_CAP are fleet budget keys, and bump! is their only
  # consumer: a Backoff built without them ignores the operator's conf.
  def test_bump_uses_the_budgets_backoff_base
    Robur::State.write_stop_reason(@repo, "gate_red")
    c = cycle(spawner: ->(_argv) { 1 }, roster: roster(@repo), out: StringIO.new)
    c.run
    # cycle()'s budget: base 1, cap 2 — the class defaults are 3600/14400.
    count, until_ts = Robur::State.read_loop_backoff(@repo)
    assert_equal 1, count
    assert_operator until_ts - Time.now.to_i, :<=, 2
  end

  # The ONE writer is wired once, in cycle_runner, against
  # Paths.fleet_log_dir — the fleet has no repo dir of its own.
  def test_cycle_runner_builds_observability_against_the_fleet_log_dir
    with_pause_home do
      c = Robur::Fleet.cycle_runner(roster: roster(@repo))
      assert_kind_of Robur::Observability, c.obs
      c.obs.emit(:fleet_end, status: 0, runs: 0, plans: 0, skips: 0)
      assert File.file?(File.join(@root, "logs", "fleet", "events.jsonl"))
    end
  end
end

