# tmp_dir Race Between Tests and Regression Ratchet Implementation Plan

## Overview

The `Tests` and `Regression ratchet` stages of a bare `mix quality` run
concurrently in the analysis phase and execute the same test modules. Those
modules use ExUnit's `@tag :tmp_dir`, whose scratch directory is a hardcoded
`tmp/` under the current working directory, so the two runs create, delete and
recreate the same paths and intermittently blow up. Beads issue: st-0vz.

This plan replaces ExUnit's built-in `:tmp_dir` tag with a project-owned
equivalent whose root is settable per process, and has `mix test.regression`
put its child `mix test` under a distinct root. Neither guarded path
(`.quality.exs`, `test/passing_tests.json`) is edited, so **no ADR-0011 ledger
entry is required** - see `## Open Questions and Human Decisions` at the end
for the tripwire that would change that.

## Current State Analysis

**The two stages and their overlap.**
`.quality.exs:82-88` registers the `regression` custom stage as
`kind: :reader`, running `mix test.regression`. Readers run in ex_quality's
parallel analysis phase, alongside the built-in `Tests` stage, in the same
working directory. `test/passing_tests.json` lists
`test/mix/**/*_test.exs` and `test/statifier/**/*_test.exs` under
`internal_tests`, so the ratchet re-runs nearly the whole internal suite. The
`.quality.exs:71-81` comment already documents that overlap as accepted.

**How the ratchet spawns its run.**
`lib/mix/tasks/test.regression.ex:95-100` shells out with
`System.cmd("mix", ["test" | args], into: ..., stderr_to_stdout: true)`. No
`env:` and no `cd:` are passed, so the child inherits the gate's environment
and working directory. `opts[:runner]` (line 53) already exists as an
injection seam for tests, which keeps the task's own tests from spawning a
nested `mix test`.

**Where the collision actually happens.**
ExUnit's runner builds the scratch path itself
(`.../elixir/1.18.3-otp-27/lib/ex_unit/lib/ex_unit/runner.ex:621-633`):

```elixir
path = ["tmp", module, "#{name}-#{short_hash}", extra_path] |> Path.join() |> Path.expand()
File.rm_rf!(path)
File.mkdir_p!(path)
```

Three things follow, and they bound every option below:

1. The literal `"tmp"` root is **not configurable**. There is no ExUnit
   config, no environment variable, no `ExUnit.start/1` option. Verified
   against the installed toolchain
   (`/Users/johnnyt/.local/share/mise/installs/elixir/1.18.3-otp-27/lib/ex_unit`),
   not from memory.
2. `@tag tmp_dir: "some/suffix"` (`runner.ex:600-602`) only appends
   `extra_path` **below** the same colliding root, and a tag value is fixed in
   source, so it cannot differ between two concurrent runs.
3. `Path.expand/1` resolves against the OS process's cwd, so cwd is the only
   lever ExUnit itself exposes - and a `mix test` child cannot be given a
   different cwd without losing its `mix.exs`.

Two concurrent runs therefore compute byte-identical paths and race on
`rm_rf!`/`mkdir_p!`, producing the failure recorded on the bead.

**Who uses the tag.** Four modules, all `async: true`:

| File | `@tag`/`@describetag :tmp_dir` sites | In the ratchet's globs? |
|---|---|---|
| `test/mix/statifier/regression_registry_test.exs` | 12 | yes |
| `test/mix/tasks/test_baseline_test.exs` | 15 | yes |
| `test/mix/tasks/test_regression_test.exs` | 7 | yes |
| `test/corpus/check_exprs_test.exs` | 3 | no |

