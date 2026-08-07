# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"

# The mechanical enforcement of ADR-0015 constraint 1 (scripts are
# step-scoped; the banned-operation list is absolute). It lives here rather
# than in lib/mix/statifier/adr_guard.ex because that guard scans Elixir
# under lib/statifier/ and would need a second language to cover Ruby - see
# ADR-0015's Consequences.
#
# The guardrail test that survives every later phase of st-hzf. Contract
# holds the scanning rules as pure functions over lines of source (so they
# can be unit-tested against synthetic fixtures, proving the regexes really
# catch what they claim to), and ContractTest applies them to the real files
# under .claude/scripts/.
#
# This test is why `git push` and `gh pr create` are hand-run commands in
# /merge-request rather than a script step: CLAUDE.md's authority table puts
# the human gate at the seam between commit and push, and a script spanning
# that seam would relocate a decision nobody decided to move.
module Contract
  BANNED_CALLS = {
    "git push" => /\bgit\s+push\b/,
    "gh pr create" => /\bgh\s+pr\s+create\b/,
    "bd close" => /\bbd\s+close\b/,
    "bd edit" => /\bbd\s+edit\b/
  }.freeze

  NON_INTERACTIVE_FLAG = /-\S*f\S*/.freeze # any dash-flag containing an f, e.g. -f, -Rf, -rf, -Rfc

  module_function

  # Strips a trailing "# ..." comment from a line. Good enough for the
  # straight-line Ruby this codebase writes; a `#` inside a string literal is
  # a false-negative risk this test accepts in exchange for staying simple
  # and dependency-free (no full Ruby parser).
  def code_only(line)
    line.sub(/#.*/, "")
  end

  def each_code_line(content)
    content.each_line.with_index(1) do |line, lineno|
      code = code_only(line)
      next if code.strip.empty?

      yield code, lineno
    end
  end

  # Returns [[lineno, label], ...] for every banned call found in content.
  # Ruby argv arrays write commands as separate string literals
  # (`["git", "push"]`), so quotes/brackets/commas are normalized to spaces
  # before matching - that lets a single word-boundary phrase regex catch
  # both an argv array and a plain string like "git push".
  def banned_calls(content)
    hits = []
    each_code_line(content) do |code, lineno|
      haystack = normalize_for_word_match(code)
      BANNED_CALLS.each do |label, pattern|
        hits << [lineno, label] if haystack =~ pattern
      end
    end
    hits
  end

  def normalize_for_word_match(code)
    code.gsub(/["'\[\],]/, " ")
  end

  def ledger_write?(content)
    each_code_line(content) do |code, _lineno|
      return true if code =~ /quality-gate-changes\.md/ && code =~ /File\.(open|write)|IO\.write/
    end
    false
  end

  def quality_exs_write?(content)
    each_code_line(content) do |code, _lineno|
      return true if code =~ /\.quality\.exs/ && code =~ /File\.(open|write)|IO\.write/
    end
    false
  end

  # Returns lines using system(...) or backtick execution instead of Sh.
  def system_or_backticks(content)
    hits = []
    each_code_line(content) do |code, lineno|
      hits << lineno if code =~ /(^|[^\w.])system\s*\(/ || code =~ /`[^`]*`/
    end
    hits
  end

  # Returns argv-literal lines starting with "cp"/"rm"/"mv" that carry no
  # non-interactive flag anywhere on the same line.
  def unsafe_cp_rm_mv(content)
    hits = []
    each_code_line(content) do |code, lineno|
      match = code.match(/\[\s*"(cp|rm|mv)"/)
      next unless match

      cmd = match[1]
      hits << [lineno, cmd] unless code =~ NON_INTERACTIVE_FLAG
    end
    hits
  end
end

class ContractRulesTest < Minitest::Test
  def test_banned_calls_ignores_comments
    hits = Contract.banned_calls("# this mentions git push only in prose\n")
    assert_empty hits
  end

  def test_banned_calls_specific_examples
    assert_equal [[1, "git push"]], Contract.banned_calls(%(Sh.run(["git", "push", "origin", branch])\n))
    assert_equal [[1, "gh pr create"]], Contract.banned_calls(%(Sh.run(["gh", "pr", "create"])\n))
    assert_equal [[1, "bd close"]], Contract.banned_calls(%(Sh.run(["bd", "close", id])\n))
    assert_equal [[1, "bd edit"]], Contract.banned_calls(%(Sh.run(["bd", "edit", id])\n))
  end

  def test_ledger_write_detected
    assert Contract.ledger_write?(%(File.open("docs/quality-gate-changes.md", "a") { |f| f.puts x }\n))
    refute Contract.ledger_write?(%(File.exist?("docs/quality-gate-changes.md")\n))
    refute Contract.ledger_write?(%(# writing to docs/quality-gate-changes.md is not allowed\n))
  end

  def test_quality_exs_write_detected
    assert Contract.quality_exs_write?(%(File.write(".quality.exs", content)\n))
    refute Contract.quality_exs_write?(%(File.exist?(".quality.exs")\n))
  end

  def test_system_or_backticks_detected
    assert_equal [1], Contract.system_or_backticks(%(system("git status")\n))
    assert_equal [1], Contract.system_or_backticks(%(out = `git status`\n))
    assert_empty Contract.system_or_backticks(%(Open3.capture3("git", "status")\n))
    assert_empty Contract.system_or_backticks(%(# never call system(...) here\n))
  end

  def test_unsafe_cp_rm_mv_detected
    assert_equal [[1, "rm"]], Contract.unsafe_cp_rm_mv(%(Sh.run(["rm", path])\n))
    assert_empty Contract.unsafe_cp_rm_mv(%(Sh.run(["rm", "-rf", path])\n))
    assert_empty Contract.unsafe_cp_rm_mv(%(Sh.run(["cp", "-Rfc", src, dst])\n))
    assert_empty Contract.unsafe_cp_rm_mv(%(Sh.run(["mv", "-f", src, dst])\n))
  end
end

# Applies the Contract rules to the real files under .claude/scripts/, so a
# future phase cannot introduce a banned operation without this suite
# catching it.
class ContractTest < Minitest::Test
  SCRIPTS_ROOT = File.expand_path(File.join(__dir__, ".."))

  def all_ruby_files
    Dir.glob(File.join(SCRIPTS_ROOT, "**", "*.rb")).sort
  end

  # Everything except this test file's own directory: the checks are about
  # what scripts (lib/ and top-level) do, not about what the tests assert or
  # exercise via fixtures.
  def non_test_files
    all_ruby_files.reject { |f| f.start_with?(File.join(SCRIPTS_ROOT, "test") + File::SEPARATOR) }
  end

  def test_no_banned_calls_outside_comments
    offenders = []
    non_test_files.each do |file|
      Contract.banned_calls(File.read(file)).each do |(lineno, label)|
        offenders << "#{file}:#{lineno} (#{label})"
      end
    end
    assert_empty offenders, "banned call(s) found outside comments: #{offenders.join(', ')}"
  end

  def test_no_write_to_quality_gate_changes_ledger
    offenders = non_test_files.select { |f| Contract.ledger_write?(File.read(f)) }
    assert_empty offenders, "a write to docs/quality-gate-changes.md found in: #{offenders.join(', ')}"
  end

  def test_no_quality_exs_write
    offenders = non_test_files.select { |f| Contract.quality_exs_write?(File.read(f)) }
    assert_empty offenders, ".quality.exs write found in: #{offenders.join(', ')}"
  end

  def test_no_system_or_backticks_everything_goes_through_sh
    offenders = []
    non_test_files.each do |file|
      Contract.system_or_backticks(File.read(file)).each { |lineno| offenders << "#{file}:#{lineno}" }
    end
    assert_empty offenders, "system(...)/backticks found (must go through Sh) in: #{offenders.join(', ')}"
  end

  # Every direct child of .claude/scripts/*.rb is a top-level, directly
  # invokable script and must carry the shebang and the executable bit. In
  # Phase 1 there are none yet (only lib/ and test/ files exist) - this test
  # must not require at least one match, since it runs unchanged in every
  # later phase once top-level scripts do exist.
  def test_top_level_scripts_have_shebang_and_executable_bit
    top_level = Dir.glob(File.join(SCRIPTS_ROOT, "*.rb")).sort

    top_level.each do |file|
      first_line = File.open(file, &:readline).chomp
      assert_equal "#!/usr/bin/env ruby", first_line, "#{file} is missing the #!/usr/bin/env ruby shebang"
      assert File.executable?(file), "#{file} is missing the executable bit"
    end
  end

  def test_cp_rm_mv_argv_carries_non_interactive_flag
    offenders = []
    non_test_files.each do |file|
      Contract.unsafe_cp_rm_mv(File.read(file)).each do |(lineno, cmd)|
        offenders << "#{file}:#{lineno} (#{cmd})"
      end
    end
    assert_empty offenders, "cp/rm/mv argv missing a non-interactive flag in: #{offenders.join(', ')}"
  end

  # A meta-check on the guardrail itself: prove the scan is not vacuously
  # green just because no scripts exist yet in Phase 1. A fixture file with a
  # violation, dropped into a temp copy of the tree shape, must be caught.
  def test_meta_the_scan_actually_catches_a_planted_violation
    Dir.mktmpdir do |dir|
      planted = File.join(dir, "planted.rb")
      File.write(planted, %(Sh.run(["git", "push", "origin", "main"])\n))

      hits = Contract.banned_calls(File.read(planted))

      refute_empty hits, "the contract scan failed to catch a planted git push"
    end
  end
end
