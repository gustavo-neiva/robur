# frozen_string_literal: true

# One-command differential runner:
#   ruby test/differential/run.rb [--suite NAME]
# Loads scenario files from test/differential/suites/ (all of them, or just
# suites/NAME.rb), runs each through the harness, prints one line per
# scenario, and ends with "N diffs across M scenarios". Exit 0 iff N == 0.
require_relative "harness"

SCENARIOS = []
UNSUPPORTED = []

def scenario(name:, argv:, setup: nil, env: {}, only: nil, drop_lines: nil)
  SCENARIOS << Robur::Differential::Scenario.new(name: name, argv: argv, setup: setup, env: env,
                                                 only: only, drop_lines: drop_lines)
end

# unsupported: a command/scenario the differential harness structurally
# cannot compare (e.g. it shells out to a live, auth/network-dependent
# external tool on BOTH sides) — listed in the report so it is never
# silently missing from the suite, but excluded from the diff count.
def unsupported(name:, reason:)
  UNSUPPORTED << [name, reason]
end

i = ARGV.index("--suite")
if i
  suite = ARGV[i + 1]
  abort "usage: ruby test/differential/run.rb [--suite NAME]" unless suite
end

dir = File.expand_path("suites", __dir__)
files = suite ? [File.join(dir, "#{suite}.rb")] : Dir.glob(File.join(dir, "*.rb")).sort
files.each do |f|
  abort "no such suite: #{f}" unless File.file?(f)
  load f
end
abort "no scenarios loaded" if SCENARIOS.empty?

runner = Robur::Differential::Runner.new
diffs = 0
SCENARIOS.each do |sc|
  report = runner.run(sc)
  if report.zero_diff?
    puts "ok  #{sc.name}"
  else
    diffs += report.differences.size
    puts "DIFF #{sc.name}: #{report.differences.join(", ")}"
  end
end
UNSUPPORTED.each { |name, reason| puts "unsupported #{name}: #{reason}" }
puts "#{diffs} diffs across #{SCENARIOS.size} scenarios (#{UNSUPPORTED.size} unsupported)"
exit(diffs.zero? ? 0 : 1)
