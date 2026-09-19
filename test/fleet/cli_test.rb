# frozen_string_literal: true

require_relative "../test_helper"
require "robur/cli"
require "tmpdir"
require "fileutils"

# T4.1: `robur fleet pause` / `resume` manage the beat flag via Paths, and
# resume never raises when the flag is absent.
class FleetCliTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @old_home = ENV["ROBUR_HOME"]
    ENV["ROBUR_HOME"] = @home
  end

  def teardown
    @old_home ? ENV["ROBUR_HOME"] = @old_home : ENV.delete("ROBUR_HOME")
    FileUtils.remove_entry(@home)
  end

  def test_pause_touches_flag_and_resume_removes_it
    out, = capture_io do
      assert_equal 0, Robur::CLI.cmd_fleet("pause")
    end
    assert File.file?(Robur::Paths.fleet_paused_flag)
    assert_includes out, "paused"
    out, = capture_io do
      assert_equal 0, Robur::CLI.cmd_fleet("resume")
    end
    refute File.exist?(Robur::Paths.fleet_paused_flag)
    assert_includes out, "resumed"
  end

  def test_resume_tolerates_absent_flag
    refute File.exist?(Robur::Paths.fleet_paused_flag)
    out, = capture_io do
      assert_equal 0, Robur::CLI.cmd_fleet("resume")
    end
    assert_includes out, "resumed"
  end

  # T4.2: retry clears every active repo's backoff via Fleet::Backoff and
  # skips parked repos — their backoff file must survive.
  def test_retry_clears_active_backoffs_and_skips_parked
    active_a = File.join(@home, "repo-a")
    active_b = File.join(@home, "repo-b")
    parked = File.join(@home, "repo-c")
    [active_a, active_b, parked].each { |d| FileUtils.mkdir_p(d) }
    [active_a, active_b, parked].each do |d|
      Robur::State.write_loop_backoff(d, 2, Time.now.to_i + 9_999)
    end
    File.write(Robur::Paths.fleet_conf,
               [active_a, active_b, "# #{parked}"].join("\n").concat("\n"))

    out, = capture_io do
      assert_equal 0, Robur::CLI.cmd_fleet("retry")
    end
    assert_includes out, "cleared 2"
    [active_a, active_b].each do |d|
      refute Robur::State.read_loop_backoff(d)
    end
    assert Robur::State.read_loop_backoff(parked)
  end

  def test_retry_with_no_backoffs_prints_cleared_0
    File.write(Robur::Paths.fleet_conf, "")
    out, = capture_io do
      assert_equal 0, Robur::CLI.cmd_fleet("retry")
    end
    assert_includes out, "cleared 0"
  end
end
