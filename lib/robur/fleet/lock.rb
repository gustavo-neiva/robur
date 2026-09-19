# frozen_string_literal: true

require "fileutils"

require_relative "../state"

module Robur
  module Fleet
    # One writer per checkout (PLAN.fleet.md T3.1). `Lock.acquire` returns a
    # `Lease` or nil immediately — never blocks, never breaks an existing
    # lock — so a contended checkout is skipped this cycle and retried on
    # the next beat. This is what stops a cycle from moving HEAD underneath
    # a human's live session in the same tree. Same flock pattern as
    # Robur::Lifecycle#acquire_lock!; the kernel releases the flock when the
    # holder dies, so a SIGKILLed holder never wedges a repo.
    module Lock
      # Held flock on a repo's loop.lock. Release in an ensure, always.
      Lease = Struct.new(:repo, :file) do
        def release
          file.flock(File::LOCK_UN)
          file.close
          nil
        end
      end

      module_function

      # Non-blocking exclusive flock on State.state_path(repo, "loop.lock").
      # Writes the holder pid so Lock.holder_pid can report who has it.
      # Returns nil, without waiting, when the checkout is already locked.
      def acquire(repo)
        path = State.state_path(repo, "loop.lock")
        FileUtils.mkdir_p(File.dirname(path))
        f = File.open(path, File::RDWR | File::CREAT)
        f.flock(File::LOCK_EX | File::LOCK_NB) or begin
          f.close
          return nil
        end
        f.truncate(0)
        f.write("#{Process.pid}\n")
        f.flush
        Lease.new(repo, f)
      end

      # The pid in the lock file — the last holder, held or released. nil
      # when the repo was never locked here.
      def holder_pid(repo)
        line = State.first_line(repo, "loop.lock")
        return nil if line.nil? || line.empty?

        line.to_i
      end

      # True while another process holds the repo's flock (T6.1's status
      # column). Probed with a non-blocking exclusive flock on a READ-ONLY
      # handle and released immediately: the kernel hands it straight back
      # and no byte is written, so status stays read-only. The kernel
      # releases a dead holder's flock, so a stale file never reads held.
      def held?(repo)
        path = State.state_path(repo, "loop.lock")
        return false unless File.file?(path)

        f = File.open(path, "r")
        f.flock(File::LOCK_EX | File::LOCK_NB)
        f.flock(File::LOCK_UN)
        false
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN
        true
      ensure
        f.close if f
      end
    end
  end
end
