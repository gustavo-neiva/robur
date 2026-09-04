# frozen_string_literal: true

require "fileutils"

module Robur
  # THE source of truth for every on-disk name robur reads or writes.
  #
  # These names used to be string literals scattered across 21 files, which is
  # why renaming them was a scary change instead of a boring one. Everything
  # goes through here now: change a constant, and the whole product follows.
  #
  # ## The rename, and why the old names still resolve
  #
  # robur is no longer a port of the bash ratchet — it is the product, and it
  # owns its own names (`.robur/`, `.robur.conf`, `~/.robur/`). But three
  # things outside this repo still read the OLD names today:
  #
  #   - `atlas/bin/money-loop.sh`  -> .ratchet.conf, .ratchet/stop_reason,
  #                                   .ratchet/loop-backoff, .ratchet/plan-approved
  #   - `atlas/bin/status.sh`      -> .ratchet/last_task.state, .ratchet/last-log,
  #                                   ~/.ratchet/logs, ~/.ratchet/metrics.tsv
  #   - `harbor`'s /blocked        -> .ratchet/stop_reason, .ratchet/last_task.state
  #
  # Breaking them to rename ourselves would be a downgrade, so:
  #
  #   READ  — new name first, old name as fallback. A repo that has only the
  #           old layout keeps working untouched, forever if it likes.
  #   WRITE — always the new name, then `link_legacy!` leaves the old path as
  #           a symlink pointing at the new one. External readers follow it
  #           and never notice; `ls` tells a human exactly what happened.
  #
  # That is the whole compatibility story. It costs one symlink and buys a
  # rename nobody else in the estate has to coordinate with.
  module Paths
    STATE_DIR          = ".robur"
    LEGACY_STATE_DIR   = ".ratchet"
    REPO_CONF          = ".robur.conf"
    LEGACY_REPO_CONF   = ".ratchet.conf"
    HOME_DIR           = ".robur"
    LEGACY_HOME_DIR    = ".ratchet"
    HOME_ENV           = "ROBUR_HOME"
    LEGACY_HOME_ENV    = "RATCHET_HOME"
    METRICS_ENV        = "ROBUR_METRICS"
    LEGACY_METRICS_ENV = "RATCHET_METRICS"
    LOOP_ENV           = "ROBUR_LOOP"
    LEGACY_LOOP_ENV    = "RATCHET_LOOP"
    METRICS_FILE       = "metrics.tsv"

    # Git identifiers robur creates: the branch namespace, the sibling
    # worktree prefix, and the commit-subject scope. Renamed with the rest of
    # the product; the legacy forms are still RECOGNISED when scanning for
    # branches and worktrees a previous version left behind, so an in-flight
    # milestone on another machine is adopted rather than orphaned. New work
    # is always created under the new names.
    BRANCH_NS          = "robur"
    LEGACY_BRANCH_NS   = "ratchet"
    WORKTREE_PREFIX    = "robur-wt-"
    LEGACY_WT_PREFIX   = "ratchet-wt-"
    COMMIT_SCOPE       = "robur"

    module_function

    # The repo's state directory. Prefers `.robur/`; falls back to a
    # pre-existing `.ratchet/` so an un-migrated repo is read correctly.
    # Never creates anything — see `ensure_state_dir!`.
    def state_dir(repo_dir)
      new_path = File.join(repo_dir, STATE_DIR)
      legacy = File.join(repo_dir, LEGACY_STATE_DIR)
      return legacy if !File.exist?(new_path) && File.directory?(legacy) && !File.symlink?(legacy)

      new_path
    end

    def state_file(repo_dir, name) = File.join(state_dir(repo_dir), name)

    # Create the state dir and leave the legacy name pointing at it. The
    # symlink is what keeps atlas and harbor working across the rename.
    def ensure_state_dir!(repo_dir)
      dir = state_dir(repo_dir)
      FileUtils.mkdir_p(dir)
      link_legacy!(repo_dir) if File.basename(dir) == STATE_DIR
      dir
    end

    # `.ratchet` -> `.robur`, relative so the pair survives a repo move.
    # Never clobbers a real directory: a repo still on the old layout keeps
    # its data, and we simply write there instead (see `state_dir`).
    def link_legacy!(repo_dir)
      legacy = File.join(repo_dir, LEGACY_STATE_DIR)
      return :occupied if File.exist?(legacy) && !File.symlink?(legacy)
      return :ok if File.symlink?(legacy) && File.readlink(legacy) == STATE_DIR

      File.unlink(legacy) if File.symlink?(legacy)
      File.symlink(STATE_DIR, legacy)
      :linked
    rescue StandardError
      nil
    end

    # Leave `.ratchet.conf` as a symlink to `.robur.conf`.
    #
    # A directory symlink covers the state dir, but a plain FILE has no such
    # shim, and `atlas/bin/money-loop.sh` gates `is_runnable()` on
    # `.ratchet.conf` existing. Without this, a repo initialized fresh onto
    # `.robur.conf` is silently never picked up by the nightly loop — the
    # exact "the estate quietly broke" failure the compat layer exists to
    # prevent. Called wherever robur writes a repo conf.
    def ensure_repo_conf_link!(repo_dir)
      legacy = File.join(repo_dir, LEGACY_REPO_CONF)
      target = File.join(repo_dir, REPO_CONF)
      return :no_target unless File.file?(target)
      return :occupied if File.exist?(legacy) && !File.symlink?(legacy)
      return :ok if File.symlink?(legacy) && File.readlink(legacy) == REPO_CONF

      File.unlink(legacy) if File.symlink?(legacy)
      File.symlink(REPO_CONF, legacy)
      :linked
    rescue StandardError
      nil
    end

    # Repo config path: `.robur.conf`, falling back to `.ratchet.conf`.
    def repo_conf(repo_dir)
      new_path = File.join(repo_dir, REPO_CONF)
      legacy = File.join(repo_dir, LEGACY_REPO_CONF)
      return legacy if !File.file?(new_path) && File.file?(legacy)

      new_path
    end

    # ROBUR_HOME, then RATCHET_HOME (so an existing isolated harness keeps
    # working), then ~/.robur, then a pre-existing ~/.ratchet.
    def home
      env = ENV[HOME_ENV] || ENV[LEGACY_HOME_ENV]
      return env unless env.to_s.empty?

      new_path = File.join(Dir.home, HOME_DIR)
      legacy = File.join(Dir.home, LEGACY_HOME_DIR)
      return legacy if !File.exist?(new_path) && File.directory?(legacy) && !File.symlink?(legacy)

      new_path
    end

    def metrics_file
      env = ENV[METRICS_ENV] || ENV[LEGACY_METRICS_ENV]
      return env unless env.to_s.empty?

      File.join(home, METRICS_FILE)
    end

    def global_conf = File.join(home, "conf")

    def logs_dir = File.join(home, "logs")

    # Both names are exported for spawned turns during the transition: an
    # agent or hook keyed on either one still fires.
    def loop_env_vars = [LOOP_ENV, LEGACY_LOOP_ENV].freeze

    def plan_branch = "#{BRANCH_NS}/plan"

    def milestone_branch(slug) = "#{BRANCH_NS}/m-#{slug}"

    def worktree_path(slug) = "../#{WORKTREE_PREFIX}#{slug}"

    # Both namespaces, newest naming first — for code that looks for a branch
    # or worktree an earlier run may have created under the old name.
    def milestone_branch_candidates(slug)
      ["#{BRANCH_NS}/m-#{slug}", "#{LEGACY_BRANCH_NS}/m-#{slug}"]
    end

    def worktree_path_candidates(slug)
      ["../#{WORKTREE_PREFIX}#{slug}", "../#{LEGACY_WT_PREFIX}#{slug}"]
    end
  end
end
