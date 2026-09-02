# frozen_string_literal: true

require_relative "test_helper"
require "robur/repo"
require "tmpdir"

module Robur
  class RepoTest < Minitest::Test
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

    def test_default_branch_without_origin_head_is_main
      assert_equal "main", Repo.new(git_repo).default_branch
    end

    def test_default_branch_reads_origin_head
      dir = git_repo
      git(dir, "update-ref", "refs/remotes/origin/develop", "HEAD")
      git(dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop")
      assert_equal "develop", Repo.new(dir).default_branch
    end

    def test_status_and_staged_helpers
      dir = git_repo
      repo = Repo.new(dir)
      File.write(File.join(dir, "f.txt"), "bye\n")
      File.write(File.join(dir, "new.txt"), "new\n")
      git(dir, "add", ".")
      assert_match(/^M  f\.txt/, repo.status_porcelain)
      assert_includes repo.staged_diff, "-hi"
      assert_equal %w[f.txt new.txt], repo.staged_files.sort
    end

    def test_commit_checkout_b_and_shortstat
      dir = git_repo
      repo = Repo.new(dir)
      assert repo.checkout_b("feature", "main")
      File.write(File.join(dir, "f.txt"), "changed\n")
      git(dir, "add", ".")
      assert repo.commit("subject", "body")
      assert_match(/1 file changed/, repo.shortstat("main..HEAD"))
    end

    def test_worktrees_lists_primary_first_with_correct_paths_and_branches
      dir = git_repo
      Dir.mktmpdir do |parent|
        wt1 = File.join(parent, "wt1")
        wt2 = File.join(parent, "wt2")
        git(dir, "worktree", "add", "-b", "wt1-branch", wt1)
        git(dir, "worktree", "add", "-b", "wt2-branch", wt2)

        records = Repo.new(dir).worktrees
        assert_equal 3, records.length
        assert_equal File.realpath(dir), File.realpath(records[0].path)
        assert_equal "main", records[0].branch
        refute records[0].detached

        paths = records[1..].map { |r| File.realpath(r.path) }
        assert_includes paths, File.realpath(wt1)
        assert_includes paths, File.realpath(wt2)
        branches = records[1..].map(&:branch)
        assert_includes branches, "wt1-branch"
        assert_includes branches, "wt2-branch"
      end
    end
  end
end
