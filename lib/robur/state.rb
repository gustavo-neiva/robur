# frozen_string_literal: true

require "fileutils"

require_relative "paths"

module Robur
  # Owns every `.robur/` state file, one read + one write method per file,
  # with byte-exact formats — the on-disk contract this module exposes to
  # any external reader. Reads tolerate a missing file (return nil / []);
  # writes never raise, so a state write is never the thing that takes a
  # turn down.
  module State
    module_function

    # stop_reason: one word on one line.
    def read_stop_reason(repo_dir)
      first_line(repo_dir, "stop_reason")
    end

    def write_stop_reason(repo_dir, reason)
      write_line(repo_dir, "stop_reason", reason)
    end

    # stop file: signals the loop to halt; the mode word says why.
    def read_stop(repo_dir)
      first_line(repo_dir, "stop")
    end

    def write_stop(repo_dir, mode)
      write_line(repo_dir, "stop", mode)
    end

    def clear_stop(repo_dir)
      File.unlink(state_path(repo_dir, "stop"))
    rescue StandardError
      nil
    end

    # loop-backoff: "count<TAB>until_epoch".
    def read_loop_backoff(repo_dir)
      count, until_epoch = tab_fields(repo_dir, "loop-backoff", 2)
      return nil unless count

      [count.to_i, until_epoch.to_i]
    end

    def write_loop_backoff(repo_dir, count, until_epoch)
      write_tab_fields(repo_dir, "loop-backoff", count, until_epoch)
    end

    # last_task.state: "taskid<TAB>status".
    def read_last_task(repo_dir)
      taskid, status = tab_fields(repo_dir, "last_task.state", 2)
      return nil unless taskid

      [taskid, status]
    end

    def write_last_task(repo_dir, taskid, status)
      write_tab_fields(repo_dir, "last_task.state", taskid, status)
    end

    # milestone.cur: "name<TAB>base_sha<TAB>cycle<TAB>errors".
    def read_milestone_cur(repo_dir)
      name, base_sha, cycle, errors = tab_fields(repo_dir, "milestone.cur", 4)
      return nil unless name

      [name, base_sha, cycle.to_i, errors.to_i]
    end

    def write_milestone_cur(repo_dir, name, base_sha, cycle, errors)
      write_tab_fields(repo_dir, "milestone.cur", name, base_sha, cycle, errors)
    end

    # conf.hash: sha256 hex, or the literal "none".
    def read_conf_hash(repo_dir)
      first_line(repo_dir, "conf.hash")
    end

    def write_conf_hash(repo_dir, hash)
      write_line(repo_dir, "conf.hash", hash)
    end

    # last-log: the log directory path, one line.
    def read_last_log(repo_dir)
      first_line(repo_dir, "last-log")
    end

    def write_last_log(repo_dir, log_dir)
      write_line(repo_dir, "last-log", log_dir)
    end

    # fanout.state: zero or more "wt_path<TAB>branch" lines, one appended per
    # created worktree. Read -> array of [wt_path, branch] pairs, [] when
    # missing/empty.
    def read_fanout(repo_dir)
      path = state_path(repo_dir, "fanout.state")
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).reject(&:empty?).map { |line| line.split("\t", 2) }
    rescue Errno::ENOENT
      []
    end

    # Write -> overwrites the whole file (a fresh fanout run truncates first).
    def write_fanout(repo_dir, pairs)
      content = pairs.map { |wt_path, branch| "#{wt_path}\t#{branch}\n" }.join
      write_raw(repo_dir, "fanout.state", content)
    end

    # Every state read/write resolves through Paths, which prefers `.robur/`
    # and falls back to a pre-existing `.ratchet/` (see Robur::Paths).
    def state_path(repo_dir, name) = Paths.state_file(repo_dir, name)

    def first_line(repo_dir, name)
      path = state_path(repo_dir, name)
      return nil unless File.file?(path)

      File.foreach(path) { |line| return line.chomp }
      nil
    rescue Errno::ENOENT
      nil
    end

    def tab_fields(repo_dir, name, count)
      line = first_line(repo_dir, name)
      return Array.new(count) unless line

      line.split("\t", count)
    end

    def write_line(repo_dir, name, value)
      write_raw(repo_dir, name, "#{value}\n")
    end

    def write_tab_fields(repo_dir, name, *values)
      write_raw(repo_dir, name, "#{values.join("\t")}\n")
    end

    def write_raw(repo_dir, name, content)
      path = state_path(repo_dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      nil
    rescue StandardError
      nil
    end
  end
end
