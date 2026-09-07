# frozen_string_literal: true

require "json"

module Robur
  # Turn-outcome detection. Classifies by CONTENT, not exit code: done > human > step > exhausted >
  # hard > timeout > empty > transient. In json mode (pi --mode json) token matches
  # count only in assistant text_end events and error scans exclude assistant
  # text/thinking events, else prose *discussing* a rate limit false-fires.
  module Classifier
    EXHAUSTED_RE = /
      (request\ failed:\ HTTP\ (429|503|529))
    |(auto_retry.{0,40}429)
    |(\\?"code\\?"\s*:\s*\\?"?130[2-8])
    |(rate_limit_error|overloaded_error)
    |(rate[ _-]?limit)
    |(quota)
    |(usage\ limit\ reached)
    |(draw\ from\ your\ extra\ usage)
    |(insufficient.{0,30}(balance|quota|credit))
    |(daily.{0,15}(limit|quota))
    |(too\ many\ requests)
    |(exceed(ed|s)?.{0,15}(quota|limit|balance|rate))
    /xi

    HARD_RE = /
      (request\ failed:\ HTTP\ (400|401|403|404|413|422))
    |(authentication_error|permission_error|not_found_error|invalid_request_error)
    |(invalid.{0,10}(api[ _-]?key|token))
    |(unauthorized)
    |(context.{0,20}(length|limit|size|window).{0,20}exceed)
    |(token.{0,20}limit.{0,20}exceed)
    |(maximum.{0,20}context)
    |(model.{0,20}(not.{0,10}(found|available|exist)|unavailable))
    |(request.{0,10}timeout)
    |(timed.{0,10}out)
    /xi

    ASSISTANT_PROSE = /\A(?:text|thinking)_(?:delta|end)\z/

    # Returns one of :done, :human, :human_park, :step, :exhausted, :hard,
    # :timeout, :empty, :transient.
    def self.classify(path, step_token:, done_token:, deadline:, json: false,
                      human_token: nil, park_token: nil)
      lines = File.exist?(path) ? File.read(path).lines : []
      events = json ? parse_lines(lines) : nil
      # All non-JSON plain text -> literal token matching (text-mode rules).
      events = nil if events && events.none? { |_, ev| ev }

      if events
        token = ->(t) { events.any? { |line, ev| assistant_text?(ev) && line.include?(t) } }
        err_lines = events.reject { |_, ev| ev && prose_event?(ev) }.map(&:first)
      else
        token = ->(t) { lines.any? { |l| l.include?(t) } }
        err_lines = lines
      end
      src = err_lines.join

      return :done       if token.call(done_token)
      return :human      if human_token && token.call(human_token)
      return :human_park if park_token && token.call(park_token)
      return :step       if token.call(step_token)
      return :exhausted if src.match?(EXHAUSTED_RE)
      return :hard      if src.match?(HARD_RE)
      return :timeout   if deadline
      return :empty     if empty_turn?(lines, events)

      :transient
    end

    # Exit 0 with no assistant output at all (prod root cause: 1,574 strikes
    # retrying nothing). Text mode -> every line blank (missing/zero-length
    # file included); json mode -> no assistant_text? event.
    def self.empty_turn?(lines, events)
      return events.none? { |_, ev| assistant_text?(ev) } if events

      lines.all? { |l| l.strip.empty? }
    end

    # Best-effort question text following the park token on whichever raw
    # line contains it (the agent prints HUMAN_PARK_TOKEN <question> per the
    # base prompt). Trailing JSON punctuation from a json-mode event blob is
    # trimmed too. Empty string when the token is not found.
    def self.park_question(path, park_token)
      return "" if park_token.to_s.empty? || !File.exist?(path)

      line = File.read(path).lines.find { |l| l.include?(park_token) }
      return "" unless line

      line.split(park_token, 2).last.to_s.strip.sub(/[\"}]+\z/, "")
    end

    def self.parse_lines(lines)
      lines.map do |line|
        ev = begin
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        [line, ev]
      end
    end

    # Any hash in the event tree whose "type" is exactly "text_end".
    def self.assistant_text?(ev)
      return false unless ev.is_a?(Hash)

      ev["type"] == "text_end" || ev.dig("assistantMessageEvent", "type") == "text_end"
    end

    def self.prose_event?(ev)
      t = ev["type"] || ev.dig("assistantMessageEvent", "type")
      t&.match?(ASSISTANT_PROSE)
    end
  end
end
