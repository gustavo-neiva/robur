# frozen_string_literal: true

require "test_helper"
require "robur/commands"
require "robur/cli"
require "robur/paths"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "digest"

module Robur
  class CommandsTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      Open3.capture3("git", "-C", @dir, "init", "-q")
    end

    def teardown
      FileUtils.remove_entry(@dir)
    end

    # T8.5 acceptance, run end to end: a bare repo gets the whole stamp from
    # one command — conf, tracker, learnings, an AGENTS.md carrying the
    # protocol marker — and the result passes doctor with zero problems.
    def test_init_on_a_bare_repo_stamps_the_full_surface_and_doctor_passes
      Commands.init(@dir, emit: ->(_m) {})

      assert_path_exists File.join(@dir, Paths::REPO_CONF)
      assert_path_exists File.join(@dir, "PLAN.md")
      assert_path_exists File.join(@dir, "LEARNINGS.md")
      assert_includes File.read(File.join(@dir, "AGENTS.md")), "robur-protocol:v1"

      out = StringIO.new
      assert_equal 0, Commands.doctor_report(@dir, out: out)
      assert_includes out.string, "protocol delivery: harness-prompt"
    end

    def test_init_stamps_conf_tracker_agents_learnings_and_gitignore
      Commands.init(@dir, emit: ->(_m) {})

      conf = File.join(@dir, Paths::REPO_CONF)

      assert_path_exists conf
      assert_path_exists File.join(@dir, "PLAN.md")
      assert_path_exists File.join(@dir, "LEARNINGS.md")
      assert_path_exists File.join(@dir, "AGENTS.md")
      assert_equal "#{Digest::SHA256.file(conf).hexdigest}\n",
                   File.read(Paths.state_file(@dir, "conf.hash"))
      # Both spellings stay gitignored: the legacy names survive as compat
      # symlinks, and neither must ever be committed.
      assert_equal [".robur/", ".robur.conf", ".ratchet/", ".ratchet.conf"],
                   File.readlines(File.join(@dir, ".gitignore"), chomp: true)
    end

    # Backward compatibility: external tooling (the nightly supervisor's
    # is_runnable check, older scripts) tests for the legacy names. init must
    # leave both resolving to the new files.
    def test_init_leaves_legacy_names_resolving_to_the_new_ones
      Commands.init(@dir, emit: ->(_m) {})

      legacy_conf = File.join(@dir, Paths::LEGACY_REPO_CONF)
      legacy_dir = File.join(@dir, Paths::LEGACY_STATE_DIR)

      assert File.symlink?(legacy_conf), "#{Paths::LEGACY_REPO_CONF} should be a compat symlink"
      assert File.symlink?(legacy_dir), "#{Paths::LEGACY_STATE_DIR} should be a compat symlink"
      assert_equal File.read(File.join(@dir, Paths::REPO_CONF)), File.read(legacy_conf)
      assert_path_exists File.join(legacy_dir, "conf.hash")
    end

    def test_init_strips_legacy_protocol_block_preserving_prose
      Commands.init(@dir, emit: ->(_m) {})
      agents = File.join(@dir, "AGENTS.md")
      File.write(agents, "before\n<!-- robur-protocol:v1:begin -->\nold stuff\n<!-- robur-protocol:v1:end -->\nafter\n")

      migrated = Commands.migrate_agents_md(@dir)

      assert migrated
      assert_equal "before\nafter\n", File.read(agents)
    end

    # Backward compatibility: repos stamped before the rename carry the
    # `ratchet-protocol` marker. Both spellings must be recognised, or an
    # un-migrated repo keeps its stale loop-in-file protocol block forever.
    def test_init_strips_a_legacy_spelled_protocol_block
      Commands.init(@dir, emit: ->(_m) {})
      agents = File.join(@dir, "AGENTS.md")
      File.write(agents,
                 "before\n<!-- ratchet-protocol:v1:begin -->\nold stuff\n<!-- ratchet-protocol:v1:end -->\nafter\n")

      migrated = Commands.migrate_agents_md(@dir)

      assert migrated
      assert_equal "before\nafter\n", File.read(agents)
    end

    def test_doctor_flags_a_legacy_spelled_protocol_block
      Commands.init(@dir, emit: ->(_m) {})
      File.write(File.join(@dir, "AGENTS.md"),
                 "<!-- ratchet-protocol:v1:begin -->\nold\n<!-- ratchet-protocol:v1:end -->\n")
      out = StringIO.new

      Commands.doctor_report(@dir, out: out)

      assert_includes out.string, "AGENTS.md carries a legacy loop-in-file protocol block"
    end

    def test_init_leaves_existing_conf_alone
      conf = File.join(@dir, Paths::REPO_CONF)
      File.write(conf, "ROBUR_PROTOCOL=1\nVERIFY_CMD=custom\n")
      lines = []
      Commands.init(@dir, emit: ->(m) { lines << m })

      assert_includes lines, "  #{Paths::REPO_CONF} exists — leaving it (re-stamp only)"
      assert_equal "ROBUR_PROTOCOL=1\nVERIFY_CMD=custom\n", File.read(conf)
    end

    # Backward compatibility: a repo that never migrated has only
    # `.ratchet.conf`. init must adopt it in place — not scaffold a second
    # conf beside it and silently split the repo's configuration in two.
    def test_init_adopts_a_legacy_conf_in_place
      conf = File.join(@dir, Paths::LEGACY_REPO_CONF)
      File.write(conf, "RATCHET_PROTOCOL=1\nVERIFY_CMD=custom\n")
      lines = []
      Commands.init(@dir, emit: ->(m) { lines << m })

      assert_includes lines, "  #{Paths::LEGACY_REPO_CONF} exists — leaving it (re-stamp only)"
      assert_equal "RATCHET_PROTOCOL=1\nVERIFY_CMD=custom\n", File.read(conf)
      refute_path_exists File.join(@dir, Paths::REPO_CONF)
    end

    def test_doctor_flags_mid_rebase
      Commands.init(@dir, emit: ->(_m) {})
      FileUtils.mkdir_p(File.join(@dir, ".git", "rebase-merge"))
      out = StringIO.new

      problems = Commands.doctor_report(@dir, out: out)

      assert_operator problems, :positive?
      assert_includes out.string, "repo is mid-rebase (interactive)"
    end

    def test_doctor_flags_legacy_protocol_block
      Commands.init(@dir, emit: ->(_m) {})
      File.write(File.join(@dir, "AGENTS.md"),
                 "<!-- robur-protocol:v1:begin -->\nold\n<!-- robur-protocol:v1:end -->\n")
      out = StringIO.new

      Commands.doctor_report(@dir, out: out)

      assert_includes out.string, "AGENTS.md carries a legacy loop-in-file protocol block"
    end

    def test_doctor_warns_light_models_without_thinking_off
      Commands.init(@dir, emit: ->(_m) {})
      conf = File.join(@dir, Paths::REPO_CONF)
      File.write(conf, File.read(conf) + "\nLIGHT_MODELS=zai/glm-5-turbo\n")
      out = StringIO.new

      Commands.doctor_report(@dir, out: out)

      assert_includes out.string, 'WARN : LIGHT_MODELS set but THINKING_LIGHT is not "off"'
    end

    def test_doctor_conf_hash_tamper_detected
      Commands.init(@dir, emit: ->(_m) {})
      conf = File.join(@dir, Paths::REPO_CONF)
      out = StringIO.new
      Commands.doctor_report(@dir, out: out)

      assert_includes out.string, "#{Paths::REPO_CONF} unchanged since onboarding"

      File.write(conf, File.read(conf) + "\n")
      out2 = StringIO.new
      Commands.doctor_report(@dir, out: out2)

      assert_includes out2.string, "#{Paths::REPO_CONF} CHANGED since onboarding"
    end

    # Both spellings of the protocol key are honoured by doctor: a conf
    # written before the rename must not start reporting a failure.
    def test_doctor_accepts_either_protocol_key_spelling
      { Paths::REPO_CONF => "ROBUR_PROTOCOL", Paths::LEGACY_REPO_CONF => "RATCHET_PROTOCOL" }.each do |file, key|
        dir = Dir.mktmpdir
        Open3.capture3("git", "-C", dir, "init", "-q")
        File.write(File.join(dir, file), "#{key}=1\nVERIFY_CMD=true\n")
        Commands.init(dir, emit: ->(_m) {})
        out = StringIO.new

        Commands.doctor_report(dir, out: out)

        assert_includes out.string, "ok   #{key}=1 supported"
      ensure
        FileUtils.remove_entry(dir) if dir
      end
    end

    def test_new_repo_scaffolds_and_stops_for_review
      idea = "Build a Cool Thing!"
      dest = File.join(Dir.mktmpdir, "target")
      lines = []
      Commands.new_repo(idea, dest, emit: ->(m) { lines << m })

      assert_path_exists File.join(dest, "BRIEF.md")
      assert_path_exists File.join(dest, "PLAN.md")
      assert_path_exists File.join(dest, Paths::REPO_CONF)
      assert_includes lines, "STOP FOR PLAN REVIEW (mandatory human checkpoint):"
      assert_includes File.read(File.join(dest, "PLAN.md")), "Plan — #{idea}"
    ensure
      FileUtils.remove_entry(File.dirname(dest)) if dest && Dir.exist?(File.dirname(dest))
    end

    def test_build_plan_prompt_switches_to_ktlo_when_no_open_tasks
      tracker = File.join(@dir, "PLAN.md")
      File.write(tracker, "# Plan\n- [x] T1 done\n")

      prompt = Commands.build_plan_prompt(tracker, "PLAN.md", "STEP_COMPLETE")

      assert_includes prompt, "KTLO PLAN-drafting turn"
    end

    def test_build_plan_prompt_normal_when_open_tasks_remain
      tracker = File.join(@dir, "PLAN.md")
      File.write(tracker, "# Plan\n- [ ] T1 todo\n")

      prompt = Commands.build_plan_prompt(tracker, "PLAN.md", "STEP_COMPLETE")

      assert_includes prompt, "PLAN-drafting turn (robur plan), not implementation"
      refute_includes prompt, "KTLO"
    end
  end
end
