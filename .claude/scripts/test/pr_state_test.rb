# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../pr_state"
require_relative "support/fake_sh"

class PrStateTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
  end

  def run_pr_state(argv)
    io = StringIO.new
    code = PrState.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def test_merged_branch_reports_merged_true_with_pr_fields
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "st-abc-x",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: %({"number":41,"mergedAt":"2026-08-01T00:00:00Z","headRefOid":"deadbeef"}\n)
    )

    code, env = run_pr_state(["st-abc-x"])

    assert_equal 0, code
    assert_equal true, env["ok"]
    assert_equal true, env["data"]["merged"]
    assert_equal 41, env["data"]["number"]
    assert_equal "deadbeef", env["data"]["head_oid"]
    assert_equal "2026-08-01T00:00:00Z", env["data"]["merged_at"]
  end

  def test_unmerged_branch_reports_merged_false
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "st-abc-x",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )

    code, env = run_pr_state(["st-abc-x"])

    assert_equal 0, code
    assert_equal false, env["data"]["merged"]
    refute env["data"].key?("number")
  end

  def test_gh_failure_blocks_needs_human_never_falls_back_to_ancestry
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "st-abc-x",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      exitstatus: 1, err: "gh: authentication required\n"
    )

    code, env = run_pr_state(["st-abc-x"])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "gh_unavailable", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
    # No merge-base/ancestry call was ever attempted: FakeSh would have
    # raised UnexpectedCommand had the script tried one as a fallback.
  end

  def test_beads_subcommand_extracts_via_refs_anchor
    @fake.expect(
      ["gh", "pr", "view", "41", "--json", "commits", "--jq", ".commits[].messageBody"],
      out: "Adds thing.\n\nRefs: st-abc\n" \
           "Fixes other thing, related to st-zzz but no trailer here.\n"
    )

    code, env = run_pr_state(%w[beads 41])

    assert_equal 0, code
    assert_equal ["st-abc"], env["data"]["beads"]
  end

  def test_beads_subcommand_gh_failure_blocks_needs_human
    @fake.expect(
      ["gh", "pr", "view", "41", "--json", "commits", "--jq", ".commits[].messageBody"],
      exitstatus: 1, err: "gh: not found\n"
    )

    code, env = run_pr_state(%w[beads 41])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "gh_unavailable", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
  end
end
