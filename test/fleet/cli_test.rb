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
end
