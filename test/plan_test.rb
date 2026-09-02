# frozen_string_literal: true

require_relative "test_helper"
require "robur/plan"
require "tmpdir"
require "shellwords"

class PlanTest < Minitest::Test
  # This repo's own tracker has open tasks; the ratchet one is the parity target.
  def own_plan = Robur::Plan.new("PLAN.md")

  def test_counts_match_bash_counters_on_ratchet_plan
    file = File.expand_path("../../ratchet/PLAN.md", __dir__)
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

  # Parity: run the bash original and compare outputs on the same file.
  BASH_TRACKER = File.expand_path("../../ratchet/lib/tracker.sh", __dir__)

  def bash_fn(fn, file)
    dir = File.dirname(file)
    `bash -c 'export REPO_DIR=#{dir.shellescape} TRACKER_FILE=#{File.basename(file).shellescape}; source #{BASH_TRACKER.shellescape}; #{fn}' 2>/dev/null`
  end

  def assert_milestone_parity(file)
    plan = Robur::Plan.new(file)
    expected = bash_fn("tracker_milestones", file).split("\n").map do |l|
      name, done, total = l.split("\t")
      { name:, done: done.to_i, total: total.to_i }
    end
    assert_equal expected, plan.milestones, file

    cur = bash_fn("tracker_current_milestone", file).split("\t")
    expected_cur = cur.empty? ? nil : { name: cur[0], index: cur[1].to_i,
                                        count: cur[2].to_i, done: cur[3].to_i, total: cur[4].to_i }
    # assert_equal(nil, _) raises on modern minitest — route nil through
    # assert_nil so a tracker with no current milestone still asserts parity.
    if expected_cur.nil?
      assert_nil plan.current_milestone, file
    else
      assert_equal expected_cur, plan.current_milestone, file
    end

    expected_ready = bash_fn("plan_is_ready && echo yes || echo no", file).strip == "yes"
    assert_equal expected_ready, plan.ready?, file

    expected_ind = bash_fn("fanout_independent_milestones", file).split("\n").map do |l|
      name, slug = l.split("\t")
      { name:, slug: }
    end
    assert_equal expected_ind, plan.independent_milestones, file
  end

  def test_milestone_parity_on_ratchet_plan_and_seed
    assert_milestone_parity(File.expand_path("../../ratchet/PLAN.md", __dir__))
    assert_milestone_parity(File.expand_path("../../ratchet/templates/PLAN.seed.md", __dir__))
  end

  def test_milestone_parity_on_synthetic_trackers
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
      assert_milestone_parity(path)
    end
  end

  def test_human_block_brief_parity_with_bash
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
      assert_equal bash_fn("human_block_brief T1 t-title", path).chomp, brief
      # fallback when the block is not found (unknown id)
      missing = Robur::Plan.new(path).human_block_brief("ZZ", nil)
      assert_equal bash_fn("human_block_brief ZZ ''", path).chomp, missing
      assert_includes missing, "<task block not found in tracker>"
      # id "?" also falls back
      assert_equal bash_fn("human_block_brief '?' ''", path).chomp,
                   Robur::Plan.new(path).human_block_brief("?", nil)
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
