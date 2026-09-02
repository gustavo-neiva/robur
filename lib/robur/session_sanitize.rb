# frozen_string_literal: true

require "json"
require "fileutils"

module Robur
  # Cross-provider session continuity (port of ratchet/lib/session-sanitize.sh).
  # Providers sign assistant "thinking" blocks differently; replaying one
  # provider's signed thinking to another fails. Rewrites the Pi JSONL session
  # in place: drops every assistant thinking block, keeps text + tool calls,
  # never leaves an empty assistant message. Snapshots the original first.
  class SessionSanitize
    Result = Struct.new(:stripped, :rewrote_lines, keyword_init: true)

    # enabled: false is the SANITIZE_THINKING=0 path — input returned untouched.
    def self.sanitize(file:, snapshot_dir:, enabled: true, clock: Sys::Clock.new)
      return Result.new(stripped: 0, rewrote_lines: 0) if !enabled || file.nil? || !File.file?(file)

      stripped = 0
      rewrote = 0
      out_lines = []

      File.foreach(file) do |raw|
        line = raw.chomp("\n")
        obj = parse(line)
        if sanitize_line?(obj) && (kept = strip_thinking(obj, ->(n) { stripped += n }))
          rewrote += 1
          out_lines << JSON.generate(obj)
        else
          out_lines << line
        end
      end

      if stripped.positive?
        FileUtils.mkdir_p(snapshot_dir)
        snap = File.join(snapshot_dir, "#{clock.now.strftime("%Y%m%dT%H%M%S")}_#{File.basename(file)}")
        FileUtils.cp(file, snap, preserve: true)
        tmp = "#{file}.sanitize.tmp"
        File.write(tmp, out_lines.join("\n") << "\n")
        File.rename(tmp, file)
      end

      Result.new(stripped: stripped, rewrote_lines: rewrote)
    end

    class << self
      private

      def parse(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def sanitize_line?(obj)
        obj.is_a?(Hash) && obj["type"] == "message" &&
          obj["message"].is_a?(Hash) && obj["message"]["role"] == "assistant" &&
          obj["message"]["content"].is_a?(Array)
      end

      def strip_thinking(obj, count)
        content = obj["message"]["content"]
        kept = content.reject { |b| b.is_a?(Hash) && b["type"] == "thinking" }
        return nil if kept.size == content.size

        count.call(content.size - kept.size)
        kept = [{ "type" => "text", "text" => "" }] if kept.empty?
        obj["message"]["content"] = kept
        kept
      end
    end
  end
end
