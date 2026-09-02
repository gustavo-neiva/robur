# frozen_string_literal: true

require "fileutils"
require "robur/config"
require "robur/tier"
require "robur/sys"

module Robur
  # `ratchet models`: list/add/remove/thinking/rank model config (port of
  # ratchet/lib/models.sh). Registry validation is against the pi model cache
  # ($RATCHET_HOME/models.registry, 24h TTL) — refreshed by the interactive
  # subcommands, read-only for `list`'s registry marks when stale.
  #
  # ponytail: models.dev cost cache (ratchet/lib/model-cost.sh) is NOT ported
  # (no task owns it yet) — `_chain_with_marks` never appends a cost suffix,
  # and rank derivation always takes bash's own "no cost signal" branch
  # (arbitrary registry order + stderr warning). Add model_cost.rb + wire the
  # cost join here when a task ports model-cost.sh.
  module ModelsCmd
    module_function

    def global_conf(home)
      ENV["GLOBAL_CONF"] || File.join(home, "conf")
    end

    # parse_pi_models: `pi --list-models` table -> "provider/id" lines,
    # skipping the header row (awk 'NF>=2 && $1!="provider"').
    def parse_pi_models(text)
      text.each_line.filter_map do |line|
        fields = line.split
        next if fields.size < 2 || fields[0] == "provider"
        "#{fields[0]}/#{fields[1]}"
      end
    end

    # pi_model_registry(refresh:) -> array of "provider/id", or nil when
    # unavailable. Default: serve the 24h cache; refresh: true calls pi and
    # rewrites the cache (nil on failure — no pi on PATH, or an empty table).
    def pi_model_registry(home, refresh: false, sys: Sys::Proc.new)
      cache = File.join(home, "models.registry")
      unless refresh
        return File.file?(cache) ? File.read(cache).each_line(chomp: true).reject(&:empty?) : nil
      end

      out, _err, status = sys.capture("pi", "--list-models")
      return nil unless status.success?
      reg = parse_pi_models(out)
      return nil if reg.empty?
      FileUtils.mkdir_p(home)
      File.write(cache, "#{reg.join("\n")}\n")
      reg
    rescue Errno::ENOENT
      nil # `pi` not on PATH (bash: `command -v pi` gate)
    end

    # chain_add CHAIN MODEL POS -> the new chain. MODEL already present is
    # removed first (so add --pos also moves).
    def chain_add(chain, model, pos = "last")
      out = split_chain(chain).reject { |m| m == model }
      case pos
      when "last", "", nil
        out << model
      when "first"
        out.unshift(model)
      else
        raise "bad --pos '#{pos}' (want first|last|N)" unless pos =~ /\A\d+\z/

        n = pos.to_i
        n = 1 if n < 1
        n = [n, out.length + 1].min
        out.insert(n - 1, model)
      end
      out.join(",")
    end

    # chain_remove CHAIN MODEL -> the chain without MODEL.
    def chain_remove(chain, model)
      split_chain(chain).reject { |m| m == model }.join(",")
    end

    def split_chain(chain)
      chain.to_s.split(",").reject(&:empty?)
    end

    # upsert_conf_key FILE KEY VALUE — replace the active KEY= line (leaving
    # commented template lines alone) or append at the end. Every other line
    # (comments included) is preserved byte-for-byte.
    def upsert_conf_key(file, key, val)
      lines = File.file?(file) ? File.readlines(file, chomp: true) : []
      done = false
      out = lines.map do |line|
        if !done && line.start_with?("#{key}=")
          done = true
          "#{key}=#{val}"
        else
          line
        end
      end
      out << "#{key}=#{val}" unless done
      File.write(file, out.empty? ? "" : "#{out.join("\n")}\n")
    end

    TIER_KEYS = {
      "models" => { "models" => "MODELS", "flat" => "MODELS", "plan" => "PLAN_MODELS",
                     "build" => "BUILD_MODELS", "light" => "LIGHT_MODELS" },
      "thinking" => { "models" => "THINKING", "flat" => "THINKING", "plan" => "THINKING_PLAN",
                        "build" => "THINKING_BUILD", "light" => "THINKING_LIGHT" },
    }.freeze

    # _tier_key KIND TIER -> the conf key, or nil (kind: models|thinking).
    def tier_key(kind, tier)
      TIER_KEYS.dig(kind, tier)
    end

    # _chain_with_marks CHAIN REGISTRY -> "m1 [ok], m2 [UNKNOWN]" (no cost —
    # see the module comment).
    def chain_with_marks(chain, reg)
      models = split_chain(chain)
      return "<empty>" if models.empty?

      models.map do |m|
        mark = if reg.nil? then "?"
               elsif reg.include?(m) then "ok"
               else "UNKNOWN"
               end
        "#{m} [#{mark}]"
      end.join(", ")
    end

    NONCODER_PATTERN = /fable|mythos|vision|image|-5v-|-5v\z|\A5v-/.freeze

    # _is_noncoder_model PROVIDER/ID -> true for known non-coder families
    # (creative-writing / vision / image); guards auto-derivation only, never
    # an explicit MODEL_RANK entry.
    def noncoder_model?(id)
      id.sub(%r{\A[^/]*/}, "") =~ NONCODER_PATTERN ? true : false
    end

    # _derive_rank_live: filtered registry order (ALLOWED_PROVIDERS, drop
    # non-coder families). No models.dev cost cache is ported here, so this
    # always takes bash's "no cost signal" branch — arbitrary registry order,
    # with the same stderr warning.
    def derive_rank_live(reg, allowed_providers)
      return nil if reg.nil? || reg.empty?

      allowed = split_chain(allowed_providers)
      avail = reg.select { |m| allowed.empty? || allowed.include?(m.split("/", 2).first.split(":").first) }
      return nil if avail.empty?

      kept = avail.reject { |m| noncoder_model?(m) }
      warn "rank: WARNING no cost/rank signal (models.dev cache empty and MODEL_RANK unset) — models are in arbitrary registry order, NOT ranked by skill. Set MODEL_RANK in ~/.ratchet/conf or run `ratchet models rank refresh`." unless kept.empty?
      kept
    end

    # derived_rank HOME -> snapshot (stable mid-project) or derive live and
    # write it.
    def derived_rank(home, reg, allowed_providers)
      snap = File.join(home, "rank.derived")
      return File.read(snap).each_line(chomp: true).reject(&:empty?) if File.file?(snap)

      ranked = derive_rank_live(reg, allowed_providers)
      return nil if ranked.nil?

      FileUtils.mkdir_p(home)
      File.write(snap, "#{ranked.join("\n")}\n")
      ranked
    end

    # ranked_available_models -> MODEL_RANK order, then unranked models in
    # registry order (no cost cache to sort unranked by — see module comment).
    def ranked_available_models(home, reg, model_rank, allowed_providers)
      return derived_rank(home, reg, allowed_providers) if model_rank.to_s.empty?
      return nil if reg.nil? || reg.empty?

      allowed = split_chain(allowed_providers)
      avail = reg.select { |m| allowed.empty? || allowed.include?(m.split("/", 2).first.split(":").first) }
      return nil if avail.empty?

      rank_arr = split_chain(model_rank)
      ranked, unranked = avail.partition { |m| rank_arr.any? { |r| m == r || m.split("/", 2).first == r } }
      ranked = ranked.sort_by { |m| rank_arr.index { |r| m == r || m.split("/", 2).first == r } }
      ranked + unranked
    end

    # suggest_chain TIER -> comma-separated chain for plan|build|light|review.
    def suggest_chain(home, tier, reg, model_rank, allowed_providers)
      ranked = ranked_available_models(home, reg, model_rank, allowed_providers)
      return nil if ranked.nil? || ranked.empty?

      slice = Tier.suggest_slice(tier, ranked)
      slice.empty? ? nil : slice.join(",")
    end

    # refresh_rank_snapshot: refresh the pi registry and rewrite rank.derived
    # from live derivation.
    def refresh_rank_snapshot(home, config, emit:, sys: Sys::Proc.new)
      reg = pi_model_registry(home, refresh: true, sys: sys)
      raise "pi registry refresh failed" if reg.nil?

      ranked = derive_rank_live(reg, config["ALLOWED_PROVIDERS"])
      raise "rank derivation failed" if ranked.nil?

      FileUtils.mkdir_p(home)
      snap = File.join(home, "rank.derived")
      File.write(snap, "#{ranked.join("\n")}\n")
      emit.call("rank snapshot refreshed: #{snap}")
    end

    # --repo edit changes the contract: re-stamp the conf hash so doctor
    # doesn't flag ratchet's own edit as tampering.
    def after_edit(target, repo, repo_dir)
      return unless repo && repo_dir && File.directory?(File.join(repo_dir, ".ratchet"))

      File.write(File.join(repo_dir, ".ratchet", "conf.hash"), "#{Config.conf_hash(target)}\n")
    rescue StandardError
      nil
    end

    Options = Struct.new(:sub, :tier, :pos, :repo, :force, :arg, :repo_dir, keyword_init: true)

    # Owns its own arg parse (model ids + --tier/--pos would trip the main
    # OptionParser). argv excludes the leading "models" subcommand token.
    def parse(argv, repo_dir)
      argv = argv.dup
      sub = argv.empty? ? "list" : argv.shift
      opts = Options.new(sub: sub, tier: "models", pos: "last", repo: false, force: false, arg: "", repo_dir: repo_dir)
      i = 0
      while i < argv.length
        a = argv[i]
        case a
        when "--tier" then opts.tier = argv[i + 1]; i += 2
        when "--pos" then opts.pos = argv[i + 1]; i += 2
        when "--repo" then opts.repo = true; i += 1
        when "--force" then opts.force = true; i += 1
        when "-d", "--dir" then opts.repo_dir = argv[i + 1]; i += 2
        when /\A-/ then raise "ratchet models: unknown option '#{a}'"
        else
          raise "ratchet models: unexpected '#{a}'" unless opts.arg.empty?

          opts.arg = a
          i += 1
        end
      end
      opts
    end

    # cmd_models ARGV CONFIG DIR — dispatched after conf precedence load, so
    # CONFIG holds the effective tier chains for `list`.
    def run(argv, config:, dir:, emit:, home: CLI.ratchet_home, sys: Sys::Proc.new)
      opts = parse(argv, dir)
      target = opts.repo ? File.join(File.expand_path(opts.repo_dir || Dir.pwd), ".ratchet.conf") : global_conf(home)
      repo_dir_abs = opts.repo ? File.expand_path(opts.repo_dir || Dir.pwd) : nil

      case opts.sub
      when "list" then list(home, config, emit, sys)
      when "add" then add(home, config, opts, target, repo_dir_abs, emit, sys)
      when "remove" then remove(config, opts, target, repo_dir_abs, emit)
      when "thinking" then thinking(opts, target, repo_dir_abs, emit)
      when "rank" then rank(home, config, opts, emit, sys)
      else raise "usage: ratchet models [list|add|remove|thinking|rank] ... (see --help)"
      end
    end

    def list(home, config, emit, sys)
      reg = pi_model_registry(home, refresh: true, sys: sys)
      emit.call("note: pi registry unavailable — showing chains without validation marks") if reg.nil?
      emit.call(config["MODEL_RANK"].to_s.empty? ? "MODEL_RANK: (unset)" : "MODEL_RANK: #{config["MODEL_RANK"]}")
      emit.call("")
      emit.call("effective chains (edit targets: global=#{global_conf(home)} | --repo <dir>/.ratchet.conf):")
      emit.call("  MODELS : #{chain_with_marks(config["MODELS"], reg)}")
      %w[plan build light].each do |t|
        key = tier_key("models", t)
        chain = config[key]
        label = format("%-6s", t.upcase)
        if chain && !chain.empty?
          emit.call("  #{label} : #{chain_with_marks(chain, reg)} (thinking=#{Tier.thinking_for(t, config)})")
        else
          derived = suggest_chain(home, t, reg, config["MODEL_RANK"], config["ALLOWED_PROVIDERS"])
          emit.call("  #{label} : -> MODELS (flat) (thinking=#{Tier.thinking_for(t, config)})")
          emit.call("           derived: #{chain_with_marks(derived, reg)}") if derived
        end
      end
      return unless reg

      emit.call("registry: #{reg.length} models from 'pi --list-models'")
      emit.call("edit: ratchet models add <provider/id> [--tier plan|build|light] [--pos first|last|N] [--repo]")
    end

    def add(home, _config, opts, target, repo_dir_abs, emit, sys)
      raise "usage: ratchet models add <provider/id> [--tier T] [--pos first|last|N] [--repo] [--force]" if opts.arg.empty?

      key = tier_key("models", opts.tier)
      raise "bad --tier '#{opts.tier}' (want models|plan|build|light)" unless key
      raise "model id must be provider/id form: '#{opts.arg}'" unless opts.arg.include?("/")

      reg = pi_model_registry(home, refresh: true, sys: sys)
      if reg && !reg.include?(opts.arg)
        raise "'#{opts.arg}' not in 'pi --list-models' (typo or churned id? --force to add anyway)" unless opts.force

        emit.call("WARNING: '#{opts.arg}' not in pi registry — added anyway (--force).")
      end
      cur = current_value(target, key)
      new_chain = chain_add(cur, opts.arg, opts.pos)
      upsert_conf_key(target, key, new_chain)
      after_edit(target, opts.repo, repo_dir_abs)
      emit.call("#{key}=#{new_chain}")
      emit.call("  -> #{target}")
    end

    def remove(_config, opts, target, repo_dir_abs, emit)
      raise "usage: ratchet models remove <provider/id> [--tier T] [--repo]" if opts.arg.empty?

      key = tier_key("models", opts.tier)
      raise "bad --tier '#{opts.tier}' (want models|plan|build|light)" unless key

      cur = current_value(target, key)
      raise "'#{opts.arg}' not in #{key}='#{cur}'" unless split_chain(cur).include?(opts.arg)

      new_chain = chain_remove(cur, opts.arg)
      upsert_conf_key(target, key, new_chain)
      after_edit(target, opts.repo, repo_dir_abs)
      emit.call("#{key}=#{new_chain}")
      emit.call("  -> #{target}")
    end

    THINKING_LEVELS = %w[off minimal low medium high xhigh].freeze

    def thinking(opts, target, repo_dir_abs, emit)
      raise "usage: ratchet models thinking <off|minimal|low|medium|high|xhigh> [--tier T] [--repo]" if opts.arg.empty?
      raise "bad thinking level '#{opts.arg}' (off|minimal|low|medium|high|xhigh)" unless THINKING_LEVELS.include?(opts.arg)

      key = tier_key("thinking", opts.tier)
      raise "bad --tier '#{opts.tier}' (want models|plan|build|light)" unless key

      upsert_conf_key(target, key, opts.arg)
      after_edit(target, opts.repo, repo_dir_abs)
      emit.call("#{key}=#{opts.arg}")
      emit.call("  -> #{target}")
    end

    def rank(home, config, opts, emit, sys)
      return refresh_rank_snapshot(home, config, emit: emit, sys: sys) if opts.arg == "refresh"

      reg = pi_model_registry(home)
      emit.call("note: pi registry unavailable — showing rank without validation marks") if reg.nil?
      if !config["MODEL_RANK"].to_s.empty?
        emit.call("effective rank: MODEL_RANK (explicit) | signal: your ordering (skill)")
        ranked = ranked_available_models(home, reg, config["MODEL_RANK"], config["ALLOWED_PROVIDERS"])
        raise "failed to resolve MODEL_RANK" if ranked.nil?

        emit.call(chain_with_marks(ranked.join(","), reg))
      else
        snap = File.join(home, "rank.derived")
        emit.call(File.file?(snap) ? "effective rank: derived (snapshot: #{snap})" : "effective rank: derived (no snapshot yet; will be created on first use)")
        emit.call("signal: NONE — arbitrary registry order (no cost cache, MODEL_RANK unset). Set MODEL_RANK or run 'ratchet models rank refresh'.")
        ranked = derived_rank(home, reg, config["ALLOWED_PROVIDERS"])
        raise "failed to derive rank" if ranked.nil?

        emit.call(chain_with_marks(ranked.join(","), reg))
      end
    end

    def current_value(target, key)
      return "" unless File.file?(target)

      line = File.readlines(target, chomp: true).find { |l| l.start_with?("#{key}=") }
      line ? line.split("=", 2)[1].to_s : ""
    end
  end
end
