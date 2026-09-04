# frozen_string_literal: true

require "test_helper"
require "robur/loop"
require "fileutils"
require "json"

# Integration tests: the full `run` cycle against the fake-agent fixture stub.
# fake-agent ticks ONE task per invocation (python3-based, portable), which is
# exactly the done-criterion: three tasks -> three turns -> three commits.
class LoopTest < Minitest::Test
  AGENT = File.expand_path("fixtures/fake-agent", __dir__)

  def setup
    @home = Dir.mktmpdir("ratchet-home")
    @old_home = ENV["RATCHET_HOME"]
    ENV["RATCHET_HOME"] = @home
  end

  def teardown
    if @old_home
      ENV["RATCHET_HOME"] = @old_home
    else
      ENV.delete("RATCHET_HOME")
    end
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
    File.write(File.join(repo, ".ratchet.conf"), <<~CONF)
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
    git repo, "reset", "-q", "--", ".ratchet.conf"
    repo
  end

  def git(repo, *args)
    Open3.capture3("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@e.c",
                   "-c", "commit.gpgsign=false", *args)
  end

  def commits(repo)
    git(repo, "log", "--format=%s")[0].lines.map(&:strip)
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
    assert_equal "done\n", File.read(File.join(repo, ".ratchet", "stop_reason"))
  end

  # Regression guard for the audit's largest observability finding: NO
  # events.jsonl existed anywhere under ~/.ratchet/logs across 244 log
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
      echo 'AWS_KEY=AKIAABCDEFGHIJKLMNOP' > conf.txt # ratchet:allow-secret
      echo "ALL_DONE"
    SH
    FileUtils.chmod(0o755, agent)
    File.write(File.join(repo, ".ratchet.conf"),
               File.read(File.join(repo, ".ratchet.conf")).sub(AGENT, agent))

    notified = []
    stub_notify(notified) do
      code = Robur::Loop.run(repo, sleep_it: ->(_s) {})
      assert_equal 1, code
    end
    assert_equal "gate_red\n", File.read(File.join(repo, ".ratchet", "stop_reason"))
    assert notified.any? { |m| m.include?("gate RED after ALL_DONE") }
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

  private

  def stub_notify(collector)
    Robur::Loop.singleton_class.send(:alias_method, :notify_human_orig, :notify_human)
    Robur::Loop.singleton_class.send(:define_method, :notify_human) do |msg, *_|
      collector << msg
      nil
    end
    yield
  ensure
    Robur::Loop.singleton_class.send(:alias_method, :notify_human, :notify_human_orig)
    Robur::Loop.singleton_class.send(:remove_method, :notify_human_orig)
  end
end
