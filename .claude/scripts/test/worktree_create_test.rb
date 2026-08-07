# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../worktree_create"
require_relative "support/fake_sh"

class WorktreeCreateTest < Minitest::Test
  def setup
    @fake = FakeSh.new
    Sh.runner = @fake
  end

  def teardown
    Sh.runner = nil
  end

  def run_create(argv)
    io = StringIO.new
    code = WorktreeCreate.run(argv, io: io)
    [code, JSON.parse(io.string)]
  end

  def expect_location(root)
    @fake.expect(%w[git rev-parse --git-dir], out: "#{root}/.git\n")
    @fake.expect(%w[git rev-parse --git-common-dir], out: "#{root}/.git\n")
    @fake.expect(%w[git rev-parse --show-toplevel], out: "#{root}\n")
  end

  def test_blocks_when_not_run_from_the_main_checkout
    @fake.expect(%w[git rev-parse --git-dir], out: "/wt/.git/worktrees/x\n")
    @fake.expect(%w[git rev-parse --git-common-dir], out: "/wt/.git\n")
    @fake.expect(%w[git rev-parse --show-toplevel], out: "/wt\n")

    code, env = run_create(["st-abc-new-thing"])

    assert_equal 1, code
    assert_equal false, env["ok"]
    assert_equal "not_main_checkout", env["blocked"].first["code"]
  end

  def test_blocks_when_branch_already_exists
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "statifier-ex")
      FileUtils.mkdir_p(root)
      expect_location(root)
      @fake.expect(["git", "branch", "--list", "st-abc-new-thing"], out: "  st-abc-new-thing\n")

      code, env = run_create(["st-abc-new-thing"])

      assert_equal 1, code
      assert_equal "branch_exists", env["blocked"].first["code"]
      assert_equal "human", env["blocked"].first["needs"]
    end
  end

  def test_blocks_when_worktree_directory_already_exists
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "statifier-ex")
      FileUtils.mkdir_p(root)
      existing = File.join(tmp, "statifier-ex-worktrees", "st-abc-new-thing")
      FileUtils.mkdir_p(existing)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "st-abc-new-thing"], out: "")

      code, env = run_create(["st-abc-new-thing"])

      assert_equal 1, code
      assert_equal "worktree_dir_exists", env["blocked"].first["code"]
    end
  end

  def test_offline_fetch_falls_back_to_local_main_and_warns
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "statifier-ex")
      FileUtils.mkdir_p(root)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "st-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], exitstatus: 1, err: "fatal: unable to access\n")

      code, env = run_create(["st-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal "main", env["data"]["base_ref"]
      assert_equal "fetch_failed", env["warnings"].first["code"]
    end
  end

  def test_dry_run_never_executes_the_mutating_steps
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "statifier-ex")
      FileUtils.mkdir_p(root)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "st-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")

      # No expectations registered for mkdir, git worktree add, mise trust,
      # cp, mix deps.get, or mix quality - if the script called Sh.run for
      # any of them, FakeSh would raise UnexpectedCommand and fail this test.
      code, env = run_create(["st-abc-new-thing", "--dry-run"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal true, env["data"]["dry_run"]
      assert_equal "origin/main", env["data"]["base_ref"]
      assert env["commands"].any? { |c| c.include?("git worktree add") }
      assert env["commands"].any? { |c| c.include?("mise trust") }
      assert env["commands"].any? { |c| c.include?("mix quality --profile loop") }
      refute env["commands"].any? { |c| c.include?("--force") }
    end
  end

  def test_dry_run_command_sequence_matches_new_worktree_prose_order
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "statifier-ex")
      FileUtils.mkdir_p(root)

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "st-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")

      _code, env = run_create(["st-abc-new-thing", "--dry-run"])

      mutating = env["commands"].select do |c|
        c =~ /mkdir -p|git worktree add|mise trust|cp -Rfc|fallback|mix deps\.get|mix quality/
      end

      assert_equal 7, mutating.length
      assert_match(/\Amkdir -p/, mutating[0])
      assert_match(/git worktree add/, mutating[1])
      assert_match(/mise trust/, mutating[2])
      assert_match(/cp -Rfc/, mutating[3])
      assert_match(/fallback/, mutating[4])
      assert_match(/mix deps\.get/, mutating[5])
      assert_match(/mix quality/, mutating[6])
    end
  end

  def test_happy_path_creates_warms_and_verifies
    Dir.mktmpdir do |tmp|
      root = File.join(tmp, "statifier-ex")
      FileUtils.mkdir_p(File.join(root, "_build", "dev"))
      FileUtils.touch(File.join(root, "_build", "dev", "dialyxir_erlang-27.3_elixir-1.18.3_deps-dev.plt"))
      worktrees_root = File.join(tmp, "statifier-ex-worktrees")
      path = File.join(worktrees_root, "st-abc-new-thing")

      expect_location(root)
      @fake.expect(["git", "branch", "--list", "st-abc-new-thing"], out: "")
      @fake.expect(%w[git fetch origin], out: "")
      @fake.expect(["mkdir", "-p", worktrees_root], out: "")
      @fake.expect(["git", "worktree", "add", path, "-b", "st-abc-new-thing", "--no-track", "origin/main"], out: "")
      @fake.expect(["mise", "trust", path], out: "")
      @fake.expect(["cp", "-Rfc", "deps", "_build", "#{path}/"], out: "")
      @fake.expect(%w[mix deps.get], out: "")
      @fake.expect(%w[mix quality --profile loop], out: "loop green\n")

      code, env = run_create(["st-abc-new-thing"])

      assert_equal 0, code
      assert_equal true, env["ok"]
      assert_equal true, env["data"]["caches_cloned"]
      assert_equal true, env["data"]["plt_present"]
      assert_equal true, env["data"]["quality_green"]
      refute env["commands"].any? { |c| c.include?("--force") }
    end
  end

  def test_never_force_in_source
    source = File.read(File.expand_path("../worktree_create.rb", __dir__))
    refute_match(/--force\b/, source)
  end
end
