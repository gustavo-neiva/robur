# frozen_string_literal: true

module Robur
  # Parses one PLAN.md task line per the frozen tracker grammar
  # (ratchet/lib/tracker.sh:1-21):  "- [ ] T1.2 (normal, serial) title"
  class Task
    ID_RE = /\A([A-Z]+(?:\d+(?:\.\d+)?|-[\w-]+))\z/
    STATUS_RE = /\A\s*-\s+\[( |x|X)\]\s*/ # leading checkbox
    MARKER_RE = /\A\s*-\s+\[( |x|X|)\]\s*|\A\s*-\s+\[IN PROGRESS\]\s*/

    attr_reader :status, :id, :tags, :text, :lineno

    def self.parse(line, lineno = nil)
      new(line, lineno)
    end

    def initialize(line, lineno = nil)
      @lineno = lineno
      @status, @id, @tags, @text = parse(line)
    end

    def task?
      !@status.nil?
    end

    private

    def parse(line)
      return [nil, nil, [], line] unless (m = line.match(/\A\s*-\s+\[( |x|X|IN PROGRESS)\]\s*/))

      status = { " " => :open, "x" => :done, "X" => :done, "IN PROGRESS" => :in_progress }[m[1]]
      rest = m.post_match

      id = "?"
      if (m = rest.match(/\A([A-Z]+(?:\d+(?:\.\d+)?|-[\w-]+))\s+/))
        id = m[1]
        rest = m.post_match
      end

      tags = []
      # First parenthesised group only — a greedy scan would re-tag a task
      # whose title mentions e.g. "hard" in parens (ratchet tracker.sh:145 bug).
      if (m = rest.match(/\A\(([^)]*)\)\s+/))
        tags = m[1].split(",").map(&:strip).reject(&:empty?)
        rest = m.post_match
      end

      [status, id, tags, rest]
    end
  end
end
