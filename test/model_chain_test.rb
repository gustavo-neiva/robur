# frozen_string_literal: true

require_relative "test_helper"
require "robur/model_chain"

class ModelChainTest < Minitest::Test
  def make_chain(models = %w[a/one b/two c/three], config = {}, time = 1_000, max_transient: 3)
    clock = Object.new
    clock.define_singleton_method(:now) { Time.at(@t ||= time) }
    clock.define_singleton_method(:advance) { |s| @t += s }
    config = { "COOLDOWN" => "14400" }.merge(config)
    [Robur::ModelChain.new(models, config, clock: clock, max_transient: max_transient), clock]
  end

  def test_pick_returns_first_available
    chain, = make_chain
    assert_equal 0, chain.pick
  end

  def test_benched_first_falls_to_second
    chain, = make_chain
    chain.bench!(0)
    assert_equal 1, chain.pick
  end

  def test_all_benched_pick_returns_nil
    chain, = make_chain
    3.times { |i| chain.bench!(i) }
    assert_nil chain.pick
  end

  def test_clock_advance_unbenches
    chain, clock = make_chain
    chain.bench!(0)
    clock.advance(14_400)
    assert_equal 0, chain.pick
  end

  def test_provider_cooldown_override
    chain, clock = make_chain(%w[zai/glm other/m], { "COOLDOWN_ZAI" => "3600", "COOLDOWN" => "14400" })
    assert_equal 3600, chain.cooldown_for("zai/glm")
    assert_equal 14_400, chain.cooldown_for("other/m")
    chain.bench!(0)
    clock.advance(3_600)
    assert_equal 0, chain.pick
    # global model still benched past 3600
    chain.bench!(1)
    clock.advance(1)
    assert_equal 0, chain.pick
  end

  def test_bench_clears_strikes
    chain, = make_chain
    2.times { chain.strike!(0) }
    chain.bench!(0)
    chain.reset_all
    assert_equal false, chain.benched?(0) # strikes restarted, one strike is not a bench
    chain.strike!(0)
    assert_equal false, chain.benched?(0)
  end

  def test_strikes_bench_at_max_transient
    chain, = make_chain
    chain.bench!(0)
    3.times { chain.strike!(1) }
    assert chain.benched?(1)
    assert_equal 2, chain.pick
  end

  def test_strike_returns_true_only_on_bench
    chain, = make_chain(max_transient: 2)
    assert_equal false, chain.strike!(0)
    assert_equal true, chain.strike!(0)
  end

  def test_reset_all_clears_everything
    chain, = make_chain
    3.times { chain.bench!(0) }
    chain.reset_all
    assert_equal 0, chain.pick
    2.times { chain.strike!(0) }
    assert_equal false, chain.benched?(0)
  end

  def test_empty_chain_raises
    assert_raises(ArgumentError) { Robur::ModelChain.new([], { "COOLDOWN" => "1" }, clock: Object.new) }
  end
end
