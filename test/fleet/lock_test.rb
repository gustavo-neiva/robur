# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet/lock"
require "tmpdir"
require "fileutils"

class FleetLockTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir("robur-lock")
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  # Acceptance case: a held lease makes a second acquire return nil without
  # blocking, holder_pid reports the first holder, and after release the
  # re-acquisition succeeds.
  def test_second_acquire_in_one_process_is_nil_then_reacquire_after_release
    lease = Robur::Fleet::Lock.acquire(@repo)
    refute_nil lease
    assert_nil Robur::Fleet::Lock.acquire(@repo)
    assert_equal Process.pid, Robur::Fleet::Lock.holder_pid(@repo)
    lease.release
    second = Robur::Fleet::Lock.acquire(@repo)
    refute_nil second
    second.release
  end

  # The forked-child case: a lock held in another process blocks acquire
  # here, and the kernel releases it when the holder dies, so the repo is
  # not wedged by a SIGKILLed holder.
  def test_acquire_across_processes_non_blocking_then_clean_reacquisition
    child = fork do
      lease = Robur::Fleet::Lock.acquire(@repo)
      exit!(1) unless lease
      sleep 30
    end
    begin
      100.times do
        break if Robur::Fleet::Lock.holder_pid(@repo) == child

        sleep 0.05
      end
      assert_equal child, Robur::Fleet::Lock.holder_pid(@repo), "child never acquired"
      assert_nil Robur::Fleet::Lock.acquire(@repo), "acquire must not block behind a live child"
    ensure
      Process.kill("KILL", child)
      Process.wait(child)
    end
    lease = Robur::Fleet::Lock.acquire(@repo)
    refute_nil lease, "a dead holder must release the repo"
    assert_equal Process.pid, Robur::Fleet::Lock.holder_pid(@repo)
    lease.release
  end

  def test_holder_pid_is_nil_when_never_locked
    assert_nil Robur::Fleet::Lock.holder_pid(@repo)
  end

  # The lock path resolves through Robur::State/Paths (design constraint 2),
  # so it lands in the repo's .robur/ state dir, not a hardcoded name.
  def test_lock_lives_in_the_repo_state_dir
    lease = Robur::Fleet::Lock.acquire(@repo)
    begin
      assert File.file?(Robur::State.state_path(@repo, "loop.lock"))
    ensure
      lease.release
    end
  end
end
