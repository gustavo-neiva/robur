# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "test_helper"
require "robur/state"
require "robur/paths"

class StateTest < Minitest::Test
  MONEY_LOOP = File.expand_path("../../atlas/bin/money-loop.sh", __dir__)

  # Extracts one `name() { ... }` function body verbatim from a bash script,
  # so sourcing it never runs the script's own `main "$@"; exit $?` tail.
  def bash_function(script, name)
    Open3.capture3("sed", "-n", "/^#{name}() {/,/^}/p", script).first
  end

  def bash_stop_reason(repo_dir)
    script = "#{bash_function(MONEY_LOOP, 'stop_reason')}\nstop_reason #{repo_dir}"
    Open3.capture3("bash", "-c", script).first.strip
  end

  def bash_backed_off(repo_dir)
    script = "#{bash_function(MONEY_LOOP, 'backed_off')}\nbacked_off #{repo_dir} && echo yes || echo no"
    Open3.capture3("bash", "-c", script).first.strip
  end

  # Deliberately the LEGACY path: atlas reads `.ratchet/last_task.state`, and
  # must keep resolving through the compat symlink robur leaves behind.
  def bash_last_task_id(repo_dir)
    Open3.capture3("cut", "-f1", File.join(repo_dir, Robur::Paths::LEGACY_STATE_DIR, "last_task.state")).first.strip
  end

  def test_read_tolerates_missing_files
    Dir.mktmpdir do |d|
      assert_nil Robur::State.read_stop(d)
      assert_nil Robur::State.read_stop_reason(d)
      assert_nil Robur::State.read_loop_backoff(d)
      assert_nil Robur::State.read_last_task(d)
      assert_nil Robur::State.read_milestone_cur(d)
      assert_nil Robur::State.read_conf_hash(d)
      assert_nil Robur::State.read_last_log(d)
      assert_equal [], Robur::State.read_fanout(d)
    end
  end

  def test_write_never_raises_when_path_is_unwritable
    Dir.mktmpdir do |d|
      file_where_dir_should_be = File.join(d, Robur::Paths::STATE_DIR)
      File.write(file_where_dir_should_be, "not a directory")
      assert_nil Robur::State.write_stop_reason(d, "done")
      refute File.directory?(file_where_dir_should_be)
    end
  end

  def test_stop_round_trip
    Dir.mktmpdir do |d|
      assert_nil Robur::State.read_stop(d)

      Robur::State.write_stop(d, "now")
      assert_equal "now", Robur::State.read_stop(d)
      assert_equal "stop", File.basename(Robur::Paths.stop_file(d))

      Robur::State.clear_stop(d)
      assert_nil Robur::State.read_stop(d)
    end
  end

  def test_stop_reason_written_by_bash_ratchet_reads_correctly_and_bash_reader_agrees
    Dir.mktmpdir do |d|
      Robur::Paths.ensure_state_dir!(d)
      File.write(Robur::Paths.state_file(d, "stop_reason"), "human_blocked\n")
      assert_equal "human_blocked", Robur::State.read_stop_reason(d)
      assert_equal "human_blocked", bash_stop_reason(d)

      Robur::State.write_stop_reason(d, "gate_red")
      assert_equal "gate_red\n", File.read(Robur::Paths.state_file(d, "stop_reason"))
      assert_equal "gate_red", bash_stop_reason(d)
    end
  end

  def test_loop_backoff_round_trip_and_bash_reader_agrees
    Dir.mktmpdir do |d|
      Robur::Paths.ensure_state_dir!(d)
      future = Time.now.to_i + 3600
      File.write(Robur::Paths.state_file(d, "loop-backoff"), "2\t#{future}\n")
      assert_equal [2, future], Robur::State.read_loop_backoff(d)
      assert_equal "yes", bash_backed_off(d)

      past = Time.now.to_i - 10
      Robur::State.write_loop_backoff(d, 3, past)
      assert_equal "3\t#{past}\n", File.read(Robur::Paths.state_file(d, "loop-backoff"))
      assert_equal [3, past], Robur::State.read_loop_backoff(d)
      assert_equal "no", bash_backed_off(d)
    end
  end

  def test_last_task_round_trip_and_bash_cut_agrees
    Dir.mktmpdir do |d|
      Robur::Paths.ensure_state_dir!(d)
      File.write(Robur::Paths.state_file(d, "last_task.state"), "T6.3\tstep\n")
      assert_equal %w[T6.3 step], Robur::State.read_last_task(d)
      assert_equal "T6.3", bash_last_task_id(d)

      Robur::State.write_last_task(d, "T7.1", "hard_error")
      assert_equal "T7.1\thard_error\n", File.read(Robur::Paths.state_file(d, "last_task.state"))
      assert_equal %w[T7.1 hard_error], Robur::State.read_last_task(d)
      assert_equal "T7.1", bash_last_task_id(d)
    end
  end

  def test_milestone_cur_round_trip
    Dir.mktmpdir do |d|
      Robur::Paths.ensure_state_dir!(d)
      File.write(Robur::Paths.state_file(d, "milestone.cur"), "M6\tabc123\t2\t1\n")
      assert_equal ["M6", "abc123", 2, 1], Robur::State.read_milestone_cur(d)

      Robur::State.write_milestone_cur(d, "M7", "def456", 0, 0)
      assert_equal "M7\tdef456\t0\t0\n", File.read(Robur::Paths.state_file(d, "milestone.cur"))
      assert_equal ["M7", "def456", 0, 0], Robur::State.read_milestone_cur(d)
    end
  end

  def test_conf_hash_round_trip
    Dir.mktmpdir do |d|
      Robur::Paths.ensure_state_dir!(d)
      File.write(Robur::Paths.state_file(d, "conf.hash"), "none\n")
      assert_equal "none", Robur::State.read_conf_hash(d)

      Robur::State.write_conf_hash(d, "a" * 64)
      assert_equal "#{'a' * 64}\n", File.read(Robur::Paths.state_file(d, "conf.hash"))
      assert_equal "a" * 64, Robur::State.read_conf_hash(d)
    end
  end

  def test_last_log_round_trip
    Dir.mktmpdir do |d|
      Robur::Paths.ensure_state_dir!(d)
      File.write(Robur::Paths.state_file(d, "last-log"), "/tmp/robur-logs/2026-09-01\n")
      assert_equal "/tmp/robur-logs/2026-09-01", Robur::State.read_last_log(d)

      Robur::State.write_last_log(d, "/tmp/robur-logs/2026-09-02")
      assert_equal "/tmp/robur-logs/2026-09-02\n", File.read(Robur::Paths.state_file(d, "last-log"))
    end
  end

  def test_fanout_state_round_trip_matches_bash_append_format
    Dir.mktmpdir do |d|
      pairs = [["../robur-wt-m1", "robur/m-m1"], ["../robur-wt-m2", "robur/m-m2"]]
      Robur::State.write_fanout(d, pairs)
      assert_equal "../robur-wt-m1\trobur/m-m1\n../robur-wt-m2\trobur/m-m2\n",
                   File.read(Robur::Paths.state_file(d, "fanout.state"))
      assert_equal pairs, Robur::State.read_fanout(d)

      Robur::State.write_fanout(d, [])
      assert_equal "", File.read(Robur::Paths.state_file(d, "fanout.state"))
      assert_equal [], Robur::State.read_fanout(d)
    end
  end

  # Backward compatibility: a repo that never migrated has a real `.ratchet/`
  # directory and no `.robur/`. State must be read from — and written back
  # into — the directory that is already there, with nothing to migrate.
  def test_repo_with_only_a_legacy_state_dir_is_read_and_written_in_place
    Dir.mktmpdir do |d|
      legacy = File.join(d, Robur::Paths::LEGACY_STATE_DIR)
      FileUtils.mkdir_p(legacy)
      File.write(File.join(legacy, "stop_reason"), "human_blocked\n")

      assert_equal "human_blocked", Robur::State.read_stop_reason(d)

      Robur::State.write_stop_reason(d, "gate_red")

      assert_equal "gate_red\n", File.read(File.join(legacy, "stop_reason"))
      refute_path_exists File.join(d, Robur::Paths::STATE_DIR)
    end
  end
end
