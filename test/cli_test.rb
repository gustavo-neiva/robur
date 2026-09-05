# frozen_string_literal: true

require "test_helper"
require "robur/cli"

class CliTest < Minitest::Test
  def parsed(argv)
    command, dir, idea = Robur::CLI.pre_scan(argv)
    [command, dir, idea, Robur::CLI.parse!(argv.dup, command, dir, idea)]
  end

  # Isolated ROBUR_HOME + repo dir; paths must not hardcode .robur, so the
  # tests point ROBUR_HOME at a tempdir like the watch tests do.
  def in_temp_repo
    home = Dir.mktmpdir("robur-home")
    repo = Dir.mktmpdir("robur-repo")
    old_home = ENV["ROBUR_HOME"]
    ENV["ROBUR_HOME"] = home
    yield repo
  ensure
    old_home ? ENV["ROBUR_HOME"] = old_home : ENV.delete("ROBUR_HOME")
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

  def test_watch_shows_one_frame_and_exits_when_loop_not_running
    home = Dir.mktmpdir("robur-home")
    repo = Dir.mktmpdir("robur-repo")
    old_home = ENV["ROBUR_HOME"]
    ENV["ROBUR_HOME"] = home
    log_dir = File.join(Robur::Paths.logs_dir, Robur::CLI.project_slug(repo))
    FileUtils.mkdir_p(log_dir)
    File.write(File.join(log_dir, "loop.log"),
                "[2026-09-04 10:47:15] turn 1 | tier=build | model=zai/glm-5.3-flash | thinking=off | task=T1 demo\n")
    out, = capture_io do
      assert_equal 0, Robur::CLI.cmd_watch(repo)
    end
    assert_includes out, "loop not running"
    assert_includes out, "zai/glm-5.3-flash"
  ensure
    old_home ? ENV["ROBUR_HOME"] = old_home : ENV.delete("ROBUR_HOME")
  end

  def test_watch_without_a_loop_log_returns_one
    home = Dir.mktmpdir("robur-home")
    repo = Dir.mktmpdir("robur-repo")
    old_home = ENV["ROBUR_HOME"]
    ENV["ROBUR_HOME"] = home
    out, = capture_io do
      assert_equal 1, Robur::CLI.cmd_watch(repo)
    end
    assert_includes out, "no loop.log"
  ensure
    old_home ? ENV["ROBUR_HOME"] = old_home : ENV.delete("ROBUR_HOME")
  end

  # The turn writes last_turn.out concurrently; watch reads it every 2s and
  # must not surface the torn trailing line (JSON fragments in Live output).
  def test_turn_text_drops_torn_trailing_line
    out = File.join(Dir.mktmpdir("robur-turn"), "last_turn.out")
    File.write(out, [
      %({"type":"session","version":3,"cwd":"/tmp"}),
      %({"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Fix the golden fixtures\\n","partial":{}}})
    ].join("\n") + "\n" + %({"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"che))
    text = Robur::CLI.turn_text(out)
    assert_equal "Fix the golden fixtures\n", text
  end

  def test_term_size_always_returns_positive_rows_and_cols
    rows, cols = Robur::CLI.term_size
    assert_operator rows, :>=, 10
    assert_operator cols, :>=, 40
  end

  # The live pi stream ends a text_delta line with a bare `}}` (no
  # `"partial":` key): `..."delta":"the"}}`. The extractor must not leak
  # that suffix into the watch board.
  def test_turn_text_extracts_delta_with_bare_brace_suffix
    out = File.join(Dir.mktmpdir("robur-turn"), "last_turn.out")
    File.write(out, [
      %({"type":"session","version":3,"cwd":"/tmp"}),
      %({"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"the"}}),
      %({"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":" first"}})
    ].join("\n") + "\n")
    assert_equal "the first", Robur::CLI.turn_text(out)
  end

  # stop must work on a repo with no loop.log (unlike status/watch) and
  # print the path it wrote.
  def test_stop_writes_drain_without_loop_log
    in_temp_repo do |repo|
      out, = capture_io do
        assert_equal 0, Robur::CLI.run(["stop", "-d", repo])
      end
      stop_file = Robur::Paths.stop_file(repo)
      assert_equal "drain\n", File.read(stop_file)
      assert_includes out, stop_file
    end
  end

  def test_stop_now_writes_now_and_clear_removes_stop_file
    in_temp_repo do |repo|
      capture_io { assert_equal 0, Robur::CLI.run(["stop", "--now", "-d", repo]) }
      assert_equal "now\n", File.read(Robur::Paths.stop_file(repo))
      capture_io { assert_equal 0, Robur::CLI.run(["stop", "--clear", "-d", repo]) }
      refute File.file?(Robur::Paths.stop_file(repo))
    end
  end

  def test_status_shows_draining_when_stop_file_pending
    in_temp_repo do |repo|
      log_dir = File.join(Robur::Paths.logs_dir, Robur::CLI.project_slug(repo))
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, "loop.log"), "")
      File.write(File.join(log_dir, "loop.pid"), "#{Process.pid}\n")
      Robur::Paths.ensure_state_dir!(repo)
      Robur::State.write_stop(repo, "drain")
      out, = capture_io do
        assert_equal 0, Robur::CLI.cmd_status(repo)
      end
      assert_includes out, "running (pid #{Process.pid}) (draining)"
    end
  end
end
