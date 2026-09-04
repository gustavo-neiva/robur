# frozen_string_literal: true

require "fileutils"
require_relative "paths"

module Robur
  # Moves live state from the legacy `.ratchet` names onto robur's own
  # `.robur` names, and leaves a symlink behind at every old path.
  #
  # The symlinks are the point, not a courtesy. Three things outside this
  # repo still read the old paths — atlas/bin/money-loop.sh,
  # atlas/bin/status.sh and harbor's /blocked — and a rename that made a
  # human go patch three repos on the same night would be a worse product,
  # not a better one. After migrating, both names resolve to the same bytes.
  #
  # Dry-run is the default and `apply: true` is the only way to touch disk,
  # because this walks a real home directory with hundreds of log dirs.
  # Every step is idempotent: a second run reports nothing to do.
  module Migrate
    Action = Struct.new(:kind, :from, :to, :note, keyword_init: true) do
      def to_s
        case kind
        when :move then "move    #{from} -> #{to}#{note ? " (#{note})" : ""}"
        when :link then "symlink #{from} -> #{to}"
        when :skip then "skip    #{from}#{note ? " (#{note})" : ""}"
        end
      end
    end

    module_function

    # Everything that would change, in the order it would happen. Pure: this
    # touches nothing, so `robur migrate-state` can print it and stop.
    def plan(home: File.join(Dir.home, Paths::LEGACY_HOME_DIR),
             new_home: File.join(Dir.home, Paths::HOME_DIR), repos: [])
      actions = []
      actions.concat(home_actions(home, new_home))
      repos.each { |r| actions.concat(repo_actions(File.expand_path(r))) }
      actions
    end

    def home_actions(legacy, target)
      return [Action.new(kind: :skip, from: legacy, note: "no legacy home")] unless File.exist?(legacy)
      if File.symlink?(legacy)
        return [Action.new(kind: :skip, from: legacy, note: "already migrated (symlink)")]
      end
      if File.exist?(target)
        return [Action.new(kind: :skip, from: legacy, note: "#{target} already exists — merge by hand")]
      end

      [Action.new(kind: :move, from: legacy, to: target, note: describe_home(legacy)),
       Action.new(kind: :link, from: legacy, to: target)]
    end

    def repo_actions(repo)
      out = []
      out.concat(pair_actions(File.join(repo, Paths::LEGACY_STATE_DIR),
                             File.join(repo, Paths::STATE_DIR), Paths::STATE_DIR))
      out.concat(pair_actions(File.join(repo, Paths::LEGACY_REPO_CONF),
                             File.join(repo, Paths::REPO_CONF), Paths::REPO_CONF))
      out
    end

    # One legacy path -> new path, plus the compat symlink. `link_target` is
    # relative so the pair survives the repo being moved or cloned elsewhere.
    def pair_actions(legacy, target, link_target)
      return [] unless File.exist?(legacy) || File.symlink?(legacy)
      return [Action.new(kind: :skip, from: legacy, note: "already migrated (symlink)")] if File.symlink?(legacy)
      return [Action.new(kind: :skip, from: legacy, note: "#{target} already exists")] if File.exist?(target)

      [Action.new(kind: :move, from: legacy, to: target),
       Action.new(kind: :link, from: legacy, to: link_target)]
    end

    # Executes a plan. Returns the actions actually performed. A :move whose
    # destination appeared since planning is downgraded to :skip rather than
    # clobbering it — this runs against a live home directory.
    def apply!(actions)
      done = []
      actions.each do |a|
        case a.kind
        when :move
          next if File.exist?(a.to) || !File.exist?(a.from)

          FileUtils.mkdir_p(File.dirname(a.to))
          FileUtils.mv(a.from, a.to)
          done << a
        when :link
          next if File.exist?(a.from) && !File.symlink?(a.from)

          File.unlink(a.from) if File.symlink?(a.from)
          File.symlink(a.to, a.from)
          done << a
        end
      end
      done
    end

    # Human-readable size of what is about to move, so a dry-run says
    # "286 log dirs, 2376 metrics rows" instead of just a path.
    def describe_home(dir)
      logs = Dir.glob(File.join(dir, "logs", "*")).count
      metrics = File.join(dir, Paths::METRICS_FILE)
      rows = File.file?(metrics) ? File.foreach(metrics).count : 0
      "#{logs} log dirs, #{rows} metrics rows"
    rescue StandardError
      nil
    end

    # Renders a plan for the terminal, including the reason dry-run exists.
    def render(actions, apply:)
      lines = actions.map { |a| "  #{a}" }
      header = apply ? "migrate-state: applying" : "migrate-state: DRY RUN (pass --apply to act)"
      changed = actions.count { |a| a.kind != :skip }
      footer = changed.zero? ? "  nothing to do" : nil
      ([header] + (footer ? [footer] : lines)).join("\n")
    end
  end
end
