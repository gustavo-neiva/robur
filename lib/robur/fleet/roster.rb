# frozen_string_literal: true

require_relative "../fleet"
require_relative "../sys"

module Robur
  module Fleet
    # The ONE parser of fleet.conf: one repo path per line, priority order.
    # A line whose first non-space char is `#` immediately followed by a path
    # is a PARKED repo — still listed, never run. `# note` (hash then space,
    # or hash then tab) is a comment and yields no entry. Blank lines yield
    # nothing. Classification ported from harbor loop/cycles.py and
    # control.py:_cycle_line_repo, which prove parked repos must stay visible
    # or the operator cannot see what they turned off.
    class Roster
      Entry = Struct.new(:path, :parked, :lineno, :raw, keyword_init: true)

      def initialize(path, fs: Sys::Fs.new)
        @path = path
        @fs = fs
      end

      # Missing/unreadable conf -> [], never a raise.
      def entries
        @entries ||= parse(@fs.read(@path).scrub)
      rescue StandardError
        []
      end

      def active
        entries.reject(&:parked)
      end

      private

      def parse(body)
        base = File.dirname(@path)
        body.split("\n", -1).each_with_index.filter_map do |raw, i|
          line = raw.strip
          next if line.empty?

          parked = line.start_with?("#")
          candidate = parked ? line[1..] : line
          # hash then space/tab -> a comment, not a parked repo
          next if candidate.start_with?(" ", "\t")
          candidate = candidate.strip
          next if candidate.empty? || candidate.start_with?("#")

          begin
            path = File.expand_path(candidate, base)
          rescue ArgumentError
            next
          end
          Entry.new(path: path, parked: parked, lineno: i + 1, raw: raw)
        end
      end
    end
  end
end
