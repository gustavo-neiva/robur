# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/notifier"
require "robur/state"
require "tmpdir"
require "fileutils"

class FleetNotifierTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("robur-notifier")
    @repo = File.join(@root, "r")
    Dir.mkdir(@repo)
    @marker = Robur::State.state_path(@repo, "last_notified")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  ClockStub = Struct.new(:now)

  def notifier(clock)
    Robur::Fleet::Notifier.new(clock: clock, log_dir: @root)
  end

  # Records deliveries through Observability#notify_human — the class is
  # stubbed, not bypassed, so the test fails if Notifier ever grows a
  # second spawn path (constraint: delivery via notify_human only).
  def with_notify_spy
    calls = []
    Robur::Observability.send(:alias_method, :notify_human_orig, :notify_human)
    Robur::Observability.send(:define_method, :notify_human) do |msg, *|
      calls << msg
      nil
    end
    yield calls
  ensure
    Robur::Observability.send(:remove_method, :notify_human)
    Robur::Observability.send(:alias_method, :notify_human, :notify_human_orig)
    Robur::Observability.send(:remove_method, :notify_human_orig)
  end

  # Acceptance: blocked on T3.1, an hour-later cycle with the same task
  # still blocked sends nothing — and the suppressing write must not slide
  # the marker's mtime, or the 24h window never expires under the
  # 15-minute beat.
  def test_same_key_within_the_window_is_suppressed_without_sliding_mtime
    with_notify_spy do |calls|
      clock = ClockStub.new(Time.now)
      n = notifier(clock)
      n.notify_once(@repo, "T3.1\thuman_blocked", "blocked on T3.1")
      mtime = File.mtime(@marker)
      clock.now += 3_600
      n.notify_once(@repo, "T3.1\thuman_blocked", "blocked on T3.1")
      assert_equal 1, calls.size
      assert_equal "T3.1\thuman_blocked", File.read(@marker)
      assert_equal mtime, File.mtime(@marker)
    end
  end

  # Acceptance: 25 hours later the same key sends again. An intermediate
  # beat at 23h proves the window measures from the SEND, not from the
  # last suppressing write.
  def test_same_key_resends_after_renotify_secs
    with_notify_spy do |calls|
      clock = ClockStub.new(Time.now)
      n = notifier(clock)
      n.notify_once(@repo, "T3.1\thuman_blocked", "blocked on T3.1")
      clock.now += 82_800
      n.notify_once(@repo, "T3.1\thuman_blocked", "blocked on T3.1")
      assert_equal 1, calls.size
      clock.now += 7_200
      n.notify_once(@repo, "T3.1\thuman_blocked", "blocked on T3.1")
      assert_equal 2, calls.size
    end
  end

  # Acceptance: the key is "<task_id>\t<reason>", so a changed task OR a
  # changed reason sends immediately, even inside the suppression window.
  def test_a_changed_task_or_reason_sends_immediately
    with_notify_spy do |calls|
      clock = ClockStub.new(Time.now)
      n = notifier(clock)
      n.notify_once(@repo, "T3.1\thuman_blocked", "a")
      clock.now += 60
      n.notify_once(@repo, "T3.1\tgate_red", "b")
      clock.now += 60
      n.notify_once(@repo, "T4.1\thuman_blocked", "c")
      assert_equal 3, calls.size
      assert_equal %w[a b c], calls
    end
  end

  # A failing NOTIFY_CMD must not raise out of the fleet cycle: the real
  # (unstubbed) delivery path spawns detached and returns.
  def test_a_failing_command_does_not_raise
    saved = ENV.delete("NOTIFY_CMD")
    ENV["NOTIFY_CMD"] = "false" # /bin/false: fails silently, exits 1
    assert_nil notifier(ClockStub.new(Time.now)).notify_once(@repo, "T1\thuman_blocked", "msg")
    assert_equal "T1\thuman_blocked", File.read(@marker)
  ensure
    ENV["NOTIFY_CMD"] = saved if saved
  end
end
