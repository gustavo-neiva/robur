# frozen_string_literal: true

require_relative "paths"

module Robur
  # Per-turn prompt builder: the base do-one-step instruction, the current
  # task quoted from the tracker, the previous turn's gate note, and — when
  # that note is RED — the tail of the failing verify output.
  class Prompt
    BLOCK_CAP = 40
    TAIL_LINES = 30

    def self.for_turn(conf:, plan:, log_dir: nil)
      sections = [base(conf)]
      sections << task_section(conf, plan)
      note = note_text(log_dir)
      sections << note if note
      sections << verify_tail(log_dir) if note&.lines&.first.to_s.include?("RED")
      sections.compact.join("\n")
    end

    def self.base(conf)
      "One step of the tracker task. If the task lacks repo-convention detail, read AGENTS.md first. Write " \
        "changes to files; never paste file contents in your reply. Never edit #{Paths::REPO_CONF} (or legacy " \
        "#{Paths::LEGACY_REPO_CONF}) or the AGENTS.md protocol markers — the loop reverts them. Step done: " \
        "change the task's `- [ ]` to `- [x]` in #{conf['TRACKER_FILE'] || 'PLAN.md'} — the loop never does this " \
        "for you, and an unflipped box means the next turn is handed the same task again — then " \
        "print #{conf['STEP_TOKEN']} on its own line. No work left at all: print #{conf['DONE_TOKEN']} on its own line."
    end

    def self.task_section(conf, plan)
      tracker = conf["TRACKER_FILE"] || "PLAN.md"
      block = plan.task_block
      if block && !block.empty?
        "Task, quoted from #{tracker} — verify it is still the first open/IN PROGRESS task before starting:\n#{cap(block)}"
      elsif (task = plan.next_task(:in_progress) || plan.next_task(:open))
        "Current tracker task: #{task.id} (#{task.tags.join(', ')}) #{task.text}\n" \
        "(Verify it is still the first open/IN PROGRESS task in #{tracker}.)"
      end
    end

    def self.cap(block)
      lines = block.lines
      return block if lines.size <= BLOCK_CAP

      "#{lines.first(BLOCK_CAP).join.chomp}\n    … (task block truncated at #{BLOCK_CAP} lines)"
    end

    def self.note_text(log_dir)
      return nil unless log_dir

      text = read_scrubbed(File.join(log_dir, "last_turn.note")).to_s.rstrip
      text unless text.empty?
    end

    def self.verify_tail(log_dir)
      out = read_scrubbed(File.join(log_dir, "last_verify.out")).to_s
      return nil if out.empty?

      "Last verify output (tail):\n```\n#{out.lines.map(&:chomp).last(TAIL_LINES).join("\n")}\n```"
    end

    # Production logs contain invalid UTF-8 bytes; a missing or unreadable
    # file is an absent section, never a raise.
    def self.read_scrubbed(path)
      File.read(path, mode: "rb").force_encoding("UTF-8").scrub
    rescue StandardError
      nil
    end
  end
end
