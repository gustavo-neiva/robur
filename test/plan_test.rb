# frozen_string_literal: true

require_relative "test_helper"
require "robur/plan"
require "tmpdir"

class PlanTest < Minitest::Test
  def own_plan = Robur::Plan.new("PLAN.md")

  # Built on a fixture tracker, NOT this repo's own PLAN.md: a tracker with
  # every task done is a legitimate steady state (it is what `run`'s all-done
  # fast path exists for), and this assertion is about task_block's shape, not
  # about whether the project happens to have work left. Coupling it to the
  # live tracker made the suite go red the moment the last box was ticked.
  def test_task_block_starts_at_current_task
    Dir.mktmpdir do |dir|
      file = File.join(dir, "PLAN.md")
      File.write(file, <<~PLAN)
        # Plan

        ## M1
        - [x] T1.1 (trivial) already done
        - [ ] T1.2 (normal) the current task
            do: something
        - [ ] T1.3 (normal) a later task
      PLAN
      plan = Robur::Plan.new(file)
      block = plan.task_block
      first = plan.next_task(:in_progress) || plan.next_task(:open)

      assert_equal "T1.2", first.id
      assert block.start_with?("- ["), block
      assert block.match?(/\A- \[[^\]]+\] #{Regexp.escape(first.id)}(\s|$)/)
      refute block.include?("\n- ["), "task_block must stop before the next task"
    end
  end

  # The all-done steady state: no open or in-progress task -> no task block.
  def test_task_block_is_nil_when_every_task_is_done
    Dir.mktmpdir do |dir|
      file = File.join(dir, "PLAN.md")
      File.write(file, "# Plan\n\n## M1\n- [x] T1.1 (trivial) done\n")
      plan = Robur::Plan.new(file)
      assert_nil plan.next_task(:open)
      assert_nil plan.next_task(:in_progress)
      assert_nil plan.task_block
    end
  end

  def test_class_marker
    assert_equal "MACHINE", own_plan.class_marker
  end

  def test_completed_list_strips_marker_and_bold
    entry = own_plan.completed_list.find { |l| l.start_with?("T1.1") }
    refute entry.match?(/\[x\]/)
    refute entry.include?("**")
  end

  # Precedence: staged [x] diff line (hard evidence) → the dispatched task →
  # newest [x] in the file. Tier tags are stripped; the id survives, because
  # the changelog joins entries to commits by exactly that id.
  def test_completed_task_prefers_staged_diff_then_dispatched_then_newest_done
    staged = Object.new
    def staged.capture(*) = ["+++ b/PLAN.md\n+- [x] T9.9 (normal, feat) freshly staged task", nil, nil]
    task = Robur::Plan.new("PLAN.md", proc: staged).completed_task
    assert_equal "T9.9", task.id
    assert_equal "freshly staged task", task.text
    assert_equal "feat", task.kind

    noop = Object.new
    def noop.capture(*) = ["", nil, nil]
    # No staged [x] line, but the loop dispatched a task — that outranks the
    # "newest [x] anywhere" guess, which attributes work to an unrelated task.
    dispatched = Robur::Task.parse("- [ ] T5.5 (normal, fix) the dispatched one")
    assert_equal "T5.5", Robur::Plan.new("PLAN.md", proc: noop).completed_task(dispatched).id

    newest_done = File.readlines("PLAN.md").grep(/\A- \[x\] (\S+)/) { Regexp.last_match(1) }.last
    assert_equal newest_done, Robur::Plan.new("PLAN.md", proc: noop).completed_task.id
  end

  def test_heading_skip_rule
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, <<~PLAN)
        <!-- class: MACHINE -->
        # Plan
        - [x] T1 done one
        ## Definition of Done
        - [ ] T1.2 (normal) not a task
        ## Work
        - [ ] T2 real task
        - [IN PROGRESS] T3 wip
      PLAN
      plan = Robur::Plan.new(path)
      assert_equal "T2", plan.next_task.id
      assert plan.open?
      assert plan.in_progress?
      assert_equal({ open: 1, in_progress: 1, done: 1, parked: 0 }, plan.counts)
      # bash tracker_task_block prefers the in-progress task as "current".
      assert_equal "- [IN PROGRESS] T3 wip", plan.task_block
    end
  end

  def test_missing_file_is_empty
    plan = Robur::Plan.new("/nonexistent/PLAN.md")
    refute plan.open?
    assert_nil plan.next_task
    assert_equal({ open: 0, in_progress: 0, done: 0, parked: 0 }, plan.counts)
    assert_nil plan.class_marker
  end

  def test_parked_task_skipped_by_next_task_open_and_counted
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, <<~PLAN)
        # Plan

        ## M1
        - [HUMAN] T1 (normal) needs a human fact — PARKED, needs human: which account?
        - [ ] T2 (normal) real next task
      PLAN
      plan = Robur::Plan.new(path)

      assert_equal "T2", plan.next_task(:open).id
      assert plan.open?
      assert_equal :parked, plan.next_task(:parked).status
      assert_equal({ open: 1, in_progress: 0, done: 0, parked: 1 }, plan.counts)
    end
  end

  def test_all_lines_cache_repeated_reads_consistent
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, "# Plan\n- [ ] T1 (normal) one\n")
      plan = Robur::Plan.new(path)
      assert_equal plan.task_block, plan.task_block
      assert_equal plan.counts, plan.counts
    end
  end

  def test_all_lines_cache_picks_up_rewritten_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, "# Plan\n- [ ] T1 (normal) original task\n")
      plan = Robur::Plan.new(path)
      assert_equal "T1", plan.next_task.id

      File.write(path, "# Plan\n- [ ] T2 (normal) rewritten task with a longer body\n")
      # Force a distinct mtime stamp even on coarse-granularity filesystems.
      File.utime(Time.now + 2, Time.now + 2, path)
      assert_equal "T2", plan.next_task.id
      assert_equal({ open: 1, in_progress: 0, done: 0, parked: 0 }, plan.counts)
    end
  end

  def test_milestones_current_milestone_ready_and_independent_on_synthetic_tracker
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, <<~PLAN)
        <!-- class: MACHINE -->
        # Plan
        ## Milestone A
        - [x] T1 (trivial) done thing
        - [ ] T2 (normal, independent) next thing
        - [IN PROGRESS] T3 (hard) current thing
        ## Milestone B
        - [ ] T4 (normal, serial) dependent
        - [ ] T5 untagged tail _placeholder example_
        ## Definition of Done
        - [ ] not a real task
      PLAN
      plan = Robur::Plan.new(path)

      assert_equal [{ name: "Milestone A", done: 1, total: 3 },
                    { name: "Milestone B", done: 0, total: 2 },
                    { name: "Definition of Done", done: 0, total: 1 }], plan.milestones
      assert_equal({ name: "Milestone A", index: 3, count: 3, done: 1, total: 3 }, plan.current_milestone)
      assert plan.ready?
      # T2 is tagged (normal, independent) — independent must be the FIRST
      # tag to count, so Milestone A's first open task does not qualify.
      assert_equal [], plan.independent_milestones
    end
  end

  def test_current_milestone_is_nil_when_every_task_is_done
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, "# Plan\n## M1\n- [x] T1 (trivial) done\n")
      assert_nil Robur::Plan.new(path).current_milestone
    end
  end

  def test_independent_milestone_is_found_when_first_open_task_is_tagged
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, <<~PLAN)
        # Plan
        ## Milestone A
        - [ ] T1 (independent) leads with the tag
        ## Milestone B
        - [ ] T2 (normal) not tagged
      PLAN
      assert_equal [{ name: "Milestone A", slug: "Milestone-A" }], Robur::Plan.new(path).independent_milestones
    end
  end

  def test_human_block_brief_shape
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      File.write(path, <<~PLAN)
        <!-- class: MACHINE -->
        # Plan
        ## M1
        - [ ] T1 (hard) blocked thing
          do: the work with details
          constraints: stay safe
        - [ ] T2 (normal) other
        PLAN
      brief = Robur::Plan.new(path).human_block_brief("T1", "t-title")
      assert_equal "#{File.basename(dir)}: loop BLOCKED on a human decision — task: t-title\n\n" \
                   "- [ ] T1 (hard) blocked thing\n  do: the work with details\n  constraints: stay safe\n\n" \
                   "Unblock: do the work, mark it [x] in #{path} — the next run resumes on its own.",
                   brief

      # fallback when the block is not found (unknown id, or "?")
      %w[ZZ ?].each do |id|
        missing = Robur::Plan.new(path).human_block_brief(id, nil)
        assert_equal "#{File.basename(dir)}: loop BLOCKED on a human decision — task: #{id}\n\n" \
                     "<task block not found in tracker>\n\n" \
                     "Unblock: do the work, mark it [x] in #{path} — the next run resumes on its own.",
                     missing
      end
    end
  end

  ARCHIVE_PLAN = <<~PLAN
    <!-- class: MACHINE -->
    # Plan
    ## M1
    - [x] T1.1 (trivial, feat) add the widget
          do: The widget is the entry point. Everything else hangs off it.
          verify: true
    - [x] T1.2 (normal, fix) stop the widget leaking
    ## M2
    - [x] T2.1 (normal, feat) done already
    - [ ] T2.2 (normal, feat) not done
    ## Definition of done
    - [x] every box ticked
  PLAN

  def archive_plan(dir, body = ARCHIVE_PLAN)
    path = File.join(dir, "PLAN.md")
    File.write(path, body)
    [path, Robur::Plan.new(path)]
  end

  def test_archive_moves_only_finished_milestones_and_keeps_the_rest
    Dir.mktmpdir do |dir|
      path, plan = archive_plan(dir)
      commits = [["aaa1", "feat(robur): T1.1 add the widget"],
                 ["bbb2", "fix(robur): T1.2 stop the widget leaking"],
                 ["ccc3", "docs: unrelated hand-written commit"]]

      assert_equal ["M1"], plan.archive_completed_milestones(commits: commits, stat: "+40/-2")

      tracker = File.read(path)
      refute_includes tracker, "T1.1"
      assert_includes tracker, "## M2"
      # all-[x] but not a milestone: the same done/checklist heading skip the
      # open-task scan uses applies to archiving.
      assert_includes tracker, "## Definition of done"

      log = File.read(File.join(dir, "CHANGELOG.md"))
      assert log.start_with?("# Changelog\n")
      assert_includes log, "3 commits"
      assert_includes log, "+40/-2"
      assert_includes log, "- [x] T1.1 add the widget"
      assert_includes log, "`aaa1`"
      # description is the task's own do: prose, first sentence only
      assert_includes log, "The widget is the entry point."
      refute_includes log, "Everything else hangs off it"
      # a commit matching no task is still reported: it is invisible to the plan
      assert_includes log, "Also in this range:"
      assert_includes log, "`ccc3` docs: unrelated hand-written commit"
    end
  end

  def test_archive_is_idempotent_and_only_last_bounds_the_loop_path
    Dir.mktmpdir do |dir|
      _path, plan = archive_plan(dir, "# Plan\n## M1\n- [x] A1 (trivial, feat) one\n## M2\n- [x] A2 (trivial, feat) two\n")

      # the loop takes the newest finished milestone only, so a repo adopting
      # this mid-flight is not swept in a single turn
      assert_equal ["M2"], plan.archive_completed_milestones
      assert_equal ["M1"], plan.archive_completed_milestones
      assert_empty plan.archive_completed_milestones

      log = File.read(File.join(dir, "CHANGELOG.md"))
      assert_equal 1, log.scan("# Changelog").size
      assert log.index("## M1") < log.index("## M2"), "newest archive goes on top"
    end
  end

  def test_archive_all_at_once_for_the_backfill_command
    Dir.mktmpdir do |dir|
      _path, plan = archive_plan(dir, "# Plan\n## M1\n- [x] A1 (trivial, feat) one\n## M2\n- [x] A2 (trivial, feat) two\n")
      assert_equal %w[M1 M2], plan.archive_completed_milestones(only_last: false)
    end
  end

  # An archived milestone must still answer milestone_completed_list: the PR
  # body is built from it AFTER the archive runs. Keeping the `- [x]` form in
  # the changelog is what lets one scan serve both files.
  def test_milestone_completed_list_and_done_count_survive_archiving
    Dir.mktmpdir do |dir|
      _path, plan = archive_plan(dir)
      plan.archive_completed_milestones

      listed = plan.milestone_completed_list("M1")
      assert_equal 2, listed.size
      assert listed[0].start_with?("[x] T1.1 add the widget")
      # archived tasks are still done: without this, archiving the final
      # milestone empties the tracker and run's all-done fast path, which
      # requires done.positive?, stops firing. 2 archived + T2.1 + the
      # Definition-of-done bullet, which is counted wherever it sits.
      assert_equal 4, plan.count(:done)
    end
  end

  def test_human_block_brief_bounded_at_900_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "PLAN.md")
      filler = "x" * 80
      File.write(path, "# Plan\n- [ ] T1 (hard) blocked\n" +
                       Array.new(50) { "  #{filler}" }.join("\n") + "\n")
      brief = Robur::Plan.new(path).human_block_brief("T1", "t")
      block = brief.split("\n\n")[1]
      assert block.bytesize <= 900
      assert_equal 900, block.bytesize
    end
  end
end