The first three are the ones the two stages run twice. `check_exprs_test.exs`
is outside `test/mix/**` and `test/statifier/**`, so it is not part of the
race; it is migrated anyway so that one rule ("this repo does not use ExUnit's
`:tmp_dir`") can be enforced mechanically rather than per-directory.

**Existing seams the fix reuses.**
`test/support/` is already on `elixirc_paths(:test)` (`mix.exs:35`) and is
already excluded from coverage (`coveralls.json` `skip_files`), so a new
support module cannot move the 90% coverage floor - which matters, because
lowering that floor is exactly what ADR-0011 forbids.
`test/support/case.ex` is the naming precedent (`Statifier.Case`).
`.gitignore:23` already ignores `/tmp/`, so any subdirectory of it is ignored
too.

**Constraints.**
- ADR-0011 plus `CLAUDE.md`: `.quality.exs` and `test/passing_tests.json` are
  guarded; `mix gate.check` fails a branch that edits them without a
  `docs/quality-gate-changes.md` entry, and writing that entry is a human's
  call.
- The bead's note forbids narrowing `test/passing_tests.json` to dodge the
  overlap.
- The bead's acceptance criteria forbid retries, `@tag :skip`, and dropping
  the module from the ratchet. The fix must isolate the tmp root or stop the
  double execution.

## Desired End State

A bare `mix quality` cannot fail from a tmp_dir collision between the `Tests`
and `Regression ratchet` stages, because the two runs provably never write to
the same scratch root:

- No file under `test/` uses ExUnit's `@tag :tmp_dir` / `@describetag
  :tmp_dir`; a test asserts this so it cannot come back by accident.
- Scratch directories come from `Statifier.TmpDir`, whose root is
  `System.get_env("STATIFIER_TMP_ROOT")` defaulting to `"tmp"`.
- `mix test.regression`'s child `mix test` runs with
  `STATIFIER_TMP_ROOT=tmp/regression`, so its scratch tree is disjoint from
  the `Tests` stage's `tmp/`.
- Test bodies still destructure `%{tmp_dir: tmp_dir}`; only the tag name and a
  `setup` line change.
- `.quality.exs`, `test/passing_tests.json`, `.credo.exs`, `coveralls.json`,
  `.sobelow-conf` and `mix.exs` are untouched, so `mix gate.check` stays green
  with no ledger entry.

Verify with a full `mix quality` plus the concurrency loop in
`## Testing Strategy`.

### Key Discoveries:

- ExUnit hardcodes the `"tmp"` root at `ex_unit/lib/ex_unit/runner.ex:629`;
  it is not configurable, and `@tag tmp_dir: "..."` appends below it rather
  than replacing it. This rules out "just configure ExUnit" and forces a
  project-owned setup helper.
- `lib/mix/tasks/test.regression.ex:95-100` owns the `System.cmd/3` call
  outright and is **not** a guarded path, so the child run's environment can
  be scoped without touching `.quality.exs`.
- `test/support/` is compiled in `:test` (`mix.exs:35`) and skipped by
  `coveralls.json`, so the helper adds no coverage pressure.
- `test/mix/statifier/regression_stage_config_test.exs` is the precedent for
  asserting gate wiring from a test rather than by editing the gate config -
  the reintroduction guard in Phase 3 follows its shape, including its
  sabotage comments.
- ADR-0011 and `docs/quality-gate-changes.md`: a ledger entry needs an
  `Approved-by:` line naming a human. No agent may write one.

## What We're NOT Doing

- Not editing `test/passing_tests.json` to stop the modules running twice.
  The bead's note forbids it and it would weaken the ratchet.
- Not editing `.quality.exs` - not to serialize the stage by flipping
  `kind: :reader` to `:writer`, not to drop the stage, not to add an `env:`
  key. Any of those needs a human-written ledger entry (ADR-0011).
- Not retrying, not `@tag :skip`, not deleting or excluding the affected
  tests. Explicitly excluded by the acceptance criteria.
- Not deduplicating the Tests/ratchet overlap itself. `.quality.exs:71-81`
  documents that overlap as accepted and expects it to shrink as the
  conformance lists grow; this plan makes the overlap safe, not smaller.
- Not vendoring or patching ExUnit.
- Not changing what any test asserts. The migration is mechanical: tag name
  and one `setup` line per module.
- No changelog fragment. `changelog.d/README.md` excludes "test harness ...
  tooling" and "quality gate, CI, or agent tooling changes", and no public
  API or observable library behavior changes.

## Implementation Approach

Two halves, and both are needed:

1. **Own the scratch-path construction.** Replace ExUnit's `:tmp_dir` tag with
   `Statifier.TmpDir`, a `test/support/` module providing an equivalent
   `setup` whose root comes from `STATIFIER_TMP_ROOT` (default `"tmp"`). This
   is a drop-in: same `tmp_dir` context key, same
   `<root>/<Module>/<test-name>-<hash>` shape, same rm-then-mkdir semantics,
   same "left behind for inspection" behavior.
2. **Give the ratchet its own root.** `mix test.regression` passes
   `env: [{"STATIFIER_TMP_ROOT", "tmp/regression"}]` to its `System.cmd/3`.
   The `Tests` stage keeps the default `tmp/`.

Half 1 alone changes nothing (both runs still default to `tmp/`); half 2 alone
does nothing (ExUnit ignores the variable). So they land in a single phase -
that phase is the smallest independently gate-verifiable unit that actually
fixes the bug, per the phase-sizing rule in the create-plan skill.

Why an environment variable rather than a CLI flag threaded through
`mix test`: the value has to reach ExUnit's *runner*, inside the child OS
process, at the moment a test's setup runs. An env var crosses that boundary
with no argument plumbing, is inherited by anything the child itself spawns,
and is exactly the seam `System.cmd/3` already offers. It is also
composable - a developer hand-running `STATIFIER_TMP_ROOT=tmp/mine mix test`
gets the same isolation.

Why `tmp/regression` rather than a unique per-run directory: determinism. A
fixed path stays greppable and inspectable after a failure, stays under the
already-ignored `/tmp/`, and does not accumulate one tree per run. Two
concurrent *ratchet* runs would still collide, but nothing in the gate does
that, and Phase 3's guard test does not pretend otherwise.

Phase order is: helper first (inert, gate-green), then the fix (migration plus
env scoping, verifiable by the concurrency loop), then the guard and docs.

## Phase 1: Project-owned tmp_dir helper

### Overview

Add `Statifier.TmpDir` under `test/support/` with its own tests. Nothing uses
it yet, so this phase is behavior-neutral and the gate stays green on its own.

### Changes Required:

#### 1. The helper

**File**: `test/support/tmp_dir.ex` (new)
**Changes**: A support module providing `root/0`, `path_for/2` (pure, so it is
testable without touching the filesystem), and a `setup` callback that acts
only when the test carries the `:isolated_tmp_dir` tag.

```elixir
defmodule Statifier.TmpDir do
  @moduledoc """
  Per-test scratch directories with a settable root.

  Stands in for ExUnit's `@tag :tmp_dir`, which hardcodes a `tmp/` root under
  the current working directory (`ex_unit/lib/ex_unit/runner.ex`) with no way
  to configure it. That root is process-global, so two `mix test` runs in the
  same directory - which is exactly what the `Tests` and `Regression ratchet`
  stages of a bare `mix quality` are - race on the same paths (st-0vz).

  Tag a test `@tag :isolated_tmp_dir` and it receives `:tmp_dir` in its
  context, same as ExUnit's tag provides. The root is `STATIFIER_TMP_ROOT`,
  defaulting to `"tmp"`; `mix test.regression` sets it so the ratchet's child
  run cannot collide with the Tests stage.

  Like ExUnit, the directory is emptied at setup and left in place afterwards
  so a failure can be inspected.
  """

  @default_root "tmp"
  @env_var "STATIFIER_TMP_ROOT"
  @escape Enum.map(~c" [~#%&*{}\\:<>?/+|\"]", &<<&1::utf8>>)

  @doc "Scratch root for this OS process."
  @spec root() :: String.t()
  def root, do: System.get_env(@env_var) || @default_root

  @doc "Name of the environment variable that overrides the root."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "Default root used when the environment variable is unset."
  @spec default_root() :: String.t()
  def default_root, do: @default_root

  @doc """
  Absolute scratch path for `module` and `test_name` under `root/0`.

  Pure - builds the path and touches nothing.
  """
  @spec path_for(module :: module(), test_name :: atom() | String.t()) :: String.t()
  def path_for(module, test_name) do
    # ... mirrors ExUnit: <root>/<escaped module>/<escaped name>-<8-char md5>
  end

  @doc "ExUnit `setup` callback; a no-op unless the test is tagged."
  @spec setup_tmp_dir(context :: map()) :: :ok | {:ok, keyword()}
  def setup_tmp_dir(%{isolated_tmp_dir: true, module: module, test: test_name}) do
    path = path_for(module, test_name)
    File.rm_rf!(path)
    File.mkdir_p!(path)
    {:ok, tmp_dir: path}
  end

  def setup_tmp_dir(_context), do: :ok
end
```

Notes for the implementer:

- Mirror ExUnit's escaping and 8-character md5 suffix
  (`runner.ex:612-639`) so escaped names cannot alias each other.
- `path_for/2` should return an absolute path (`Path.expand/1`), matching
  what ExUnit's tag hands tests today, so no test body needs adjusting.
- Keep it out of `lib/`. It is test harness, and `test/support/` is already
  coverage-skipped and test-env-only.

#### 2. Tests for the helper

**File**: `test/statifier/tmp_dir_test.exs` (new)
**Changes**: cover `root/0` honoring and defaulting the env var, `path_for/2`
nesting under `root/0` and distinguishing two test names, and
`setup_tmp_dir/1` creating an empty directory and emptying a dirty one.

Sabotage: this module lives in `test/support/` and is harness plumbing, so its
tests carry `# sabotage: n/a - harness plumbing, asserts test/support/ not
lib/` rather than a mutation note. Note that the file itself lands under
`test/statifier/`, which `test/passing_tests.json` already globs, so the
ratchet picks it up with no registry edit.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `test/support/tmp_dir.ex` and its test file exist and compile in the
      test env: `mix compile --warnings-as-errors && mix test test/statifier/tmp_dir_test.exs`
- [x] Root override works end to end:
      `STATIFIER_TMP_ROOT=tmp/probe mix test test/statifier/tmp_dir_test.exs`
      is green and leaves a `tmp/probe/` tree behind
- [x] Gate guard is untouched-clean: `mix gate.check` reports no guarded-path
      change

#### Manual Verification:
- [ ] The moduledoc explains *why* this exists (the ExUnit hardcoded root)
      rather than only what it does
- [ ] Path shape matches what ExUnit produced, so an existing scratch tree
      under `tmp/` is still recognizable

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for manual confirmation before proceeding. In looped (`--loop`) execution,
this phase's Automated Verification gates advancement automatically (via
`/commit --auto`); Manual Verification items are deferred and surfaced once at
the end.

