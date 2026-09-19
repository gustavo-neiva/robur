# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/render"
require "robur/fleet"
require "robur/fleet/roster"
require "stringio"
require "tmpdir"
require "fileutils"

class FleetRenderTest < Minitest::Test
  def test_board_alignment_is_stable
    verdicts = ["run", "skip:caught-up", "skip:parked"]
    lines = Robur::Fleet::Render.board([
      ["alpha", verdicts[0], 2],
      ["a-very-long-name", verdicts[1], 0],
      ["b", verdicts[2], 1]
    ]).split("\n")
    assert_equal 3, lines.size
    # the verdict column starts at the same offset on every line
    starts = lines.each_with_index.map { |l, i| l.index(verdicts[i]) }
    assert_equal 1, starts.uniq.size
    assert lines.first.end_with?("2 open")
    assert lines.last.end_with?("1 open")
  end

  def test_empty_roster_renders_empty_string
    assert_equal "", Robur::Fleet::Render.board([])
  end

  def test_dry_run_maps_entries_to_verdicts_read_only
    Dir.mktmpdir do |home|
      run_repo = File.join(home, "run-repo")
      FileUtils.mkdir_p(run_repo)
      File.write(File.join(run_repo, ".robur.conf"), "VERIFY_CMD=true\n")
      File.write(File.join(run_repo, "PLAN.md"), "<!-- class: MACHINE -->\n- [ ] a\n- [ ] b\n")
      caught = File.join(home, "caught-up")
      FileUtils.mkdir_p(caught)
      File.write(File.join(caught, ".robur.conf"), "VERIFY_CMD=true\n")
      File.write(File.join(caught, "PLAN.md"), "- [x] a\n")
      File.write(File.join(home, "fleet.conf"),
                 "#{run_repo}\n#{caught}\n#/parked/repo\n#{File.join(home, 'no-conf')}\n")
      before = Dir[File.join(home, "**", "*")].sort
      out = StringIO.new
      Robur::Fleet.dry_run(roster: Robur::Fleet::Roster.new(File.join(home, "fleet.conf")), out: out)

      lines = out.string.split("\n")
      assert_equal 4, lines.size
      assert_includes lines[0], "run"
      assert_includes lines[0], "2 open"
      assert_includes lines[1], "skip:caught-up"
      # decisions walk roster.active in file order; parked rows are appended
      # last for visibility only (never decided by the planner).
      assert_includes lines[2], "skip:no-conf"
      assert_includes lines[3], "skip:parked"
      # read-only: nothing new on disk but the conf itself
      assert_equal before, Dir[File.join(home, "**", "*")].sort
    end
  end
end
