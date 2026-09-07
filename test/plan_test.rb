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

  def test_completed_subject_prefers_staged_diff_then_newest_done
    noop = Object.new
    def noop.capture(*) = ["", nil, nil]
    # no staged [x] line → falls back to the newest [x] in the file; derive
    # the expected id from the file so this doesn't break as tasks complete.
    newest_done = File.readlines("PLAN.md").grep(/\A- \[x\] (\S+)/) { Regexp.last_match(1) }.last
    assert Robur::Plan.new("PLAN.md", proc: noop).completed_subject.start_with?(newest_done)

    staged = Object.new
    def staged.capture(*) = ["+++ b/PLAN.md\n+- [x] T9.9 (normal) freshly staged task", nil, nil]
    assert_equal "T9.9 (normal) freshly staged task",
                 Robur::Plan.new("PLAN.md", proc: staged).completed_subject
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
