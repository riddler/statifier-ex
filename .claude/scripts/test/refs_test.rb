# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/refs"

class RefsTest < Minitest::Test
  # The real body of 146c69f, reachable in this repo's own history
  # (`git show 146c69f --format=%B -s`) - captured here verbatim, not
  # paraphrased.
  #
  # Note: 146c69f predates the st2- -> st- bead-id rename (commit
  # 36c4b9d), so the ids it names read "st2-00p.1" and "st2-gnr" rather
  # than the "st-00p.1"/"st-gnr" the plan text describes post-rename.
  # Either way it carries no `Refs:` line at all, so it must still yield
  # [] - but since "st2-..." doesn't even contain the literal "st-"
  # substring BEAD_ID requires, this fixture alone doesn't exercise the
  # anchor-vs-prose distinction as strongly as a post-rename body would.
  # test_anchor_ignores_bead_ids_named_in_prose below covers that case
  # directly with a synthetic body using current-shaped ids.
  FIXTURE_146C69F = <<~MSG.freeze
    Updates beads interaction log

    Records the status changes from closing st2-00p.1 and st2-gnr
    after PR #2 and PR #3 merged. The Dolt DB is the source of truth
    and is already pushed; this file is a passive export catching up.
  MSG

  def test_146c69f_fixture_yields_no_beads
    assert_equal [], Refs.beads_from_messages([FIXTURE_146C69F])
  end

  def test_anchor_ignores_bead_ids_named_in_prose
    body = <<~MSG
      Fixes the exit-set ordering bug.

      Related to st-abc and discussed in st-def, but this commit does not
      close either of them.
    MSG

    assert_equal [], Refs.beads_from_messages([body])
  end

  def test_extracts_from_refs_trailer_line
    body = <<~MSG
      Adds retry backoff to the send queue.

      Refs: st-abc
    MSG

    assert_equal ["st-abc"], Refs.beads_from_messages([body])
  end

  def test_multiple_ids_on_one_trailer_line_uniq_and_sorted
    body = "Body text\n\nRefs: st-def st-abc st-abc\n"

    assert_equal %w[st-abc st-def], Refs.beads_from_messages([body])
  end

  def test_dotted_bead_id
    body = "Body\n\nRefs: st-00p.3\n"

    assert_equal ["st-00p.3"], Refs.beads_from_messages([body])
  end

  def test_multiple_messages_uniq_and_sort_across_all
    a = "x\n\nRefs: st-b\n"
    b = "y\n\nRefs: st-a\n"

    assert_equal %w[st-a st-b], Refs.beads_from_messages([a, b])
  end

  def test_indented_refs_line_is_not_matched
    body = "Body\n\n  Refs: st-abc\n"

    assert_equal [], Refs.beads_from_messages([body])
  end

  def test_nil_and_empty_messages_are_safe
    assert_equal [], Refs.beads_from_messages([nil, "", "no refs here\n"])
    assert_equal [], Refs.beads_from_messages(nil)
  end

  def test_trailer_line_single_id
    assert_equal "Refs: st-abc", Refs.trailer_line(["st-abc"])
  end

  def test_trailer_line_multiple_ids
    assert_equal "Refs: st-abc st-def", Refs.trailer_line(%w[st-abc st-def])
  end
end
