# frozen_string_literal: true

require "test_helper"
require "robur/turn"

module Robur
  class TurnTest < Minitest::Test
    def run_turn(cmd, turn_timeout: 2, stall_timeout: 2, poll: 0.2)
      file = File.join(Dir.mktmpdir, "turn.out")
      result = Turn.run(
        cmd: cmd, turn_file: file, turn_timeout: turn_timeout,
        stall_timeout: stall_timeout, poll_interval: poll
      )
      [result, File.read(file)]
    end

    def test_deadline_kill
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, _out = run_turn([RbConfig.ruby, "-e", "sleep 30"], turn_timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      assert_equal "deadline-1s", result.kill_reason
      assert_operator result.elapsed, :<, 1.5 # within one poll interval of the cap
      assert_operator elapsed, :<, 5
      assert_predicate result.status, :signaled?
    end

    def test_stall_kill
      result, out = run_turn(
        [RbConfig.ruby, "-e", "print 'x'; $stdout.flush; sleep 30"],
        stall_timeout: 1, poll: 0.2
      )
      assert_equal "stall-1s", result.kill_reason
      assert_equal "x", out
      assert_predicate result.status, :signaled?
    end

    def test_normal_completion
      result, out = run_turn([RbConfig.ruby, "-e", "print 'done'; exit 7"])
      assert_nil result.kill_reason
      assert_equal 7, result.status.exitstatus
      assert_equal "done", out
    end
  end
end
