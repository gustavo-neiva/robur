# frozen_string_literal: true

require_relative "test_helper"
require "robur/task"

class TaskTest < Minitest::Test
  def test_open_serial_task
    t = Robur::Task.parse("- [ ] T1.2 (normal, serial) rewrite the greedy matcher")
    assert_equal :open, t.status
    assert_equal "T1.2", t.id
    assert_equal %w[normal serial], t.tags
    assert_equal "rewrite the greedy matcher", t.text
  end

  def test_id_forms
    {
      "- [ ] T5 (hard) x" => "T5",
      "- [ ] A1 do" => "A1",
      "- [ ] I3 fix" => "I3",
      "- [ ] N-postmortem write up" => "N-postmortem",
      "- [ ] plain checkbox no id" => "?",
      "- [x] T2.1 (trivial) done thing" => "T2.1"
    }.each do |line, id|
      assert_equal id, Robur::Task.parse(line).id, line
    end
  end

  def test_statuses
    assert_equal :open, Robur::Task.parse("- [ ] T1 x").status
    assert_equal :in_progress, Robur::Task.parse("- [IN PROGRESS] T1 x").status
    assert_equal :done, Robur::Task.parse("- [x] T1 x").status
    assert_equal :done, Robur::Task.parse("- [X] T1 x").status
    assert_equal :parked, Robur::Task.parse("- [HUMAN] T1 x").status
  end

  def test_human_parked_task_parses_id_tags_and_text
    t = Robur::Task.parse("- [HUMAN] T8.4 (trivial) anchor real balances — PARKED, needs human: current balance?")
    assert_equal :parked, t.status
    assert_equal "T8.4", t.id
    assert_equal ["trivial"], t.tags
  end

  def test_regression_tracker_145_greedy_paren_retag
    # bash sed 's/.*\((trivial|normal|hard)[,)].*$/' is greedy: the last
    # parenthesised tier word wins. First-paren-only scan must keep (trivial).
    t = Robur::Task.parse("- [ ] T9 (trivial) mention the word (hard) in title")
    assert_equal "trivial", t.tags.first
  end

  def test_untagged_defaults_to_no_tags
    t = Robur::Task.parse("- [ ] do the thing")
    assert_empty t.tags
    assert_equal "do the thing", t.text
  end

  def test_non_task_line
    t = Robur::Task.parse("Some prose line", 3)
    refute t.task?
    assert_equal 3, t.lineno
  end

  def test_indentation_and_serial_only_tag
    t = Robur::Task.parse("  - [ ] T3.1 (hard, serial) Task — a correct tag parser")
    assert_equal "T3.1", t.id
    assert_equal %w[hard serial], t.tags
  end
end
