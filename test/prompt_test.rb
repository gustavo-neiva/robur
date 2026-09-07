# frozen_string_literal: true

require_relative "test_helper"
require "robur/prompt"
require "robur/plan"
require "tmpdir"

class PromptTest < Minitest::Test
  CONF = { "STEP_TOKEN" => "STEP_T", "DONE_TOKEN" => "DONE_T", "HUMAN_PARK_TOKEN" => "PARK_T" }.freeze
  BASE = "One step of the tracker task. If the task lacks repo-convention detail, read AGENTS.md first. Write " \
         "changes to files; never paste file contents in your reply. Never edit .robur.conf (or legacy " \
         ".ratchet.conf) or the AGENTS.md protocol markers — the loop reverts them. Step done: " \
         "change the task's `- [ ]` to `- [x]` in PLAN.md — the loop never does this for you, and an " \
         "unflipped box means the next turn is handed the same task again — then print STEP_T on " \
         "its own line. No work left at all: print DONE_T on its own line. " \
         "Need a fact only the human has (a number, a decision) to proceed: print PARK_T <one-line question> " \
         "on its own line and stop — never guess."

  def plan_with(content)
    dir = Dir.mktmpdir
    path = File.join(dir, "PLAN.md")
    File.write(path, content)
    Robur::Plan.new(path)
  end

  def test_base_prompt_substitutes_tokens_and_omits_task_section_when_done
    plan = plan_with("## Done\n- [x] T1 (trivial) old task\n")
    assert_equal BASE, Robur::Prompt.for_turn(conf: CONF, plan: plan)
  end

  def test_task_block_injected_when_present
    plan = plan_with(<<~PLAN)
      <!-- class: MACHINE -->

      ## Milestone 1

      - [IN PROGRESS] T1.1 (normal) do the thing
        do: first step
        accept: gate green
      ## Done
    PLAN
    header = "Task, quoted from PLAN.md — verify it is still the first open/IN PROGRESS task before starting:"
    prompt = Robur::Prompt.for_turn(conf: CONF, plan: plan)
    assert_equal [BASE, "#{header}\n- [IN PROGRESS] T1.1 (normal) do the thing\n  do: first step\n  accept: gate green"].join("\n"),
                 prompt
  end

  def test_task_block_truncated_at_40_lines
    block = (["- [ ] T1 (trivial) task"] + Array.new(40) { |i| "  body line #{i + 1}" }).join("\n")
    plan = plan_with("## M\n\n#{block}\n")
    prompt = Robur::Prompt.for_turn(conf: CONF, plan: plan)
    refute prompt.include?("body line 40")
    assert prompt.include?("body line 39\n    … (task block truncated at 40 lines)")
    assert_equal 39, prompt.scan(/body line /).size # 41-line block capped at 40 (task + 39 body) + marker
  end

  def test_one_line_fallback_when_no_block_but_next_task
    plan = Object.new
    plan.define_singleton_method(:task_block) { nil }
    plan.define_singleton_method(:next_task) do |kind|
      Robur::Task.parse("- [ ] T2.3 (normal, serial) wire the prompt", 3) if kind == :open
    end
    prompt = Robur::Prompt.for_turn(conf: CONF, plan: plan)
    assert_equal [BASE, "Current tracker task: T2.3 (normal, serial) wire the prompt\n" \
                        "(Verify it is still the first open/IN PROGRESS task in PLAN.md.)"].join("\n"),
                 prompt
  end

  def test_note_appended_when_present
    plan = plan_with("## Done\n- [x] T1 (trivial) done\n")
    Dir.mktmpdir do |log_dir|
      File.write(File.join(log_dir, "last_turn.note"), "Verify gate after last turn: RED (fix this first)\nLast turn: gate RED, left staged.\n\n")
      prompt = Robur::Prompt.for_turn(conf: CONF, plan: plan, log_dir: log_dir)
      assert prompt.end_with?("Verify gate after last turn: RED (fix this first)\nLast turn: gate RED, left staged.")
      refute prompt.include?("\n\n\n")
    end
  end

  def test_verify_tail_on_red_note
    plan = plan_with("## Done\n- [x] T1 (trivial) done\n")
    Dir.mktmpdir do |log_dir|
      File.write(File.join(log_dir, "last_turn.note"), "Verify gate after last turn: RED (fix this first)\nfix the gate\n")
      File.write(File.join(log_dir, "last_verify.out"), (1..35).map { |i| "fail line #{i}" }.join("\n"))
      prompt = Robur::Prompt.for_turn(conf: CONF, plan: plan, log_dir: log_dir)
      assert prompt.include?("Last verify output (tail):\n```\nfail line 6\n")
      assert prompt.end_with?("fail line 35\n```")
      refute prompt.include?("fail line 5")
    end
  end

  def test_verify_tail_absent_on_green_note
    plan = plan_with("## Done\n- [x] T1 (trivial) done\n")
    Dir.mktmpdir do |log_dir|
      File.write(File.join(log_dir, "last_turn.note"), "Verify gate after last turn: GREEN\nLast turn changed: lib/a.rb\n")
      File.write(File.join(log_dir, "last_verify.out"), "still passing\n")
      refute Robur::Prompt.for_turn(conf: CONF, plan: plan, log_dir: log_dir).include?("Last verify output")
    end
  end

  def test_red_note_without_verify_out_omits_tail
    plan = plan_with("## Done\n- [x] T1 (trivial) done\n")
    Dir.mktmpdir do |log_dir|
      File.write(File.join(log_dir, "last_turn.note"), "Verify gate after last turn: RED (fix this first)\nfix it\n")
      refute Robur::Prompt.for_turn(conf: CONF, plan: plan, log_dir: log_dir).include?("Last verify output")
    end
  end

  def test_invalid_utf8_in_verify_out_does_not_raise
    plan = plan_with("## Done\n- [x] T1 (trivial) done\n")
    Dir.mktmpdir do |log_dir|
      File.write(File.join(log_dir, "last_turn.note"), "Verify gate after last turn: RED (fix this first)\nfix it\n")
      File.binwrite(File.join(log_dir, "last_verify.out"), "ok \xFF\xFE bad bytes\n1 failure\n")
      prompt = Robur::Prompt.for_turn(conf: CONF, plan: plan, log_dir: log_dir)
      assert prompt.include?("bad bytes\n1 failure")
      assert prompt.valid_encoding?
    end
  end
end
