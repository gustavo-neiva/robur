# frozen_string_literal: true

require "json"

module Robur
  # Turn-outcome detection. Classifies by CONTENT, not exit code: done > human > step > transport >
  # exhausted > hard > timeout > empty > transient. In json mode (pi --mode json), token matches
  # count only in assistant text_end events; error scans inspect only non-JSON and error-signalling
  # events, so tool results and prose discussing a rate limit cannot false-fire.
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

    TRANSPORT_RE = /provider_transport_failure|WebSocket idle timeout|socket hang up|ECONNRESET|ETIMEDOUT/i

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
        err_lines = events.select { |_, ev| error_signalling?(ev) }.map(&:first)
      else
        token = ->(t) { lines.any? { |l| l.include?(t) } }
        err_lines = lines
      end
      src = err_lines.join

      return :done       if token.call(done_token)
      return :human      if human_token && token.call(human_token)
      return :human_park if park_token && token.call(park_token)
      return :step       if token.call(step_token)
      return :transient if src.match?(TRANSPORT_RE)
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

    # Best-effort question text following the park token (the agent prints
    # HUMAN_PARK_TOKEN <question> per the base prompt). Empty string when the
    # token is not found.
    #
    # In json mode only ASSISTANT text counts, for the same reason classify
    # filters: the base prompt that TELLS the agent to print the token also
    # CONTAINS the token, and it is the FIRST line of the log. Matching any
    # raw line filed the entire prompt blob into the tracker as the
    # "question" (prod: 6 parked tasks, 6 leaked prompts, 6 lost questions).
    # The answer is extracted from the parsed event, so JSON escaping is
    # undone by the parser instead of by punctuation-stripping regex.
    #
    # Newest match wins (the park is the turn's last act), and only its FIRST
    # line survives -- the agent is told to put the question on its own line,
    # so a multi-line blob can never leak again even via the text-mode path.
    def self.park_question(path, park_token)
      return "" if park_token.to_s.empty? || !File.exist?(path)

      lines = File.read(path).lines
      events = parse_lines(lines)
      texts = if events.any? { |_, ev| ev }
                events.select { |_, ev| assistant_text?(ev) }.map { |line, ev| assistant_content(ev) || line }
              else
                lines
              end

      hit = texts.reverse.find { |t| t.include?(park_token) }
      return "" unless hit

      hit.split(park_token, 2).last.to_s.lines.first.to_s.strip.sub(/[\"}]+\z/, "")
    end

    # The assistant's own text out of either event shape.
    def self.assistant_content(ev)
      return nil unless ev.is_a?(Hash)

      ev["text"] || ev.dig("assistantMessageEvent", "content")
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

    # A nil event is a non-JSON line. JSON events are error-signalling only when
    # their top-level type or fields say so; nested tool payloads are data.
    def self.error_signalling?(ev)
      ev.nil? || (ev.is_a?(Hash) && (ev["type"] == "error" || ev.key?("diagnostics") || ev.key?("errorMessage")))
    end
  end
end
