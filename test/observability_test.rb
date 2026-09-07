# frozen_string_literal: true

require_relative "test_helper"
require "robur/observability"
require "robur/cli"
require "robur/loop"
require "robur/turn"
require "robur/state"
require "json"
require "time"
require "tmpdir"
require "shellwords"
require "fileutils"
require "open3"

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
          [2026-01-02 03:04:05] robur END after 3 turn(s).
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

    # Log dirs are REUSED across runs (~/.robur/logs/<slug>/events.jsonl is
    # one file for the life of the repo), so a consumer needs a run_id on
    # EVERY record — including run_start/run_end — to tell two runs apart. A
    # real production file held two separate run_start events with
    # overlapping turn numbers before this existed.
    def test_every_event_and_emit_event_record_carries_the_same_run_id
      Dir.mktmpdir do |dir|
        o = obs(dir)
        o.emit(:run_start, repo: dir, session: "s", tracker: "PLAN.md", models: %w[m],
               turn_timeout: 1, cooldown: 1, both_wait: 1, step_token: "S", done_token: "D",
               agent_cmd: "a", thinking: "", verify_cmd: "", commit_each_turn: "1",
               push_on_done: "0", open_pr: "0", log_dir: dir)
        o.emit(:turn_start, turn: 1, model: "acme/a", tier: "build", thinking: "off", task: "T1")
        o.emit_event(:tokens, input: 1, output: 1, cache_read: 0, cache_write: 0, cost: 0.0, messages: 1)
        o.emit(:run_end, turns: 1)

        records = File.readlines(File.join(dir, "events.jsonl")).map { |l| JSON.parse(l) }
        run_ids = records.map { |r| r["run_id"] }
        refute_nil run_ids.first
        assert_equal 1, run_ids.uniq.size, "every record of one run must carry the same run_id: #{run_ids}"
        assert_equal o.run_id, run_ids.first
      end
    end

    # Two runs sharing the SAME reused log dir must be distinguishable.
    def test_two_sequential_runs_in_the_same_log_dir_get_distinct_run_ids
      Dir.mktmpdir do |dir|
        first = obs(dir)
        first.emit(:run_start, repo: dir, session: "s", tracker: "PLAN.md", models: %w[m],
                   turn_timeout: 1, cooldown: 1, both_wait: 1, step_token: "S", done_token: "D",
                   agent_cmd: "a", thinking: "", verify_cmd: "", commit_each_turn: "1",
                   push_on_done: "0", open_pr: "0", log_dir: dir)
        first.emit(:run_end, turns: 3)

        second = obs(dir)
        second.emit(:run_start, repo: dir, session: "s", tracker: "PLAN.md", models: %w[m],
                    turn_timeout: 1, cooldown: 1, both_wait: 1, step_token: "S", done_token: "D",
                    agent_cmd: "a", thinking: "", verify_cmd: "", commit_each_turn: "1",
                    push_on_done: "0", open_pr: "0", log_dir: dir)
        second.emit(:run_end, turns: 7)

        refute_equal first.run_id, second.run_id

        records = File.readlines(File.join(dir, "events.jsonl")).map { |l| JSON.parse(l) }
        run_ids = records.map { |r| r["run_id"] }
        assert_equal 2, run_ids.uniq.size
        # the two run_start/run_end pairs are cleanly separable by run_id
        first_run = records.select { |r| r["run_id"] == first.run_id }
        second_run = records.select { |r| r["run_id"] == second.run_id }
        assert_equal %w[run_start run_end], first_run.map { |r| r["kind"] }
        assert_equal %w[run_start run_end], second_run.map { |r| r["kind"] }
      end
    end

    FIXTURES = File.expand_path("fixtures/turn-usage", __dir__)

    # `in` counts fresh input plus cacheRead+cacheWrite (cache-inclusive, so
    # prompt-caching spend is never under-reported); `out`/`cost` are the
    # plain summed counters. Pinned on a concatenated stream of 3 distinct
    # real pi turns (the turn-usage fixtures).
    def test_turn_usage_sums_input_output_and_cost_across_concatenated_turns
      Dir.mktmpdir do |dir|
        path = File.join(dir, "turn.jsonl")
        lines = %w[m1_think.json m1_end.json m2_tc.json m2_end.json m3_end.json start_zero.json]
                .map { |f| File.read(File.join(FIXTURES, f)).chomp }
        File.write(path, lines.join("\n") + "\n")

        detail = Observability.turn_usage_detail(path)
        ruby_in, ruby_out, ruby_cost = Observability.turn_usage(path).split("\t")

        assert_equal "387", ruby_out
        assert_equal "0.001034", ruby_cost
        assert_equal 3, detail[:messages]
        assert_equal 1011 + detail[:cache_read] + detail[:cache_write], ruby_in.to_i
        # Regression lock: with 3 distinct nonzero messages, sum > any single one.
        assert_operator ruby_in.to_i, :>, 637
      end
    end

    # Production usage fixture (2026-09, live session): cacheRead is ~1300x
    # input — the field every prior metric dropped on the floor.
    PROD_USAGE = {
      "input" => 321, "output" => 398, "cacheRead" => 423_488, "cacheWrite" => 0,
      "reasoning" => 307, "totalTokens" => 424_207, "cost" => { "total" => 0.006475895 }
    }.freeze

    def write_usage_events(path, usage_events)
      File.write(path, usage_events.map { |u| JSON.generate(u) }.join("\n") + "\n")
    end

    def usage_event(id, usage)
      { "id" => id, "message" => { "usage" => usage } }
    end

    def test_turn_usage_detail_sums_all_counters_on_the_production_fixture
      Dir.mktmpdir do |dir|
        path = File.join(dir, "turn.jsonl")
        write_usage_events(path, [usage_event("m1", PROD_USAGE)])

        d = Observability.turn_usage_detail(path)
        assert_equal 321, d[:input]
        assert_equal 398, d[:output]
        assert_equal 423_488, d[:cache_read]
        assert_equal 0, d[:cache_write]
        assert_equal 307, d[:reasoning]
        assert_in_delta 0.006475895, d[:cost], 1e-9
        assert_equal 1, d[:messages]
        # the metrics.tsv `in` column = total prompt-side tokens moved
        assert_equal "423809\t398\t0.006476", Observability.turn_usage(path)
      end
    end

    def test_turn_usage_detail_sums_deltas_not_max_on_non_monotonic_outputs
      Dir.mktmpdir do |dir|
        path = File.join(dir, "turn.jsonl")
        write_usage_events(path, [103, 193, 111].each_with_index.map do |out, i|
          usage_event("m#{i}", { "input" => 10, "output" => out, "cacheRead" => 100,
                                 "cacheWrite" => 1, "cost" => { "total" => 0.0 } })
        end)

        d = Observability.turn_usage_detail(path)
        assert_equal 3, d[:messages]
        assert_equal 407, d[:output] # 103+193+111: per-message deltas summed, never max
        assert_equal 30, d[:input]
        assert_equal 303, d[:cache_read] + d[:cache_write]
      end
    end

    def test_turn_usage_detail_collapses_an_all_zero_duplicate_flood_to_one_event
      Dir.mktmpdir do |dir|
        path = File.join(dir, "turn.jsonl")
        zero = usage_event("same", { "input" => 0, "output" => 0, "cacheRead" => 0,
                                     "cacheWrite" => 0, "cost" => { "total" => 0.0 } })
        write_usage_events(path, [zero] * 6)

        d = Observability.turn_usage_detail(path)
        assert_equal 1, d[:messages]
        assert_equal 0, d[:input]
        assert_equal "0\t0\t0.000000", Observability.turn_usage(path)
      end
    end

    def test_turn_usage_detail_ignores_message_update_stream_chunks
      Dir.mktmpdir do |dir|
        path = File.join(dir, "turn.jsonl")
        # production shape: per token a message_update with zero usage and no
        # id; the real usage lands once on message_end/turn_end.
        File.open(path, "w") do |f|
          500.times { |i| f.puts JSON.generate("type" => "message_update", "message" =>
            { "role" => "assistant", "content" => [{ "type" => "text", "text" => "chunk#{i}" }],
              "usage" => { "input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0 } }) }
          f.puts JSON.generate("type" => "turn_end", "message" =>
            { "role" => "assistant", "responseId" => "r1",
              "usage" => { "input" => 10, "output" => 170, "cacheRead" => 100, "cacheWrite" => 0,
                           "cost" => { "total" => 0.001 } } })
        end

        d = Observability.turn_usage_detail(path)
        assert_equal 1, d[:messages]
        assert_equal 170, d[:output]
      end
    end

    def test_turn_usage_detail_on_absent_file_is_all_zeros_without_raising
      d = Observability.turn_usage_detail("/nonexistent/turn.jsonl")
      assert_equal({ input: 0, output: 0, cache_read: 0, cache_write: 0,
                     reasoning: 0, cost: 0.0, messages: 0 }, d)
      assert_equal "0\t0\t0", Observability.turn_usage("/nonexistent/turn.jsonl")
    end

    def test_emit_event_writes_events_jsonl_only_with_v1
      Dir.mktmpdir do |dir|
        obs(dir).emit_event(:tokens, input: 321, output: 398, cache_read: 423_488,
                            cache_write: 0, cost: 0.006475895, messages: 1)

        refute File.exist?(File.join(dir, "loop.log"))
        rec = JSON.parse(File.read(File.join(dir, "events.jsonl")))
        assert_equal "tokens", rec["kind"]
        assert_equal 1, rec["v"]
        assert_equal "2026-01-02 03:04:05", rec["ts"]
        assert_equal 423_488, rec["cache_read"]
      end
    end

    def test_run_start_render_reproduces_the_loop_banner_verbatim
      lines = Observability::RENDER.fetch(:run_start).call(
        repo: "/repo/ta_justo", session: "robur-ta-justo (resume=yes)", resume: "yes",
        tracker: "PLAN.md", models: %w[m1 m2], turn_timeout: 3600, cooldown: 14_400,
        both_wait: 900, step_token: "STEP_COMPLETE", done_token: "ALL_DONE",
        agent_cmd: "pi agent", thinking: "", verify_cmd: "", commit_each_turn: "1",
        push_on_done: "0", open_pr: "1", log_dir: "/repo/ta_justo/.robur/logs/x"
      )
      expected = [
        "=" * 60,
        "robur START",
        "  repo      : /repo/ta_justo",
        "  session   : robur-ta-justo (resume=yes)",
        "  tracker   : PLAN.md",
        "  models    : m1 m2  (preference order, fallback chain)",
        "  turn cap  : 3600s   cooldown: 14400s   both-wait: 900s",
        "  tokens    : step='STEP_COMPLETE'  done='ALL_DONE'",
        "  agent     : pi agent",
        "  thinking  : inherit",
        "  verify    : <EMPTY — loud warning, no gate>",
        "  commit    : per-turn=yes  push-on-done=no  pr=yes",
        "  loop log  : /repo/ta_justo/.robur/logs/x/loop.log",
        "  stop      : Ctrl-C",
        "=" * 60
      ]
      assert_equal expected, lines
    end

    def test_new_render_kinds_render_their_human_lines
      r = Observability::RENDER
      assert_equal ["  model acme/a selected (tier up)"],
                   r.fetch(:model_selected).call(model: "acme/a", tier: "light",
                                                 chain: "acme/a acme/b", reason: "tier up")
      assert_equal ["  model acme/a benched for 900s (rate limit)"],
                   r.fetch(:model_benched).call(model: "acme/a", seconds: 900, reason: "rate limit")
      assert_equal ["  gate: red (verify failed)"],
                   r.fetch(:gate_result).call(status: "red", reason: "verify failed")
      assert_equal ["  progress stalled 3x — reset"],
                   r.fetch(:progress_stall).call(stalls: 3, action: "reset")
      assert_equal ["  task T1.2 blocked after 5 stall(s)"],
                   r.fetch(:task_blocked).call(task: "T1.2", stalls: 5)
      # `fresh` (input + cache_write) is the number that moves when a prompt
      # bloats; `in` is dominated by cache_r and hides it. robur-only kind —
      # no bash wording to hold frozen.
      assert_equal ["  tokens: in=423809 fresh=321 out=398 cache_r=423488 msgs=1 cost=$0.006476"],
                   r.fetch(:tokens).call(input: 321, output: 398, cache_read: 423_488,
                                         cache_write: 0, cost: 0.006475895, messages: 1)
      assert_equal ["robur END after 7 turn(s)."], r.fetch(:run_end).call(turns: 7)
      assert_equal r.fetch(:stop).call(turns: 7), r.fetch(:run_end).call(turns: 7)
    end

    def test_stats_counts_the_empty_outcome_class
      Dir.mktmpdir do |dir|
        o = obs(dir)
        o.emit(:turn_start, turn: 1, model: "acme/a", tier: "build", thinking: "off", task: "T1")
        o.emit(:turn_end, turn: 1, class: "empty", took: 10, exitcode: 0, task: "T1")

        out = Observability.stats(dir, cheap_model: "acme/a")
        assert_includes out, "failures              : hard=0 transient=0 timeout=0 exhausted=0 empty=1"
      end
    end

    def test_turn_usage_on_absent_file_is_zero
      assert_equal "0\t0\t0", Observability.turn_usage("/nonexistent/turn.jsonl")
    end

    def test_metrics_append_writes_twelve_frozen_columns_in_order
      Dir.mktmpdir do |dir|
        metrics = File.join(dir, "metrics.tsv")
        ENV["ROBUR_METRICS"] = metrics
        begin
          obs(dir).metrics_append("/repo/my-project", "turn", 3, "build", "acme/model",
                                   "step", 42, "T1", 100, 200, "0.001234")
        ensure
          ENV.delete("ROBUR_METRICS")
        end
        row = File.read(metrics).chomp
        fields = row.split("\t")
        assert_equal 12, fields.size
        assert_equal ["2026-01-02 03:04:05", "my-project", "turn", "3", "build", "acme/model",
                       "step", "42", "T1", "100", "200", "0.001234"], fields
      end
    end

    # The extension is opt-in: no `usage:`, no extra columns, so bash parity
    # on the frozen 12 is preserved for every legacy caller.
    def test_metrics_append_appends_extension_columns_only_when_usage_is_given
      Dir.mktmpdir do |dir|
        metrics = File.join(dir, "metrics.tsv")
        ENV["ROBUR_METRICS"] = metrics
        begin
          usage = { input: 3565, output: 785, cache_read: 2_555_904, cache_write: 0,
                    reasoning: 175, cost: 0.0388, messages: 6 }
          obs(dir).metrics_append("/repo/p", "turn", 1, "build", "m", "step", 1, "T1",
                                   3565 + 2_555_904, 785, "0.038800", usage: usage)
          obs(dir).metrics_append("/repo/p", "run", "-", "-", "m", "done", 1, "T1", 0, 0, "0.000000")
        ensure
          ENV.delete("ROBUR_METRICS")
        end
        turn_row, run_row = File.readlines(metrics).map { |l| l.chomp.split("\t", -1) }

        assert_equal 15, turn_row.size
        # fresh_in = input + cache_write; cache_read split out; messages last
        assert_equal %w[3565 2555904 6], turn_row.last(3)
        # tin stays reconstructible: col 10 == fresh_in + cache_read
        assert_equal turn_row[9].to_i, turn_row[12].to_i + turn_row[13].to_i

        assert_equal 12, run_row.size, "a caller passing no usage: must still write 12 columns"
      end
    end

    # The runaway ceiling: 6 round-trips is a healthy production turn, the
    # observed pathology was ~1,100.
    def test_runaway_detection_and_env_override
      refute Observability.runaway?({ messages: 6 })
      assert Observability.runaway?({ messages: 1100 })
      assert_equal Observability::RUNAWAY_MESSAGES_DEFAULT, Observability.runaway_messages

      ENV["ROBUR_RUNAWAY_MESSAGES"] = "5"
      begin
        assert_equal 5, Observability.runaway_messages
        assert Observability.runaway?({ messages: 6 })
      ensure
        ENV.delete("ROBUR_RUNAWAY_MESSAGES")
      end

      # a junk/zero override falls back to the default rather than firing on
      # every turn (messages >= 0 is always true)
      ENV["ROBUR_RUNAWAY_MESSAGES"] = "0"
      begin
        assert_equal Observability::RUNAWAY_MESSAGES_DEFAULT, Observability.runaway_messages
        refute Observability.runaway?({ messages: 0 })
      ensure
        ENV.delete("ROBUR_RUNAWAY_MESSAGES")
      end
    end

    # Backward compatibility: the ceiling was tunable as RATCHET_RUNAWAY_MESSAGES
    # long before the rename, so that name keeps working — ROBUR_ first, the
    # legacy name as the fallback.
    def test_runaway_ceiling_falls_back_to_the_legacy_env_name
      ENV["RATCHET_RUNAWAY_MESSAGES"] = "5"
      begin
        assert_equal 5, Observability.runaway_messages

        ENV["ROBUR_RUNAWAY_MESSAGES"] = "9"

        assert_equal 9, Observability.runaway_messages, "ROBUR_ must win over RATCHET_"
      ensure
        ENV.delete("RATCHET_RUNAWAY_MESSAGES")
        ENV.delete("ROBUR_RUNAWAY_MESSAGES")
      end
    end

    # stats stays byte-identical to bash; the source is a separate surface.
    # Real production logs contain invalid UTF-8 (agents stream partial UTF-8
    # when a turn is killed mid-write). bash was byte-oriented and immune;
    # Ruby raises ArgumentError the moment a regex touches such a string.
    # Measured against ~/.ratchet/logs/robur-271438/loop.log, this crashed
    # `ratchet status`, `ratchet stats` and the ETA path outright — a
    # cutover blocker, since both are on the CLI parity surface.
    BAD_UTF8 = "[2026-09-01 00:00:00] turn 1 end | class=step | took=10s \xC3\x28 \xFF\xFE\n"

    def test_log_readers_survive_invalid_utf8
      Dir.mktmpdir do |dir|
        log = File.join(dir, "loop.log")
        File.binwrite(log, "[2026-09-01 00:00:00] --- turn 1 | model=acme/a ---\n" + BAD_UTF8)

        assert_equal 10, Observability.avg_turn_secs(log)
        assert_includes Observability.stats(dir, cheap_model: "acme/a"), "turns started         : 1"
        assert_equal 10, Robur::CLI.avg_turn_secs(log)
      end
    end

    def test_turn_usage_detail_survives_invalid_utf8
      Dir.mktmpdir do |dir|
        f = File.join(dir, "turn.out")
        File.binwrite(f, "\xFF\xFE not json\n" +
                         %({"usage":{"input":10,"output":2,"cacheRead":5,"cost":{"total":0.5}}}\n))
        d = Observability.turn_usage_detail(f)
        assert_equal 10, d[:input]
        assert_equal 5, d[:cache_read]
        assert_equal 1, d[:messages]
      end
    end

    def test_read_scrubbed_returns_nil_rather_than_raising_on_a_missing_file
      assert_nil Robur::Sys.read_scrubbed("/nonexistent/nope.log")
    end

    def test_stats_source_names_the_adapter_without_touching_the_rendered_block
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "loop.log"), "")
        assert_includes Observability.stats_source(dir), "legacy"
        File.write(File.join(dir, "events.jsonl"), "")
        assert_equal "events.jsonl", Observability.stats_source(dir)
      end
    end

    def test_metrics_append_honours_robur_metrics_and_never_touches_the_real_file
      Dir.mktmpdir do |dir|
        real_home = File.join(dir, "home", ".robur")
        FileUtils.mkdir_p(real_home)
        metrics = File.join(dir, "isolated.tsv")
        ENV["ROBUR_HOME"] = real_home
        ENV["ROBUR_METRICS"] = metrics
        begin
          obs(dir).metrics_append("/repo/x", "run", "-", "-", "none", "done", 1, "?", 0, 0, "0.000000")
        ensure
          ENV.delete("ROBUR_HOME")
          ENV.delete("ROBUR_METRICS")
        end
        assert File.exist?(metrics)
        refute File.exist?(File.join(real_home, "metrics.tsv"))
      end
    end

    # Backward compatibility: an existing external harness (a shell wrapper,
    # a CI job) still exports the RATCHET_* names. Both must be honoured,
    # with the new name winning when they disagree.
    def test_legacy_ratchet_metrics_env_is_still_honoured
      Dir.mktmpdir do |dir|
        legacy = File.join(dir, "legacy.tsv")
        ENV["RATCHET_METRICS"] = legacy
        begin
          obs(dir).metrics_append("/repo/x", "run", "-", "-", "none", "done", 1, "?", 0, 0, "0.000000")

          assert_path_exists legacy

          preferred = File.join(dir, "preferred.tsv")
          ENV["ROBUR_METRICS"] = preferred
          obs(dir).metrics_append("/repo/x", "run", "-", "-", "none", "done", 1, "?", 0, 0, "0.000000")

          assert_path_exists preferred
          assert_equal 1, File.readlines(legacy).size, "ROBUR_METRICS must win over RATCHET_METRICS"
        ensure
          ENV.delete("RATCHET_METRICS")
          ENV.delete("ROBUR_METRICS")
        end
      end
    end

    # notify_human: the stub receives the message as $1, exactly once, and the
    # call returns without waiting on it (observability.sh:17).
    def test_notify_human_passes_message_as_dollar1_exactly_once
      Dir.mktmpdir do |dir|
        marker = File.join(dir, "touched")
        notify_cmd = "printf '%s\\n' \"$1\" >> #{marker.shellescape}"
        obs(dir).notify_human("merge the PR", notify_cmd: notify_cmd)

        # Poll on CONTENT, not existence: the async printf creates the file
        # before flushing, so reading at first existence can race to "".
        content = ""
        500.times do # 5s deadline; exits on first success, tolerates a loaded machine
          content = File.exist?(marker) ? File.read(marker) : ""
          break if content.include?("merge the PR")

          sleep 0.01
        end
        assert_includes content, "merge the PR"
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

    # Pinned rendering of `stats` on the logs/*.log fixtures (old/new
    # loop.log formats) — loop.log-only directories, so `stats` takes the
    # legacy fallback path (no events.jsonl).
    LOG_FIXTURES = File.expand_path("fixtures/logs", __dir__)

    EXPECTED_STATS = {
      "new-format.log" => <<~TXT,
        turns started         : 5
          on cheap (anthropic/claude-sonnet-4): 2 (40%)
        successes (step+done) : 5  (steps=4 done=1)
        failures              : hard=0 transient=0 timeout=0 exhausted=0 empty=0
        step-success rate     : 100%
        deadline kills        : 0
        wasted wall-hours     : 0.00h  (0.00h per 100 turns)
        turns by tier         : build=2, light=2, plan=1
        turns by model        : anthropic/claude-fable-5=1, anthropic/claude-sonnet-4=2, zai/glm-5-turbo=2
      TXT
      "old-format.log" => <<~TXT,
        turns started         : 4
          on cheap (anthropic/claude-sonnet-4): 3 (75%)
        successes (step+done) : 4  (steps=3 done=1)
        failures              : hard=0 transient=0 timeout=0 exhausted=0 empty=0
        step-success rate     : 100%
        deadline kills        : 0
        wasted wall-hours     : 0.00h  (0.00h per 100 turns)
      TXT
      "with-took.log" => <<~TXT,
        turns started         : 3
          on cheap (anthropic/claude-sonnet-4): 2 (67%)
        successes (step+done) : 3  (steps=3 done=0)
        failures              : hard=0 transient=0 timeout=0 exhausted=0 empty=0
        step-success rate     : 100%
        deadline kills        : 0
        wasted wall-hours     : 0.00h  (0.00h per 100 turns)
        turns by tier         : build=2, light=1
        turns by model        : anthropic/claude-sonnet-4=2, zai/glm-5-turbo=1
        turn duration         : avg=64s max=84s
      TXT
    }.freeze

    def test_stats_on_the_log_fixtures
      cheap_model = "anthropic/claude-sonnet-4"
      Dir.glob(File.join(LOG_FIXTURES, "*.log")).each do |fixture|
        Dir.mktmpdir do |dir|
          FileUtils.cp(fixture, File.join(dir, "loop.log"))
          assert_equal EXPECTED_STATS.fetch(File.basename(fixture)).chomp,
                       Observability.stats(dir, cheap_model: cheap_model),
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

    # T4.1: a stop-file drain must be an EVENT first — events.jsonl carries a
    # stop_requested record and a stopped record naming reason "stopped", and
    # loop.log shows one rendered human line for each (loop.log is a
    # RENDERING of events.jsonl, never free-form prose).
    def test_stop_file_run_emits_stop_requested_and_stopped_events
      home = Dir.mktmpdir("robur-home")
      old_home = ENV[Robur::Paths::HOME_ENV]
      ENV[Robur::Paths::HOME_ENV] = home
      repo = Dir.mktmpdir
      File.write(File.join(repo, "PLAN.md"), "- [ ] T1 (trivial) only task\n")
      File.write(File.join(repo, Robur::Paths::REPO_CONF), <<~CONF)
        MODELS="stub/stub-1"
        AGENT_CMD="stub-agent"
        VERIFY_CMD="true"
        TURN_TIMEOUT="30"
        SHORT_SLEEP="0"
        COMMIT_EACH_TURN="1"
      CONF
      Open3.capture3("git", "-C", repo, "init", "-q")
      Open3.capture3("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@e.c",
                     "-c", "commit.gpgsign=false", "add", "-A")
      Open3.capture3("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@e.c",
                     "-c", "commit.gpgsign=false", "commit", "-q", "-m", "seed")
      Open3.capture3("git", "-C", repo, "reset", "-q", "--", Robur::Paths::REPO_CONF)

      # Stop "drain" (level 1) arrives DURING turn 1 (startup clears any
      # pre-existing stop file), so the top-of-loop check fires for turn 2.
      Robur::Turn.singleton_class.send(:alias_method, :t41_run_orig, :run)
      Robur::Turn.singleton_class.send(:define_method, :run) do |**kw|
        Robur::State.write_stop(repo, "drain")
        File.write(kw[:turn_file], "STEP_COMPLETE\n")
        system("true")
        Robur::Turn::Result.new(status: $?, kill_reason: nil, elapsed: 0)
      end
      code = nil
      begin
        capture_io { code = Robur::Loop.run(repo, sleep_it: ->(_s) {}) }
      ensure
        Robur::Turn.singleton_class.send(:alias_method, :run, :t41_run_orig)
        Robur::Turn.singleton_class.send(:remove_method, :t41_run_orig)
      end

      assert_equal 0, code
      log_dir = File.join(home, "logs", Robur::CLI.project_slug(repo))
      events = File.readlines(File.join(log_dir, "events.jsonl")).map { |l| JSON.parse(l) }
      sr = events.find { |e| e["kind"] == "stop_requested" }
      sp = events.find { |e| e["kind"] == "stopped" }
      refute_nil sr, "stop_requested record missing from events.jsonl"
      assert_equal "stop file", sr["source"]
      assert_equal 1, sr["level"]
      refute_nil sp, "stopped record missing from events.jsonl"
      assert_equal "stopped", sp["reason"]
      assert_equal 1, sp["turns"]
      log = File.read(File.join(log_dir, "loop.log"))
      assert_includes log, "  stop requested (stop file, level 1)"
      assert_includes log, "  stopped: stopped after 1 turn(s)"
    ensure
      old_home ? ENV[Robur::Paths::HOME_ENV] = old_home : ENV.delete(Robur::Paths::HOME_ENV)
      Robur::CLI.instance_variable_set(:@loop_log, nil)
      Robur::CLI.instance_variable_set(:@quiet, nil)
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(repo)
    end
  end
end
