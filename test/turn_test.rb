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

    # json mode: the streamed user-message echo and thinking deltas quote the
    # token names in prose — only a completed assistant text event counts
    # (the 2026-09-04 outage: every model died :empty at the first poll).
    def test_token_in_json_mode_ignores_prompt_echo_and_thinking_prose
      file = File.join(Dir.mktmpdir, "turn.out")
      File.write(file, [
        %({"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"print the token STEP_COMPLETE on its own line, else ALL_DONE"}]}},),
        %({"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"I must end with STEP_COMPLETE\\n"}})
      ].join("\n") + "\n")
      refute Turn.token_in?(file, ["STEP_COMPLETE", "ALL_DONE"], from: 0)

      File.open(file, "a") do |f|
        f.puts %({"type":"message_update","assistantMessageEvent":{"type":"text_end","contentIndex":0,"content":"done\\nSTEP_COMPLETE\\n"}})
      end
      assert Turn.token_in?(file, ["STEP_COMPLETE", "ALL_DONE"], from: 0)
    end

    # End-to-end for the outage: a json-mode turn whose only output is the
    # prompt echo must NOT be token-killed — it runs to its deadline.
    def test_json_prompt_echo_quoting_the_token_does_not_early_kill
      echo = %({"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"print the token STEP_COMPLETE on its own line. Otherwise ALL_DONE."}]}})
      file = File.join(Dir.mktmpdir, "turn.out")
      result = Turn.run(
        cmd: [RbConfig.ruby, "-e", "puts '#{echo}'; $stdout.flush; sleep 30"],
        turn_file: file, turn_timeout: 1, stall_timeout: 10, poll_interval: 0.05,
        early_tokens: ["STEP_COMPLETE", "ALL_DONE"]
      )
      assert_includes File.read(file), "STEP_COMPLETE"
      assert_equal "deadline-1s", result.kill_reason
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

    # The grace used to be an unconditional sleep(2), so a TERM-responsive
    # child cost 2s on every watchdog kill. Now it polls for the exit.
    def test_deadline_kill_returns_promptly_when_term_is_honoured
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, _out = run_turn([RbConfig.ruby, "-e", "sleep 30"], turn_timeout: 1, poll: 0.05)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      assert_equal "deadline-1s", result.kill_reason
      assert_equal 15, result.status.termsig
      # detection is capped at turn_timeout + one poll; the kill itself must
      # not add anything like the old 2s grace on top.
      assert_operator elapsed - result.elapsed, :<, 1.0
    end

    # A child that traps TERM still has to die — the escalation to KILL at the
    # ceiling is what the poll loop must not lose.
    def test_term_trapping_hanger_still_dies_by_sigkill
      result, _out = run_turn(
        [RbConfig.ruby, "-e", "trap('TERM') {}; $stdout.sync = true; sleep 30"],
        turn_timeout: 1, poll: 0.05
      )
      assert_equal "deadline-1s", result.kill_reason
      assert_equal 9, result.status.termsig
    end

    # Level 2 (abort) ends the turn; the kill tail makes it TERM-then-KILL,
    # so the reaped status is a signal, not a clean exit.
    def test_stop_check_level_2_aborts_the_turn
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Turn.run(
        cmd: [RbConfig.ruby, "-e", "sleep 30"],
        turn_file: File.join(Dir.mktmpdir, "turn.out"),
        turn_timeout: 30, stall_timeout: 30, poll_interval: 0.05,
        stop_check: -> { 2 }
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      assert_equal "stop-requested", result.kill_reason
      assert_operator elapsed, :<, 5 # ended long before the 30s deadline
      assert_predicate result.status, :signaled?
    end

    # Level 1 is drain: the current turn finishes normally.
    def test_stop_check_level_1_lets_the_turn_finish
      result, out = run_turn(
        [RbConfig.ruby, "-e", "print 'done'"],
        turn_timeout: 2, stall_timeout: 2, poll: 0.2
      )
      assert_nil result.kill_reason
      assert_equal "done", out
    end

    def test_normal_completion
      result, out = run_turn([RbConfig.ruby, "-e", "print 'done'; exit 7"])
      assert_nil result.kill_reason
      assert_equal 7, result.status.exitstatus
      assert_equal "done", out
    end

    def test_mode_args_context_profiles
      bare = ["--mode", "json", "--no-skills", "--no-context-files"]
      assert_equal bare, Turn.mode_args("pi")
      assert_equal bare, Turn.mode_args("/opt/homebrew/bin/pi")
      assert_equal bare, Turn.mode_args("pi", kind: :step)
      assert_equal bare, Turn.mode_args("pi", kind: :unknown) # unknown kind falls back to step
      assert_equal ["--mode", "json"], Turn.mode_args("pi", kind: :plan)
      assert_equal ["--mode", "json", "--no-skills"], Turn.mode_args("pi", kind: :review)
      assert_equal [], Turn.mode_args("claude")
      assert_equal [], Turn.mode_args("/path/to/fake-agent", kind: :plan)
      assert_equal true, Turn.pi_json?("pi")
      assert_equal false, Turn.pi_json?("claude")
    end
  end
end