---

## Phase 2: Migrate the tests and scope the ratchet's root

### Overview

The fix. Move all four modules off ExUnit's tag onto `Statifier.TmpDir`, and
have `mix test.regression` run its child under `tmp/regression`. After this
phase the two stages cannot share a scratch path.

### Changes Required:

#### 1. Migrate the four test modules

**Files**:
- `test/mix/statifier/regression_registry_test.exs` (12 sites)
- `test/mix/tasks/test_baseline_test.exs` (15 sites)
- `test/mix/tasks/test_regression_test.exs` (7 sites)
- `test/corpus/check_exprs_test.exs` (3 sites, incl. one `@describetag`)

**Changes**: per module, add the setup hook once and rename every tag.

```elixir
  use ExUnit.Case, async: true

  setup :setup_tmp_dir
```

with `import Statifier.TmpDir, only: [setup_tmp_dir: 1]` (or a fully-qualified
`setup {Statifier.TmpDir, :setup_tmp_dir}`), then

```elixir
-    @tag :tmp_dir
+    @tag :isolated_tmp_dir
```

Test bodies are unchanged: they still match `%{tmp_dir: tmp_dir}`.

Watch for the two *nested* test sources inside heredocs
(`test/mix/tasks/test_regression_test.exs:114`,
`test/mix/tasks/test_baseline_test.exs:265`) - those are fixture strings
written into scratch directories, not real modules. They use `ExUnit.Case`
but no tmp_dir tag; leave them alone.

