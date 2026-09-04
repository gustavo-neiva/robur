# frozen_string_literal: true

require "robur/sys"

module Robur
  # Thin git wrapper through Sys::Proc. Every caller shares ONE default-branch
  # detection (symbolic-ref with a `main` fallback) and ONE worktree-porcelain
  # parser, so the fanout paths and the milestone paths can never disagree
  # about which branch is the base or which worktrees exist.
  class Repo
    Worktree = Struct.new(:path, :head, :branch, :detached, keyword_init: true)

    def initialize(dir, proc: Sys::Proc.new)
      @dir = dir
      @proc = proc
    end

    # refs/remotes/origin/HEAD's branch, or "main" when there's no such ref.
    def default_branch
      out, _err, status = git("symbolic-ref", "refs/remotes/origin/HEAD")
      return "main" unless status&.success?

      branch = out.strip.sub(%r{\Arefs/remotes/origin/}, "")
      branch.empty? ? "main" : branch
    end

    def status_porcelain
      out, = git("status", "--porcelain")
      out
    end

    def staged_diff
      out, = git("diff", "--cached")
      out
    end

    def add_all
      git("add", "-A")
    end

    def add(pathspec)
      git("add", "--", pathspec)
    end

    # Un-stage a pathspec (glob wildcards resolve via git's own pathspec
    # matching, not the shell's).
    def reset(pathspec)
      git("reset", "-q", "--", pathspec)
    end

    def staged_files
      out, = git("diff", "--cached", "--name-only")
      out.split("\n")
    end

    def shortstat(range)
      out, = git("diff", "--shortstat", range)
      out
    end

    def commit(subject, body = nil)
      args = ["commit", "-q", "-m", subject]
      args += ["-m", body] if body
      _out, _err, status = git(*args)
      status&.success? || false
    end

    def checkout_b(branch, base)
      _out, _err, status = git("checkout", "-b", branch, base)
      status&.success? || false
    end

    def push(*args)
      _out, _err, status = git("push", *args)
      status&.success? || false
    end

    def checkout(branch)
      _out, _err, status = git("checkout", branch)
      status&.success? || false
    end

    def pull_ff_only
      _out, _err, status = git("pull", "--ff-only")
      status&.success? || false
    end

    def current_branch
      out, _err, status = git("rev-parse", "--abbrev-ref", "HEAD")
      status&.success? ? out.strip : nil
    end

    def remote?(name = "origin")
      _out, _err, status = git("remote", "get-url", name)
      status&.success? || false
    end

    def diffstat(range)
      out, = git("diff", "--stat", range)
      out
    end

    def rev_parse(ref)
      out, _err, status = git("rev-parse", ref)
      status&.success? ? out.strip : nil
    end

    # Full unified diff for RANGE (optionally scoped to a pathspec), or nil on
    # failure (distinct from an empty string, which is a valid "no changes" diff).
    def diff(range, pathspec = nil)
      args = pathspec ? ["diff", range, "--", pathspec] : ["diff", range]
      out, _err, status = git(*args)
      status&.success? ? out : nil
    end

    # Parsed `git worktree list --porcelain` records; the primary worktree
    # is always first (git's own ordering).
    def worktrees
      out, = git("worktree", "list", "--porcelain")
      parse_worktrees(out)
    end

    # [ok, stderr] -- stderr is inspected by the fanout config.lock retry loop.
    def worktree_add(path, branch, base)
      _out, err, status = git("worktree", "add", path, "-b", branch, base)
      [status&.success? || false, err]
    end

    def worktree_remove(path)
      _out, _err, status = git("worktree", "remove", path)
      status&.success? || false
    end

    def worktree_prune
      git("worktree", "prune")
    end

    def branch_delete_d(branch)
      _out, _err, status = git("branch", "-D", branch)
      status&.success? || false
    end

    # nil (fail toward KEEP) on a git failure, else the raw `git stash list`
    # output (possibly empty).
    def stash_list
      out, _err, status = git("stash", "list")
      status&.success? ? out : nil
    end

    # `git -C WT_PATH log --branches --not --remotes` -- repo-wide (ALL local
    # branches not on ANY remote), scoped by cwd only. Returns nil on failure
    # so callers fail toward KEEPING a worktree, else the raw output
    # (empty = nothing unpushed).
    def unpushed_commits(wt_path)
      out, _err, status = @proc.capture("git", "-C", wt_path, "log", "--branches", "--not", "--remotes")
      status&.success? ? out : nil
    end

    private

    def git(*args)
      @proc.capture("git", "-C", @dir, *args)
    end

    def parse_worktrees(text)
      records = []
      current = nil
      text.each_line(chomp: true) do |line|
        case line
        when /\Aworktree (.+)\z/
          records << Worktree.new(**current) if current
          current = { path: Regexp.last_match(1), head: nil, branch: nil, detached: false }
        when /\AHEAD (.+)\z/
          current[:head] = Regexp.last_match(1)
        when /\Abranch (.+)\z/
          current[:branch] = Regexp.last_match(1).sub(%r{\Arefs/heads/}, "")
        when "detached"
          current[:detached] = true
        end
      end
      records << Worktree.new(**current) if current
      records
    end
  end
end
