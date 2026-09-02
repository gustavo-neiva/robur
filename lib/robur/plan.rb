# frozen_string_literal: true

require "robur/task"
require "robur/sys"

module Robur
  # Wraps a tracker file (PLAN.md) per the frozen grammar
  # (ratchet/lib/tracker.sh). One counter for open/in-progress/done — the
  # bash loop had three, and atlas/bin/board-update.sh got the open one
  # wrong by anchoring `^- [ ]`.
  class Plan
    TASK_LINE = /\A[[:space:]]*-?[[:space:]]*\[( |x|X|IN PROGRESS)\]/
    HEADING = /\A#+ /
    SKIP_HEADING = /done|checklist/

    def initialize(path, proc: Sys::Proc.new)
      @path = path
      @proc = proc
    end

    def next_task(kind = :open)
      each_task(kind) { |t| return t }
      nil
    end

    def open? = !next_task(:open).nil?

    def in_progress? = !next_task(:in_progress).nil?

    def counts
      { open: count(:open), in_progress: count(:in_progress), done: count(:done) }
    end

    def completed_list
      done_lines.map { |l| l.sub(/\A[[:space:]]*-?[[:space:]]*\[x\][[:space:]]*/, "").gsub("**", "") }
    end

    # Best-effort: the [x] line newly staged this turn, else the newest [x]
    # in the file (tracker_completed_subject).
    def completed_subject
      line = staged_done_line
      line ||= done_lines.last
      return "step" unless line

      line.sub(/\A\+[[:space:]]*-?[[:space:]]*\[x\][[:space:]]*/, "")
          .sub(/\A[[:space:]]*-?[[:space:]]*\[x\][[:space:]]*/, "")
          .gsub("**", "")
          .slice(0, 100)
    end

    def task_block
      cur = next_task(:in_progress) || next_task(:open)
      return nil unless cur

      block = [all_lines[cur.lineno - 1].rstrip]
      all_lines[cur.lineno..].take_while { |l| l !~ TASK_LINE && l !~ HEADING }
                         .each { |l| block << l.rstrip }
      block.join("\n")
    end

    # The `<!-- class: MACHINE -->` marker on the tracker's first line.
    def class_marker
      all_lines[0]&.match(/<!--\s*class:\s*(\w+)\s*-->/)&.send(:[], 1)
    end

    private

    def count(kind)
      n = 0
      each_task(kind) { n += 1 }
      n
    end

    # Yields tasks of `kind`, skipping open/in-progress lines under a
    # done/checklist heading. Done lines count everywhere — that matches
    # tracker_count_done's plain grep.
    def each_task(kind)
      heading = nil
      all_lines.each_with_index do |line, i|
        heading = line.downcase if line =~ HEADING
        next unless line =~ TASK_LINE

        status = { " " => :open, "x" => :done, "X" => :done, "IN PROGRESS" => :in_progress }[$1]
        next unless status == kind
        next if status != :done && heading =~ SKIP_HEADING

        yield Task.parse(line, i + 1)
      end
    end

    def done_lines
      all_lines.select { |l| l =~ /\A[[:space:]]*-?[[:space:]]*\[x\]/ }
    end

    def all_lines
      @all_lines ||= File.exist?(@path) ? File.readlines(@path, chomp: true) : []
    end

    def staged_done_line
      out, = @proc.capture("git", "-C", File.dirname(@path), "diff", "--cached", "-U0", "--", File.basename(@path))
      out[/^\+.*\[x\].*/]&.chomp
    rescue StandardError
      nil
    end
  end
end
