# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require_relative "test_helper"
require "robur/render"
require "robur/cli"

class RenderTest < Minitest::Test
  LOGS_DIR = File.expand_path("fixtures/logs", __dir__)

  # Pinned expected values (integer math, no floating point) — width 12 covers
  # rounding down (33/50/99%) and both clamp directions (-5/150).
  def test_bar_at_various_percentages
    {
      0 => "\u2591" * 12,
      1 => "\u2591" * 12, # 1*12/100 rounds down to 0 fill
      33 => ("\u2593" * 3) + ("\u2591" * 9),
      50 => ("\u2593" * 6) + ("\u2591" * 6),
      99 => ("\u2593" * 11) + "\u2591",
      100 => "\u2593" * 12,
      -5 => "\u2591" * 12,  # clamps to 0
      150 => "\u2593" * 12, # clamps to 100
    }.each do |pct, expected|
      assert_equal expected, Robur::Render.bar(pct, 12), "pct=#{pct}"
    end
  end

  def test_fmt_dur_at_various_durations
    {
      0 => "0s", 5 => "5s", 59 => "59s",
      60 => "1m", 61 => "1m", 3599 => "59m",
      3600 => "1h0m", 4820 => "1h20m",
    }.each do |secs, expected|
      assert_equal expected, Robur::Render.fmt_dur(secs), "secs=#{secs}"
    end
  end

  def test_eta_at_various_remaining_and_avg
    {
      [0, 0] => "ETA unknown",
      [5, 0] => "ETA unknown",
      [19, 171] => "~19 turns / ~54m left",
      [1, 30] => "~1 turns / ~30s left",
    }.each do |(remaining, avg), expected|
      assert_equal expected, Robur::Render.eta(remaining, avg), "remaining=#{remaining} avg=#{avg}"
    end
  end

  def test_eta_unknown_before_any_recorded_duration
    assert_equal "ETA unknown", Robur::Render.eta(7, 0)
  end

  def test_summary_keeps_last_n_nonblank_lines
    text = "a\n\nb\nc\n  \nd\n"
    assert_equal "c\nd", Robur::Render.summary(text, 2)
  end

  # Pinned end-to-end `robur status` output over the frozen logs/*.log
  # fixtures (old/new loop.log formats). Only the project slug and the log
  # path vary run to run (they embed a tmpdir), so both are normalized before
  # comparing against the pinned text.
  EXPECTED_STATUS = {
    "new-format.log" => "<SLUG> \u25CB\nStep ?/?  [\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591 0%]\n\n" \
                          "Current: \nTier/Model: plan / anthropic/claude-fable-5 (thinking=low)\nNode: build\n" \
                          "Turn 5: running\nETA: ETA unknown\n\nLoop: not running\nLog: <LOG_PATH>\n",
    "old-format.log" => "<SLUG> \u25CB\nStep ?/?  [\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591 0%]\n" \
                          "Tier/Model: \u2014 / anthropic/claude (thinking=\u2014)\nNode: build\n" \
                          "Turn 4: running\nETA: ETA unknown\n\nLoop: not running\nLog: <LOG_PATH>\n",
    "with-took.log" => "<SLUG> \u25CB\nStep ?/?  [\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591\u2591 0%]\n\n" \
                         "Current: \nTier/Model: build / anthropic/claude-sonnet-4 (thinking=high)\nNode: build\n" \
                         "Turn 3: took 84s\nETA: ~0 turns / ~0s left\n\nLoop: not running\nLog: <LOG_PATH>\n",
  }.freeze

  def test_status_report_on_log_fixtures
    Dir.glob(File.join(LOGS_DIR, "*.log")).each do |fixture|
      Dir.mktmpdir do |repo|
        Dir.mktmpdir do |home|
          `git -C #{repo} init -q`
          slug = Robur::CLI.project_slug(repo)
          log_dir = File.join(home, "logs", slug)
          FileUtils.mkdir_p(log_dir)
          FileUtils.cp(fixture, File.join(log_dir, "loop.log"))
          env = { "ROBUR_HOME" => home, "NO_COLOR" => "1", "HOME" => home }

          out, = Open3.capture3(env, RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}",
                                 File.expand_path("../exe/robur", __dir__), "status", repo)
          norm = out.sub(/\A\S+/, "<SLUG>").gsub(/Log: .*$/, "Log: <LOG_PATH>")

          assert_equal EXPECTED_STATUS.fetch(File.basename(fixture)), norm, "fixture=#{File.basename(fixture)}"
        end
      end
    end
  end
end