`test/corpus/check_exprs_test.exs:55` uses `@describetag :tmp_dir`; the same
rename applies, and `setup_tmp_dir/1` must therefore read the tag from the
merged context (which `@describetag` supplies) rather than from anything
test-local.

#### 2. Scope the ratchet's child run

**File**: `lib/mix/tasks/test.regression.ex`
**Changes**: give the spawned `mix test` its own scratch root, and expose the
value as a public function so it is assertable without spawning a process.

```elixir
  @tmp_root "tmp/regression"

  @doc """
  Environment for the spawned `mix test`.

  The ratchet runs concurrently with `mix quality`'s own Tests stage, in the
  same working directory, over largely the same modules. Scratch directories
  are rooted per OS process (`Statifier.TmpDir`), so without a distinct root
  the two runs delete each other's directories mid-test (st-0vz).
  """
  @spec test_env() :: [{String.t(), String.t()}]
  def test_env, do: [{"STATIFIER_TMP_ROOT", @tmp_root}]

  defp mix_test(args) do
    {_output, status} =
      System.cmd("mix", ["test" | args],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: test_env()
      )

    status
  end
```

`Statifier.TmpDir` is test-env-only, so `lib/` must not reference it - hence
the literal variable name here. Phase 3's guard test is what keeps the two
spellings from drifting apart.

