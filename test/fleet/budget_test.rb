# frozen_string_literal: true

require_relative "../test_helper"
require "robur/fleet"
require "tmpdir"
require "fileutils"

# T2.4: Fleet.budget — the ONE resolver for the seven GLOBAL-ONLY keys,
# precedence ENV > ~/.robur/conf > declared defaults. Never the repo conf,
# never Config::ALLOWLIST (design constraint 4).
class FleetBudgetTest < Minitest::Test
  KEYS = %w[
    MAX_RUNS_PER_CYCLE MAX_PLANS_PER_CYCLE AUTOPLAN_MIN_SECS
    BACKOFF_BASE BACKOFF_CAP FLEET_INTERVAL HEALTHCHECK_URL
  ].freeze

  def setup
    @home = Dir.mktmpdir
    @saved = KEYS.to_h { |k| [k, ENV[k]] }
    KEYS.each { |k| ENV.delete(k) }
    ENV["ROBUR_HOME"] = @home
  end

  def teardown
    @saved.each { |k, v| v ? (ENV[k] = v) : ENV.delete(k) }
    ENV.delete("ROBUR_HOME")
    FileUtils.remove_entry(@home)
  end

  def write_conf(text)
    File.write(File.join(@home, "conf"), text)
  end

  def budget = Robur::Fleet.budget

  def test_struct_carries_exactly_the_seven_fields
    assert_equal %i[max_runs max_plans autoplan_min_secs backoff_base
                    backoff_cap interval healthcheck_url],
                 Robur::Fleet::Budget.members
  end

  # Acceptance: no ~/.robur/conf at all -> every field is its default.
  def test_missing_conf_yields_defaults_without_raising
    assert_equal 4, budget.max_runs
    assert_equal 4, budget.max_plans
    assert_equal 21_600, budget.autoplan_min_secs
    assert_equal 3_600, budget.backoff_base
    assert_equal 14_400, budget.backoff_cap
    assert_equal 900, budget.interval
    assert_equal "", budget.healthcheck_url
  end

  # Acceptance: conf sets MAX_RUNS_PER_CYCLE=2, no MAX_PLANS_PER_CYCLE ->
  # max_runs 2, max_plans the default 4; then ENV=9 wins over the conf.
  def test_conf_wins_over_default_and_env_wins_over_conf
    write_conf("MAX_RUNS_PER_CYCLE=2\n")
    assert_equal 2, budget.max_runs
    assert_equal 4, budget.max_plans
    ENV["MAX_RUNS_PER_CYCLE"] = "9"
    assert_equal 9, budget.max_runs
  end

  # load_global's two halves both feed the resolver: plain assignments land
  # in [:values], exports in [:env] — and ENV (the live process) beats both.
  def test_reads_both_values_and_env_halves_of_the_global_conf
    write_conf(<<~CONF)
      MAX_PLANS_PER_CYCLE=3
      export AUTOPLAN_MIN_SECS=60
    CONF
    assert_equal 3, budget.max_plans
    assert_equal 60, budget.autoplan_min_secs
    ENV["AUTOPLAN_MIN_SECS"] = "120"
    assert_equal 120, budget.autoplan_min_secs
  end

  def test_every_key_reads_through_from_the_conf
    write_conf(<<~CONF)
      MAX_RUNS_PER_CYCLE=1
      MAX_PLANS_PER_CYCLE=2
      AUTOPLAN_MIN_SECS=3
      BACKOFF_BASE=5
      BACKOFF_CAP=6
      FLEET_INTERVAL=7
      HEALTHCHECK_URL=https://hc.example/uuid
    CONF
    assert_equal [1, 2, 3, 5, 6, 7, "https://hc.example/uuid"],
                 budget.values
  end

  # A value that is not a number falls back to the default rather than
  # killing the beat; the human-owned conf is still parsed, not evaluated.
  def test_unparsable_number_falls_back_to_default
    ENV["BACKOFF_BASE"] = "soon"
    assert_equal 3_600, budget.backoff_base
  end

  # Design constraint 4: the repo .robur.conf is never consulted — an
  # agent-writable file must not be able to move its own budget.
  def test_repo_conf_setting_these_keys_is_ignored
    write_conf("MAX_RUNS_PER_CYCLE=2\n")
    repo = File.join(@home, "repo")
    FileUtils.mkdir_p(repo)
    File.write(File.join(repo, ".robur.conf"),
               "MAX_RUNS_PER_CYCLE=7\nMAX_PLANS_PER_CYCLE=7\nAUTOPLAN_MIN_SECS=1\n")
    Dir.chdir(repo) do
      b = budget
      assert_equal 2, b.max_runs
      assert_equal 4, b.max_plans
      assert_equal 21_600, b.autoplan_min_secs
    end
  end

  # None of the seven keys may ever reach the repo-conf allowlist.
  def test_fleet_keys_are_not_in_the_allowlist
    assert_empty KEYS & Robur::Config::ALLOWLIST,
                 "fleet budget keys are GLOBAL-ONLY — never enter Config::ALLOWLIST"
  end
end
