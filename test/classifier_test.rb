# frozen_string_literal: true

require_relative "test_helper"
require "robur/classifier"

module Robur
  class ClassifierTest < Minitest::Test
    STEP = "STEP_COMPLETE"
    DONE = "ALL_DONE"
    HUMAN = "HUMAN_BLOCKED"

    def classify(str, json: false, deadline: false, human_token: HUMAN)
      f = File.join(Dir.mktmpdir, "turn.out")
      File.write(f, str)
      Classifier.classify(f, step_token: STEP, done_token: DONE,
                          deadline: deadline, json: json, human_token: human_token).to_s
    end

    # Suite-1 parity with bash classify_turn (text mode).
    def test_suite1_text_cases
      cases = {
        "step" => "did the thing\n#{STEP}",
        "done" => DONE,
        "exhausted" => 'Anthropic request failed: HTTP 429 {"type":"error","error":{"type":"rate_limit_error"}}',
        "exhausted2" => 'Anthropic request failed: HTTP 529 {"error":{"type":"overloaded_error"}}',
        "exhausted3" => 'request failed: HTTP 429 {"error":{"code":"1304","message":"daily call limit reached"}}',
        "exhausted4" => 'request failed: HTTP 403 {"error":{"code":"1308","message":"quota insufficient balance"}}',
        "hard" => 'Anthropic request failed: HTTP 404 {"error":{"type":"not_found_error"}}',
        "hard2" => 'request failed: HTTP 401 {"error":{"type":"authentication_error"}}',
        "hard3" => 'HTTP 400 {"error":{"type":"invalid_request_error","message":"Invalid signature in thinking block"}}',
        "transient" => "fetch failed: ECONNRESET",
        "transient2" => "I am still thinking about the problem.",
        "human" => "thinking...\n#{HUMAN}",
        "done_wins" => "need help\n#{HUMAN}\n#{DONE}",
        "hard4" => "Error: context length exceeded maximum of 200000 tokens",
        "hard5" => 'request failed: HTTP 400 {"error":{"message":"token limit exceeded"}}',
        "hard6" => "Error: model not found or unavailable",
        "hard7" => "request timeout after 30s"
      }
      cases.each do |name, str|
        exp = name.sub(/\d+\z/, "").sub("done_wins", "done")
        assert_equal exp, classify(str), name
      end
    end

    def test_json_prose_quota_not_exhausted
      str = %({"type":"text_delta","delta":"Next I will add dependency-scanning; note the daily quota / rate limit handling."}\n) +
            %({"type":"text_end","text":"done with #{STEP}"})
      assert_equal "step", classify(str, json: true)
    end

    def test_json_real_429_still_exhausted
      str = %({"type":"text_delta","delta":"working on it"}\n) +
            %({"type":"error","error":{"type":"rate_limit_error"}} request failed: HTTP 429)
      assert_equal "exhausted", classify(str, json: true)
    end

    def test_json_human_token
      assert_equal "human", classify(%({"type":"text_end","text":"#{HUMAN}"}), json: true)
      # Token in the echoed user prompt does NOT count (text_end keeps the
      # stream non-empty; a text_end-less stream is now :empty).
      str = %({"type":"message","message":{"content":[{"type":"text","text":"#{HUMAN} is the token"}]}}\n) +
            %({"type":"text_end","text":"working on it"})
      assert_equal "transient", classify(str, json: true)
    end

    def test_deadline_timeout
      assert_equal "timeout", classify("agent still working, no token", deadline: true)
    end

    def test_non_json_plain_text_falls_back_to_literal_matching
      assert_equal "step", classify("all finished here\n#{STEP}", json: true)
    end

    def test_empty_text_mode
      ["", "\n\n \n"].each do |str|
        assert_equal "empty", classify(str), str.inspect
        assert_equal "empty", classify(str, json: true), str.inspect
      end
    end

    def test_empty_missing_file
      assert_equal "empty", Classifier.classify(File.join(Dir.mktmpdir, "nope.out"),
                                                step_token: STEP, done_token: DONE,
                                                deadline: false).to_s
    end

    def test_empty_json_no_assistant_text
      str = %({"type":"text_delta","delta":"working"}\n) +
            %({"type":"text_delta","delta":" more"}\n) +
            %({"type":"error","error":{"type":"api_error"}})
      assert_equal "empty", classify(str, json: true)
    end

    def test_empty_does_not_shadow_earlier_returns
      assert_equal "transient", classify(%({"type":"text_end","text":"still working on it"}), json: true)
      assert_equal "exhausted", classify("429 rate limit")
      assert_equal "timeout", classify("", deadline: true)
    end
  end
end
