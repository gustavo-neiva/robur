# frozen_string_literal: true

require_relative "test_helper"
require "robur/observability"
require "json"
require "time"
require "tmpdir"
require "shellwords"
require "fileutils"

module Robur
  class ObservabilityTest < Minitest::Test
    FakeClock = Struct.new(:time) do
      def now = time
    end

    def obs(dir, ts: "2026-01-02 03:04:05")
      Observability.new(dir, clock: FakeClock.new(Time.strptime(ts, "%Y-%m-%d %H:%M:%S")))
    end

    def test_run_of_five_events_renders_the_frozen_bash_lines
      Dir.mktmpdir do |dir|
        o = obs(dir)
        o.emit(:turn_start, turn: 3, model: "acme/model", tier: "build", thinking: "off", task: "T1 do a thing")
        o.emit(:turn_end, turn: 3, class: "step", took: 42, exitcode: 0, task: "T1 do a thing")
        o.emit(:commit, subject: "T1 (normal) do a thing")
        o.emit(:bench, attempt: 2, backoff: 900)
        o.emit(:stop, turns: 3)

        expected = <<~LOG
          [2026-01-02 03:04:05] --- turn 3 | model=acme/model ---
          [2026-01-02 03:04:05] turn 3 | tier=build | model=acme/model | thinking=off | task=T1 do a thing
          [2026-01-02 03:04:05] turn 3 end | class=step | took=42s | exitcode=0 | task=T1 do a thing
          [2026-01-02 03:04:05]   committed: T1 (normal) do a thing
          [2026-01-02 03:04:05] ALL models benched (exhausted), attempt 2. Sleeping 900s, then reset + retry.
          [2026-01-02 03:04:05] ratchet END after 3 turn(s).
        LOG
        assert_equal expected, File.read(File.join(dir, "loop.log"))
      end
    end

    def test_events_jsonl_has_one_parseable_record_per_line_reconstructing_the_log_line
      Dir.mktmpdir do |dir|
        o = obs(dir)
        o.emit(:turn_start, turn: 3, model: "acme/model", tier: "build", thinking: "off", task: "T1")
        o.emit(:turn_end, turn: 3, class: "step", took: 42, exitcode: 0, task: "T1")
        o.emit(:commit, subject: "T1 subject")
        o.emit(:bench, attempt: 2, backoff: 900)
        o.emit(:stop, turns: 3)

        records = File.readlines(File.join(dir, "events.jsonl")).map { |l| JSON.parse(l, symbolize_names: true) }
        assert_equal 5, records.size
        assert records.all? { |r| r[:ts] == "2026-01-02 03:04:05" }

        kinds = records.map { |r| r[:kind] }
        assert_equal %w[turn_start turn_end commit bench stop], kinds

        rendered = records.map do |r|
          f = r.reject { |k, _| %i[kind ts].include?(k) }
          Observability::RENDER.fetch(r[:kind].to_sym).call(f)
        end.flatten
        loop_lines = File.readlines(File.join(dir, "loop.log")).map { |l| l.sub(/^\[[^\]]+\] /, "").chomp }
        assert_equal loop_lines, rendered
      end
    end

    def test_emit_appends_across_calls_and_returns_the_event
      Dir.mktmpdir do |dir|
        o = obs(dir)
        event = o.emit(:stop, turns: 1)
        o.emit(:stop, turns: 2)
        assert_equal :stop, event.kind
        assert_equal({ turns: 1 }, event.fields)
        assert_equal 2, File.readlines(File.join(dir, "loop.log")).size
        assert_equal 2, File.readlines(File.join(dir, "events.jsonl")).size
      end
    end

    # Parity: bash observability.sh's _turn_usage on the same concatenated
    # stream of real pi events (the turn-usage fixtures).
    BASH_OBSERVABILITY = File.expand_path("../../ratchet/lib/observability.sh", __dir__)
    FIXTURES = File.expand_path("fixtures/turn-usage", __dir__)

    def bash_turn_usage(path)
      `bash -c 'source #{BASH_OBSERVABILITY.shellescape}; _turn_usage #{path.shellescape}' 2>/dev/null`.chomp
    end

    def test_turn_usage_matches_bash_turn_usage_on_the_fixtures
      Dir.mktmpdir do |dir|
        path = File.join(dir, "turn.jsonl")
        lines = %w[m1_think.json m1_end.json m2_tc.json m2_end.json m3_end.json start_zero.json]
                .map { |f| File.read(File.join(FIXTURES, f)).chomp }
        File.write(path, lines.join("\n") + "\n")

        assert_equal bash_turn_usage(path), Observability.turn_usage(path)
        # Regression lock: with 3 distinct nonzero messages, sum > any single one.
        input, = Observability.turn_usage(path).split("\t").map(&:to_i)
        assert_operator input, :>, 637
      end
    end

    def test_turn_usage_on_absent_file_is_zero
      assert_equal "0\t0\t0", Observability.turn_usage("/nonexistent/turn.jsonl")
    end

    def test_metrics_append_writes_twelve_frozen_columns_in_order
      Dir.mktmpdir do |dir|
        metrics = File.join(dir, "metrics.tsv")
        ENV["RATCHET_METRICS"] = metrics
        begin
          obs(dir).metrics_append("/repo/my-project", "turn", 3, "build", "acme/model",
                                   "step", 42, "T1", 100, 200, "0.001234")
        ensure
          ENV.delete("RATCHET_METRICS")
        end
        row = File.read(metrics).chomp
        fields = row.split("\t")
        assert_equal 12, fields.size
        assert_equal ["2026-01-02 03:04:05", "my-project", "turn", "3", "build", "acme/model",
                       "step", "42", "T1", "100", "200", "0.001234"], fields
      end
    end

    def test_metrics_append_honours_ratchet_metrics_and_never_touches_the_real_file
      Dir.mktmpdir do |dir|
        real_home = File.join(dir, "home", ".ratchet")
        FileUtils.mkdir_p(real_home)
        metrics = File.join(dir, "isolated.tsv")
        ENV["RATCHET_HOME"] = real_home
        ENV["RATCHET_METRICS"] = metrics
        begin
          obs(dir).metrics_append("/repo/x", "run", "-", "-", "none", "done", 1, "?", 0, 0, "0.000000")
        ensure
          ENV.delete("RATCHET_HOME")
          ENV.delete("RATCHET_METRICS")
        end
        assert File.exist?(metrics)
        refute File.exist?(File.join(real_home, "metrics.tsv"))
      end
    end

    # notify_human: the stub receives the message as $1, exactly once, and the
    # call returns without waiting on it (observability.sh:17).
    def test_notify_human_passes_message_as_dollar1_exactly_once
      Dir.mktmpdir do |dir|
        marker = File.join(dir, "touched")
        notify_cmd = "printf '%s\\n' \"$1\" >> #{marker.shellescape}"
        obs(dir).notify_human("merge the PR", notify_cmd: notify_cmd)

        50.times do
          break if File.exist?(marker)

          sleep 0.01
        end

        assert File.exist?(marker), "NOTIFY_CMD never fired"
        assert_includes File.read(marker), "merge the PR"
      end
    end

    def test_notify_human_is_a_noop_hook_when_notify_cmd_is_empty
      Dir.mktmpdir { |dir| assert_nil obs(dir).notify_human("nothing to run", notify_cmd: "") }
    end

    def test_notify_human_emits_the_human_needed_line
      Dir.mktmpdir do |dir|
        obs(dir).notify_human("nothing to run", notify_cmd: "")
        assert_includes File.read(File.join(dir, "loop.log")), "HUMAN NEEDED: nothing to run"
        event = JSON.parse(File.read(File.join(dir, "events.jsonl")).lines.first)
        assert_equal "human", event["kind"]
        assert_equal "nothing to run", event["msg"]
      end
    end

    # Parity: bash observability.sh's cmd_stats on the logs/*.log fixtures —
    # loop.log-only directories, so `stats` takes the legacy fallback path.
    LOG_FIXTURES = File.expand_path("fixtures/logs", __dir__)
    RATCHET_LIB_DIR = File.dirname(BASH_OBSERVABILITY)

    def bash_stats(loop_log, cheap_model)
      script = <<~SH
        source #{RATCHET_LIB_DIR.shellescape}/common.sh
        source #{RATCHET_LIB_DIR.shellescape}/observability.sh
        models_arr=(#{cheap_model.shellescape})
        LOOP_LOG=#{loop_log.shellescape}
        cmd_stats
      SH
      `bash -c #{script.shellescape} 2>/dev/null`.chomp
    end

    def test_stats_matches_bash_cmd_stats_on_the_log_fixtures
      cheap_model = "anthropic/claude-sonnet-4"
      Dir.glob(File.join(LOG_FIXTURES, "*.log")).each do |fixture|
        Dir.mktmpdir do |dir|
          FileUtils.cp(fixture, File.join(dir, "loop.log"))
          assert_equal bash_stats(fixture, cheap_model), Observability.stats(dir, cheap_model: cheap_model),
                       "mismatch for #{File.basename(fixture)}"
        end
      end
    end

    # events.jsonl is structured (turn_end's `class` field IS the outcome), so
    # a run stats() reads while events.jsonl exists sees successes/tier/model
    # counts a loop.log-only fallback cannot recover from prose alone.
    def test_stats_prefers_events_jsonl_when_present
      Dir.mktmpdir do |dir|
        o = obs(dir)
        o.emit(:turn_start, turn: 1, model: "acme/a", tier: "build", thinking: "off", task: "T1")
        o.emit(:turn_end, turn: 1, class: :step, took: 10, exitcode: 0, task: "T1")
        o.emit(:turn_start, turn: 2, model: "acme/b", tier: "light", thinking: "off", task: "T2")
        o.emit(:turn_end, turn: 2, class: :done, took: 5, exitcode: 0, task: "T2")

        out = Observability.stats(dir, cheap_model: "acme/a")
        assert_includes out, "turns started         : 2"
        assert_includes out, "successes (step+done) : 2  (steps=1 done=1)"
        assert_includes out, "turns by tier         : build=1, light=1"
        assert_includes out, "turn duration         : avg=8s max=10s"

        File.delete(File.join(dir, "events.jsonl"))
        fallback = Observability.stats(dir, cheap_model: "acme/a")
        assert_includes fallback, "turns started         : 2" # the fallback still sees turn markers
      end
    end

    def test_stats_raises_when_neither_source_exists
      Dir.mktmpdir do |dir|
        assert_raises(RuntimeError) { Observability.stats(dir) }
      end
    end
  end
end
