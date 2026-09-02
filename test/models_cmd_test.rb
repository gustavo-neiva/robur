# frozen_string_literal: true

require "test_helper"
require "robur/models_cmd"
require "tmpdir"
require "digest"

module Robur
  class ModelsCmdTest < Minitest::Test
    def setup
      @home = Dir.mktmpdir
      @dir = Dir.mktmpdir
      @emitted = []
      @emit = ->(m) { @emitted << m }
    end

    def teardown
      FileUtils.remove_entry(@home)
      FileUtils.remove_entry(@dir)
    end

    class FakeProc
      def initialize(out: "", ok: true)
        @out = out
        @ok = ok
      end

      def capture(*_cmd)
        [@out, "", Struct.new(:success?).new(@ok)]
      end
    end

    # --- chain_add / chain_remove -------------------------------------------

    def test_chain_add_last_default
      assert_equal "a,b,c", ModelsCmd.chain_add("a,b", "c")
    end

    def test_chain_add_first
      assert_equal "c,a,b", ModelsCmd.chain_add("a,b", "c", "first")
    end

    def test_chain_add_position
      assert_equal "a,c,b", ModelsCmd.chain_add("a,b", "c", "2")
    end

    def test_chain_add_moves_existing_model
      assert_equal "b,a", ModelsCmd.chain_add("a,b", "a", "last")
    end

    def test_chain_add_bad_pos_raises
      assert_raises(RuntimeError) { ModelsCmd.chain_add("a,b", "c", "x") }
    end

    def test_chain_remove
      assert_equal "a,c", ModelsCmd.chain_remove("a,b,c", "b")
    end

    # --- upsert_conf_key -----------------------------------------------------

    def test_upsert_conf_key_appends_when_absent
      file = File.join(@dir, ".ratchet.conf")
      File.write(file, "MODELS=x\n")
      ModelsCmd.upsert_conf_key(file, "PLAN_MODELS", "a/b")
      assert_equal "MODELS=x\nPLAN_MODELS=a/b\n", File.read(file)
    end

    def test_upsert_conf_key_replaces_existing_preserving_other_lines
      file = File.join(@dir, ".ratchet.conf")
      File.write(file, "# comment\nPLAN_MODELS=old\nMODELS=x\n")
      ModelsCmd.upsert_conf_key(file, "PLAN_MODELS", "new")
      assert_equal "# comment\nPLAN_MODELS=new\nMODELS=x\n", File.read(file)
    end

    def test_upsert_conf_key_leaves_commented_template_line_alone
      file = File.join(@dir, ".ratchet.conf")
      File.write(file, "#PLAN_MODELS=\nMODELS=x\n")
      ModelsCmd.upsert_conf_key(file, "PLAN_MODELS", "a/b")
      assert_equal "#PLAN_MODELS=\nMODELS=x\nPLAN_MODELS=a/b\n", File.read(file)
    end

    # --- tier_key / noncoder --------------------------------------------------

    def test_tier_key_models
      assert_equal "PLAN_MODELS", ModelsCmd.tier_key("models", "plan")
      assert_nil ModelsCmd.tier_key("models", "bogus")
    end

    def test_tier_key_thinking
      assert_equal "THINKING_LIGHT", ModelsCmd.tier_key("thinking", "light")
    end

    def test_noncoder_model
      assert ModelsCmd.noncoder_model?("anthropic/claude-fable-5")
      refute ModelsCmd.noncoder_model?("anthropic/claude-sonnet-5")
    end

    def test_chain_with_marks
      assert_equal "a/b [ok], a/c [UNKNOWN]", ModelsCmd.chain_with_marks("a/b,a/c", ["a/b"])
      assert_equal "a/b [?]", ModelsCmd.chain_with_marks("a/b", nil)
      assert_equal "<empty>", ModelsCmd.chain_with_marks("", ["a/b"])
    end

    # --- run: add/remove/thinking --------------------------------------------

    def test_run_add_writes_conf_and_emits
      sys = FakeProc.new(out: "provider  id\na  b\n")
      ModelsCmd.run(["add", "a/b"], config: {}, dir: @dir, emit: @emit, home: @home, sys: sys)
      assert_equal "MODELS=a/b", @emitted[0]
      assert_equal "  -> #{@home}/conf", @emitted[1]
      assert_equal "MODELS=a/b\n", File.read(File.join(@home, "conf"))
    end

    def test_run_add_rejects_unknown_model_without_force
      sys = FakeProc.new(out: "provider  id\nx  y\n")
      err = assert_raises(RuntimeError) do
        ModelsCmd.run(["add", "a/b"], config: {}, dir: @dir, emit: @emit, home: @home, sys: sys)
      end
      assert_match(/not in 'pi --list-models'/, err.message)
    end

    def test_run_add_force_warns_and_adds
      sys = FakeProc.new(out: "provider  id\nx  y\n")
      ModelsCmd.run(["add", "a/b", "--force"], config: {}, dir: @dir, emit: @emit, home: @home, sys: sys)
      assert_match(/WARNING.*not in pi registry/, @emitted[0])
      assert_equal "MODELS=a/b", @emitted[1]
    end

    def test_run_add_repo_target_restamps_conf_hash
      FileUtils.mkdir_p(File.join(@dir, ".ratchet"))
      sys = FakeProc.new(out: "provider  id\na  b\n")
      ModelsCmd.run(["add", "a/b", "--repo"], config: {}, dir: @dir, emit: @emit, home: @home, sys: sys)
      target = File.join(@dir, ".ratchet.conf")
      assert_equal "MODELS=a/b\n", File.read(target)
      expected = "#{Digest::SHA256.file(target).hexdigest}\n"
      assert_equal expected, File.read(File.join(@dir, ".ratchet", "conf.hash"))
    end

    def test_run_remove
      target = File.join(@home, "conf")
      File.write(target, "MODELS=a/b,a/c\n")
      ModelsCmd.run(["remove", "a/b"], config: {}, dir: @dir, emit: @emit, home: @home)
      assert_equal "MODELS=a/c", @emitted[0]
    end

    def test_run_remove_not_present_raises
      target = File.join(@home, "conf")
      File.write(target, "MODELS=a/c\n")
      assert_raises(RuntimeError) { ModelsCmd.run(["remove", "a/b"], config: {}, dir: @dir, emit: @emit, home: @home) }
    end

    def test_run_thinking
      ModelsCmd.run(["thinking", "high", "--tier", "build"], config: {}, dir: @dir, emit: @emit, home: @home)
      assert_equal "THINKING_BUILD=high", @emitted[0]
      assert_equal "THINKING_BUILD=high\n", File.read(File.join(@home, "conf"))
    end

    def test_run_thinking_bad_level_raises
      assert_raises(RuntimeError) { ModelsCmd.run(["thinking", "bogus"], config: {}, dir: @dir, emit: @emit, home: @home) }
    end

    # --- run: list -------------------------------------------------------------

    def test_run_list_shows_effective_chains
      sys = FakeProc.new(out: "provider  id\na  b\n")
      config = { "MODELS" => "a/b", "MODEL_RANK" => "" }
      ModelsCmd.run(["list"], config: config, dir: @dir, emit: @emit, home: @home, sys: sys)
      assert_includes @emitted, "MODEL_RANK: (unset)"
      assert_includes @emitted, "  MODELS : a/b [ok]"
    end

    # --- rank --------------------------------------------------------------

    def test_run_rank_derives_from_registry_when_unset
      sys = FakeProc.new(out: "provider  id\na  b\np  q\n")
      ModelsCmd.run(["list"], config: { "MODELS" => "" }, dir: @dir, emit: @emit, home: @home, sys: sys) # warms cache
      ModelsCmd.run(["rank"], config: { "MODEL_RANK" => "" }, dir: @dir, emit: @emit, home: @home, sys: sys)
      assert(@emitted.any? { |l| l.include?("effective rank: derived") })
      assert File.file?(File.join(@home, "rank.derived"))
    end
  end
end
