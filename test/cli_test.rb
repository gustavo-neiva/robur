# frozen_string_literal: true

require "test_helper"
require "robur/cli"

class CliTest < Minitest::Test
  def parsed(argv)
    command, dir, idea = Robur::CLI.pre_scan(argv)
    [command, dir, idea, Robur::CLI.parse!(argv.dup, command, dir, idea)]
  end

  def test_pre_scan_finds_command_dir_idea_and_skips_flags
    command, dir, idea = Robur::CLI.pre_scan(["--models", "a/b,c/d", "once", "-d", "/tmp/x"])
    assert_equal "once", command
    assert_equal "/tmp/x", dir
    assert_nil idea
  end

  def test_pre_scan_dir_equals_form_and_default_run
    assert_equal "/tmp/y", Robur::CLI.pre_scan(["--dir=/tmp/y"])[1]
    assert_equal "run", Robur::CLI.pre_scan([])[0]
    assert_equal "why not", Robur::CLI.pre_scan(["new", "why not"])[2]
  end

  def test_flag_overrides_match_bash_keys
    overrides = parsed(["-m", "zai/glm-5.3-flash", "--turn-timeout", "90",
                        "--no-commit", "--pr", "--quiet"])[3]
    assert_equal({
      "MODELS" => "zai/glm-5.3-flash",
      "TURN_TIMEOUT" => "90",
      "COMMIT_EACH_TURN" => "0",
      "OPEN_PR" => "1",
      "PUSH_ON_DONE" => "1", # --pr implies push
      "QUIET" => "1",
      "STREAM_AGENT" => "0", # --quiet forces stream off
    }, overrides)
  end

  def test_pr_push_and_no_resume_and_verify_cmd
    overrides = parsed(["--no-resume", "--verify-cmd", "rake"])[3]
    assert_equal "0", overrides["RESUME_SESSION"]
    assert_equal "rake", overrides["VERIFY_CMD"]
  end

  def test_dir_and_cmd_flags_hoisted_by_run_not_conf
    result = parsed(["-d", "/tmp/r", "--cheap"])[3]
    assert_equal "/tmp/r", result.delete(:dir)
    assert_equal({ "CHEAP_MODE" => "1" }, result)
    assert_equal "stats", parsed(["--stats"])[3][:cmd]
  end

  def test_unknown_option_dies_with_bash_message_shape
    ex = assert_raises(SystemExit) { parsed(["--bogus"]) }
    assert_equal 1, ex.status
  end

  def test_unexpected_positional_dies
    ex = assert_raises(SystemExit) { parsed(["once", "/a", "/b"]) }
    assert_equal 1, ex.status
  end

  def test_prescan_dir_positional_skipped_not_fatal
    _c, dir, _i, overrides = parsed(["/tmp/repo", "--stream"])
    assert_equal "/tmp/repo", dir
    assert_equal({ "STREAM_AGENT" => "1" }, overrides)
  end

  def test_help_prints_usage_and_exits_zero
    out, _e = capture_io do
      begin
        Robur::CLI.parse!(["--help"], "run", nil, nil)
      rescue SystemExit => e
        @status = e.status
      end
    end
    assert_equal 0, @status
    assert_includes out, "Usage: robur <command>"
    assert_includes out, "--verify-cmd"
    refute_includes out, "Usage: ratchet"
  end
end
