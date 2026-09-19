# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet"
require "robur/paths"
require "tmpdir"
require "fileutils"

class FleetPathsTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    ENV["ROBUR_HOME"] = @home
  end

  def teardown
    ENV.delete("ROBUR_HOME")
    FileUtils.remove_entry(@home)
  end

  def test_fleet_conf_honours_robur_home_and_creates_nothing
    assert_equal File.join(@home, "fleet.conf"), Robur::Paths.fleet_conf
    assert_empty(Dir.glob(File.join(@home, "**", "*")))
  end

  def test_fleet_paused_flag_honours_robur_home_and_creates_nothing
    assert_equal File.join(@home, "fleet.paused"), Robur::Paths.fleet_paused_flag
    assert_empty(Dir.glob(File.join(@home, "**", "*")))
  end

  def test_fleet_log_dir_is_a_directory_under_logs_and_creates_nothing
    assert_equal File.join(@home, "logs", "fleet"), Robur::Paths.fleet_log_dir
    assert_empty(Dir.glob(File.join(@home, "**", "*")))
  end

  def test_fleet_namespace_loads
    assert Robur::Fleet.is_a?(Module)
  end
end
