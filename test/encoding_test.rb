# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"

# Under launchd there is no LANG, so Ruby's default_external/default_internal
# fall back to US-ASCII and any bare File.read/readlines/foreach of a UTF-8
# tracker or AGENTS.md raises "invalid byte sequence in US-ASCII" — this is
# what killed every nightly run inside Commands.doctor_report. exe/robur pins
# both process encodings to UTF-8 before requiring anything else, so this
# test exercises the real entrypoint as a subprocess under an environment
# scrubbed the way launchd actually runs it. An in-process test cannot see a
# regression here: by the time minitest boots, this test process's own
# encoding is already pinned by whatever launched *it*.
class EncodingTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXE = File.join(ROOT, "exe/robur")

  def setup
    @dir = Dir.mktmpdir
    Open3.capture3("git", "-C", @dir, "init", "-q")
    File.write(File.join(@dir, "PLAN.md"), <<~PLAN)
      # Plan

      - [ ] T1 (trivial) café ñ 日本語 — non-ASCII task title
    PLAN
    File.write(File.join(@dir, ".robur.conf"), "VERIFY_CMD=true\n")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_doctor_survives_a_utf8_tracker_under_a_launchd_like_scrubbed_env
    # No LANG/LC_* at all, and a minimal PATH — this is what launchd hands a
    # process. unsetenv_others: true means only the keys below exist; nothing
    # from this test's own environment leaks through.
    env = {"PATH" => "/usr/bin:/bin", "HOME" => ENV["HOME"]}
    out, err, status = Open3.capture3(env, RbConfig.ruby, EXE, "doctor", @dir,
                                       unsetenv_others: true, chdir: @dir)

    refute_includes err, "invalid byte sequence", "doctor crashed on the UTF-8 tracker: #{err}"
    refute_includes out, "invalid byte sequence", "doctor crashed on the UTF-8 tracker: #{out}"
    refute_match(/\.rb:\d+:in [`']/, err, "doctor raised instead of reporting: #{err}")
    # Proves the tracker was actually read (not skipped) without raising: the
    # ok line only prints once the regex match against its UTF-8 content
    # succeeds — under US-ASCII that match raises on the file's first
    # non-ASCII byte instead of returning.
    assert_includes out, "tracker 'PLAN.md' has an open task"
  end
end
