# frozen_string_literal: true

require_relative "test_helper"
require "robur/observability"
require "json"
require "time"
require "tmpdir"

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
  end
end
