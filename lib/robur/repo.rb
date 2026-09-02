# frozen_string_literal: true

require "robur/sys"

module Robur
  # Thin git wrapper through Sys::Proc — one default-branch detection (the
  # bash ratchet has four copies of the symbolic-ref + main fallback) and one
  # worktree-porcelain parser (bash has two copies of that state machine, in
  # and after the read loop, in ratchet/lib/commands.sh's fanout-clean).
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

    # Parsed `git worktree list --porcelain` records; the primary worktree
    # is always first (git's own ordering).
    def worktrees
      out, = git("worktree", "list", "--porcelain")
      parse_worktrees(out)
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
