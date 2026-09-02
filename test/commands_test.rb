# frozen_string_literal: true

require "test_helper"
require "robur/commands"
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

    def test_init_stamps_conf_tracker_agents_learnings_and_gitignore
      Commands.init(@dir, emit: ->(_m) {})

      assert_path_exists File.join(@dir, ".ratchet.conf")
      assert_path_exists File.join(@dir, "PLAN.md")
      assert_path_exists File.join(@dir, "LEARNINGS.md")
      assert_path_exists File.join(@dir, "AGENTS.md")
      assert_equal "#{Digest::SHA256.file(File.join(@dir, ".ratchet.conf")).hexdigest}\n",
                   File.read(File.join(@dir, ".ratchet", "conf.hash"))
      assert_equal [".ratchet/", ".ratchet.conf"], File.readlines(File.join(@dir, ".gitignore"), chomp: true)
    end

    def test_init_strips_legacy_protocol_block_preserving_prose
      Commands.init(@dir, emit: ->(_m) {})
      agents = File.join(@dir, "AGENTS.md")
      File.write(agents, "before\n<!-- ratchet-protocol:v1:begin -->\nold stuff\n<!-- ratchet-protocol:v1:end -->\nafter\n")

      migrated = Commands.migrate_agents_md(@dir)

      assert migrated
      assert_equal "before\nafter\n", File.read(agents)
    end

    def test_init_leaves_existing_conf_alone
      conf = File.join(@dir, ".ratchet.conf")
      File.write(conf, "RATCHET_PROTOCOL=1\nVERIFY_CMD=custom\n")
      lines = []
      Commands.init(@dir, emit: ->(m) { lines << m })

      assert_includes lines, "  .ratchet.conf exists — leaving it (re-stamp only)"
      assert_equal "RATCHET_PROTOCOL=1\nVERIFY_CMD=custom\n", File.read(conf)
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
                 "<!-- ratchet-protocol:v1:begin -->\nold\n<!-- ratchet-protocol:v1:end -->\n")
      out = StringIO.new

      Commands.doctor_report(@dir, out: out)

      assert_includes out.string, "AGENTS.md carries a legacy loop-in-file protocol block"
    end

    def test_doctor_warns_light_models_without_thinking_off
      Commands.init(@dir, emit: ->(_m) {})
      File.write(File.join(@dir, ".ratchet.conf"),
                 File.read(File.join(@dir, ".ratchet.conf")) + "\nLIGHT_MODELS=zai/glm-5-turbo\n")
      out = StringIO.new

      Commands.doctor_report(@dir, out: out)

      assert_includes out.string, 'WARN : LIGHT_MODELS set but THINKING_LIGHT is not "off"'
    end

    def test_doctor_conf_hash_tamper_detected
      Commands.init(@dir, emit: ->(_m) {})
      out = StringIO.new
      Commands.doctor_report(@dir, out: out)
      assert_includes out.string, ".ratchet.conf unchanged since onboarding"

      File.write(File.join(@dir, ".ratchet.conf"), File.read(File.join(@dir, ".ratchet.conf")) + "\n")
      out2 = StringIO.new
      Commands.doctor_report(@dir, out: out2)
      assert_includes out2.string, ".ratchet.conf CHANGED since onboarding"
    end

    def test_new_repo_scaffolds_and_stops_for_review
      idea = "Build a Cool Thing!"
      dest = File.join(Dir.mktmpdir, "target")
      lines = []
      Commands.new_repo(idea, dest, emit: ->(m) { lines << m })

      assert_path_exists File.join(dest, "BRIEF.md")
      assert_path_exists File.join(dest, "PLAN.md")
      assert_path_exists File.join(dest, ".ratchet.conf")
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

      assert_includes prompt, "PLAN-drafting turn (ratchet plan), not implementation"
      refute_includes prompt, "KTLO"
    end
  end
end
