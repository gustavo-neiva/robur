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

    # token_in? scans only bytes past last_size; a token written one byte at
    # a time straddles poll boundaries, and the max_token-1 rewind is the
    # only thing that keeps it findable.
    def test_token_split_across_poll_boundaries_is_still_seen
      file = File.join(Dir.mktmpdir, "turn.out")
      result = Turn.run(
        cmd: [RbConfig.ruby, "-e",
              "'STEP_COMPLETE'.each_char { |c| print c; $stdout.flush; sleep 0.05 }; sleep 30"],
        turn_file: file, turn_timeout: 10, stall_timeout: 10, poll_interval: 0.02,
        early_tokens: ["STEP_COMPLETE", "ALL_DONE"]
      )
      assert_equal "token-seen", result.kill_reason
      assert_includes File.read(file), "STEP_COMPLETE"
    end

    # from: offset semantics, isolated from the watchdog.
    def test_token_in_honours_the_from_offset
      file = File.join(Dir.mktmpdir, "turn.out")
      File.write(file, "xxxxxSTEP_COMPLETEyyy") # token occupies bytes 5...18
      assert Turn.token_in?(file, ["STEP_COMPLETE"], from: 0)
      assert Turn.token_in?(file, ["STEP_COMPLETE"], from: 5)
      refute Turn.token_in?(file, ["STEP_COMPLETE"], from: 6)
      refute Turn.token_in?(file, ["STEP_COMPLETE"], from: 99) # past EOF, no raise
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
