require_relative "../test_helper"
require_relative "harness"
require "fileutils"
require "tmpdir"

# T1.5 done-criteria. The real baseline/candidate pair has no CLI parity yet
# (the CLI port lands in M6), so the harness self-test runs the same binary on
# both sides: identical output proves the plumbing reports zero differences,
# and a deliberately injected space proves it catches exactly that difference.
class DifferentialHarnessTest < Minitest::Test
  H = Robur::Differential

  def test_help_scenario_reports_zero_differences
    report = H::Runner.new.run(help_scenario,
                               baseline_cmd: H::CANDIDATE_CMD,
                               candidate_cmd: H::CANDIDATE_CMD)
    assert_kind_of H::DiffReport, report
    assert_empty report.differences, "expected zero diffs, got: #{report.differences}"
  end

  def test_injected_extra_space_lists_exactly_one_difference_named_stdout
    Dir.mktmpdir("robur-mutant") do |dir|
      # exe/robur resolves lib/ relative to itself, so the mutant needs the
      # real lib/ beside it — a lone copy dies with LoadError before printing.
      path = File.join(dir, "exe/robur")
      src = File.read(H::CANDIDATE_CMD)
      assert_includes src, "usage: robur", "usage text moved; update the injection"
      FileUtils.cp_r(File.join(H::ROBUR_ROOT, "lib"), File.join(dir, "lib"))
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, src.sub("usage: robur", "usage:  robur"))
      FileUtils.chmod(0o755, path)
      report = H::Runner.new.run(help_scenario, candidate_cmd: path)
      assert_equal ["stdout"], report.differences
    end
  end

  private

  def help_scenario
    H::Scenario.new(name: "help", argv: ["--help"])
  end
end
