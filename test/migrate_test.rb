# frozen_string_literal: true

require_relative "test_helper"
require "robur/migrate"
require "tmpdir"

module Robur
  # migrate-state walks a real home directory with hundreds of log dirs, so
  # the two properties that matter are: dry-run touches NOTHING, and a second
  # apply is a no-op.
  class MigrateTest < Minitest::Test
    def seed_home(root)
      home = File.join(root, ".ratchet")
      FileUtils.mkdir_p(File.join(home, "logs", "proj-1"))
      FileUtils.mkdir_p(File.join(home, "logs", "proj-2"))
      File.write(File.join(home, "metrics.tsv"), "a\nb\nc\n")
      File.write(File.join(home, "conf"), "MODELS=x\n")
      home
    end

    def seed_repo(root)
      repo = File.join(root, "repo")
      FileUtils.mkdir_p(File.join(repo, ".ratchet"))
      File.write(File.join(repo, ".ratchet", "stop_reason"), "done\n")
      File.write(File.join(repo, ".ratchet.conf"), "MODELS=y\n")
      repo
    end

    def test_dry_run_touches_nothing
      Dir.mktmpdir do |root|
        home = seed_home(root)
        repo = seed_repo(root)
        before = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort

        actions = Migrate.plan(home: home, new_home: File.join(root, ".robur"), repos: [repo])
        out = Migrate.render(actions, apply: false)

        assert_includes out, "DRY RUN"
        assert_includes out, "--apply"
        assert_equal before, Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort,
                     "planning must not touch disk"
      end
    end

    def test_plan_reports_the_size_of_what_moves
      Dir.mktmpdir do |root|
        home = seed_home(root)
        actions = Migrate.plan(home: home, new_home: File.join(root, ".robur"))
        move = actions.find { |a| a.kind == :move }
        assert_equal "2 log dirs, 3 metrics rows", move.note
      end
    end

    def test_apply_moves_state_and_leaves_resolvable_legacy_paths
      Dir.mktmpdir do |root|
        home = seed_home(root)
        repo = seed_repo(root)
        new_home = File.join(root, ".robur")

        Migrate.apply!(Migrate.plan(home: home, new_home: new_home, repos: [repo]))

        # moved
        assert File.directory?(new_home)
        assert_equal "MODELS=x\n", File.read(File.join(new_home, "conf"))
        assert_equal "done\n", File.read(File.join(repo, ".robur", "stop_reason"))
        assert_equal "MODELS=y\n", File.read(File.join(repo, ".robur.conf"))

        # and the legacy paths still resolve — this is what keeps atlas and
        # harbor working without anyone editing them
        assert File.symlink?(home)
        assert File.symlink?(File.join(repo, ".ratchet"))
        assert File.symlink?(File.join(repo, ".ratchet.conf"))
        assert_equal "done\n", File.read(File.join(repo, ".ratchet", "stop_reason"))
        assert_equal "MODELS=y\n", File.read(File.join(repo, ".ratchet.conf"))
        assert_equal "MODELS=x\n", File.read(File.join(home, "conf"))

        # repo-level links are relative so the repo can be moved or cloned
        assert_equal ".robur", File.readlink(File.join(repo, ".ratchet"))
      end
    end

    def test_apply_is_idempotent
      Dir.mktmpdir do |root|
        home = seed_home(root)
        repo = seed_repo(root)
        new_home = File.join(root, ".robur")
        args = { home: home, new_home: new_home, repos: [repo] }

        Migrate.apply!(Migrate.plan(**args))
        second = Migrate.plan(**args)

        assert(second.all? { |a| a.kind == :skip }, "second plan should be all skips: #{second.map(&:to_s)}")
        assert_includes Migrate.render(second, apply: false), "nothing to do"
        assert_empty Migrate.apply!(second)
        assert_equal "done\n", File.read(File.join(repo, ".robur", "stop_reason"))
      end
    end

    def test_apply_never_clobbers_an_existing_destination
      Dir.mktmpdir do |root|
        home = seed_home(root)
        new_home = File.join(root, ".robur")
        FileUtils.mkdir_p(new_home)
        File.write(File.join(new_home, "conf"), "PRECIOUS\n")

        actions = Migrate.plan(home: home, new_home: new_home)
        Migrate.apply!(actions)

        assert_equal "PRECIOUS\n", File.read(File.join(new_home, "conf"))
        assert_includes actions.map(&:note).compact.join, "already exists"
      end
    end

    def test_absent_legacy_home_is_a_skip_not_an_error
      Dir.mktmpdir do |root|
        actions = Migrate.plan(home: File.join(root, "nope"), new_home: File.join(root, ".robur"))
        assert_equal [:skip], actions.map(&:kind)
        assert_empty Migrate.apply!(actions)
      end
    end
  end
end
