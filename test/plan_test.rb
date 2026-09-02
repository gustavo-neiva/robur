# frozen_string_literal: true

require_relative "test_helper"
require "robur/plan"
require "tmpdir"

class PlanTest < Minitest::Test
  # This repo's own tracker has open tasks; the ratchet one is the parity target.
  def own_plan = Robur::Plan.new("PLAN.md")

  def test_counts_match_bash_counters_on_ratchet_plan
    file = File.expand_path("../ratchet/PLAN.md", __dir__)
    done = `grep -cE '^[[:space:]]*-?[[:space:]]*\\[x\\]' #{file}`.to_i
    open = `awk '/^#+ / { heading = tolower($0) }
                 /^[[:space:]]*-?[[:space:]]*\\[ \\]/ {
                   if (heading !~ /done|checklist/) n++ }
                 END { print n + 0 }' #{file}`.to_i
    counts = Robur::Plan.new(file).counts
    assert_equal done, counts[:done]
    assert_equal open, counts[:open]
    assert_equal 0, counts[:in_progress]
  end

  def test_task_block_starts_at_current_task
    block = own_plan.task_block
    first = own_plan.next_task
    assert block.start_with?("- [ ] #{first.id}")
    refute block.include?("\n- [")
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
    # no staged [x] line → falls back to the newest [x] in the file
    assert Robur::Plan.new("PLAN.md", proc: noop).completed_subject.start_with?("T3.1")

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
      assert_equal({ open: 1, in_progress: 1, done: 1 }, plan.counts)
      # bash tracker_task_block prefers the in-progress task as "current".
      assert_equal "- [IN PROGRESS] T3 wip", plan.task_block
    end
  end

  def test_missing_file_is_empty
    plan = Robur::Plan.new("/nonexistent/PLAN.md")
    refute plan.open?
    assert_equal({ open: 0, in_progress: 0, done: 0 }, plan.counts)
    assert_nil plan.class_marker
  end
end
