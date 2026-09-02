# frozen_string_literal: true

# Differential harness core: run the same scenario against the bash ratchet
# (baseline) and robur (candidate) in pristine fixture copies, then diff the
# observable surfaces. Normalization is a deliberately NARROW substitution
# list — a wide normalizer would hide exactly the regressions this exists
# to catch.
require "fileutils"
require "open3"
require "tmpdir"

module Robur
  module Differential
    ROBUR_ROOT = File.expand_path("../..", __dir__)
    BASELINE_CMD = File.expand_path("../ratchet/bin/ratchet", ROBUR_ROOT)
    CANDIDATE_CMD = File.join(ROBUR_ROOT, "exe/robur")
    FAKE_AGENT = File.join(ROBUR_ROOT, "test/fixtures/fake-agent")
    FIXTURE_REPO = File.join(ROBUR_ROOT, "test/fixtures/fixture-repo")

    # Explicit, narrow: timestamps, temp paths, elapsed seconds, PIDs, shas.
    # Nothing else. Add entries only with a concrete observed diff in hand.
    NORMALIZATIONS = [
      [/^\h{40}$/, "<sha>"],                                   # full commit sha lines
      [/\b\h{7}\b(?=[[:space:]]|$)/, "<sha>"],                 # short shas
      [/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/, "<timestamp>"],
      [/\d{4}-\d{2}-\d{2}/, "<date>"],
      [/\d+\.\d+s\b/, "<elapsed>s"],
      [/\bin \d+s\b/, "in <elapsed>s"],
      [/\bpid[=: ]+\d+\b/i, "pid<PID>"],
      [/\b[A-Za-z0-9-]+-\d{6}\b/, "<slug>"], # project_slug: cksum of abs path differs per side
    ].freeze

    Scenario = Struct.new(:name, :argv, :setup, :env, keyword_init: true) do
      # setup: optional proc called with the fresh fixture repo path, per run,
      # so each side gets an identical pre-state.
      def initialize(name:, argv:, setup: nil, env: {})
        raise ArgumentError, "setup must be callable" if setup && !setup.respond_to?(:call)
        super
      end
    end

    # Surface name => [baseline, candidate] (normalized).
    class DiffReport
      attr_reader :scenario, :surfaces

      def initialize(scenario, surfaces)
        @scenario = scenario
        @surfaces = surfaces
      end

      def differences
        surfaces.select { |_, (a, b)| a != b }.keys
      end

      def zero_diff?
        differences.empty?
      end
    end

    class Runner
      def self.normalize(text, temp_root: nil, home: nil)
        text = text.gsub(home, "<RATCHET_HOME>") if home
        text = text.gsub(temp_root, "<TMP>") if temp_root
        text = text.scrub # baseline logs may carry invalid UTF-8
        NORMALIZATIONS.each { |re, rep| text = text.gsub(re, rep) }
        text
      end

      # Returns a DiffReport for one scenario. The command pair is injectable
      # so the harness can prove itself (zero-diff control, injected mutation)
      # before the real pair has CLI parity — see test/differential/harness_test.rb.
      def run(scenario, baseline_cmd: BASELINE_CMD, candidate_cmd: CANDIDATE_CMD)
        Dir.mktmpdir("robur-diff") do |tmp|
          runs = {
            baseline: {cmd: baseline_cmd, home: File.join(tmp, "home-base")},
            candidate: {cmd: candidate_cmd, home: File.join(tmp, "home-cand"), extra: asdf_env},
          }
          results = runs.transform_values do |r|
            FileUtils.mkdir_p(r[:home])
            # Repo inside the side's home dir so both sides share the repo
            # basename — the home-path normalization then covers repo paths.
            repo = File.join(r[:home], "repo")
            pristine_fixture_repo(repo)
            scenario.setup&.call(repo)
            env = {
              "RATCHET_HOME" => r[:home],
              "AGENT_CMD" => FAKE_AGENT,
              "HOME" => r[:home],
            }.merge(r[:extra] || {}).merge(scenario.env)
            out, err, st = Open3.capture3(env, r[:cmd], *scenario.argv, chdir: repo)
            {
              stdout: out, stderr: err, exit: st.exitstatus,
              files: snapshot_files(repo, r[:home]), git_log: git_log(repo),
              tmp: tmp, home: r[:home],
            }
          end
          build_report(scenario, results)
        end
      end

      private

      # Redirecting HOME breaks the asdf ruby shim (its global-version
      # fallback reads $HOME/.tool-versions), so exe/robur exits 126. Pin
      # the version the harness itself is running under.
      def asdf_env
        {"ASDF_RUBY_VERSION" => RUBY_VERSION}
      end

      private

      # Pristine copy of the fixture repo with one deterministic commit, so
      # both sides see an identical repo and `git log` is comparable.
      def pristine_fixture_repo(dest)
        FileUtils.cp_r(File.join(FIXTURE_REPO, "."), dest)
        git = ->(*args) { system("git", "-C", dest, *args, out: File::NULL, err: File::NULL) }
        git.call("init", "-q")
        git.call("add", "-A")
        git.call("-c", "user.name=fixture", "-c", "user.email=fixture@example.com",
                 "-c", "commit.gpgsign=false",
                 "commit", "-q", "-m", "fixture",
                 "--date=2026-01-01T00:00:00Z", "--author=fixture <fixture@example.com>")
      end

      def snapshot_files(repo, home)
        files = {}
        [File.join(repo, ".ratchet"), home].each do |root|
          Dir.glob("#{root}/**/*", File::FNM_DOTMATCH).sort.each do |path|
            next if File.directory?(path) || path.include?("/.git/")
            key = path.delete_prefix("#{root}/")
            key = "home/#{key}" unless root.end_with?(".ratchet")
            files[key] = File.read(path)
          end
        end
        files
      end

      def git_log(repo)
        Open3.capture3("git", "-C", repo, "log", "--format=%s").first
      end

      def build_report(scenario, results)
        base, cand = results[:baseline], results[:candidate]
        surfaces = {
          "stdout" => [norm(base[:stdout], base[:tmp], base[:home]), norm(cand[:stdout], cand[:tmp], cand[:home])],
          "stderr" => [norm(base[:stderr], base[:tmp], base[:home]), norm(cand[:stderr], cand[:tmp], cand[:home])],
          "exit code" => [base[:exit].to_s, cand[:exit].to_s],
          "git log" => [base[:git_log], cand[:git_log]],
        }
        # Group per-side snapshot keys by their normalized name: slug-bearing
        # log paths (home/logs/<slug>/loop.log) differ per side by the path
        # cksum but are the same surface.
        groups = Hash.new { |h, k| h[k] = {} }
        {baseline: base, candidate: cand}.each do |side, r|
          r[:files].each { |orig, content| groups[self.class.normalize(orig, temp_root: r[:tmp], home: r[:home])][side] = content }
        end
        groups.sort.each do |k, pair|
          surfaces["file #{k}"] = [norm(pair[:baseline].to_s, base[:tmp], base[:home]),
                                   norm(pair[:candidate].to_s, cand[:tmp], cand[:home])]
        end
        # metrics.tsv and loop.log live under RATCHET_HOME, already in files
        DiffReport.new(scenario, surfaces)
      end

      def norm(text, tmp, home = nil)
        self.class.normalize(text, temp_root: tmp, home: home)
      end
    end
  end
end
