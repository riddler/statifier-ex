#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/envelope"
require_relative "lib/cli"

# CommitMessage is pure validation over an already-drafted commit message -
# it never drafts or fixes one. Encodes /commit Step 2's three hard limits
# (subject under 50 characters, body lines at most 72, whole message at
# most 40 lines), the Refs: trailer shape, and the Step 4.4 attribution
# check, so the same rules run both pre-commit (over the drafted message)
# and post-commit (over `git log -1 --pretty=format:%B`). See
# docs/plans/260806-st-hzf-skill-mechanics-scripts.md Phase 12.
#
# There is no --fix flag and none will be added - drafting the message is a
# session-model (or Haiku-delegated, per docs/skill-automation.md's Model
# routing) job; this script only reports pass/fail per rule.
module CommitMessage
  SUBJECT_MAX = 49 # "under 50 characters"
  BODY_LINE_MAX = 72
  TOTAL_LINES_MAX = 40
  REFS_LINE_RE = /\ARefs: (\S+)\z/.freeze
  # Same substrings /commit Step 4.4 checks for - kept in exact sync so the
  # pre-commit draft check and the post-commit verification cannot drift.
  ATTRIBUTION_PATTERNS = ["Co-Authored-By", "Generated with", "Claude"].freeze

  class << self
    # Returns an array of {rule:, ok:, message:}, always in the same order.
    # `refs`, when given, is the bead id /commit Step 1.5 resolved - the
    # Refs: rule is only checked when a caller passes one, since /commit
    # only requires the trailer when a bead was actually resolved ("If no
    # issue, omit this line entirely" - Step 2). Callers with no bead (the
    # rare interactive fallback where the user skips the prompt) omit
    # `refs` and get no Refs check at all, rather than a forced failure.
    def check(text, refs: nil)
      lines = text.to_s.each_line.map { |l| l.chomp }
      checks = [
        subject_check(lines),
        body_line_check(lines),
        total_lines_check(lines)
      ]
      checks << refs_check(lines, refs) if refs
      checks << attribution_check(text)
      checks
    end

    private

    def subject_check(lines)
      subject = lines.first.to_s
      ok = !subject.empty? && subject.length <= SUBJECT_MAX
      { rule: "subject_length", ok: ok,
        message: "subject line is #{subject.length} characters (limit #{SUBJECT_MAX})" }
    end

    def body_line_check(lines)
      body = lines[1..-1] || []
      offenders = body.each_with_index.select { |line, _i| line.length > BODY_LINE_MAX }
      ok = offenders.empty?
      message =
        if ok
          "every body line is #{BODY_LINE_MAX} characters or fewer"
        else
          "line(s) over #{BODY_LINE_MAX} characters: #{offenders.map { |_line, i| i + 2 }.join(', ')}"
        end
      { rule: "body_line_length", ok: ok, message: message }
    end

    def total_lines_check(lines)
      ok = lines.length <= TOTAL_LINES_MAX
      { rule: "total_lines", ok: ok, message: "message is #{lines.length} lines (limit #{TOTAL_LINES_MAX})" }
    end

    def refs_check(lines, refs)
      non_blank = lines.reject { |l| l.strip.empty? }
      last = non_blank.last.to_s
      m = last.match(REFS_LINE_RE)
      ok = !m.nil? && m[1] == refs
      message = ok ? "\"Refs: #{refs}\" present and last" : "expected \"Refs: #{refs}\" as the last non-blank line, found #{last.inspect}"
      { rule: "refs_present_and_last", ok: ok, message: message }
    end

    def attribution_check(text)
      hit = ATTRIBUTION_PATTERNS.find { |p| text.to_s.include?(p) }
      ok = hit.nil?
      message = ok ? "no forbidden attribution text found" : "found forbidden attribution text: #{hit.inspect}"
      { rule: "no_attribution", ok: ok, message: message }
    end
  end
end

# The thin CLI: reads the message from stdin (never as an argument - commit
# messages are multi-line and shell-argument-hostile), runs
# CommitMessage.check, and reports each rule's pass/fail in the envelope.
# `check` is accepted as an optional leading subcommand for symmetry with
# the other scripts' subcommand style, and is also the default - there is
# only one thing this script does.
module CommitMessageCli
  class << self
    def run(argv, io: $stdout, stdin: $stdin)
      argv = argv.dup
      argv.shift if argv.first == "check"

      options = { dry_run: false }
      parser, options = Cli.build("commit_message.rb [check] [--refs ID] < message", options) do |opts|
        opts.on("--refs ID", "require \"Refs: ID\" present and last") { |v| options[:refs] = v }
      end
      Cli.parse!(parser, argv)

      text = stdin.read

      env = Envelope.new(script: "commit_message")
      results = CommitMessage.check(text, refs: options[:refs])

      env.data[:refs_required] = !options[:refs].nil?
      env.data[:checks] = results

      results.each do |r|
        env.block!(code: r[:rule], message: r[:message]) unless r[:ok]
      end

      env.emit(io)
    end
  end
end

exit CommitMessageCli.run(ARGV) if __FILE__ == $PROGRAM_NAME
