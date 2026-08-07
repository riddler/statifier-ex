# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require_relative "../select_batch"
require_relative "support/fake_sh"

class SelectBatchTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
  end

  def run_select(argv = [])
    io = StringIO.new
    code = SelectBatch.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # No other worktrees: survey is one call and nothing else.
  def expect_empty_survey
    @fake.expect(
      %w[git worktree list --porcelain],
      out: "worktree /Users/johnnyt/repos/github/statifier-ex\nHEAD aaaa\nbranch refs/heads/main\n"
    )
  end

  # One other worktree, for a branch/bead/areas/merged combination the
  # caller supplies.
  def expect_survey_with_worktree(branch:, bead_id:, labels:, merged:)
    porcelain = <<~TXT
      worktree /Users/johnnyt/repos/github/statifier-ex
      HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      branch refs/heads/main

      worktree /Users/johnnyt/repos/github/statifier-ex-worktrees/#{branch}
      HEAD bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      branch refs/heads/#{branch}
    TXT

    @fake.expect(%w[git worktree list --porcelain], out: porcelain)
    @fake.expect(%w[git status --porcelain], out: "")
    @fake.expect(%w[git merge-base --is-ancestor origin/main HEAD], exitstatus: merged ? 0 : 1)
    @fake.expect(["bd", "show", bead_id, "--json"], out: JSON.generate([{ "id" => bead_id, "labels" => labels }]))

    merged_json = merged ? %({"number":9,"mergedAt":"2026-08-05T00:00:00Z","headRefOid":"deadbeef"}\n) : "null\n"
    @fake.expect(
      ["gh", "pr", "list", "--state", "merged", "--head", branch,
       "--json", "number,mergedAt,headRefOid", "--jq", ".[0]"],
      out: merged_json
    )
  end

  def expect_ready(issues, filters: [])
    @fake.expect(["bd", "ready", "--json"] + filters, out: JSON.generate(issues))
  end

  def issue(id, priority:, labels:, issue_type: "chore", description: "Description for #{id}.")
    { "id" => id, "title" => "title for #{id}", "priority" => priority, "issue_type" => issue_type, "labels" => labels,
      "description" => description }
  end

  # --- verdict table cases -------------------------------------------------

  def test_area_build_takes_the_batch_alone
    expect_ready([
                   issue("st-bld", priority: 1, labels: ["area:build"]),
                   issue("st-int", priority: 2, labels: ["area:interpreter"])
                 ])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    assert_equal ["st-bld"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "st-int" }
    assert_match(/area:build lands alone/, skipped["reason"])
  end

  def test_unlabeled_skipped_with_reason_string
    expect_ready([issue("st-nol", priority: 1, labels: [])])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    assert_equal [], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "st-nol" }
    assert_equal "unlabeled - blast radius undecided", skipped["reason"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "st-nol" }
    assert_equal "unlabeled", candidate["verdict"]
  end

  def test_upstream_beads_collide_with_nothing
    expect_ready([
                   issue("st-up1", priority: 1, labels: ["upstream"]),
                   issue("st-up2", priority: 2, labels: ["upstream"])
                 ])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    assert_equal %w[st-up1 st-up2], env["data"]["recommended"]
    env["data"]["candidates"].each { |c| assert_equal "free", c["verdict"] }
  end

  def test_stale_worktree_areas_do_not_block
    expect_ready([issue("st-new", priority: 1, labels: ["area:interpreter"])])
    expect_survey_with_worktree(branch: "st-old-thing", bead_id: "st-old", labels: ["area:interpreter"], merged: true)

    _code, env = run_select(["--auto"])

    assert_equal ["st-new"], env["data"]["recommended"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "st-new" }
    assert_equal "free", candidate["verdict"]
  end

  # Regression fixture for the failure mode observed live 2026-08-05: a
  # merged-but-not-removed worktree for st-o9a caused st-d9g to be reported
  # as colliding with work that had already landed on main minutes earlier
  # (.claude/skills/next-issues/SKILL.md:150-157, worktree_survey.rb's
  # holds_areas comment).
  def test_2026_08_05_phantom_collision_regression
    expect_ready([issue("st-d9g", priority: 1, labels: ["area:corpus"])])
    expect_survey_with_worktree(branch: "st-o9a-corpus-thing", bead_id: "st-o9a", labels: ["area:corpus"], merged: true)

    _code, env = run_select(["--auto"])

    assert_equal ["st-d9g"], env["data"]["recommended"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "st-d9g" }
    refute_equal "collides-with-live-worktree", candidate["verdict"]
    assert_equal "free", candidate["verdict"]
  end

  def test_collides_with_live_non_stale_worktree_is_named_and_skipped_in_auto_mode
    expect_ready([issue("st-new", priority: 1, labels: ["area:skills"])])
    expect_survey_with_worktree(branch: "st-hzf-skill-mechanics-scripts", bead_id: "st-hzf", labels: ["area:skills"], merged: false)

    _code, env = run_select(["--auto"])

    assert_equal [], env["data"]["recommended"]
    candidate = env["data"]["candidates"].find { |c| c["id"] == "st-new" }
    assert_equal "collides-with-live-worktree", candidate["verdict"]
    assert_match(/area:skills/, candidate["reason"])
    skipped = env["data"]["skipped"].find { |s| s["id"] == "st-new" }
    refute_nil skipped
  end

  def test_dependency_edge_not_batched_across_epic_row_absorbs_it
    expect_ready([
                   issue("st-epic", priority: 1, labels: ["area:corpus"], issue_type: "epic"),
                   issue("st-child", priority: 2, labels: ["area:corpus"])
                 ])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    assert_equal ["st-child"], env["data"]["recommended"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "st-epic" }
    assert_equal "epic - work its children", skipped["reason"]
  end

  # --- ceiling ---------------------------------------------------------------

  def test_n_greater_than_4_blocks_never_clamps
    _code, env = run_select(["--n", "5", "--auto"])

    assert_equal false, env["ok"]
    assert_equal "n_too_large", env["blocked"].first["code"]
    refute_equal [4], env["data"]["recommended"] # never silently substitutes 4 and proceeds
    assert_nil env["data"]["recommended"]
  end

  def test_ceiling_hit_false_when_the_pool_ran_out
    expect_ready([
                   issue("st-a", priority: 1, labels: ["area:interpreter"]),
                   issue("st-b", priority: 2, labels: ["area:parser"])
                 ])
    expect_empty_survey

    _code, env = run_select(["--n", "3", "--auto"])

    assert_equal %w[st-a st-b], env["data"]["recommended"]
    assert_equal false, env["data"]["ceiling_hit"]
  end

  def test_ceiling_hit_true_when_batch_full_before_pool_exhausted
    expect_ready([
                   issue("st-a", priority: 1, labels: ["area:interpreter"]),
                   issue("st-b", priority: 2, labels: ["area:parser"]),
                   issue("st-c", priority: 3, labels: ["area:datamodel"])
                 ])
    expect_empty_survey

    _code, env = run_select(["--n", "2", "--auto"])

    assert_equal %w[st-a st-b], env["data"]["recommended"]
    assert_equal true, env["data"]["ceiling_hit"]
    skipped = env["data"]["skipped"].find { |s| s["id"] == "st-c" }
    assert_match(/ceiling/, skipped["reason"])
  end

  # --- mode: manual vs auto ---------------------------------------------------

  def test_manual_mode_sets_requires_user_choice_and_offers_override
    expect_ready([issue("st-new", priority: 1, labels: ["area:skills"])])
    expect_survey_with_worktree(branch: "st-hzf-skill-mechanics-scripts", bead_id: "st-hzf", labels: ["area:skills"], merged: false)

    _code, env = run_select([])

    assert_equal "manual", env["data"]["mode"]
    assert_equal true, env["data"]["requires_user_choice"]
    override = env["data"]["alternatives"].find { |a| a["type"] == "override" && a["id"] == "st-new" }
    refute_nil override
  end

  def test_auto_mode_has_no_requires_user_choice_and_no_override_alternative
    expect_ready([issue("st-new", priority: 1, labels: ["area:skills"])])
    expect_survey_with_worktree(branch: "st-hzf-skill-mechanics-scripts", bead_id: "st-hzf", labels: ["area:skills"], merged: false)

    _code, env = run_select(["--auto"])

    assert_equal "auto", env["data"]["mode"]
    refute env["data"].key?("requires_user_choice")
    assert_equal [], env["data"]["alternatives"]
  end

  # --- filter-sanity check -----------------------------------------------------

  def test_label_filter_that_changed_nothing_blocks_rather_than_silently_proceeding
    same_set = [issue("st-a", priority: 1, labels: ["area:interpreter"])]
    expect_ready(same_set, filters: ["-l", "area:skills"])
    expect_ready(same_set)

    _code, env = run_select(["-l", "area:skills"])

    assert_equal false, env["ok"]
    assert_equal "unverified_filter", env["blocked"].first["code"]
  end

  def test_label_filter_that_actually_filtered_proceeds_normally
    expect_ready([issue("st-a", priority: 1, labels: ["area:skills"])], filters: ["-l", "area:skills"])
    expect_ready([
                   issue("st-a", priority: 1, labels: ["area:skills"]),
                   issue("st-b", priority: 2, labels: ["area:interpreter"])
                 ])
    expect_empty_survey

    _code, env = run_select(["-l", "area:skills", "--auto"])

    assert_equal true, env["ok"]
    assert_equal ["st-a"], env["data"]["recommended"]
  end

  # --- ambiguous input ---------------------------------------------------------

  def test_mixing_explicit_ids_and_filters_is_refused
    _code, env = run_select(["st-abc", "-l", "area:skills"])

    assert_equal false, env["ok"]
    assert_equal "ambiguous_input", env["blocked"].first["code"]
  end

  # --- summary field (st-sdv) ---------------------------------------------

  # sabotage: dropped `summary: Summary.of(issue["description"])` from
  # annotate/2's returned hash -> red, candidate carries no "summary" key
  def test_every_candidate_carries_a_summary_derived_from_the_description_in_default_mode
    expect_ready([
                   issue("st-a", priority: 1, labels: ["area:interpreter"],
                                 description: "Fixes the interpreter's idle path. More detail follows."),
                   issue("st-b", priority: 2, labels: ["area:parser"],
                                 description: "Extends the parser's guard clause. More detail follows.")
                 ])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    env["data"]["candidates"].each { |c| assert c.key?("summary") }
    a = env["data"]["candidates"].find { |c| c["id"] == "st-a" }
    b = env["data"]["candidates"].find { |c| c["id"] == "st-b" }
    assert_equal "Fixes the interpreter's idle path.", a["summary"]
    assert_equal "Extends the parser's guard clause.", b["summary"]
  end

  # Explicit-selection mode reads the description from `bd show` (a
  # different code path than `bd ready`, in explicit_candidates/2) - this
  # is the only test exercising that path for the summary field.
  # sabotage: `"summary" => c[:summary]` dropped from public_candidate/1
  # -> red, candidate carries no "summary" key even though annotate/2 set it
  def test_summary_present_in_explicit_selection_mode_too
    @fake.expect(
      %w[bd show st-trm --json],
      out: JSON.generate([{
        "id" => "st-trm", "title" => "title for st-trm",
        "description" => "Extends the ADR guard to cover ADR-0015 in Ruby. More detail follows.",
        "labels" => ["area:skills"], "priority" => 2, "issue_type" => "chore"
      }])
    )
    expect_empty_survey

    _code, env = run_select(["st-trm", "--auto"])

    candidate = env["data"]["candidates"].find { |c| c["id"] == "st-trm" }
    assert_equal "Extends the ADR guard to cover ADR-0015 in Ruby.", candidate["summary"]
  end

  # sabotage: `Summary.of` body changed to always `return description`
  # (skip the blank check) -> red, expects nil but gets ""
  def test_candidate_with_empty_description_carries_summary_key_with_nil_value
    expect_ready([issue("st-nod", priority: 1, labels: ["area:interpreter"], description: "")])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    candidate = env["data"]["candidates"].find { |c| c["id"] == "st-nod" }
    assert candidate.key?("summary")
    assert_nil candidate["summary"]
  end

  # The st-trm/st-tgv motivating case from st-sdv's own description: two
  # ready beads sharing an identical title, distinguishable only by
  # description.
  # sabotage: `issue["description"]` changed to `issue["title"]` in
  # annotate/2 -> red, both summaries collapse to the shared title's summary
  def test_identical_titles_with_different_descriptions_produce_different_summaries
    shared_title = "Extends the ADR guard"
    expect_ready([
                   { "id" => "st-trm", "title" => shared_title, "priority" => 1, "issue_type" => "chore",
                     "labels" => ["area:interpreter"],
                     "description" => "Extends the ADR guard to cover ADR-0015 in Ruby." },
                   { "id" => "st-tgv", "title" => shared_title, "priority" => 2, "issue_type" => "chore",
                     "labels" => ["area:parser"],
                     "description" => "plan_state_test.rb's real-plan fixture assumes an always-incomplete phase." }
                 ])
    expect_empty_survey

    _code, env = run_select(["--auto"])

    trm = env["data"]["candidates"].find { |c| c["id"] == "st-trm" }
    tgv = env["data"]["candidates"].find { |c| c["id"] == "st-tgv" }
    assert_equal trm["title"], tgv["title"]
    refute_equal trm["summary"], tgv["summary"]
  end
end
