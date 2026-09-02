# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require_relative "test_helper"
require "robur/render"
require "robur/cli"

class RenderTest < Minitest::Test
  RENDER_SH = File.expand_path("../../ratchet/lib/render.sh", __dir__)
  BASH_RATCHET = File.expand_path("../../ratchet/bin/ratchet", __dir__)
  LOGS_DIR = File.expand_path("fixtures/logs", __dir__)

  def bash_render(*funcs_and_call)
    script = funcs_and_call.join("\n")
    src = File.read(RENDER_SH)
    body = src[/^render_bar\(\).*?\n}\n/m] + src[/^fmt_dur\(\).*?\n}\n/m] + src[/^render_eta\(\).*?\n}\n/m]
    Open3.capture3("bash", "-c", "#{body}\n#{script}").first
  end

  def test_bar_matches_bash_at_various_percentages
    [0, 1, 33, 50, 99, 100, -5, 150].each do |pct|
      expected = bash_render("render_bar #{pct} 12")
      assert_equal expected, Robur::Render.bar(pct, 12), "pct=#{pct}"
    end
  end

  def test_fmt_dur_matches_bash
    [0, 5, 59, 60, 61, 3599, 3600, 4820].each do |secs|
      expected = bash_render("fmt_dur #{secs}")
      assert_equal expected, Robur::Render.fmt_dur(secs), "secs=#{secs}"
    end
  end

  def test_eta_matches_bash_including_unknown
    [[0, 0], [5, 0], [19, 171], [1, 30]].each do |remaining, avg|
      expected = bash_render("render_eta #{remaining} #{avg}")
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

  # Full `robur status` vs `ratchet status`, byte-identical, over the frozen
  # logs/*.log fixtures (T6.4 done criterion).
  def test_status_byte_identical_to_bash_on_log_fixtures
    Dir.glob(File.join(LOGS_DIR, "*.log")).each do |fixture|
      Dir.mktmpdir do |repo|
        Dir.mktmpdir do |home|
          `git -C #{repo} init -q`
          slug = Robur::CLI.project_slug(repo)
          log_dir = File.join(home, "logs", slug)
          FileUtils.mkdir_p(log_dir)
          FileUtils.cp(fixture, File.join(log_dir, "loop.log"))
          env = { "RATCHET_HOME" => home, "NO_COLOR" => "1", "HOME" => home }

          bash_out, = Open3.capture3(env, BASH_RATCHET, "status", repo)
          robur_out, = Open3.capture3(env, RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}",
                                       File.expand_path("../exe/robur", __dir__), "status", repo)

          assert_equal bash_out, robur_out, "fixture=#{File.basename(fixture)}"
        end
      end
    end
  end
end
