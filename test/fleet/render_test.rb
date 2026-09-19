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

  def test_status_aligns_columns_and_shows_relative_backoff
    verdicts = ["runnable", "backoff", "human-block"]
    lines = Robur::Fleet::Render.status(
      [["alpha", verdicts[0], 3, 10, nil, "stopped", false],
       ["a-very-long-name", verdicts[1], 2, 8, 1380, "transient-failure", true],
       ["b", verdicts[2], 1, 5, nil, "human_blocked", false]],
      []
    ).split("\n")
    assert_equal 3, lines.size
    # the verdict column starts at the same offset on every line
    starts = lines.each_with_index.map { |l, i| l.index(verdicts[i]) }
    assert_equal 1, starts.uniq.size
    # the backed-off row shows a RELATIVE expiry (23m), never a raw epoch
    assert_match(/\bin 23m\b/, lines[1])
    refute_match(/\d{10}/, lines[1])
    assert_includes lines[1], "locked"
  end

  def test_status_lists_human_waiting_rows_under_their_own_header
    lines = Robur::Fleet::Render.status(
      [["alpha", "runnable", 1, 2, nil, "stopped", false],
       ["gamma", "human-block", 1, 4, nil, "human_blocked", false]],
      [["gamma", "T4.2", "what number?"]]
    ).split("\n")
    i = lines.index("waiting on you")
    refute_nil i
    assert_match(/gamma/, lines[i + 1])
    assert_match(/T4\.2/, lines[i + 1])
    assert_match(/what number\?/, lines[i + 1])
    # only the waiting repos appear below the header
    refute lines[(i + 1)..].any? { |l| l.include?("alpha") }
  end

  def test_fleet_status_gathers_verdicts_read_only
    Dir.mktmpdir do |home|
      mk = lambda do |name, tracker|
        d = File.join(home, name)
        FileUtils.mkdir_p(d)
        File.write(File.join(d, ".robur.conf"), "VERIFY_CMD=true\n")
        File.write(File.join(d, "PLAN.md"), tracker)
        d
      end
      run_repo = mk.("run-repo", "<!-- class: MACHINE -->\n- [ ] a\n- [x] b\n")
      backoff_repo = mk.("backed-off", "<!-- class: MACHINE -->\n- [ ] a\n- [x] b\n")
      blocked_repo = mk.("blocked", "<!-- class: MACHINE -->\n- [ ] T1.1 decide the thing\n- [x] b\n")
      File.write(File.join(home, "fleet.conf"), "#{run_repo}\n#{backoff_repo}\n#{blocked_repo}\n")
      Robur::State.write_loop_backoff(backoff_repo, 1, Time.now.to_i + 1380)
      Robur::State.write_stop_reason(blocked_repo, "human_blocked")
      Robur::State.write_last_task(blocked_repo, "T1.1", "human_blocked")
      before = Dir[File.join(home, "**", "*")].sort
      out = StringIO.new
      Robur::Fleet.status(roster: Robur::Fleet::Roster.new(File.join(home, "fleet.conf")),
                          out: out, now: Time.now.to_i)

      lines = out.string.split("\n")
      assert_includes lines[0], "runnable"
      assert_includes lines[0], "1/2"
      assert_includes lines[1], "backoff"
      assert_match(/\bin 23m\b/, lines[1])
      refute_match(/\d{10}/, lines[1])
      assert_includes lines[2], "human-block"
      # the human-blocked repo also appears under "waiting on you" with its
      # parked task id and question line
      i = lines.index("waiting on you")
      refute_nil i
      assert_match(/blocked/, lines[i + 1])
      assert_match(/T1\.1/, lines[i + 1])
      assert_match(/decide the thing/, lines[i + 1])
      # read-only: nothing new on disk but the conf itself
      assert_equal before, Dir[File.join(home, "**", "*")].sort
    end
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
      # caught-up + tracker + no stamp = due -> the cycle would emit a
      # plan turn (T2.2)
      assert_includes lines[1], "plan"
      # decisions walk roster.active in file order; parked rows are appended
      # last for visibility only (never decided by the planner).
      assert_includes lines[2], "skip:no-conf"
      assert_includes lines[3], "skip:parked"
      # read-only: nothing new on disk but the conf itself
      assert_equal before, Dir[File.join(home, "**", "*")].sort
    end
  end
end