#### 3. Test the new lib behavior

**File**: `test/mix/tasks/test_regression_test.exs`
**Changes**: assert `test_env/0` names the variable `Statifier.TmpDir` reads
and points somewhere other than the default root.

```elixir
  # sabotage: change test_env/0 to return [] -> red
  test "the spawned run gets its own scratch root" do
    assert [{var, root}] = Regression.test_env()
    assert var == Statifier.TmpDir.env_var()
    refute root == Statifier.TmpDir.default_root()
  end
```

This is a `lib/` assertion, so it carries a real sabotage note per `CLAUDE.md`
and `docs/testing.md`.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] No ExUnit tmp_dir tag remains:
      `! grep -rn "tag :tmp_dir\b" test/ --include=*.exs`
- [x] Concurrency loop is green 10/10 (fish):
      `for i in (seq 1 10); mix test test/mix test/corpus & mix test.regression & wait; end`
      (bash: `for i in $(seq 1 10); do mix test test/mix test/corpus & mix test.regression & wait; done`)
- [x] The two runs land in disjoint trees: after one loop iteration,
      `ls tmp` shows both `regression/` and at least one `Mix.Statifier.*`
      directory, and `ls tmp/regression` shows the ratchet's copies
- [x] Ratchet still covers the same files (no registry shrink):
      `mix test.regression` reports the same file count as before the change
- [x] Gate guard clean: `mix gate.check` reports no guarded-path change

#### Manual Verification:
- [ ] The diff is mechanical: no test's assertions or fixtures changed, only
      tag names and one setup line per module
- [ ] The pre-fix repro (stash Phase 2, keep Phase 1) is observed to fail at
      least once over a longer loop, confirming the loop above exercises the
      real race rather than passing vacuously
- [ ] `tmp/regression/` is git-ignored in practice (`git status` clean after a
      ratchet run)

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for manual confirmation before proceeding. In looped (`--loop`) execution,
this phase's Automated Verification gates advancement automatically; Manual
Verification items are deferred to the end.

---

## Phase 3: Guard against reintroduction, and document it

### Overview

The fix is only durable if the next `@tag :tmp_dir` someone types goes red.
Add a mechanical guard and record the rule where a test author will look.

### Changes Required:

#### 1. Reintroduction guard

**File**: `test/statifier/tmp_dir_test.exs` (extend) or
`test/mix/statifier/tmp_dir_guard_test.exs` (new)
**Changes**: scan `test/**/*.exs` for ExUnit's tag and fail naming the
offending files.

```elixir
  # sabotage: n/a - harness plumbing, guards a convention rather than lib/
  test "no test file uses ExUnit's built-in tmp_dir tag" do
    # Built at runtime so this file does not match its own assertion.
    pattern = ~r/@(?:describe)?tag\s+:#{"tmp" <> "_dir"}\b/

    offenders =
      "test/**/*.exs"
      |> Path.wildcard()
      |> Enum.filter(&(&1 |> File.read!() |> then(fn src -> Regex.match?(pattern, src) end)))

    assert offenders == [],
           "use @tag :isolated_tmp_dir (Statifier.TmpDir) - ExUnit's tag hardcodes a shared tmp/ root (st-0vz): " <>
             Enum.join(offenders, ", ")
  end
```

The self-match dodge matters and should be commented as such; a naive literal
would make the guard fail on itself.

#### 2. Document the convention

**File**: `docs/testing.md`
**Changes**: a short subsection near the regression-ratchet material (around
lines 81-105) stating that the ratchet and the Tests stage run concurrently in
the same directory, that scratch directories therefore come from
`Statifier.TmpDir` with `@tag :isolated_tmp_dir`, that `STATIFIER_TMP_ROOT`
overrides the root, and that ExUnit's `@tag :tmp_dir` is banned with a test
enforcing it. Cite st-0vz.

