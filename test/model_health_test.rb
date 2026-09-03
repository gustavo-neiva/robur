# frozen_string_literal: true

require_relative "test_helper"
require "robur/model_health"

class ModelHealthTest < Minitest::Test
  def make_health(config = {}, time = 1_000, max_transient: 3, hard_disable_after: 20)
    clock = Object.new
    clock.define_singleton_method(:now) { Time.at(@t ||= time) }
    clock.define_singleton_method(:advance) { |s| @t += s }
    config = { "COOLDOWN" => "14400" }.merge(config)
    [Robur::ModelHealth.new(config, clock: clock, max_transient: max_transient,
                            hard_disable_after: hard_disable_after), clock]
  end

  # THE regression: production keyed strike/bench state by CHAIN STRING, so
  # the same model in a tier chain and the flat MODELS chain carried two
  # independent strike counters and never benched. State here must be keyed
  # by model id and shared across chains.
  def test_shared_state_across_chains
    health, = make_health
    chain_a = %w[a/one b/two]
    chain_b = %w[b/two a/one]
    3.times { health.strike!("b/two") }
    assert health.benched?("b/two")
    # b/two benched via chain A's strikes: pick on chain B, where it is
    # FIRST, must skip it — same registry, not a fresh per-chain one.
    assert_equal "a/one", health.pick(chain_b)
    assert_equal "a/one", health.pick(chain_a)
  end

  def test_pick_returns_first_available_and_empty_chain_nil
    health, = make_health
    assert_equal "a/one", health.pick(%w[a/one b/two])
    assert_nil health.pick([])
  end

  def test_strike_returns_true_only_on_bench
    health, = make_health(max_transient: 2)
    assert_equal false, health.strike!("a/one")
    assert_equal true, health.strike!("a/one")
    assert health.benched?("a/one")
  end

  def test_bench_clears_strikes
    health, = make_health(max_transient: 3)
    3.times { health.strike!("a/one") }
    health.bench!("a/one")
    health.reset_all
    2.times { health.strike!("a/one") }
    assert_equal false, health.benched?("a/one")
  end

  def test_bench_expiry_via_clock_advance
    health, clock = make_health
    health.bench!("a/one")
    assert_equal "b/two", health.pick(%w[a/one b/two])
    clock.advance(14_400)
    assert_equal "a/one", health.pick(%w[a/one b/two])
  end

  def test_provider_cooldown_override
    health, clock = make_health({ "COOLDOWN_ZAI" => "3600", "COOLDOWN" => "14400" })
    assert_equal 3600, health.cooldown_for("zai/glm")
    assert_equal 14_400, health.cooldown_for("other/m")
    health.bench!("zai/glm")
    clock.advance(3_600)
    assert_equal false, health.benched?("zai/glm")
    # global cooldown model still benched at 3600
    health.bench!("other/m")
    assert health.benched?("other/m")
  end

  def test_record_step_clears_partial_strikes
    health, = make_health
    2.times { health.strike!("a/one") }
    health.record!("a/one", :step)
    assert_equal({ "attempts" => 1, "wins" => 1, "strikes" => 0, "benched_until" => 0 },
                 health.snapshot["a/one"].transform_keys(&:to_s))
    health.strike!("a/one") # back to 1 of 3, not a bench
    assert_equal false, health.benched?("a/one")
  end

  def test_record_done_wins_and_clears
    health, = make_health
    health.strike!("a/one")
    health.record!("a/one", :done)
    assert_equal({ "attempts" => 1, "wins" => 1, "strikes" => 0, "benched_until" => 0 },
                 health.snapshot["a/one"].transform_keys(&:to_s))
  end

  def test_record_transient_counts_attempt_not_win
    health, = make_health(hard_disable_after: 2)
    2.times { health.record!("a/one", :transient) }
    assert_equal 2, health.snapshot["a/one"][:attempts]
    assert_equal 0, health.snapshot["a/one"][:wins]
    assert health.hard_disabled?("a/one")
  end

  def test_hard_disable_fires_at_zero_wins_only
    health, = make_health(hard_disable_after: 2)
    2.times { health.record!("a/one", :transient) }
    assert health.hard_disabled?("a/one")
    assert_equal "b/two", health.pick(%w[a/one b/two])

    health_winning, = make_health(hard_disable_after: 2)
    health_winning.record!("a/one", :step)
    health_winning.record!("a/one", :transient)
    assert_equal false, health_winning.hard_disabled?("a/one")
    assert_equal "a/one", health_winning.pick(%w[a/one b/two])
  end

  def test_reset_all_clears_benches_but_preserves_hard_disable
    health, clock = make_health(hard_disable_after: 2)
    2.times { health.record!("a/one", :transient) }
    health.bench!("b/two")
    health.reset_all
    assert_equal false, health.benched?("b/two")
    # bench reset must not revive a hard-disabled model
    assert health.hard_disabled?("a/one")
    assert_equal "b/two", health.pick(%w[a/one b/two])
    clock.advance(100_000)
    assert_equal "b/two", health.pick(%w[a/one b/two]) # skipped forever
  end

  def test_snapshot_shape
    health, = make_health
    health.record!("a/one", :step)
    3.times { health.strike!("b/two") } # strikes reset to 0 by the bench
    snap = health.snapshot
    assert_equal %w[a/one b/two], snap.keys.sort
    assert_equal({ attempts: 1, wins: 1, strikes: 0, benched_until: 0 }, snap["a/one"])
    assert_equal 15_400, snap["b/two"][:benched_until] # t=1000 + COOLDOWN 14400
    assert_operator snap["b/two"][:strikes], :==, 0
  end
end
