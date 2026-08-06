# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../worktree_survey"
require_relative "support/fake_sh"

class WorktreeSurveyTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
  end

  def run_survey(argv = [])
    io = StringIO.new
    code = WorktreeSurvey.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def test_survey_drops_main_decomposes_dotted_id_and_marks_stale_holds_no_areas
    porcelain = <<~TXT
      worktree /Users/johnnyt/repos/github/statifier-ex
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-exit-sets
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/st-abc-exit-sets

      worktree /Users/johnnyt/repos/github/statifier-ex-worktrees/st-00p.3-fix-thing
      HEAD cccccccccccccccccccccccccccccccccccccccc
      branch refs/heads/st-00p.3-fix-thing
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)

    # st-abc-exit-sets: clean, ahead of origin/main, merged (stale).
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show st-abc --json], out: '[{"id":"st-abc","labels":["area:interpreter"]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "st-abc-exit-sets",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: %({"number":9,"mergedAt":"2026-08-01T00:00:00Z","headRefOid":"deadbeef"}\n)
    )

    # st-00p.3-fix-thing: dirty, not merged, dotted bead id.
    @fake.expect(%w[git status --porcelain], out: " M lib/foo.ex\n")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 1)
    @fake.expect(%w[bd show st-00p.3 --json], out: '[{"id":"st-00p.3","labels":["area:parser"]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "st-00p.3-fix-thing",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: "null\n"
    )

    code, env = run_survey

    assert_equal 0, code
    data = env["data"]
    assert_equal "/Users/johnnyt/repos/github/statifier-ex", data["main_checkout"]
    assert_equal 2, data["worktrees"].length

    wt1 = data["worktrees"].find { |w| w["bead"] == "st-abc" }
    assert_equal true, wt1["stale"]
    assert_equal ["area:interpreter"], wt1["areas"]
    assert_equal [], wt1["holds_areas"]
    assert_equal "MERGED", wt1["pr"]["state"]

    wt2 = data["worktrees"].find { |w| w["bead"] == "st-00p.3" }
    assert_equal false, wt2["stale"]
    assert_equal ["area:parser"], wt2["areas"]
    assert_equal ["area:parser"], wt2["holds_areas"]
    assert_equal true, wt2["dirty"]
    assert_nil wt2["pr"]

    assert_equal true, data["gh_available"]
    assert_equal [], data["degraded"]
  end

  def test_gh_unavailable_degrades_once_not_per_worktree
    porcelain = <<~TXT
      worktree /Users/johnnyt/repos/github/statifier-ex
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-exit-sets
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/st-abc-exit-sets

      worktree /Users/johnnyt/repos/github/statifier-ex-worktrees/st-def-other
      HEAD cccccccccccccccccccccccccccccccccccccccc
      branch refs/heads/st-def-other
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show st-abc --json], out: '[{"id":"st-abc","labels":["area:interpreter"]}]')
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", "st-abc-exit-sets",
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      exitstatus: 1, err: "gh: authentication required\n"
    )

    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: 0)
    @fake.expect(%w[bd show st-def --json], out: '[{"id":"st-def","labels":["area:parser"]}]')
    # No second "gh pr list" expectation is registered - if the script
    # queried gh again after it went unavailable, FakeSh would raise
    # UnexpectedCommand and fail this test.

    code, env = run_survey

    assert_equal 0, code
    data = env["data"]
    assert_equal false, data["gh_available"]
    assert_equal 1, env["warnings"].length
    assert_equal "gh_unavailable", env["warnings"].first["code"]
    assert_equal(
      %w[
        /Users/johnnyt/repos/github/statifier-ex-worktrees/st-abc-exit-sets
        /Users/johnnyt/repos/github/statifier-ex-worktrees/st-def-other
      ],
      data["degraded"]
    )

    wt2 = data["worktrees"].find { |w| w["bead"] == "st-def" }
    assert_equal false, wt2["stale"]
    assert_equal ["area:parser"], wt2["holds_areas"]
  end

  def test_git_worktree_list_failure_blocks
    @fake.expect(%w[git worktree list --porcelain], exitstatus: 1, err: "fatal: not a git repository\n")

    code, env = run_survey

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "git_worktree_list_failed", env["blocked"].first["code"]
  end
end