**File**: `CLAUDE.md`
**Changes**: one line in `## Conventions`, beside the existing XML-heredoc and
sabotage bullets - "Scratch directories in tests: `@tag :isolated_tmp_dir`
(`Statifier.TmpDir`), never ExUnit's `@tag :tmp_dir`". Optional but cheap, and
`CLAUDE.md` is where an agent actually reads conventions.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] The guard is real: temporarily add `@tag :tmp_dir` to any test, confirm
      `mix test` goes red naming that file, then revert
- [x] The guard does not flag itself: `mix test` green with the guard file in
      the scanned set
- [x] Gate guard clean: `mix gate.check` reports no guarded-path change

#### Manual Verification:
- [ ] `docs/testing.md` explains the concurrency reason, not just the rule -
      a rule without its reason gets "simplified" away later
- [ ] Wording in `docs/testing.md` matches the file's existing house style

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for manual confirmation. In looped (`--loop`) execution, Automated
Verification gates advancement; Manual Verification is surfaced at the end.

---

## Testing Strategy

### Unit Tests:

- `Statifier.TmpDir.root/0`: returns `"tmp"` unset; returns the override when
  `STATIFIER_TMP_ROOT` is set. Set and restore the variable inside the test
  (`System.put_env/2` + `on_exit`), and mark those tests `async: false` - env
  is process-global and would otherwise leak across concurrent tests.
- `Statifier.TmpDir.path_for/2`: nests under `root/0`; two different test
  names in the same module produce different paths; escaping matches ExUnit's.
- `Statifier.TmpDir.setup_tmp_dir/1`: creates the directory; empties a
  pre-populated one; is a no-op for an untagged context.
- `Mix.Tasks.Test.Regression.test_env/0`: names `Statifier.TmpDir.env_var/0`
  and differs from `default_root/0`. Sabotage note required (asserts `lib/`).
- Reintroduction guard: `test/**/*.exs` contains no `@tag :tmp_dir`.

### Conformance Tests:

None. This touches no interpreter behavior, so no SCION or W3C test changes
state and nothing is ratcheted in. `test/passing_tests.json` is not edited -
its `test/mix/**` and `test/statifier/**` globs already cover every file this
plan adds or changes.

### Manual Testing Steps:

1. Reproduce first: on Phase 1's tree (helper present, migration not yet
   done), run the concurrency loop with a higher count (say 30) and confirm at
   least one `File.Error ... file already exists` under
   `tmp/Mix.Statifier.RegressionRegistryTest/`.
2. Apply Phase 2, `rm -rf tmp`, rerun the same loop 30 times: all green.
3. Inspect `tmp/` afterwards: the ratchet's directories are under
   `tmp/regression/`, the Tests stage's are directly under `tmp/`, and the two
   sets do not overlap.
4. Run a bare `mix quality` three times in a row; all green, and `mix
   gate.check` reports no guarded-path change on any of them.
5. Confirm `mix gate.verify` reports the run as a full, unscoped gate before
   the work is called done.

## Corpus/Ratchet Notes

`test/passing_tests.json` is **not** edited. The new and modified test files
all fall under its existing `test/mix/**/*_test.exs` and
`test/statifier/**/*_test.exs` globs, so the ratchet's coverage grows with the
work rather than needing a registry change - which is exactly what the bead's
note requires, since shrinking or hand-editing that file would need a human
ledger entry under ADR-0011.

`mix test.regression`'s reported file count should be unchanged or higher
after this plan. A lower count means something narrowed the ratchet and the
work should stop.

## References

- Beads issue: `st-0vz`
- Related ADRs: `docs/adr/0011-quality-gate-config-not-agent-editable.md`
  (guarded paths, human-only ledger),
  `docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md` (why the
  ratchet exists), `docs/adr/0009-ex-quality-as-quality-gate.md`
- Gate ledger: `docs/quality-gate-changes.md`
- Race site: `.../elixir/1.18.3-otp-27/lib/ex_unit/lib/ex_unit/runner.ex:621-633`
- Ratchet stage registration: `.quality.exs:60-88`
- Spawn site to change: `lib/mix/tasks/test.regression.ex:95-100`
- Registry globs: `test/passing_tests.json`
- Support-module precedent: `test/support/case.ex`, `mix.exs:35`,
  `coveralls.json`
