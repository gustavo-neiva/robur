# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/roster"
require "tmpdir"
require "fileutils"

class FleetRosterTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @home = Dir.mktmpdir
    @old_home = ENV["HOME"]
    ENV["HOME"] = @home
  end

  def teardown
    ENV["HOME"] = @old_home
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@home)
  end

  def write_conf(content)
    path = File.join(@dir, "fleet.conf")
    File.write(path, content)
    path
  end

  def roster(path) = Robur::Fleet::Roster.new(path)

  def test_active_parked_and_comment_yield_two_entries_parked_second
    entries = roster(write_conf("/repos/alpha\n#/repos/parked\n# a note\n")).entries
    assert_equal 2, entries.size
    assert_equal "/repos/alpha", entries[0].path
    refute entries[0].parked
    assert entries[1].parked
    assert_equal "/repos/parked", entries[1].path
    assert_equal 2, entries[1].lineno
    assert_equal "#/repos/parked", entries[1].raw
  end

  def test_active_returns_only_non_parked_in_file_order
    path = write_conf("#/repos/b\n/repos/a\n/repos/c\n")
    assert_equal ["/repos/a", "/repos/c"], roster(path).active.map(&:path)
  end

  def test_blank_lines_yield_nothing
    entries = roster(write_conf("\n   \n/repos/a\n")).entries
    assert_equal 1, entries.size
    assert_equal 3, entries.first.lineno
  end

  def test_hash_space_tab_and_bare_hash_are_comments
    entries = roster(write_conf("# note\n#\t/repos/x\n# /repos/y\n#\n")).entries
    assert_empty entries
  end

  def test_tilde_expands_against_home
    path = write_conf("~/code/alpha\n")
    assert_equal File.join(@home, "code/alpha"), roster(path).entries.first.path
  end

  def test_relative_path_resolves_against_conf_dir
    path = write_conf("sub/repo\n")
    assert_equal File.join(@dir, "sub/repo"), roster(path).entries.first.path
  end

  def test_missing_file_returns_empty
    missing = File.join(@dir, "nope.conf")
    assert_empty roster(missing).entries
    assert_empty roster(missing).active
  end
end
