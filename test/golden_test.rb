# frozen_string_literal: true

# =============================================================================
#  golden_test.rb — robur's own observable surfaces, pinned.
# =============================================================================
#
#  WHAT THIS REPLACES
#  ------------------
#  This file is the successor to `test/differential/`, which proved robur was
#  byte-for-byte identical to the bash `ratchet` it was ported from. Parity is
#  retired: robur is the product, and it is meant to get BETTER than the thing
#  it replaced, not stay identical to it. A gate that diffs against a binary
#  which no longer defines correctness is worse than no gate — it is a gate
#  that lies, and it punishes every improvement.
#
#  So the oracle changed. There is no second binary here. These tests pin
#  robur's OWN output: the help text, the error surfaces, the doctor report,
#  what `init` puts on disk, the loop's log, and the stats block. When one of
#  them changes, that is a DECISION — re-bless the golden and the diff shows
#  up in review, which is exactly where a user-visible wording change belongs.
#
#  RE-BLESSING A GOLDEN
#  --------------------
#  When you deliberately change a surface, regenerate the fixtures:
#
#      UPDATE_GOLDEN=1 ruby -Ilib -Itest test/golden_test.rb
#
#  That rewrites every file under test/fixtures/golden/ from the current
#  behaviour and reports which ones moved. Then READ THE DIFF (`git diff
#  test/fixtures/golden`) before committing — an unreviewed re-bless is how a
#  golden suite quietly stops meaning anything. To re-bless a single surface,
#  add minitest's name filter:
#
#      UPDATE_GOLDEN=1 ruby -Ilib -Itest test/golden_test.rb -n /doctor/
#
#  STABILITY
#  ---------
#  Golden output is normalized before comparison (see `normalize`) — the same
#  problem the old differential harness solved, and its solutions are carried
#  over: temp paths, timestamps, dates, elapsed seconds, pids, the project
#  slug's path cksum. Two host-dependent probes that robur reports on but does
#  not control (`gitleaks` presence) are collapsed to a canonical line; `pi`
#  is stubbed onto PATH so the default-agent probe is deterministic instead of
#  depending on whether the developer happens to have pi installed. A flaky
#  golden is worse than no golden — anything genuinely nondeterministic gets
#  normalized here, never asserted loosely.
# =============================================================================

require "test_helper"
require "robur/loop"
require "robur/observability"
require "fileutils"
require "open3"
require "tmpdir"

class GoldenTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe/robur")
  AGENT = File.expand_path("fixtures/fake-agent", __dir__)
  GOLDEN_DIR = File.expand_path("fixtures/golden", __dir__)
  UPDATING = ENV["UPDATE_GOLDEN"] == "1"

  PLAN_TWO = <<~PLAN
    # Plan

    ## M1
    - [ ] T1.1 (trivial) first task
    - [ ] T1.2 (trivial) second task
  PLAN

  def setup
    # realpath: macOS hands back /var/... while a chdir'd subprocess reports
    # /private/var/..., and project_slug is a cksum OF THE PATH STRING — the
    # two spellings hash to different log dirs. Canonicalize once, here.
    @tmp = File.realpath(Dir.mktmpdir("robur-golden"))
    # Fixed basenames: the project slug is "<basename>-<cksum of abs path>",
    # so a random basename would leak mktmpdir's pid/date into every surface.
    @home = File.join(@tmp, "home")
    @repo = File.join(@tmp, "repo")
    @stub_bin = File.join(@tmp, "bin")
    FileUtils.mkdir_p([@home, @repo, @stub_bin])
    stub_pi!
    @old_env = ENV.to_hash
    ENV["ROBUR_HOME"] = @home
    ENV.delete("RATCHET_HOME")
  end

  def teardown
    ENV.replace(@old_env) if @old_env
    # Loop.run points these module-level globals at @home; clear them before
    # the dir is gone or a LATER test's CLI.emit ENOENTs on a deleted path.
    Robur::CLI.instance_variable_set(:@loop_log, nil)
    Robur::CLI.instance_variable_set(:@quiet, nil)
    FileUtils.rm_rf(@tmp)
  end

  # --------------------------------------------------------------------------
  #  CLI surfaces
  # --------------------------------------------------------------------------

  def test_help_text
    out, err, status = robur("--help")
    assert_equal 0, status, "--help must exit 0 (stderr: #{err})"
    assert_empty err
    assert_golden "help", cli_surface(out, err, status)
  end

  # The unknown-option surface. Ruby's OptionParser hands you a free
  # `--version`/`-V` that robur never defined; both must land on the SAME
  # FATAL shape, so a stray freebie can't silently become a supported flag.
  def test_unknown_option_is_fatal
    out, err, status = robur("--nope")
    assert_equal 1, status
    assert_golden "unknown-option", cli_surface(out, err, status)
  end

  def test_version_flag_is_the_same_fatal_shape_as_any_unknown_option
    vout, verr, vstatus = robur("--version")
    nout, nerr, nstatus = robur("--nope")
    assert_equal 1, vstatus
    assert_equal nstatus, vstatus
    assert_equal norm(cli_surface(nout, nerr, nstatus)).sub("--nope", "<FLAG>"),
                 norm(cli_surface(vout, verr, vstatus)).sub("--version", "<FLAG>"),
                 "--version must FATAL with the same shape as any other unknown option"
    assert_golden "version-flag", cli_surface(vout, verr, vstatus)
  end

  # --------------------------------------------------------------------------
  #  doctor — the primary user surface for "is this repo loop-ready?"
  # --------------------------------------------------------------------------

  def test_doctor_on_a_well_formed_repo
    seed_repo!
    out, err, status = robur("doctor", ".", chdir: @repo)
    assert_equal 0, status, "a well-formed repo must report zero problems"
    assert_golden "doctor-ok", cli_surface(out, err, status)
  end

  def test_doctor_on_a_conf_with_an_unknown_key
    seed_repo!(conf: base_conf + "NOT_A_KEY=1\n")
    out, err, status = robur("doctor", ".", chdir: @repo)
    assert_equal 1, status, "one unknown key is exactly one problem"
    assert_golden "doctor-unknown-key", cli_surface(out, err, status)
  end

  def test_doctor_on_a_conf_with_a_malformed_line
    seed_repo!(conf: base_conf + "this is not a conf line\n")
    out, err, status = robur("doctor", ".", chdir: @repo)
    assert_equal 1, status
    assert_golden "doctor-malformed-line", cli_surface(out, err, status)
  end

  def test_doctor_on_a_repo_with_no_conf_at_all
    seed_repo!(conf: nil)
    out, err, status = robur("doctor", ".", chdir: @repo)
    assert_equal 2, status, "missing conf + empty VERIFY_CMD are two problems"
    assert_golden "doctor-no-conf", cli_surface(out, err, status)
  end

  # --------------------------------------------------------------------------
  #  init — exactly which files land on a bare repo
  # --------------------------------------------------------------------------

  # The compat symlinks are load-bearing, not cosmetic: atlas' nightly
  # supervisor decides a repo is runnable by testing for `.ratchet.conf`, and
  # harbor reads `.ratchet/stop_reason`. A rename that drops them breaks
  # things outside this repo silently, so the tree listing records the link
  # targets and this test asserts them by name on top of the golden.
  def test_init_on_a_bare_repo_creates_exactly_these_files
    system("git", "-C", @repo, "init", "-q")
    out, err, status = robur("init", ".", chdir: @repo)
    assert_equal 0, status

    assert_golden "init-bare", "#{cli_surface(out, err, status)}--- tree ---\n#{tree_listing(@repo)}"

    assert_equal ".robur", File.readlink(File.join(@repo, ".ratchet")),
                 ".ratchet must stay a symlink to .robur (atlas/harbor read the old name)"
    assert_equal ".robur.conf", File.readlink(File.join(@repo, ".ratchet.conf")),
                 ".ratchet.conf must stay a symlink to .robur.conf (atlas gates runnability on it)"
  end

  # --------------------------------------------------------------------------
  #  the loop — banner in, banner out, and everything logged between
  # --------------------------------------------------------------------------

  # Driven in-process (like loop_test.rb) so the inter-turn sleeps are stubbed;
  # a subprocess `run` would really sleep. The fake-agent ticks exactly one
  # task per invocation, so two tasks = two working turns + one ALL_DONE turn.
  def test_loop_log_of_a_full_run_to_all_done
    seed_repo!(committed: true)
    code = nil
    capture_io { code = Robur::Loop.run(@repo, sleep_it: ->(_s) {}) }
    assert_equal 0, code

    log = File.read(loop_log_path)
    assert_golden "loop-log", log

    # Named separately from the golden so a banner rename says WHICH banner
    # broke, not just "loop-log changed".
    assert_includes log, "robur START", "the run-start banner line is a user surface"
    assert_match(/robur END after 3 turn\(s\)\.$/, log,
                 "the run-end banner must name the turn count")
  end

  def test_stats_rendering_after_a_run
    seed_repo!(committed: true)
    capture_io { Robur::Loop.run(@repo, sleep_it: ->(_s) {}) }
    out, err, status = robur("stats", ".", chdir: @repo)
    assert_equal 0, status
    assert_golden "stats", cli_surface(out, err, status)
  end

  def test_stats_with_nothing_run_yet_is_fatal
    seed_repo!
    out, err, status = robur("stats", ".", chdir: @repo)
    assert_equal 1, status
    assert_golden "stats-no-log", cli_surface(out, err, status)
  end

  def test_status_with_nothing_run_yet
    seed_repo!
    out, err, status = robur("status", ".", chdir: @repo)
    assert_equal 1, status
    assert_golden "status-no-log", cli_surface(out, err, status)
  end

  # --------------------------------------------------------------------------
  #  fanout — the two paths reachable with no gh, no remote, no network
  # --------------------------------------------------------------------------

  def test_fanout_without_parallel_stops_at_the_gate
    seed_repo!
    out, err, status = robur("fanout", ".", chdir: @repo)
    assert_equal 1, status
    assert_golden "fanout-requires-parallel", cli_surface(out, err, status)
  end

  def test_fanout_clean_on_a_repo_with_no_worktrees
    seed_repo!
    out, err, status = robur("fanout-clean", ".", chdir: @repo)
    assert_equal 0, status
    assert_golden "fanout-clean-empty", cli_surface(out, err, status)
  end

  private

  # ---------------------------- golden plumbing -----------------------------

  # One CLI invocation, rendered as a single comparable block. Exit code and
  # WHICH stream a message came out on are part of the contract too — robur's
  # own `emit` routes some errors to stdout, and a silent move between streams
  # would break a pipeline without changing a single word of the text.
  def cli_surface(out, err, status)
    "exit: #{status}\n--- stdout ---\n#{out}--- stderr ---\n#{err}"
  end

  # Compare ACTUAL against the blessed fixture for NAME, or rewrite it under
  # UPDATE_GOLDEN=1. The failure message names the surface and shows a diff,
  # so someone who renamed a string knows immediately what they broke.
  def assert_golden(name, actual)
    path = File.join(GOLDEN_DIR, "#{name}.txt")
    actual = norm(actual)

    if UPDATING
      FileUtils.mkdir_p(GOLDEN_DIR)
      before = File.file?(path) ? File.read(path) : nil
      File.write(path, actual)
      warn "golden #{before.nil? ? 'created' : 'updated'}: #{name}" if before != actual
      return
    end

    unless File.file?(path)
      flunk "no golden for surface '#{name}' (#{path}).\n" \
            "Bless it with:  UPDATE_GOLDEN=1 ruby -Ilib -Itest test/golden_test.rb\n" \
            "--- current output ---\n#{actual}"
    end

    expected = File.read(path)
    return if expected == actual

    flunk <<~MSG
      golden surface '#{name}' changed (#{path.delete_prefix(ROOT + "/")}).

      If this change is intentional, re-bless it:
          UPDATE_GOLDEN=1 ruby -Ilib -Itest test/golden_test.rb -n /#{name.tr("-", ".")}/
      then review `git diff test/fixtures/golden` before committing.

      --- diff (- golden, + actual) ---
      #{unified_diff(expected, actual)}
    MSG
  end

  # A trimmed line diff: drop the identical head and tail, show what moved.
  # Deliberately not a full LCS — for the sizes here (a help screen, a doctor
  # report) prefix/suffix trimming already points at the changed lines.
  def unified_diff(expected, actual)
    e = expected.lines
    a = actual.lines
    pre = 0
    pre += 1 while pre < e.size && pre < a.size && e[pre] == a[pre]
    suf = 0
    suf += 1 while suf < e.size - pre && suf < a.size - pre && e[e.size - 1 - suf] == a[a.size - 1 - suf]

    out = []
    out << "  … #{pre} identical line(s) …" if pre.positive?
    e[pre...(e.size - suf)].each { |l| out << "- #{l.chomp}" }
    a[pre...(a.size - suf)].each { |l| out << "+ #{l.chomp}" }
    out << "  … #{suf} identical line(s) …" if suf.positive?
    out << "  (no line differences — trailing whitespace or newline)" if out.empty?
    out.join("\n")
  end

  # Everything that legitimately differs between two runs of the same code.
  # Narrow on purpose: a wide normalizer hides exactly the regressions this
  # file exists to catch. Add an entry only with a concrete observed flake.
  def norm(text)
    text = text.to_s.scrub
    # Longest paths first.
    text = text.gsub(@tmp, "<TMP>")
    text = text.gsub(ROOT, "<ROOT>")
    text = text.gsub(Dir.home, "<USERHOME>")
    NORMALIZATIONS.each { |re, rep| text = text.gsub(re, rep) }
    text
  end

  NORMALIZATIONS = [
    # CLI.emit's log prefix, and any ISO timestamp/date that reaches output.
    [/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/, "[<timestamp>]"],
    [/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/, "<timestamp>"],
    [/\d{4}-\d{2}-\d{2}/, "<date>"],
    # Wall-clock: the fake-agent's turn is ~3s of python startup and can tick
    # over a second boundary under load. The turn CLASS is the contract here,
    # not how long a stub took.
    [/\btook=\d+s\b/, "took=<n>s"],
    [/\bavg=\d+s max=\d+s\b/, "avg=<n>s max=<n>s"],
    [/\b\d+\.\d+s\b/, "<elapsed>s"],
    [/\bpid[=: ]+\d+\b/i, "pid=<pid>"],
    [/\b\h{40}\b/, "<sha>"],
    # project_slug is "<basename>-<6 digits of cksum(abs path)>": the cksum is
    # of a tmpdir that moves every run.
    [/-\d{6}\b/, "-<cksum>"],
    # doctor REPORTS on gitleaks but does not own it; both branches are `ok`,
    # so collapsing them cannot hide a problem-count change.
    [/^ {2}ok {3}gitleaks .*$/, "  ok   gitleaks: <present or absent on this host>"],
  ].freeze

  # ---------------------------- fixtures ------------------------------------

  def base_conf
    <<~CONF
      MODELS="stub/stub-1"
      AGENT_CMD="#{AGENT}"
      VERIFY_CMD="true"
      TURN_TIMEOUT="30"
      COMMIT_EACH_TURN="1"
      COMMIT_VERIFY_GATE="1"
    CONF
  end

  # A git repo with a tracker and (unless conf: nil) a conf. `committed: true`
  # seeds one commit so a turn's staged diff is the agent's work, not the
  # initial import — .robur.conf is deliberately left untracked, the way the
  # commit gate expects.
  def seed_repo!(conf: base_conf, plan: PLAN_TWO, committed: false)
    File.write(File.join(@repo, "PLAN.md"), plan)
    File.write(File.join(@repo, ".robur.conf"), conf) if conf
    system("git", "-C", @repo, "init", "-q")
    return unless committed

    git("add", "-A")
    git("commit", "-q", "-m", "seed")
    git("reset", "-q", "--", ".robur.conf")
  end

  def git(*args)
    Open3.capture3("git", "-C", @repo, "-c", "user.name=t", "-c", "user.email=t@e.c",
                   "-c", "commit.gpgsign=false", *args)
  end

  # doctor probes whether the default agent (`pi`) is on PATH. Whether the
  # developer happens to have pi installed is not a robur behaviour, so the
  # probe is pinned with a stub rather than normalized away — the ok/FAIL it
  # produces feeds doctor's problem COUNT, which is part of the contract.
  def stub_pi!
    pi = File.join(@stub_bin, "pi")
    File.write(pi, "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, pi)
  end

  def loop_log_path
    File.join(@home, "logs", Robur::CLI.project_slug(@repo), "loop.log")
  end

  def robur(*argv, chdir: @tmp)
    env = {"ROBUR_HOME" => @home, "RATCHET_HOME" => nil,
           "PATH" => "#{@stub_bin}:#{ENV.fetch("PATH", "")}"}
    out, err, st = Open3.capture3(env, EXE, *argv, chdir: chdir)
    [out, err, st.exitstatus]
  end

  # Every path init leaves behind, with symlinks resolved to their target so
  # the compat links are visible in the golden instead of looking like files.
  def tree_listing(dir)
    Dir.glob("#{dir}/**/*", File::FNM_DOTMATCH).sort.filter_map do |path|
      next if %w[. ..].include?(File.basename(path))
      next if path == File.join(dir, ".git") || path.start_with?("#{dir}/.git/")

      kind = if File.symlink?(path) then "symlink -> #{File.readlink(path)}"
             elsif File.directory?(path) then "dir"
             else "file"
             end
      "#{path.delete_prefix("#{dir}/")}  [#{kind}]\n"
    end.join
  end
end
