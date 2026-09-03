# frozen_string_literal: true

require "robur/sys"

module Robur
  # ONE strike/bench registry keyed by MODEL ID, shared across every chain.
  # The loop previously keyed this state by chain string, so a model present
  # in both a tier chain and the flat MODELS chain got two independent
  # strike counters — the production infinite-spin (same model "strike 1/3"
  # twice, 2.46 wall-hours, 0 successes at position 2). hard_disable_after
  # kills such models permanently: N attempts with zero wins → pick skips
  # forever, even after reset_all (bench reset must not revive a dead model).
  class ModelHealth
    # config: String=>String values (Config.load). max_transient: strike
    # count that triggers a bench. hard_disable_after: attempt count that
    # hard-disables a winless model.
    def initialize(config, clock: Sys::Clock.new, max_transient: 3, hard_disable_after: 20)
      @config = config
      @clock = clock
      @max_transient = max_transient
      @hard_disable_after = hard_disable_after
      @attempts = Hash.new(0)
      @wins = Hash.new(0)
      @strikes = Hash.new(0)
      @bench_until = {}
    end

    # First model in chain not benched and not hard-disabled; nil if none.
    def pick(chain)
      now = @clock.now.to_i
      chain.find { |m| !hard_disabled?(m) && ((@bench_until[m] || 0) <= now) }
    end

    # Bench model for its cooldown; clears its strikes.
    def bench!(model)
      @bench_until[model] = @clock.now.to_i + cooldown_for(model)
      @strikes[model] = 0
    end

    # Bump transient strikes; bench at max_transient. Returns true when
    # THIS strike caused the bench.
    def strike!(model)
      @strikes[model] += 1
      if @strikes[model] >= @max_transient
        bench!(model)
        true
      else
        false
      end
    end

    # klass: classifier verdict (:step, :done, :transient, ...). Any
    # attempt counts; only :step/:done are wins and clear partial strikes.
    def record!(model, klass)
      @attempts[model] += 1
      if klass == :step || klass == :done
        @wins[model] += 1
        @strikes[model] = 0
      end
    end

    def benched?(model)
      (@bench_until[model] || 0) > @clock.now.to_i
    end

    def hard_disabled?(model)
      @attempts[model] >= @hard_disable_after && @wins[model].zero?
    end

    # Clears benches + strikes, NOT attempts/wins — hard-disable survives.
    def reset_all
      @bench_until.clear
      @strikes.clear
    end

    # Per-provider override COOLDOWN_<PROVIDER> beats global COOLDOWN.
    # Byte-identical to the old ModelChain#cooldown_for (port lineage).
    def cooldown_for(model)
      prov = model.split("/", 2).first.split(":", 2).first
      key = "COOLDOWN_#{prov.upcase.gsub(/[^A-Z0-9]/, '_')}"
      val = @config[key]
      val && !val.empty? ? val.to_i : @config.fetch("COOLDOWN").to_i
    end

    def snapshot
      (@attempts.keys | @wins.keys | @strikes.keys | @bench_until.keys).to_h do |m|
        [m, { attempts: @attempts[m], wins: @wins[m], strikes: @strikes[m], benched_until: @bench_until[m] || 0 }]
      end
    end
  end
end
