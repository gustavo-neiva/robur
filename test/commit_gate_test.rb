# frozen_string_literal: true

require_relative "test_helper"
require "robur/commit_gate"
require "tmpdir"
require "open3"

module Robur
  class CommitGateTest < Minitest::Test
    FakePlan = Struct.new(:completed_subject)

    def git_repo
      dir = Dir.mktmpdir
      git(dir, "init", "-q", "-b", "main")
      git(dir, "config", "user.email", "t@example.com")
      git(dir, "config", "user.name", "T")
      File.write(File.join(dir, "f.txt"), "hi\n")
      git(dir, "add", "f.txt")
      git(dir, "commit", "-q", "-m", "init")
      dir
    end

    def git(dir, *args) = system("git", "-C", dir, *args, out: File::NULL, err: File::NULL)

    def config(overrides = {})
      { "COMMIT_EACH_TURN" => "1", "COMMIT_VERIFY_GATE" => "1", "VERIFY_CMD" => "true",
        "COMMIT_EXCLUDE_GLOBS" => "" }.merge(overrides)
    end

    def gate(dir, cfg = config)
      CommitGate.new(dir, plan: FakePlan.new("SUBJECT"), config: cfg)
    end

    def test_green_tree_commits_once_with_mined_subject
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir).run(turn: 3, model: "acme/model")
      assert result.committed
      out, = Open3.capture3("git", "-C", dir, "log", "--format=%s", "-1")
      assert_equal "auto(ratchet): turn 3 acme/model \u2014 SUBJECT\n", out
    end

    def test_red_verify_cmd_blocks_and_leaves_work_staged
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir, config("VERIFY_CMD" => "false")).run(turn: 1, model: "m")
      refute result.committed
      assert_equal "commit gate RED", result.block_reason
      out, = Open3.capture3("git", "-C", dir, "diff", "--cached", "--name-only")
      assert_equal "new.txt\n", out
    end

    def test_empty_verify_cmd_is_a_loud_warning_not_a_silent_skip
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir, config("VERIFY_CMD" => "")).run(turn: 1, model: "m")
      assert result.committed
      assert result.verify_cmd_empty
    end

    def test_zero_added_lines_is_clean_and_commit_proceeds
      dir = git_repo
      File.delete(File.join(dir, "f.txt"))
      result = gate(dir).run(turn: 1, model: "m")
      assert result.committed
      assert_nil result.block_reason
    end

    def test_nothing_staged_skips_cleanly
      dir = git_repo
      result = gate(dir).run(turn: 1, model: "m")
      refute result.committed
      assert_nil result.block_reason
    end

    # ratchet:allow-secret — these are synthetic fixture shapes for the scanner
    # under test, not real credentials; the outer commit gate's own scan would
    # otherwise block committing this test file.
    def test_blocks_private_key
      assert_blocked("id_rsa", "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n", # ratchet:allow-secret
                      "private key material in staged diff")
    end

    def test_blocks_aws_access_key_id
      assert_blocked("conf.txt", "AWS_KEY=AKIAABCDEFGHIJKLMNOP\n", "AWS access key id in staged diff") # ratchet:allow-secret
    end

    def test_blocks_sk_style_api_key
      assert_blocked("conf.txt", "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx\n", # ratchet:allow-secret
                      "API key (sk-/sk-ant-) in staged diff")
    end

    def test_blocks_jwt
      header = "eyJhbGciOiJIUzI1NiJ9"
      payload = "eyJzdWIiOiIxMjM0NTY3ODkwIn0"
      sig = "SflKxwRJSMeKKF2QT4fwpMeJf36POk6y"
      assert_blocked("conf.txt", "Authorization: Bearer #{header}.#{payload}.#{sig}\n", "JWT in staged diff") # ratchet:allow-secret
    end

    def test_blocks_dot_env_addition
      dir = git_repo
      File.write(File.join(dir, ".env"), "SECRET=1\n")
      result = gate(dir).run(turn: 1, model: "m")
      refute result.committed
      assert_equal ".env file staged", result.block_reason
    end

    def test_allow_secret_marker_exempts_a_line
      dir = git_repo
      File.write(File.join(dir, "conf.txt"), "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx # ratchet:allow-secret\n")
      result = gate(dir).run(turn: 1, model: "m")
      assert result.committed
    end

    def test_commit_each_turn_off_skips_cleanly
      dir = git_repo
      File.write(File.join(dir, "new.txt"), "hello\n")
      result = gate(dir, config("COMMIT_EACH_TURN" => "0")).run(turn: 1, model: "m")
      refute result.committed
      assert_nil result.block_reason
      out, = Open3.capture3("git", "-C", dir, "diff", "--cached", "--name-only")
      assert_equal "", out
    end

    def test_unstages_dot_ratchet_conf
      dir = git_repo
      File.write(File.join(dir, ".ratchet.conf"), "VERIFY_CMD=true\n")
      File.write(File.join(dir, "new.txt"), "hello\n")
      gate(dir).run(turn: 1, model: "m")
      out, = Open3.capture3("git", "-C", dir, "log", "--format=", "-1", "--name-only")
      refute_includes out, ".ratchet.conf"
    end

    private

    def assert_blocked(filename, content, reason)
      dir = git_repo
      File.write(File.join(dir, filename), content)
      result = gate(dir).run(turn: 1, model: "m")
      refute result.committed
      assert_equal reason, result.block_reason
    end
  end
end