- Gate-wiring-assertion precedent:
  `test/mix/statifier/regression_stage_config_test.exs`
- Conventions: `CLAUDE.md`, `docs/testing.md`, `changelog.d/README.md`

## Open Questions and Human Decisions

Recorded rather than resolved, because this plan was produced in an unattended
run. Each carries a recommendation the implementer should follow unless a
human says otherwise.

1. **ADR-0011 ledger entry - not required, and that is load-bearing.**
   This plan deliberately routes around `.quality.exs` and
   `test/passing_tests.json` so that no `docs/quality-gate-changes.md` entry is
   needed and no human approval blocks the work. **If implementation drifts
   into editing either file - including "just" adding an `env:` key to the
   regression stage, or flipping it to `kind: :writer` to serialize it - stop
   and hand it back.** `mix gate.check` will go red, and the required entry
   needs an `Approved-by:` line naming a human. An agent writing that entry for
   itself is precisely what ADR-0011 forbids.
   *Recommendation*: keep the fix inside `lib/mix/tasks/test.regression.ex`,
   `test/support/`, and the test files, as planned.

2. **Serializing the stage was the other viable design.**
   Making the regression stage a `:writer` would move it out of the parallel
   analysis phase and end the race by construction, and it is arguably the more
   honest statement of the constraint. It was rejected only because it is a
   `.quality.exs` edit (question 1) and because it makes a bare `mix quality`
   slower for every run to fix an intermittent fault.
   *Recommendation*: stay with tmp-root isolation. If a human later prefers
   serialization, it is a small, self-contained change plus one ledger entry.

3. **Names.** `@tag :isolated_tmp_dir`, `Statifier.TmpDir`,
   `STATIFIER_TMP_ROOT`, `tmp/regression`. All are the implementer's call and
   none affect correctness; they only need to be consistent across the helper,
   the task, the guard test and the docs.
   *Recommendation*: use them as written, so the docs in Phase 3 need no edits.

4. **Migrating `test/corpus/check_exprs_test.exs`.** It is not in the
   ratchet's globs, so it is not part of the race, and migrating it is
   strictly optional for the acceptance criteria.
   *Recommendation*: migrate it. Phase 3's guard is repo-wide, and a
   one-exception rule is not a rule.

5. **`mix test.baseline` also shells out to `mix test`.** It is not part of
   `mix quality`, so it cannot collide with the gate today, but a developer
   running it beside a test run would hit the same class of collision.
   *Recommendation*: out of scope for st-0vz. File a follow-up bead if it ever
   bites; the fix would be one more `env:` option using the same seam.

6. **Changelog fragment.** None planned:
   `changelog.d/README.md` excludes test-harness and quality-gate tooling, and
   nothing user-visible changes.
   *Recommendation*: no `changelog.d/st-0vz.md`.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The moduledoc explains *why* this exists (the ExUnit hardcoded root)
      rather than only what it does
- [ ] Path shape matches what ExUnit produced, so an existing scratch tree
      under `tmp/` is still recognizable

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for manual confirmation before proceeding. In looped (`--loop`) execution,
this phase's Automated Verification gates advancement automatically (via
`/commit --auto`); Manual Verification items are deferred and surfaced once at
the end.

---

### Phase 2

- [ ] The diff is mechanical: no test's assertions or fixtures changed, only
      tag names and one setup line per module
- [ ] The pre-fix repro (stash Phase 2, keep Phase 1) is observed to fail at
      least once over a longer loop, confirming the loop above exercises the
      real race rather than passing vacuously
- [ ] `tmp/regression/` is git-ignored in practice (`git status` clean after a
      ratchet run)

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for manual confirmation before proceeding. In looped (`--loop`) execution,
this phase's Automated Verification gates advancement automatically; Manual
Verification items are deferred to the end.

---

### Phase 3

- [ ] `docs/testing.md` explains the concurrency reason, not just the rule -
      a rule without its reason gets "simplified" away later
- [ ] Wording in `docs/testing.md` matches the file's existing house style

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause here
for manual confirmation. In looped (`--loop`) execution, Automated
Verification gates advancement; Manual Verification is surfaced at the end.

---
