# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../commit_message"

# CommitMessage.check (pure function).
class CommitMessageLibTest < Minitest::Test
  def test_a_clean_message_with_no_refs_required_passes_every_rule
    message = <<~MSG
      Adds exit set computation for parallel states

      - Ports compute_exit_set and get_transition_domain per Appendix D
      - Handles cross-boundary exits out of parallel regions
    MSG

    checks = CommitMessage.check(message)

    assert checks.all? { |c| c[:ok] }, checks.inspect
    refute_includes checks.map { |c| c[:rule] }, "refs_present_and_last"
  end

  def test_subject_over_49_characters_fails
    subject = "A" * 50
    checks = CommitMessage.check(subject)

    refute check_for(checks, "subject_length")[:ok]
  end

  def test_subject_at_49_characters_passes
    subject = "A" * 49
    checks = CommitMessage.check(subject)

    assert check_for(checks, "subject_length")[:ok]
  end

  def test_empty_subject_fails
    checks = CommitMessage.check("\n\nbody\n")

    refute check_for(checks, "subject_length")[:ok]
  end

  def test_a_body_line_over_72_characters_fails
    message = "Adds a thing\n\n#{'x' * 73}\n"
    checks = CommitMessage.check(message)

    refute check_for(checks, "body_line_length")[:ok]
  end

  def test_a_body_line_at_72_characters_passes
    message = "Adds a thing\n\n#{'x' * 72}\n"
    checks = CommitMessage.check(message)

    assert check_for(checks, "body_line_length")[:ok]
  end

  def test_a_message_with_more_than_40_lines_fails
    message = "Adds a thing\n" + (["- line"] * 40).join("\n")
    checks = CommitMessage.check(message)

    refute check_for(checks, "total_lines")[:ok]
  end

  def test_a_message_with_40_lines_or_fewer_passes
    message = "Adds a thing\n" + (["- line"] * 10).join("\n")
    checks = CommitMessage.check(message)

    assert check_for(checks, "total_lines")[:ok]
  end

  def test_refs_check_is_absent_when_no_refs_id_is_given
    checks = CommitMessage.check("Adds a thing\n")

    assert_nil check_for(checks, "refs_present_and_last")
  end

  def test_refs_present_and_last_passes_when_it_matches_and_is_the_last_non_blank_line
    message = <<~MSG
      Adds a thing

      - detail

      Refs: st-abc
    MSG

    checks = CommitMessage.check(message, refs: "st-abc")

    assert check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_refs_missing_entirely_fails
    checks = CommitMessage.check("Adds a thing\n\n- detail\n", refs: "st-abc")

    refute check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_refs_present_but_not_last_fails
    message = <<~MSG
      Adds a thing

      Refs: st-abc

      - detail added after the trailer
    MSG

    checks = CommitMessage.check(message, refs: "st-abc")

    refute check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_refs_present_but_wrong_id_fails
    checks = CommitMessage.check("Adds a thing\n\nRefs: st-other\n", refs: "st-abc")

    refute check_for(checks, "refs_present_and_last")[:ok]
  end

  def test_co_authored_by_is_detected
    checks = CommitMessage.check("Adds a thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n")

    refute check_for(checks, "no_attribution")[:ok]
  end

  def test_generated_with_is_detected
    checks = CommitMessage.check("Adds a thing\n\nGenerated with Claude Code\n")

    refute check_for(checks, "no_attribution")[:ok]
  end

  def test_bare_claude_mention_is_detected
    checks = CommitMessage.check("Adds a thing\n\nWritten by Claude\n")

    refute check_for(checks, "no_attribution")[:ok]
  end

  def test_no_attribution_passes_a_clean_message
    checks = CommitMessage.check("Adds a thing\n\n- detail\n")

    assert check_for(checks, "no_attribution")[:ok]
  end

  private

  def check_for(checks, rule)
    checks.find { |c| c[:rule] == rule }
  end
end

# CommitMessageCli (the stdin-reading, envelope-emitting shell).
class CommitMessageCliTest < Minitest::Test
  def run_check(argv, message)
    io = StringIO.new
    stdin = StringIO.new(message)
    code = CommitMessageCli.run(argv, io: io, stdin: stdin)
    [code, JSON.parse(io.string)]
  end

  def test_a_clean_message_exits_0_and_reports_ok_true
    code, result = run_check([], "Adds a thing\n\n- detail\n")

    assert_equal 0, code
    assert result["ok"]
  end

  def test_check_subcommand_is_accepted_and_behaves_identically
    code, result = run_check(["check"], "Adds a thing\n\n- detail\n")

    assert_equal 0, code
    assert result["ok"]
  end

  # The Success Criteria fixture from the plan: a 52-char subject, an
  # 80-char body line, 41 lines, a missing Refs:, and a Co-Authored-By
  # line - every rule should fail at once.
  def test_kitchen_sink_bad_message_is_rejected_with_every_rule_named
    subject = "A" * 52
    long_line = "x" * 80
    body_lines = (["- detail"] * 37) # subject + blank + long_line + 37 details + attribution line = 41
    message = ([subject, "", long_line] + body_lines + ["Co-Authored-By: Claude <noreply@anthropic.com>"]).join("\n") + "\n"

    code, result = run_check(["--refs", "st-abc"], message)

    assert_equal 1, code
    refute result["ok"]

    failing_rules = result["data"]["checks"].reject { |c| c["ok"] }.map { |c| c["rule"] }
    assert_includes failing_rules, "subject_length"
    assert_includes failing_rules, "body_line_length"
    assert_includes failing_rules, "total_lines"
    assert_includes failing_rules, "refs_present_and_last"
    assert_includes failing_rules, "no_attribution"

    blocked_codes = result["blocked"].map { |b| b["code"] }
    assert_includes blocked_codes, "no_attribution"
  end

  def test_refs_not_required_when_the_flag_is_omitted_even_if_absent
    code, result = run_check([], "Adds a thing\n\n- detail\n")

    assert_equal 0, code
    refute result["data"]["checks"].any? { |c| c["rule"] == "refs_present_and_last" }
    refute result["data"]["refs_required"]
  end

  def test_commands_stays_empty_this_script_never_shells_out
    _code, result = run_check([], "Adds a thing\n")

    assert_equal [], result["commands"]
  end
end
