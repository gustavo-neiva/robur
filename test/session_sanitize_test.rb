# frozen_string_literal: true

require_relative "test_helper"
require "robur/session_sanitize"
require "tmpdir"
require "fileutils"

require "tmpdir"
require "fileutils"

class SessionSanitizeTest < Minitest::Test
  SUITE6 = [
    '{"type":"session","version":3,"id":"x"}',
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}',
    '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","thinkingSignature":"reasoning_content"},{"type":"text","text":"ok"},{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/x"}}]}}',
    '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"only","thinkingSignature":"reasoning_content"}]}}'
  ].join("\n") << "\n"

  # Byte-identical to the bash result (recorded from ratchet session-sanitize).
  SUITE6_EXPECTED = [
    '{"type":"session","version":3,"id":"x"}',
    '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}',
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"/x"}}]}}',
    '{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":""}]}}'
  ].join("\n") << "\n"

  def sanitize(input, **opts)
    dir = Dir.mktmpdir
    file = File.join(dir, "sess.jsonl")
    File.write(file, input)
    result = Robur::SessionSanitize.sanitize(snapshot_dir: File.join(dir, "snaps"), **opts.merge(file: file))
    [result, File.read(file), dir]
  end

  def test_suite6_fixture_strips_thinking_byte_identical
    result, out, = sanitize(SUITE6)
    assert_equal 2, result.stripped
    assert_equal 2, result.rewrote_lines
    assert_equal SUITE6_EXPECTED, out
  end

  def test_disabled_returns_input_unchanged
    result, out, = sanitize(SUITE6, enabled: false)
    assert_equal 0, result.stripped
    assert_equal SUITE6, out
  end

  def test_missing_file_is_noop
    result = Robur::SessionSanitize.sanitize(file: "/nonexistent/x.jsonl", snapshot_dir: "/tmp")
    assert_equal 0, result.stripped
  end

  def test_no_thinking_leaves_file_untouched
    result, out, = sanitize(SUITE6_EXPECTED)
    assert_equal 0, result.stripped
    assert_equal SUITE6_EXPECTED, out
  end

  def test_blank_and_unparseable_lines_preserved
    input = "\nnot json\n#{SUITE6.lines[2]}"
    result, out, = sanitize(input)
    assert_equal 1, result.stripped
    lines = out.split("\n", -1)
    assert_equal "", lines[0]
    assert_equal "not json", lines[1]
    assert_includes lines[2], '"toolCall"'
    refute_includes out, '"thinking"'
  end
end
