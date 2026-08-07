# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../gate"
require_relative "../lib/touches_elixir"
require_relative "support/fake_sh"

class GateTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
    @orig_pwd = Dir.pwd
  end

  def teardown
    Sh.runner = nil
    Dir.chdir(@orig_pwd)
  end

  def run_gate(argv = [])
    io = StringIO.new
    code = Gate.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # Runs the block inside a fresh tmp dir so File.exist?(LEDGER_PATH) checks
  # (a relative path) resolve predictably regardless of where the ledger
  # happens to exist in this real checkout.
  def in_tmp_cwd(ledger_present: false)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "docs")) if ledger_present
      File.write(File.join(dir, "docs", "quality-gate-changes.md"), "# ledger\n") if ledger_present
      Dir.chdir(dir) { yield }
    end
  end

  def expect_no_elixir_diff
    @fake.expect(%w[git diff --name-only main...HEAD], out: "docs/plans/x.md\n")
    @fake.expect(%w[git status --porcelain], out: "")
  end

  def expect_elixir_diff
    @fake.expect(%w[git diff --name-only main...HEAD], out: "lib/statifier/foo.ex\n")
    @fake.expect(%w[git status --porcelain], out: "")
  end

  def expect_no_sabotage_diff(out: "")
    @fake.expect(
      %w[git diff main...HEAD -U0 -- test/ :!test/scion_tests :!test/scxml_tests],
      out: out
    )
  end

  GREEN_REPORT = {
    "status" => "ok",
    "scope" => "all",
    "stages" => [
      { "name" => "Format", "status" => "ok", "summary" => "clean" },
      { "name" => "Compile", "status" => "ok", "summary" => "no warnings" }
    ]
  }.freeze

  def test_carve_out_applies_and_skips_the_gate_entirely
    in_tmp_cwd do
      expect_no_elixir_diff
      expect_no_sabotage_diff

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal false, env["data"]["applicable"]
      refute_nil env["data"]["carve_out_reason"]
      assert_nil env["data"]["ran"]
      assert_nil env["data"]["attested"]
      assert_equal [], env["data"]["skipped_stages"]
      # No `mix quality` or `mix gate.verify` call was ever registered above,
      # so if the script tried to shell out to either, FakeSh would raise
      # FakeSh::UnexpectedCommand and this test would fail loudly.
    end
  end

  def test_full_run_green_report_attests_and_is_ok
    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[mix quality --report -], out: JSON.generate(GREEN_REPORT))
      @fake.expect(%w[mix gate.verify], out: "Full gate green: scope all, no profile, 2 stages considered.\n")

      code, env = run_gate

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal true, env["data"]["applicable"]
      assert_equal "all", env["data"]["ran"]
      assert_equal true, env["data"]["attested"]
      assert_equal [], env["data"]["skipped_stages"]
      assert_equal [], env["blocked"]
    end
  end

  def test_skipped_stage_forces_ok_false_even_though_status_is_ok
    report = {
      "status" => "ok",
      "scope" => "all",
      "stages" => [
        { "name" => "Format", "status" => "ok", "summary" => "clean" },
        { "name" => "Sobelow", "status" => "skipped", "summary" => ":sobelow not installed" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[mix quality --report -], out: JSON.generate(report))
      @fake.expect(%w[mix gate.verify], out: "Full gate green...\n")

      code, env = run_gate

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal 1, env["data"]["skipped_stages"].length
      assert_equal "Sobelow", env["data"]["skipped_stages"].first["name"]
      assert_equal 1, env["blocked"].length
      assert_equal "stage_skipped", env["blocked"].first["code"]
      # Skipped stages are a report, not evidence the run failed - so this
      # must still show up in data, not silently vanish.
      assert_equal report["stages"], env["data"]["stages"]
    end
  end

  def test_red_gate_fails_without_being_blocked
    report = {
      "status" => "error",
      "scope" => "all",
      "stages" => [
        { "name" => "Credo", "status" => "error", "summary" => "5 issues" }
      ]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[mix quality --report -], out: JSON.generate(report))
      @fake.expect(%w[mix gate.verify], exitstatus: 1, err: "** (Mix) Not a full gate: the gate is red (Credo).\n")

      code, env = run_gate

      assert_equal 1, code
      assert_equal false, env["ok"]
      assert_equal false, env["data"]["attested"]
      assert_equal "error", env["data"]["status"]
    end
  end

  def test_profile_loop_sets_attested_false_and_forwards_the_loop_profile_only
    report = {
      "status" => "ok",
      "profile" => "loop",
      "scope" => "changed",
      "stages" => [{ "name" => "Format", "status" => "ok", "summary" => "clean" }]
    }

    in_tmp_cwd do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[mix quality --report - --profile loop], out: JSON.generate(report))
      # No `mix gate.verify` expectation registered: a loop run must never
      # call it, since attested is already forced to false.

      code, env = run_gate(["--profile", "loop"])

      assert_equal 0, code
      assert_equal "loop", env["data"]["ran"]
      assert_equal false, env["data"]["attested"]
    end
  end

  def test_profile_loop_runs_even_when_the_carve_out_would_otherwise_apply
    report = {
      "status" => "ok",
      "profile" => "loop",
      "scope" => "changed",
      "stages" => [{ "name" => "Format", "status" => "ok", "summary" => "clean" }]
    }

    in_tmp_cwd do
      expect_no_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[mix quality --report - --profile loop], out: JSON.generate(report))

      code, env = run_gate(["--profile", "loop"])

      assert_equal 0, code
      assert_equal false, env["data"]["applicable"]
      assert_equal "loop", env["data"]["ran"]
      assert_equal false, env["data"]["attested"]
    end
  end

  def test_profile_other_than_loop_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { Gate.run(["--profile", "merge"]) } }
    assert_match(/profile must be 'loop'/, err)
  end

  def test_skip_flag_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { Gate.run(["--skip", "dialyzer"]) } }
    assert_match(/invalid option/, err)
  end

  def test_quick_flag_is_a_usage_error_not_an_envelope
    err = capture_io_stderr { assert_raises(SystemExit) { Gate.run(["--quick"]) } }
    assert_match(/invalid option/, err)
  end

  def capture_io_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # --- Carve-out predicate: matches /commit's Step 0 (L97-98) exactly ---

  def test_touches_elixir_predicate_matches_commit_skill_wording
    matching = %w[
      lib/statifier/interpreter.ex
      test/statifier/interpreter_test.exs
      config/config.exs
      mix.exs
      mix.lock
    ]
    non_matching = %w[
      docs/plans/260806-st-hzf-x.md
      changelog.d/st-hzf.md
      .claude/scripts/gate.rb
      docs/adr/0011.md
      README.md
    ]

    matching.each { |path| assert TouchesElixir.any?([path]), "expected #{path} to touch elixir" }
    non_matching.each { |path| refute TouchesElixir.any?([path]), "expected #{path} not to touch elixir" }
  end

  # --- Sabotage scan ---

  def test_sabotage_scan_flags_a_missing_note
    diff = <<~DIFF
      diff --git a/test/statifier/foo_test.exs b/test/statifier/foo_test.exs
      --- a/test/statifier/foo_test.exs
      +++ b/test/statifier/foo_test.exs
      @@ -10,0 +11,2 @@
      +  test "does the thing" do
      +  end
    DIFF

    missing = Gate.scan_sabotage(diff)

    assert_equal 1, missing.length
    assert_equal "test/statifier/foo_test.exs", missing.first[:file]
  end

  def test_sabotage_scan_accepts_a_real_mutation_note
    diff = <<~DIFF
      diff --git a/test/statifier/foo_test.exs b/test/statifier/foo_test.exs
      --- a/test/statifier/foo_test.exs
      +++ b/test/statifier/foo_test.exs
      @@ -10,0 +11,3 @@
      +  # sabotage: enter_states/2 skips the initial child -> red
      +  test "does the thing" do
      +  end
    DIFF

    assert_empty Gate.scan_sabotage(diff)
  end

  def test_sabotage_scan_accepts_an_n_a_exemption_note
    diff = <<~DIFF
      diff --git a/test/statifier/foo_test.exs b/test/statifier/foo_test.exs
      --- a/test/statifier/foo_test.exs
      +++ b/test/statifier/foo_test.exs
      @@ -10,0 +11,3 @@
      +  # sabotage: n/a - generated corpus fixture
      +  test "does the thing" do
      +  end
    DIFF

    assert_empty Gate.scan_sabotage(diff)
  end

  def test_sabotage_scan_ignores_scion_and_scxml_test_dirs
    diff = <<~DIFF
      diff --git a/test/scion_tests/foo_test.exs b/test/scion_tests/foo_test.exs
      --- a/test/scion_tests/foo_test.exs
      +++ b/test/scion_tests/foo_test.exs
      @@ -0,0 +1,2 @@
      +  test "generated corpus case" do
      +  end
      diff --git a/test/scxml_tests/bar_test.exs b/test/scxml_tests/bar_test.exs
      --- a/test/scxml_tests/bar_test.exs
      +++ b/test/scxml_tests/bar_test.exs
      @@ -0,0 +1,2 @@
      +  test "another generated corpus case" do
      +  end
    DIFF

    assert_empty Gate.scan_sabotage(diff)
  end

  def test_sabotage_scan_runs_over_the_committed_diff_pathspec
    in_tmp_cwd do
      expect_no_elixir_diff
      @fake.expect(
        %w[git diff main...HEAD -U0 -- test/ :!test/scion_tests :!test/scxml_tests],
        out: "diff --git a/test/foo_test.exs b/test/foo_test.exs\n" \
             "--- a/test/foo_test.exs\n+++ b/test/foo_test.exs\n@@ -0,0 +1,1 @@\n" \
             "+  test \"missing its note\" do\n"
      )

      _code, env = run_gate

      assert_equal 1, env["data"]["sabotage"]["missing"].length
      assert_equal 1, env["warnings"].length
      assert_equal "sabotage_note_missing", env["warnings"].first["code"]
      # A warning never blocks and never flips ok, even though applicable
      # is false here (the carve-out and the sabotage scan are independent).
      assert_equal true, env["ok"]
    end
  end

  # --- Gate guard: reported, never repaired ---

  def test_gate_guard_reports_ledger_state_with_no_write_attempted
    report = {
      "status" => "error",
      "scope" => "all",
      "stages" => [
        {
          "name" => "Gate guard",
          "status" => "error",
          "summary" => "1 unjustified gate change",
          "findings" => [
            { "file" => ".quality.exs", "line" => nil, "message" => "changed with no ledger entry" }
          ]
        }
      ]
    }

    in_tmp_cwd(ledger_present: true) do
      expect_elixir_diff
      expect_no_sabotage_diff
      @fake.expect(%w[mix quality --report -], out: JSON.generate(report))
      @fake.expect(%w[mix gate.verify], exitstatus: 1, err: "not a full gate\n")

      _code, env = run_gate

      gate_guard = env["data"]["gate_guard"]
      assert_equal true, gate_guard["ledger_exists"]
      assert_equal "docs/quality-gate-changes.md", gate_guard["ledger_path"]
      assert_equal "error", gate_guard["stage"]["status"]
      assert_equal 1, gate_guard["stage"]["findings"].length
    end
  end

  def test_gate_guard_ledger_missing_is_reported_not_created
    in_tmp_cwd(ledger_present: false) do
      expect_no_elixir_diff
      expect_no_sabotage_diff

      _code, env = run_gate

      assert_equal false, env["data"]["gate_guard"]["ledger_exists"]
      refute File.exist?("docs/quality-gate-changes.md")
    end
  end
end
