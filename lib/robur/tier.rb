# frozen_string_literal: true

module Robur
  # Tier routing: tracker tag → tier, tier → model chain, tier → thinking
  # level. The MODEL_RANK auto-slice takes an already-ranked model list;
  # deriving that list from the live pi registry and cost cache is the
  # registry layer's job, injected here.
  module Tier
    TAG_TO_TIER = { "trivial" => "light", "hard" => "build-hard" }.freeze

    # Tracker tag → tier; --cheap forces every tier to light.
    def self.from_tag(tag, cheap: false)
      return "light" if cheap
      TAG_TO_TIER.fetch(tag, "build")
    end

    # build-hard resolves its CHAIN on the build tier (thinking is what differs).
    def self.chain_tier(tier)
      tier.sub(/\Abuild-hard\z/, "build")
    end

    TIER_CONF_KEYS = {
      "plan" => "PLAN_MODELS", "build" => "BUILD_MODELS", "light" => "LIGHT_MODELS",
      "review" => "REVIEW_MODELS", "autoplan" => "AUTOPLAN_MODELS",
    }.freeze

    # Effective model chain for a tier. Precedence: tier-specific *_MODELS →
    # flat MODELS → MODEL_RANK auto-slice (autoplan derives from plan) → nil.
    # ranked: ordered model list from the rank layer, or nil when unavailable.
    def self.chain_for(tier, config, ranked: nil)
      key = TIER_CONF_KEYS[chain_tier(tier)]
      chain = pick(config[key], key == "AUTOPLAN_MODELS" ? config["PLAN_MODELS"] : nil)
      return chain if chain && !chain.empty?
      flat = config["MODELS"]
      return flat if flat && !flat.empty?

      slice = suggest_slice(chain_tier(tier) == "autoplan" ? "plan" : chain_tier(tier), ranked || [])
      slice && !slice.empty? ? slice.join(",") : nil
    end

    # suggest_chain: plan = top + fallback; light = bottom + one up;
    # build/review = middle + fallbacks down (top only when ≤2 models).
    def self.suggest_slice(tier, ranked)
      total = ranked.size
      return [] if total.zero?
      case tier
      when "plan"
        ranked.first(2)
      when "light"
        total >= 2 ? [ranked[-1], ranked[-2]] : [ranked[-1]]
      when "build", "review"
        total <= 2 ? ranked : ranked[1..]
      end || []
    end

    THINKING_KEYS = {
      "plan" => "THINKING_PLAN", "build" => "THINKING_BUILD", "light" => "THINKING_LIGHT",
      "review" => "THINKING_REVIEW", "autoplan" => "THINKING_AUTOPLAN",
    }.freeze

    BUMP = { "off" => "minimal", "minimal" => "low", "low" => "medium",
             "medium" => "high", "high" => "high", "xhigh" => "high" }.freeze

    # Audit C4 (2026-09-03): production logs showed thinking=high handed to
    # zai/glm-5.3-flash — cheap fast-tier models ignore or choke on
    # heavyweight thinking. Clamp them to THINKING_LIGHT (default off)
    # UNLESS the tier's THINKING_* key names a level explicitly.
    CLAMP_MODEL_RE = /(flash|turbo|highspeed|air)/

    # Effective thinking level for a tier. Unset tier thinking → THINKING.
    # build-hard bumps one notch above THINKING (capped at high) unless
    # THINKING_BUILD is explicitly set. model: applies the C4 clamp.
    def self.thinking_for(tier, config, model: nil)
      tier_key = THINKING_KEYS[chain_tier(tier)]
      explicit = !tier_key.nil? && !config[tier_key].to_s.empty?
      level =
        if tier == "build-hard"
          explicit_build = config["THINKING_BUILD"]
          if explicit_build && !explicit_build.empty?
            explicit_build
          else
            bump(config["THINKING"])
          end
        else
          val = pick(config[tier_key], tier_key == "THINKING_AUTOPLAN" ? config["THINKING_PLAN"] : nil)
          val && !val.empty? ? val : config["THINKING"]
        end
      if !explicit && !level.to_s.empty? && model.to_s.match?(CLAMP_MODEL_RE)
        level = pick(config["THINKING_LIGHT"], "off")
      end
      level || ""
    end

    # First non-empty value — an empty string counts as unset, not as a value.
    def self.pick(*vals)
      vals.find { |v| v && !v.empty? }
    end

    def self.bump(level)
      BUMP[level] || ""
    end
  end
end
