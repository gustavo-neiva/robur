# frozen_string_literal: true

require_relative "test_helper"
require "robur/paths"
require "tmpdir"

module Robur
  # The compatibility contract: new names are canonical, legacy names still
  # resolve, and a write leaves the legacy path pointing at the new one.
  # atlas/bin/*.sh and harbor's /blocked read the legacy paths and must keep
  # working across the rename without anyone editing them.
  class PathsTest < Minitest::Test
    def with_env(vars)
      old = vars.to_h { |k, _| [k, ENV[k]] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    def test_state_dir_prefers_the_new_name_for_a_fresh_repo
      Dir.mktmpdir { |d| assert_equal File.join(d, ".robur"), Paths.state_dir(d) }
    end

    def test_state_dir_falls_back_to_an_unmigrated_legacy_dir
      Dir.mktmpdir do |d|
        FileUtils.mkdir_p(File.join(d, ".ratchet"))
        assert_equal File.join(d, ".ratchet"), Paths.state_dir(d),
                     "a repo that never migrated must keep reading its own state"
      end
    end

    def test_state_dir_prefers_new_when_both_exist
      Dir.mktmpdir do |d|
        FileUtils.mkdir_p(File.join(d, ".ratchet"))
        FileUtils.mkdir_p(File.join(d, ".robur"))
        assert_equal File.join(d, ".robur"), Paths.state_dir(d)
      end
    end

    def test_ensure_state_dir_creates_new_and_links_the_legacy_name
      Dir.mktmpdir do |d|
        dir = Paths.ensure_state_dir!(d)
        assert_equal File.join(d, ".robur"), dir
        assert File.directory?(dir)

        legacy = File.join(d, ".ratchet")
        assert File.symlink?(legacy), "legacy path must remain resolvable for external readers"
        assert_equal ".robur", File.readlink(legacy), "link must be relative so the repo can move"

        # the whole point: an external reader using the OLD path sees new writes
        File.write(File.join(dir, "stop_reason"), "done\n")
        assert_equal "done\n", File.read(File.join(legacy, "stop_reason"))
      end
    end

    def test_ensure_state_dir_is_idempotent
      Dir.mktmpdir do |d|
        Paths.ensure_state_dir!(d)
        assert_equal :ok, Paths.link_legacy!(d)
        Paths.ensure_state_dir!(d)
        assert File.symlink?(File.join(d, ".ratchet"))
      end
    end

    def test_link_legacy_never_clobbers_a_real_legacy_directory
      Dir.mktmpdir do |d|
        FileUtils.mkdir_p(File.join(d, ".ratchet"))
        File.write(File.join(d, ".ratchet", "stop_reason"), "keep me\n")
        assert_equal :occupied, Paths.link_legacy!(d)
        assert_equal "keep me\n", File.read(File.join(d, ".ratchet", "stop_reason"))
      end
    end

    def test_repo_conf_prefers_new_then_falls_back
      Dir.mktmpdir do |d|
        assert_equal File.join(d, ".robur.conf"), Paths.repo_conf(d)

        File.write(File.join(d, ".ratchet.conf"), "MODELS=x\n")
        assert_equal File.join(d, ".ratchet.conf"), Paths.repo_conf(d),
                     "an unmigrated repo must keep working with no migration"

        File.write(File.join(d, ".robur.conf"), "MODELS=y\n")
        assert_equal File.join(d, ".robur.conf"), Paths.repo_conf(d)
      end
    end

    # A directory symlink covers the state dir; a plain file does not, and
    # atlas/bin/money-loop.sh gates is_runnable() on `.ratchet.conf`
    # existing. A fresh repo must still be visible to the nightly loop.
    def test_repo_conf_link_keeps_a_fresh_repo_visible_to_the_estate
      Dir.mktmpdir do |d|
        assert_equal :no_target, Paths.ensure_repo_conf_link!(d)

        File.write(File.join(d, ".robur.conf"), "MODELS=x\n")
        assert_equal :linked, Paths.ensure_repo_conf_link!(d)

        legacy = File.join(d, ".ratchet.conf")
        assert File.symlink?(legacy)
        assert_equal ".robur.conf", File.readlink(legacy)
        assert_equal "MODELS=x\n", File.read(legacy)
        assert_equal :ok, Paths.ensure_repo_conf_link!(d)
      end
    end

    def test_repo_conf_link_never_clobbers_a_real_legacy_conf
      Dir.mktmpdir do |d|
        File.write(File.join(d, ".robur.conf"), "new\n")
        File.write(File.join(d, ".ratchet.conf"), "PRECIOUS\n")
        assert_equal :occupied, Paths.ensure_repo_conf_link!(d)
        assert_equal "PRECIOUS\n", File.read(File.join(d, ".ratchet.conf"))
      end
    end

    def test_home_env_precedence_new_then_legacy
      Dir.mktmpdir do |d|
        with_env("ROBUR_HOME" => File.join(d, "a"), "RATCHET_HOME" => File.join(d, "b")) do
          assert_equal File.join(d, "a"), Paths.home
        end
        with_env("ROBUR_HOME" => nil, "RATCHET_HOME" => File.join(d, "b")) do
          assert_equal File.join(d, "b"), Paths.home, "an isolated legacy harness must still work"
        end
      end
    end

    def test_metrics_file_env_precedence_and_default
      Dir.mktmpdir do |d|
        with_env("ROBUR_METRICS" => "/x/m.tsv", "RATCHET_METRICS" => "/y/m.tsv") do
          assert_equal "/x/m.tsv", Paths.metrics_file
        end
        with_env("ROBUR_METRICS" => nil, "RATCHET_METRICS" => "/y/m.tsv") do
          assert_equal "/y/m.tsv", Paths.metrics_file
        end
        with_env("ROBUR_METRICS" => nil, "RATCHET_METRICS" => nil, "ROBUR_HOME" => d) do
          assert_equal File.join(d, "metrics.tsv"), Paths.metrics_file
          assert_equal File.join(d, "conf"), Paths.global_conf
          assert_equal File.join(d, "logs"), Paths.logs_dir
        end
      end
    end

    def test_both_loop_env_vars_are_exported_during_the_transition
      assert_equal %w[ROBUR_LOOP RATCHET_LOOP], Paths.loop_env_vars
    end
  end
end
