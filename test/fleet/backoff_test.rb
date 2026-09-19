# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/backoff"
require "tmpdir"
require "fileutils"

class FleetBackoffTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @t = 1_700_000_000
    @clock = StubClock.new(@t)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def backoff(**opts) = Robur::Fleet::Backoff.new(@dir, clock: @clock, **opts)

  def test_bump_doubles_from_base_then_caps
    bo = backoff
    assert_equal [1, 3600], bo.bump!
    assert_equal [2, 7200], bo.bump!
    assert_equal [3, 14_400], bo.bump!
    assert_equal [4, 14_400], bo.bump!
  end

  def test_bump_active_until_now_plus_delay
    bo = backoff
    count, delay = bo.bump!
    assert_equal 1, count
    assert_equal 3600, delay
    assert bo.active?
    @clock.now = @t + 3599
    assert bo.active?
    @clock.now = @t + 3600
    refute bo.active?
  end

  def test_acceptance_three_failures_then_bump_returns_4_capped
    bo = backoff(base: 3600, cap: 14_400)
    3.times { bo.bump! }
    @clock.now = @t + 1_000_000
    assert_equal [4, 14_400], bo.bump!
    assert bo.active?
    @clock.now = @t + 1_000_000 + 14_400
    refute bo.active?
  end

  def test_new_repo_is_not_active
    refute backoff.active?
  end

  def test_clear_deletes_and_reports_true_then_false
    bo = backoff
    bo.bump!
    assert bo.active?
    assert bo.clear!
    refute bo.active?
    refute bo.clear!
  end

  def test_default_keywords_make_bare_new_valid
    bo = Robur::Fleet::Backoff.new(@dir)
    assert_equal [1, 3600], bo.bump!
  end

  class StubClock
    attr_accessor :now

    def initialize(now) = @now = Time.at(now)
  end
end
