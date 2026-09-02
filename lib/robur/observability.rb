# frozen_string_literal: true

require "json"
require_relative "sys"

module Robur
  # loop.log is a RENDERING of events.jsonl, not free-form prose parsed back
  # with regexes (port of the emit lines in ratchet/bin/ratchet +
  # ratchet/lib/commit-gate.sh). Each emit call appends one JSON record with
  # the exact fields that produced the human line, so a metric never breaks
  # because someone reworded a log line.
  class Observability
    Event = Struct.new(:kind, :ts, :fields, keyword_init: true)

    # kind => fields hash -> array of human lines, in the exact bash wording.
    RENDER = {
      turn_start: lambda { |f|
        ["--- turn #{f[:turn]} | model=#{f[:model]} ---",
         "turn #{f[:turn]} | tier=#{f[:tier]} | model=#{f[:model]} | " \
         "thinking=#{f[:thinking]} | task=#{f[:task]}"]
      },
      turn_end: lambda { |f|
        ["turn #{f[:turn]} end | class=#{f[:class]} | took=#{f[:took]}s | " \
         "exitcode=#{f[:exitcode]} | task=#{f[:task]}"]
      },
      commit: ->(f) { ["  committed: #{f[:subject]}"] },
      bench: lambda { |f|
        ["ALL models benched (exhausted), attempt #{f[:attempt]}. " \
         "Sleeping #{f[:backoff]}s, then reset + retry."]
      },
      stop: ->(f) { ["ratchet END after #{f[:turns]} turn(s)."] },
    }.freeze

    def initialize(dir, clock: Sys::Clock.new)
      @loop_log = File.join(dir, "loop.log")
      @events_log = File.join(dir, "events.jsonl")
      @clock = clock
    end

    # emit(:turn_start, turn: 3, model: "m", tier: "build", thinking: "off", task: "T1")
    # -> appends the rendered line(s) to loop.log and one JSON record to
    # events.jsonl, and returns the Event.
    def emit(kind, **fields)
      lines = RENDER.fetch(kind).call(fields)
      ts = @clock.now.strftime("%Y-%m-%d %H:%M:%S")
      append(@loop_log, lines.map { |l| "[#{ts}] #{l}" }.join("\n") + "\n")
      append(@events_log, JSON.generate({ kind: kind.to_s, ts: ts }.merge(fields)) + "\n")
      Event.new(kind: kind, ts: ts, fields: fields)
    end

    private

    def append(path, text)
      File.open(path, "a") { |f| f.write(text) }
    end
  end
end
