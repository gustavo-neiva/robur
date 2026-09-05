# frozen_string_literal: true

require_relative "test_helper"
require "robur/task_attempts"

class TaskAttemptsTest < Minitest::Test
  def test_under_the_ceiling_is_not_exceeded
    ta = Robur::TaskAttempts.new(3)
    refute ta.attempt!("T1")
    refute ta.attempt!("T1")
    refute ta.attempt!("T1")
    assert_equal 3, ta.count("T1")
  end

  def test_the_attempt_that_pushes_past_the_ceiling_returns_true
    ta = Robur::TaskAttempts.new(3)
    3.times { ta.attempt!("T1") }
    assert ta.attempt!("T1")
    assert ta.exceeded?("T1")
  end

  def test_counts_are_independent_per_task_id
    ta = Robur::TaskAttempts.new(2)
    3.times { ta.attempt!("T1") }
    ta.attempt!("T2")
    assert ta.exceeded?("T1")
    refute ta.exceeded?("T2")
    assert_equal 3, ta.count("T1")
    assert_equal 1, ta.count("T2")
  end

  def test_unseen_task_id_is_zero_and_not_exceeded
    ta = Robur::TaskAttempts.new(20)
    assert_equal 0, ta.count("never-seen")
    refute ta.exceeded?("never-seen")
  end

  # The whole point: nothing about this class offers a reset. A caller that
  # wants the production spin fixed cannot accidentally wire this into the
  # same reset_all cycle that caused it.
  def test_has_no_reset_method
    refute_respond_to Robur::TaskAttempts.new(1), :reset_all
    refute_respond_to Robur::TaskAttempts.new(1), :reset
  end
end
