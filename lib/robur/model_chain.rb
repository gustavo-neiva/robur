# frozen_string_literal: true

module Robur
  # First-available model chain with per-model transient strikes and
  # bench-until cooldowns (port of ratchet/lib/model-fallback.sh).
  # Clock is injected so cooldown expiry is testable without sleeping.
  class ModelChain
    attr_reader :models

    # models: array of model id strings. config: String=>String values
    # (Config.load). max_transient: strike count that triggers a bench.
    def initialize(models, config, clock:, max_transient: 3)
      raise ArgumentError, "no models configured (MODELS='#{models.join(',')}')" if models.empty?

      @models = models
      @config = config
      @clock = clock
      @max_transient = max_transient
      @bench_until = Array.new(models.size, nil)
      @strikes = Array.new(models.size, 0)
    end

    # Index of the first model whose cooldown has expired, or nil if all benched.
    def pick
      now = @clock.now.to_i
      @models.each_index do |idx|
        return idx if (@bench_until[idx] || 0) <= now
      end
      nil
    end

    # Bench model at index for its cooldown; clears its strikes.
    def bench!(index)
      @bench_until[index] = @clock.now.to_i + cooldown_for(@models[index])
      @strikes[index] = 0
    end

    # Bump transient strikes; bench at MAX_TRANSIENT consecutive failures.
    # Returns true when the strike caused a bench.
    def strike!(index)
      @strikes[index] += 1
      if @strikes[index] >= @max_transient
        bench!(index)
        true
      else
        false
      end
    end

    # Clear all cooldowns and strikes (the BOTH_WAIT reset path).
    def reset_all
      @bench_until.fill(nil)
      @strikes.fill(0)
    end

    def benched?(index)
      (@bench_until[index] || 0) > @clock.now.to_i
    end

    # Per-provider override COOLDOWN_<PROVIDER> beats global COOLDOWN.
    # Provider is the model's leading path segment (before '/' or ':'),
    # upper-cased, non-alnum → _.
    def cooldown_for(model)
      prov = model.split("/", 2).first.split(":", 2).first
      key = "COOLDOWN_#{prov.upcase.gsub(/[^A-Z0-9]/, '_')}"
      val = @config[key]
      val && !val.empty? ? val.to_i : @config.fetch("COOLDOWN").to_i
    end
  end
end
