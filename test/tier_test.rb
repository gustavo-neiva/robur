# frozen_string_literal: true

require_relative "test_helper"
require "robur/tier"

class TierTest < Minitest::Test
  # --- tag → tier (--cheap forces light) ---

  def test_from_tag
    assert_equal "light", Robur::Tier.from_tag("trivial")
    assert_equal "build-hard", Robur::Tier.from_tag("hard")
    assert_equal "build", Robur::Tier.from_tag("normal")
    assert_equal "build", Robur::Tier.from_tag("anything-else")
  end

  def test_cheap_forces_light
    %w[trivial hard normal].each do |tag|
      assert_equal "light", Robur::Tier.from_tag(tag, cheap: true), tag
    end
  end

  def test_chain_tier_strips_hard
    assert_equal "build", Robur::Tier.chain_tier("build-hard")
    assert_equal "build", Robur::Tier.chain_tier("build")
  end

  # --- chain_for_tier, suite-5 combos (recorded bash output) ---

  def test_suite5_chain_overrides
    assert_equal "p/a,p/b", chain("plan", "PLAN_MODELS" => "p/a,p/b", "MODELS" => "m/x")
    assert_equal "b/a,b/b", chain("build", "BUILD_MODELS" => "b/a,b/b", "MODELS" => "m/x")
    assert_equal "l/a", chain("light", "LIGHT_MODELS" => "l/a", "MODELS" => "m/x")
    assert_equal "m/x,m/y", chain("plan", "MODELS" => "m/x,m/y")
    assert_equal "m/x,m/y", chain("build", "MODELS" => "m/x,m/y")
    assert_equal "m/x,m/y", chain("light", "MODELS" => "m/x,m/y")
    assert_equal "zai/glm-5.2", chain("review", "REVIEW_MODELS" => "zai/glm-5.2", "MODELS" => "m/x")
    assert_equal "m/x,m/y", chain("review", "MODELS" => "m/x,m/y")
  end

  # suite-22: override-wins / flat-override / derive-when-empty / empty-when-nothing
  def test_suite22_chain
    rank5 = %w[anthropic/claude-opus-4-8 anthropic/claude-sonnet-4-5 zai/glm-5.2 zai/glm-4.5-air kimi-coding/k3]
    rank4 = rank5.first(4)
    assert_equal "custom/model-1,custom/model-2",
                 chain("build", { "BUILD_MODELS" => "custom/model-1,custom/model-2", "MODELS" => "" }, rank5)
    assert_equal "flat/model-a,flat/model-b",
                 chain("build", { "MODELS" => "flat/model-a,flat/model-b" }, rank4)
    # bash: chain_for_tier plan → opus,sonnet; light → k3,glm-4.5-air; build → sonnet…k3
    assert_equal "anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5",
                 chain("plan", {}, rank5)
    assert_equal "kimi-coding/k3,zai/glm-4.5-air", chain("light", {}, rank5)
    assert_equal "anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air,kimi-coding/k3",
                 chain("build", {}, rank5)
    assert_equal "anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air,kimi-coding/k3",
                 chain("review", {}, rank5)
    # 4-model suite-22 fixture
    assert_equal "anthropic/claude-opus-4-8,anthropic/claude-sonnet-4-5", chain("plan", {}, rank4)
    assert_equal "zai/glm-4.5-air,zai/glm-5.2", chain("light", {}, rank4)
    assert_equal "anthropic/claude-sonnet-4-5,zai/glm-5.2,zai/glm-4.5-air", chain("build", {}, rank4)
    # empty-when-nothing: nil, caller handles the die path
    assert_nil chain("build", {}, nil)
    assert_nil chain("build", {}, [])
  end

  def test_autoplan_fallbacks
    # bash: AUTOPLAN_MODELS ap/a; PLAN fallback p/a; flat m/x
    assert_equal "ap/a", chain("autoplan", { "AUTOPLAN_MODELS" => "ap/a", "PLAN_MODELS" => "p/a", "MODELS" => "m/x" })
    assert_equal "p/a", chain("autoplan", { "AUTOPLAN_MODELS" => "", "PLAN_MODELS" => "p/a", "MODELS" => "m/x" })
    assert_equal "m/x", chain("autoplan", { "MODELS" => "m/x" })
    # empty AUTOPLAN_MODELS/PLAN_MODELS derives from the plan slice of MODEL_RANK
    rank = %w[a/strong b/mid c/cheap]
    assert_equal "a/strong,b/mid", chain("autoplan", {}, rank)
  end

  def test_build_hard_chain_resolves_on_build_tier
    rank = %w[a/strong b/mid c/cheap]
    assert_equal "b/mid,c/cheap", chain("build-hard", {}, rank)
    assert_equal "b/explicit", chain("build-hard", { "BUILD_MODELS" => "b/explicit" }, rank)
  end

  # --- thinking_for_tier, suite-5 + build-hard bump (recorded bash output) ---

  def test_suite5_thinking
    t = ->(tier, cfg) { Robur::Tier.thinking_for(tier, cfg) }
    assert_equal "high", t.call("plan", { "THINKING_PLAN" => "high", "THINKING" => "low" })
    assert_equal "medium", t.call("build", { "THINKING_BUILD" => "medium", "THINKING" => "low" })
    assert_equal "off", t.call("light", { "THINKING_LIGHT" => "off", "THINKING" => "low" })
    assert_equal "low", t.call("plan", { "THINKING" => "low" })
    assert_equal "medium", t.call("build", { "THINKING" => "medium" })
    assert_equal "high", t.call("light", { "THINKING" => "high" })
    assert_equal "medium", t.call("review", { "THINKING_REVIEW" => "medium", "THINKING" => "low" })
    assert_equal "high", t.call("review", { "THINKING" => "high" })
  end

  def test_build_hard_bump
    t = ->(tier, cfg) { Robur::Tier.thinking_for(tier, cfg) }
    # bash suite-5 bump ladder
    assert_equal "minimal", t.call("build-hard", { "THINKING" => "off" })
    assert_equal "low", t.call("build-hard", { "THINKING" => "minimal" })
    assert_equal "medium", t.call("build-hard", { "THINKING" => "low" })
    assert_equal "high", t.call("build-hard", { "THINKING" => "medium" })
    assert_equal "high", t.call("build-hard", { "THINKING" => "high" })
    assert_equal "high", t.call("build-hard", { "THINKING" => "xhigh" })
    # explicit THINKING_BUILD wins, no bump
    assert_equal "low", t.call("build-hard", { "THINKING_BUILD" => "low", "THINKING" => "medium" })
  end

  def test_autoplan_thinking_fallback
    t = ->(tier, cfg) { Robur::Tier.thinking_for(tier, cfg) }
    assert_equal "ahigh", t.call("autoplan", { "THINKING_AUTOPLAN" => "ahigh", "THINKING_PLAN" => "phigh", "THINKING" => "low" })
    assert_equal "phigh", t.call("autoplan", { "THINKING_AUTOPLAN" => "", "THINKING_PLAN" => "phigh", "THINKING" => "low" })
    assert_equal "low", t.call("autoplan", { "THINKING" => "low" })
  end

  private

  def chain(tier, config, ranked = nil)
    Robur::Tier.chain_for(tier, config, ranked: ranked)
  end
end
