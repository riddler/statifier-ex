# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../rebase_onto"
require_relative "support/fake_sh"

class RebaseOntoTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
  end

  def run_rebase(argv)
    io = StringIO.new
    code = RebaseOnto.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  # The whole point of the extraction: the diff --diff-filter=U capture must
  # precede the rebase --abort in the recorded call sequence, because the
  # abort clears the conflict state a report assembled afterward would
  # otherwise have nothing left to name.
  def test_conflict_captures_files_before_aborting_in_that_order
    path = "/wt/st-abc-x"
    @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
    @fake.expect(%w[git rebase origin/main], exitstatus: 1, err: "CONFLICT\n")
    @fake.expect(%w[git diff --name-only --diff-filter=U], out: "lib/foo.ex\nlib/bar.ex\n")
    @fake.expect(%w[git rebase --abort], out: "")

    code, env = run_rebase([path])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "rebase_conflict", env["blocked"].first["code"]
    assert_equal "human", env["blocked"].first["needs"]
    assert_equal %w[lib/foo.ex lib/bar.ex], env["data"]["files"]

    capture_index = @fake.calls.find_index { |c| c.argv == %w[git diff --name-only --diff-filter=U] }
    abort_index = @fake.calls.find_index { |c| c.argv == %w[git rebase --abort] }
    refute_nil capture_index
    refute_nil abort_index
    assert capture_index < abort_index, "expected the diff capture to precede the rebase --abort"
  end

  def test_conflict_has_no_resolve_path_the_script_never_calls_checkout_or_merge_tool
    source = File.read(File.expand_path("../rebase_onto.rb", __dir__))
    refute_match(/checkout\s+--(ours|theirs)/, source)
    refute_match(/git\s+add\b/, source)
    refute_match(/rebase\s+--continue/, source)
  end

  def test_mix_lock_unchanged_fast_path_issues_no_deps_get
    path = "/wt/st-abc-x"
    @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
    @fake.expect(%w[git rebase origin/main], out: "")
    @fake.expect(%w[git rev-parse origin/main], out: "bbbbbbb\n")
    @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "mix.lock"], exitstatus: 0)

    # No "mix deps.get" expectation registered - if the script called it on
    # the unchanged fast path, FakeSh would raise UnexpectedCommand.
    code, env = run_rebase([path])

    assert_equal 0, code
    assert_equal "rebased", env["data"]["status"]
    assert_equal false, env["data"]["lock_changed"]
    assert_nil env["data"]["repaired"]
  end

  def test_mix_lock_changed_runs_deps_get_and_copies_the_plt_targeted
    Dir.mktmpdir do |tmp|
      main = File.join(tmp, "statifier-ex")
      path = File.join(tmp, "statifier-ex-worktrees", "st-abc-x")
      FileUtils.mkdir_p(File.join(main, "_build", "dev"))
      FileUtils.mkdir_p(File.join(path, "_build", "dev"))
      plt = File.join(main, "_build", "dev", "dialyxir_erlang-27.3_elixir-1.18.3_deps-dev.plt")
      FileUtils.touch(plt)

      @fake.expect(%w[git rev-parse HEAD], out: "aaaaaaa\n")
      @fake.expect(%w[git rebase origin/main], out: "")
      @fake.expect(%w[git rev-parse origin/main], out: "bbbbbbb\n")
      @fake.expect(["git", "diff", "--quiet", "aaaaaaa", "HEAD", "--", "mix.lock"], exitstatus: 1)
      @fake.expect(%w[mix deps.get], out: "")
      @fake.expect(%w[git worktree list --porcelain], out: "worktree #{main}\nHEAD cccc\nbranch refs/heads/main\n")
      @fake.expect(["cp", "-f", plt, File.join(path, "_build", "dev", File.basename(plt))], out: "")

      code, env = run_rebase([path])

      assert_equal 0, code
      assert_equal true, env["data"]["lock_changed"]
      assert_equal true, env["data"]["repaired"]
    end
  end

  def test_never_reclones_deps_or_build_wholesale
    source = File.read(File.expand_path("../rebase_onto.rb", __dir__))
    refute_match(/cp.*-R.*deps.*_build/, source)
  end

  def test_dry_run_executes_nothing
    path = "/wt/st-abc-x"

    # No FakeSh expectations at all - any Sh.run call would raise.
    code, env = run_rebase([path, "--dry-run"])

    assert_equal 0, code
    assert_equal true, env["ok"]
    assert_equal "dry_run", env["data"]["status"]
    assert env["commands"].any? { |c| c.include?("git rebase origin/main") }
    refute env["commands"].any? { |c| c.include?("--force") }
  end

  def test_never_force_in_source
    source = File.read(File.expand_path("../rebase_onto.rb", __dir__))
    refute_match(/--force\b/, source)
  end
end
