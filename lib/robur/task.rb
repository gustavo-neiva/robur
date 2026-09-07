# frozen_string_literal: true

module Robur
  # Parses one PLAN.md task line per the frozen tracker grammar:
  #   "- [ ] T1.2 (normal, serial) title"
  class Task
    ID_RE = /\A([A-Z]+(?:\d+(?:\.\d+)?|-[\w-]+))\z/
    STATUS_RE = /\A\s*-\s+\[( |x|X|HUMAN)\]\s*/ # leading checkbox
    MARKER_RE = /\A\s*-\s+\[( |x|X|)\]\s*|\A\s*-\s+\[IN PROGRESS\]\s*|\A\s*-\s+\[HUMAN\]\s*/

    # Conventional-commit types, carried as a NON-FIRST tag so tier routing is
    # untouched: Tier.from_tag reads tags.first only and defaults anything it
    # does not know to "build", so `(normal, feat)` routes exactly as
    # `(normal)` did. The kind becomes the commit subject's prefix, which is
    # what makes the generated CHANGELOG groupable.
    KINDS = %w[feat fix perf refactor docs test chore].freeze

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

    # Conventional-commit type tag, or nil for a task written before the kind
    # tag was required — those still commit under the legacy `auto` prefix.
    def kind = (@tags & KINDS).first

    private

    def parse(line)
      return [nil, nil, [], line] unless (m = line.match(/\A\s*-\s+\[( |x|X|IN PROGRESS|HUMAN)\]\s*/))

      status = { " " => :open, "x" => :done, "X" => :done, "IN PROGRESS" => :in_progress, "HUMAN" => :parked }[m[1]]
      rest = m.post_match

      id = "?"
      if (m = rest.match(/\A([A-Z]+(?:\d+(?:\.\d+)?|-[\w-]+))\s+/))
        id = m[1]
        rest = m.post_match
      end

      tags = []
      # First parenthesised group only — a greedy scan would re-tag a task
      # whose title happens to mention e.g. "hard" in parens.
      if (m = rest.match(/\A\(([^)]*)\)\s+/))
        tags = m[1].split(",").map(&:strip).reject(&:empty?)
        rest = m.post_match
      end

      [status, id, tags, rest]
    end
  end
end
