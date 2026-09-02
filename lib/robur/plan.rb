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

    def count(kind)
      n = 0
      each_task(kind) { n += 1 }
      n
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

    # "name\tdone\ttotal" per `## ` section (tracker_milestones). Plain
    # counting — no done/checklist heading skip, uppercase [X] not counted.
    def milestones
      sections.filter_map do |sec, lines|
        next if sec.nil?

        done = lines.count { |l| l =~ /^\s*-\s+\[x\]/ }
        total = done + lines.count { |l| l =~ /^\s*-\s+\[( |IN PROGRESS)\]/ }
        { name: sec, done: done, total: total } if total.positive?
      end
    end

    # Section holding the first open/in-progress task (tracker_next applies
    # the done/checklist heading skip when finding it; the section scan does
    # not). index is the 1-based position of that task within its section.
    def current_milestone
      target = bash_skipped_line(:in_progress) || bash_skipped_line(:open)
      return unless target

      name = nil
      idx = mdone = mtotal = 0
      found = false
      all_lines.each_with_index do |line, i|
        if line =~ /^## /
          break if found

          name = line.sub(/^## /, "")
          idx = mdone = mtotal = 0
        end
        case line
        when /^\s*-\s+\[x\]/
          mdone += 1
          mtotal += 1
          idx += 1 unless found
        when /^\s*-\s+\[( |IN PROGRESS)\]/
          mtotal += 1
          idx += 1 unless found
          found = true if i + 1 == target
        end
      end
      return unless found

      { name: name, index: idx, count: mtotal, done: mdone, total: mtotal }
    end

    def ready?
      return false unless File.exist?(@path)

      # Placeholder markers _(...)_, skipping backtick-quoted examples.
      return false if all_lines.any? { |l| !l.include?("`") && l =~ /_\([^)]+\)_/ }

      # All done (no open/in-progress tasks) = ready.
      tasks = all_lines.grep(/^\s*-?\s*\[( |IN PROGRESS)\]/)
      return true if tasks.empty?

      tasks.any? { |l| l =~ /\((trivial|normal|hard)[,)]/ }
    end

    # Milestones whose FIRST open task is tagged (independent).
    def independent_milestones
      sections.filter_map do |sec, lines|
        next if sec.nil?

        first = lines.find { |l| l =~ /^\s*-\s+\[ \]/ }
        next unless first&.match(/\(independent[,)]/)

        slug = sec.gsub(/[^A-Za-z0-9_-]/, "-").gsub(/-+/, "-").gsub(/\A-+|-+\z/, "")
        { name: sec, slug: slug }
      end
    end

    def task_block
      cur = next_task(:in_progress) || next_task(:open)
      return nil unless cur

      block = [all_lines[cur.lineno - 1].rstrip]
      all_lines[cur.lineno..].take_while { |l| l !~ TASK_LINE && l !~ HEADING }
                         .each { |l| block << l.rstrip }
      block.join("\n")
    end

    # Telegram DM body for a human-gate stop (human_block_brief): title line,
    # the task's block bounded at 900 bytes, unblock instruction, /blocked
    # pointer. Byte-truncated to match bash `head -c 900`.
    def human_block_brief(id, title)
      block = block_for(id)
      block = block.byteslice(0, 900) if block&.empty? == false
      format("%s: loop BLOCKED on a human decision — task: %s\n\n%s\n\n" \
             "Unblock: do the work, mark it [x] in %s — the next run resumes " \
             "on its own.\nFull context: /blocked in the Harbor Telegram bot.",
             File.basename(File.dirname(@path) || "repo"),
             title.nil? || title.empty? ? id : title,
             block.nil? || block.empty? ? "<task block not found in tracker>" : block,
             @path)
    end

    # The `<!-- class: MACHINE -->` marker on the tracker's first line.
    def class_marker
      all_lines[0]&.match(/<!--\s*class:\s*(\w+)\s*-->/)&.send(:[], 1)
    end

    private

    # Line number of the first task of `kind`, using tracker_next's rule:
    # open/in-progress lines under a done/checklist heading are skipped.
    def bash_skipped_line(kind)
      each_task(kind) { |t| return t.lineno }
      nil
    end

    # Yields each `## ` section as [name_without_prefix, lines]. Sections are
    # separated by `## ` headings; lines before the first one belong to nil.
    def sections
      result = [[nil, []]]
      all_lines.each do |line|
        if line =~ /^## /
          result << [line.sub(/^## /, ""), []]
        else
          result.last[1] << line
        end
      end
      result
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

    # Lines from the `- [...] id` task line through just before the next task
    # or heading — nil when the file is missing, id is "?", or no match.
    def block_for(id)
      return nil if id == "?" || !File.exist?(@path)

      start = /\A\s*- \[[^\]]+\] #{Regexp.escape(id)}( |$)/
      i = all_lines.index { |l| l =~ start }
      return nil unless i

      all_lines[i..].take_while.with_index do |l, j|
        j.zero? || (l !~ /\A\s*- \[/ && l !~ HEADING)
      end.join("\n")
    end

    def staged_done_line
      out, = @proc.capture("git", "-C", File.dirname(@path), "diff", "--cached", "-U0", "--", File.basename(@path))
      out[/^\+.*\[x\].*/]&.chomp
    rescue StandardError
      nil
    end
  end
end
