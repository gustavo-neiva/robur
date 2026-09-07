# frozen_string_literal: true

require "robur/task"
require "robur/sys"

module Robur
  # Wraps a tracker file (PLAN.md) per the frozen grammar. ONE counter serves
  # open/in-progress/done: separate counters drift, and a duplicated one has
  # already gotten the open count wrong by anchoring `^- [ ]` instead of
  # going through this parser.
  class Plan
    TASK_LINE = /\A[[:space:]]*-?[[:space:]]*\[( |x|X|IN PROGRESS|HUMAN)\]/
    HEADING = /\A#+ /
    SKIP_HEADING = /done|checklist/

    # Where finished milestones go. Hardcoded, not a conf key: Config::ALLOWLIST
    # is a frozen contract, and this is a value that never varies per repo.
    CHANGELOG_FILE = "CHANGELOG.md"
    CHANGELOG_TITLE = "# Changelog"

    # Task-block field labels, used to bound the `do:` prose when mining a
    # one-sentence changelog description.
    BLOCK_FIELDS = %w[touches do snippet accept verify constraints].freeze

    def initialize(path, proc: Sys::Proc.new)
      @path = path
      @proc = proc
    end

    def changelog_path = File.join(File.dirname(@path), CHANGELOG_FILE)

    def next_task(kind = :open)
      each_task(kind) { |t| return t }
      nil
    end

    def open? = !next_task(:open).nil?

    def in_progress? = !next_task(:in_progress).nil?

    def counts
      { open: count(:open), in_progress: count(:in_progress), done: count(:done), parked: count(:parked) }
    end

    def count(kind)
      n = 0
      each_task(kind) { n += 1 }
      n += archived_done_count if kind == :done
      n
    end

    def completed_list
      done_lines.map { |l| l.sub(/\A[[:space:]]*-?[[:space:]]*\[x\][[:space:]]*/, "").gsub("**", "") }
    end

    # [x] tasks under the named `## ` milestone, in `[x] text` form — only
    # the leading dash is stripped, the checkbox is kept. The literal `-` is
    # required: a bare `[x]` with no dash does not count.
    #
    # Scans the tracker AND the changelog: once a milestone is archived its
    # section no longer exists in the tracker, and the milestone PR body is
    # built from this method AFTER the archive runs. Keeping the `- [x]` form
    # in the changelog is what makes one scan serve both files.
    def milestone_completed_list(mname)
      sec = sections(all_lines + changelog_lines).find { |name, _| name == mname }
      return [] unless sec

      sec[1].select { |l| l =~ /^[[:space:]]*-[[:space:]]*\[x\]/ }
            .map { |l| l.sub(/^[[:space:]]*-?[[:space:]]*/, "").gsub("**", "") }
    end

    # The Task this turn completed, or nil. Precedence is deliberate:
    #
    #   1. the [x] line newly STAGED this turn — hard evidence of what was
    #      actually ticked, so it outranks what the loop handed out;
    #   2. `dispatched`, the task the loop selected for this turn;
    #   3. the newest [x] anywhere in the file.
    #
    # (3) alone used to be the whole fallback, and it is a guess: a turn that
    # staged no tracker diff commits under an unrelated task's title. That is
    # cosmetic for a commit and corrupting for a changelog, which joins
    # entries to commits by task id — so (2) was inserted ahead of it.
    def completed_task(dispatched = nil)
      line = staged_done_line
      if line
        task = Task.parse(line.sub(/\A\+/, ""))
        return task if task.task?
      end
      return dispatched if dispatched

      last = done_lines.last
      last.nil? ? nil : Task.parse(last)
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
      target = first_task_lineno(:in_progress) || first_task_lineno(:open)
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

    # Notification body for a human-gate stop (human_block_brief): title
    # line, the task's block bounded at 900 bytes, unblock instruction. This
    # is what reaches the human via NOTIFY_CMD — robur owns the words, not
    # whatever downstream tool renders them, so it names no specific channel
    # or bot command. Byte-truncated at 900 so a DM-sized channel fits it in
    # one message.
    def human_block_brief(id, title)
      block = block_for(id)
      block = block.byteslice(0, 900) if block&.empty? == false
      format("%s: loop BLOCKED on a human decision — task: %s\n\n%s\n\n" \
             "Unblock: do the work, mark it [x] in %s — the next run resumes on its own.",
             File.basename(File.dirname(@path) || "repo"),
             title.nil? || title.empty? ? id : title,
             block.nil? || block.empty? ? "<task block not found in tracker>" : block,
             @path)
    end

    # The `<!-- class: MACHINE -->` marker on the tracker's first line.
    def class_marker
      all_lines[0]&.match(/<!--\s*class:\s*(\w+)\s*-->/)&.send(:[], 1)
    end

    # Move every finished `## ` milestone out of the tracker and into
    # CHANGELOG.md, newest first. Returns the archived section names.
    #
    # "Finished" is purely structural and needs no state file: a section with
    # at least one task line and no `[ ]`, `[IN PROGRESS]` or `[HUMAN]` left.
    # The section is DELETED from the tracker as it is written out, so a
    # second call is a no-op and the operation is idempotent by construction.
    #
    # only_last archives at most the newest finished section. That is the loop
    # default on purpose: a repo adopting this feature mid-flight would
    # otherwise have its entire finished backlog swept into the changelog in
    # one turn. `robur changelog` passes false to do exactly that, once,
    # deliberately.
    #
    # commits are [short_sha, subject] pairs covering the range since the last
    # archive; each is joined to a task by the id its subject carries. Commits
    # matching no task (hand-written fixes, merges) are listed separately —
    # they are invisible to the tracker and are most of what a reader wants.
    def archive_completed_milestones(commits: [], stat: nil, only_last: true, now: Time.now)
      return [] unless File.exist?(@path)

      lines = all_lines
      finished = section_ranges(lines).select { |name, s, e| archivable?(name, lines[s...e]) }
      finished = finished.last(1) if only_last
      return [] if finished.empty?

      entries = finished.map { |name, s, e| render_entry(name, lines[s...e], commits, stat, now) }
      prepend_changelog(entries.reverse)

      cut = finished.map { |_n, s, e| (s...e) }
      kept = lines.each_with_index.reject { |_l, i| cut.any? { |r| r.cover?(i) } }.map(&:first)
      File.write(@path, "#{kept.join("\n").rstrip}\n")
      @cache_stamp = nil
      finished.map(&:first)
    end

    private

    # [[name, start_index, end_index_exclusive], ...] for every `## ` section.
    # start_index is the heading line itself, so cutting a range removes the
    # heading with its body.
    def section_ranges(lines)
      starts = lines.each_index.select { |i| lines[i] =~ /^## / }
      starts.each_with_index.map do |s, n|
        [lines[s].sub(/^## /, ""), s, starts[n + 1] || lines.size]
      end
    end

    # A section is archivable when it holds real tasks and none of them are
    # still open. The done/checklist heading skip is reused from the task
    # scan so "## Definition of done" is never mistaken for a milestone.
    def archivable?(name, body)
      return false if name.to_s.downcase =~ SKIP_HEADING

      tasks = body.grep(TASK_LINE)
      return false if tasks.empty?

      tasks.none? { |l| l =~ /\A[[:space:]]*-?[[:space:]]*\[( |IN PROGRESS|HUMAN)\]/ }
    end

    # Groups a section body into [task_line, indented_body_lines] pairs.
    def task_groups(body)
      groups = []
      body.each do |line|
        if line =~ TASK_LINE
          groups << [line, []]
        elsif !groups.empty? && line !~ HEADING
          groups.last[1] << line
        end
      end
      groups
    end

    # First sentence of the task block's `do:` field — the description the
    # planner already wrote, reused verbatim so the changelog needs no model.
    def do_summary(block)
      text = block.join(" ")[/(?:\A|\s)do:\s*(.+)/m, 1]
      return nil if text.nil?

      text = text.split(/\s(?:#{BLOCK_FIELDS.join("|")}):\s/).first.to_s.squeeze(" ").strip
      sentence = text[/\A.*?[.!?](?=\s|\z)/] || text
      sentence.empty? ? nil : sentence
    end

    # One `## <name>` changelog section. The task lines keep their `- [x]`
    # marker so milestone_completed_list can still find them here after the
    # tracker section is gone.
    def render_entry(name, body, commits, stat, now)
      claimed = []
      tasks = task_groups(body).flat_map do |line, block|
        task = Task.parse(line)
        hit = commits.find { |sha, subject| !claimed.include?(sha) && mentions?(subject, task.id) }
        claimed << hit[0] if hit
        summary = do_summary(block)
        ["- [x] #{task.id} #{task.text.gsub("**", "").strip}#{hit ? " — `#{hit[0]}`" : ""}",
         summary ? "      #{summary}" : nil]
      end.compact

      extra = unmatched_after_first_task(commits, claimed)
      out = ["## #{name}", subheading(now, claimed.size + extra.size, stat), "", *tasks]
      unless extra.empty?
        out << ""
        out << "Also in this range:"
        extra.each { |sha, subject| out << "- `#{sha}` #{subject}" }
      end
      "#{out.join("\n")}\n"
    end

    # Counts only the commits attributed to this milestone, not every commit in
    # the range — the two differ whenever the range has no anchor.
    def subheading(now, commit_count, stat)
      parts = [now.strftime("%Y-%m-%d")]
      parts << "#{commit_count} commit#{"s" unless commit_count == 1}" if commit_count.positive?
      parts << stat unless stat.to_s.empty?
      "_#{parts.join(" · ")}_"
    end

    # Word-boundary id match that does not let "T1.1" match inside "T1.10".
    def mentions?(subject, id)
      return false if id.nil? || id == "?"

      subject =~ /(?<![\w.])#{Regexp.escape(id)}(?![\w.])/ ? true : false
    end

    # Commits in the range belonging to no task — hand-written fixes, which are
    # invisible to the tracker and are most of what a reader wants. Bounded to
    # the span starting at the milestone's OWN first commit: with no anchor the
    # range is the repo's entire history, so the first archive in a repo would
    # otherwise file every commit ever made under this one milestone. Nothing
    # claimed means the span is unknowable, so nothing is listed.
    def unmatched_after_first_task(commits, claimed)
      first = commits.index { |sha, _subject| claimed.include?(sha) }
      return [] if first.nil?

      commits[first..].reject { |sha, _subject| claimed.include?(sha) }
    end

    # Tasks moved into the changelog are still done — the tracker just no
    # longer holds them. count(:done) must see them, or archiving the final
    # milestone empties the tracker and `run`'s all-done fast path (which
    # requires done.positive?) stops firing, spinning an extra turn.
    def archived_done_count
      changelog_lines.count { |l| l =~ /\A[[:space:]]*-[[:space:]]*\[x\]/ }
    end

    def changelog_lines
      path = changelog_path
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end

    def prepend_changelog(entries)
      path = changelog_path
      body = File.exist?(path) ? File.read(path) : ""
      body = body.sub(/\A#{Regexp.escape(CHANGELOG_TITLE)}\n+/, "").rstrip
      blocks = entries.map(&:rstrip)
      blocks << body unless body.empty?
      File.write(path, "#{CHANGELOG_TITLE}\n\n#{blocks.join("\n\n")}\n")
    end

    # Line number of the first task of `kind`, using tracker_next's rule:
    # open/in-progress lines under a done/checklist heading are skipped.
    def first_task_lineno(kind)
      each_task(kind) { |t| return t.lineno }
      nil
    end

    # Yields each `## ` section as [name_without_prefix, lines]. Sections are
    # separated by `## ` headings; lines before the first one belong to nil.
    def sections(lines = all_lines)
      result = [[nil, []]]
      lines.each do |line|
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

        status = { " " => :open, "x" => :done, "X" => :done, "IN PROGRESS" => :in_progress, "HUMAN" => :parked }[$1]
        next unless status == kind
        next if status != :done && heading =~ SKIP_HEADING

        yield Task.parse(line, i + 1)
      end
    end

    def done_lines
      all_lines.select { |l| l =~ /\A[[:space:]]*-?[[:space:]]*\[x\]/ }
    end

    def all_lines
      # Cache keyed on [mtime, size], re-statted on EVERY call: the run loop
      # holds one Plan across turns while the agent edits the file — a naive
      # memo once served turn-1's lines forever. The stamp check gives
      # always-fresh reads at one read per change instead of one per call.
      # ponytail: a same-tick same-size rewrite keeps the stale cache; upgrade
      # path = content digest instead of mtime+size.
      return [] unless File.exist?(@path)

      stamp = [File.mtime(@path), File.size(@path)]
      if @cache_stamp != stamp
        @cache_stamp = stamp
        @cache_lines = File.readlines(@path, chomp: true)
      end
      @cache_lines
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
