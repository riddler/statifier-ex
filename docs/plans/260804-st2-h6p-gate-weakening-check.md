# Quality Gate Weakening Check Implementation Plan

## Overview

ADR-0011 states the policy that the quality gate's own config is not
agent-editable. Nothing enforces it mechanically. This plan adds that
enforcement: a `Mix.Statifier.GateGuard` analyzer, a `mix gate.check` task
registered as an ex_quality custom stage, an append-only justification ledger
at `docs/quality-gate-changes.md`, and a `mix gate.verify` wrapper that makes a
scoped run unable to masquerade as a full gate.

Beads issue: st2-h6p (discovered from st2-qw9, which produced ADR-0011).

## Current State Analysis

**What exists:**

- `docs/adr/0011-quality-gate-config-not-agent-editable.md` states the policy
  and explicitly names st2-h6p as "the mechanical half".
- `CLAUDE.md`'s ExQuality section repeats the rule in prose ("Never go green by
  weakening the check").
- `deps/ex_quality/usage-rules.md:154-180` ("Never do these") repeats it again,
  also in prose.
- `.quality.exs` configures `compile: [warnings_as_errors: true]`,
  `credo: [strict: true]`, and a `loop` profile. It already carries a commented
  `custom:` block sketching the regression ratchet as a future custom stage,
  so the custom-stage mechanism is anticipated by the file.
- `.credo.exs:12-13` states the same rule for its own file ("Checks are excluded
  by path or by check parameter, with a comment giving the reason. Never by
  weakening or removing a check.").
- `coveralls.json` holds `minimum_coverage: 90`.
- `lib/mix/tasks/test.regression.ex` and `lib/mix/tasks/test.baseline.ex` are the
  precedent for project mix tasks: a thin `run/1` over an `execute/2` that
  returns `:ok | {:error, String.t()}`, with an injectable `opts[:runner]` so
  tests drive it without a nested `mix test`.
- `lib/mix/statifier/regression_registry.ex` owns `test/passing_tests.json`,
  whose categories are glob-pattern lists (`internal_tests`, `scion_tests`,
  `w3c_tests`).
- `.claude/skills/commit/SKILL.md` Step 0 already refuses to commit on a
  narrowed gate, but that refusal is prose an agent must remember, not a check.

**What is missing:**

- There is no CI in this repo. `ls .github` finds nothing and `git ls-files`
  has no workflow file, so `mix quality` on a developer or agent machine is the
  only enforcement point that exists. A GitHub Actions check is not available
  as a fallback.
- No check reads the diff for gate-config edits, added skip tags, or a shrunk
  ratchet registry.
- No mechanism makes a config change human-visible; today it lands inside a
  commit diff alongside whatever else the branch touched.
- `test/passing_tests.json` can be shrunk by hand with nothing noticing.
  `mix test.baseline` only grows it.

**Key constraints:**

- ex_quality custom stages are declared in `.quality.exs` under `custom:` with
  `key`, `name`, and `command`/`args` (`deps/ex_quality/docs/configuration.md:228-296`).
  A stage may print one JSON document on stdout following the finding contract
  (`deps/ex_quality/docs/stages.md:225-245`); `file` and `message` are the only
  required per-finding keys. `skip_exit_code: 2` lets the command report itself
  as skipped with its own `summary` as the reason.
- `kind: :reader` is correct here: the check reads git and source, and writes
  nothing (`deps/ex_quality/docs/stages.md:191-207`).
- The `loop` profile lists `stages: [:format, :compile, :credo, :test]`, so a
  custom stage is reported as `○ skipped (not in profile :loop)` there and runs
  in a full `mix quality`. That is the intended split: the guard is a
  pre-commit concern, not an every-edit one.
- Coverage minimum is 90%, so the new modules need real test coverage.
- Every new test needs a sabotage note per `CLAUDE.md` / `docs/testing.md`.
- Credo runs strict with `Credo.Check.Design.MissingCheckInConfig` enabled;
  `@moduledoc` and `@spec` on public functions are required.

## Desired End State

A full `mix quality` run reports one more stage:

```
✓ Gate guard: No unjustified gate changes (180ms)
```

and, when the branch edits gate config without a ledger entry:

```
✗ Gate guard: 1 unjustified gate change
────────────────────────────────────────────────────────────
Gate guard - FAILED
────────────────────────────────────────────────────────────
.quality.exs
  1:  [error] gate config changed with no entry in docs/quality-gate-changes.md
      naming it (gate-config)
```

Agents verifying a full gate run `mix gate.verify`, which fails when the
underlying run was scoped or profiled rather than reporting a green.

**How to verify the end state:**

1. `mix quality` is green on a clean branch and lists the Gate guard stage.
2. Temporarily lower `minimum_coverage` in `coveralls.json`; `mix quality` fails
   the Gate guard stage naming that file. Revert.
3. Add `@tag :skip` to an internal test; `mix quality` fails the Gate guard
   stage naming the file and line. Revert.
4. Add a matching ledger entry for either of those; the stage goes green while
   the change is visible in the diff.
5. `mix gate.verify` exits 0 on a clean tree; `mix quality --profile loop`
   cannot satisfy it.

### Key Discoveries:

- The guard's own bootstrap commit edits `.quality.exs` (to register the stage),
  so it trips its own check. Seeding `docs/quality-gate-changes.md` with that
  first entry is not a workaround; it is the mechanism dogfooding itself, and
  the entry documents that the change adds a stage rather than loosening one.
- The check cannot distinguish weakening from strengthening, and should not try.
  Any guarded change requires a ledger entry; the entry is where a human states
  which it was. This matches the issue's own wording: "require it to be called
  out explicitly rather than silently landing in a commit".
- `Mix.Statifier.RegressionRegistry.load/1` already parses
  `test/passing_tests.json`, so ratchet-shrink detection compares parsed pattern
  sets rather than diff lines, and survives reformatting by
  `mix test.baseline`.
- No corpus-generated test carries a skip tag today
  (`grep -rn "@tag :skip" test/ tools/` is empty), so generated files need no
  exemption from the skip-tag rule. A generated skip tag would be exactly the
  thing worth catching.
- ex_quality's `deps/ex_quality/usage-rules.md:165` warns against converting a
  failing built-in check into a custom stage so it can be skipped. That is a
  different thing from adding a genuinely new project check, which is what
  `custom:` is documented for (`configuration.md:228`).

## What We're NOT Doing

- No git hooks. `.git` here is a worktree file, hooks are per-clone and
  uncommitted, and a hook an agent can bypass with `--no-verify` adds a false
  sense of enforcement.
- No CI workflow. This repo has none, and standing one up is its own decision,
  not a side effect of this issue.
- No attempt to classify a config change as weakening versus strengthening. Any
  guarded change needs an entry.
- No blocking of `git commit` itself. The guard is a gate stage; the commit
  skill's existing Step 0 is what connects a red gate to a refused commit.
- No changes to `.credo.exs`, `coveralls.json`, or the thresholds themselves.
- No changelog fragment. Quality gate and agent tooling are explicitly listed as
  "no fragment" in `changelog.d/README.md` and in the commit skill's Step 1.6.
- No `mix quality` plugin or upstream ex_quality change. Everything lands in
  this repo.
- No history rewrite or retroactive audit of past commits. The guard reads the
  current branch against its base ref, nothing older.

## Implementation Approach

Three phases, split so each one leaves a green `mix quality` and is
independently committable:

1. The analyzer, pure and unit-tested, with git access isolated behind an
   injectable function. Nothing is wired into the gate yet, so the phase adds a
   module and its tests and nothing else can break.
2. The mix task, the `.quality.exs` registration, the ledger with its bootstrap
   entry, and a self-guard test. This is the phase where the check becomes
   live, and where it must clear itself.
3. `mix gate.verify` plus the agent-facing documentation that names it.

Phases 1 and 2 are deliberately not merged: phase 1's module is fully exercised
by its own tests, so its gate is meaningful on its own, and keeping the wiring
separate means the bootstrap ledger entry describes exactly one commit's worth
of change.

## Phase 1: Gate Guard Analyzer

### Overview

A pure module that turns a diff plus two registry snapshots into a list of
findings. All git access lives behind injected functions so the tests never
need a fixture repository.

### Changes Required:

#### 1. The analyzer

**File**: `lib/mix/statifier/gate_guard.ex` (new)
**Changes**: New module `Mix.Statifier.GateGuard`.

Public surface:

```elixir
@type finding :: %{
        file: String.t(),
        line: pos_integer() | nil,
        severity: String.t(),
        check: String.t(),
        message: String.t()
      }

@type source :: %{
        diff: String.t(),
        base_registry: String.t() | nil,
        head_registry: String.t() | nil
      }

@spec guarded_paths() :: [String.t()]
@spec analyze(source :: source()) :: [finding()]
@spec collect(opts :: keyword()) :: {:ok, source()} | {:error, String.t()} | :no_base_ref
```

`collect/1` resolves the base ref and shells out to git; `opts[:runner]`
replaces the shell-out with a function of an argument list returning
`{output, status}`, mirroring `Mix.Tasks.Test.Regression`'s `opts[:runner]`
(`lib/mix/tasks/test.regression.ex:53`).

Base ref resolution, in order: `opts[:base]`, then `origin/main`, then `main`.
When none resolves, `collect/1` returns `:no_base_ref` rather than guessing;
the task turns that into a skip.

The diff is `git diff <merge-base> --unified=0` against the merge base of the
base ref and `HEAD`. Plain `git diff` (not `...`) so uncommitted working-tree
changes are included; the guard has to see a change before it is committed, not
after.

Checks, all four producing the same `finding()` shape:

| Check key | Fires on |
|---|---|
| `gate-config` | any hunk in `.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf` |
| `gate-config` (mix.exs) | an added or removed `mix.exs` line matching `test_coverage`, `dialyzer:`, `warnings_as_errors`, `aliases`, `:ex_quality`, `:credo`, `:excoveralls`, `:dialyxir` |
| `skip-tag` | an added line under `test/` matching `@tag :skip`, `@tag :pending`, `@moduletag :skip`, `@moduletag :pending`, `@tag skip:`, `@tag pending:` |
| `ratchet-shrink` | a glob pattern present in the base `test/passing_tests.json` and absent from the head one, per category |

`mix.exs` is matched by line content rather than by path because most `mix.exs`
edits (a dep bump, a new alias unrelated to the gate) have nothing to do with
the gate, and a path-level guard would make every dependency change require a
ledger entry.

The skip-tag scan covers generated corpus directories too. Nothing generated
emits a skip tag today, and a generated one is worth catching.

Ratchet shrink compares pattern sets, so `mix test.baseline`'s reformatting is
invisible and only an actually removed pattern is a finding.

#### 2. Ledger clearance

**File**: `lib/mix/statifier/gate_guard.ex`
**Changes**: Findings are filtered against ledger lines added in the same diff.

A finding for path `P` is cleared when the diff's added lines for
`docs/quality-gate-changes.md` contain `P` as a substring **and** those added
lines contain an `Approved-by:` line. Both conditions read off the same diff the
findings came from, so a ledger entry written in an earlier commit on another
branch clears nothing here.

An uncleared finding carries the message:

```
gate config changed with no entry in docs/quality-gate-changes.md naming it
```

with the check key and, for skip tags, the line number from the hunk header.

#### 3. Unit tests

**File**: `test/mix/statifier/gate_guard_test.exs` (new)
**Changes**: Table-driven tests over hand-written diff strings.

Cases: each guarded path fires; an unrelated `mix.exs` dep bump does not fire;
each gate-relevant `mix.exs` line does fire; each skip-tag form fires with its
line number; a `# @tag :skip` inside a heredoc or comment is out of scope and
documented as such; a removed registry pattern fires; a reformatted registry
with the same patterns does not; a ledger entry naming the path clears it; a
ledger entry without `Approved-by:` does not clear it; a ledger entry naming a
different path does not clear it; `collect/1` with an injected runner returns
`:no_base_ref` when no base resolves.

Every test carries its sabotage note.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `Mix.Statifier.GateGuard` is covered at or above the 90% minimum (the
      Tests stage reports per-module coverage failures by name)
- [x] `mix test test/mix/statifier/gate_guard_test.exs` passes on its own

#### Manual Verification:
- [x] Each test's sabotage note names a real mutation that was observed red
- [x] The guarded-path list matches what ADR-0011 actually names, with no path
      added because it seemed related

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation before proceeding. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred and
surfaced once at the end.

---

## Phase 2: Wire the Stage and Seed the Ledger

### Overview

The task, the registration, the ledger, and a test that keeps the registration
from quietly disappearing. After this phase the check is live.

### Changes Required:

#### 1. The mix task

**File**: `lib/mix/tasks/gate.check.ex` (new)
**Changes**: `Mix.Tasks.Gate.Check`, following the `test.regression` shape.

```elixir
@switches [base: :string, format: :string]

@spec execute(argv :: [String.t()], opts :: keyword()) ::
        {:ok, iodata()} | {:skip, String.t()} | {:error, iodata()}
```

`run/1` prints what `execute/2` returns and sets the exit status: 0 for `:ok`,
2 for `:skip`, 1 for `:error`. `--format json` (what the stage passes) prints
the ex_quality finding contract:

```json
{
  "summary": "1 unjustified gate change",
  "stats": {"finding_count": 1},
  "findings": [
    {
      "file": ".quality.exs",
      "line": null,
      "severity": "error",
      "check": "gate-config",
      "message": "gate config changed with no entry in docs/quality-gate-changes.md naming it"
    }
  ]
}
```

A skip writes its own `summary` (`"no base ref: neither origin/main nor main
resolves"`) rather than relying on the first line of output, per
`deps/ex_quality/docs/stages.md:250-262`.

Without `--format json` the task prints human-readable lines, so it is usable
directly from a shell.

**File**: `test/mix/tasks/gate_check_test.exs` (new)
**Changes**: Drives `execute/2` with an injected runner over synthetic diffs;
asserts the JSON shape parses and carries the expected keys, that the skip path
returns `{:skip, _}` with a written summary, and that a cleared finding returns
`{:ok, _}`. Sabotage notes on each.

#### 2. Registration

**File**: `.quality.exs`
**Changes**: Replace the commented `custom:` sketch with a live block that keeps
the ratchet comment.

```elixir
custom: [
  [
    key: :gate_guard,
    name: "Gate guard",
    command: "mix",
    args: ["gate.check", "--format", "json"],
    kind: :reader,
    skip_exit_code: 2
  ]
]
```

`kind: :reader` because the task reads git and source and writes nothing.
`key`/`name` collide with no built-in stage. The `loop` profile's `stages:` list
is left alone, so the guard is skipped there and runs in a full `mix quality`.

#### 3. The ledger

**File**: `docs/quality-gate-changes.md` (new)
**Changes**: The append-only justification log, seeded with this commit's own
entry.

```markdown
# Quality gate change log

Every change to the quality gate's configuration gets an entry here, per
ADR-0011. `mix gate.check` fails the Gate guard stage when a guarded file
changes and no entry added in the same diff names it.

An entry needs a `## <date> - <issue>` heading, an `Approved-by:` line naming
the human who made the call, one `- <path>: <what changed>` bullet per guarded
path, and a reason. The check is mechanical about the path and the
`Approved-by:` line; the reason is for the reader.

Adding an entry is not permission to weaken a check. ADR-0011 says a genuinely
wrong check is a human call, and this file is where that call is recorded, not
where an agent grants itself one.

## 2026-08-04 - st2-h6p

Approved-by: JohnnyT (in session)

- .quality.exs: registers the gate_guard custom stage

Reason: bootstraps the check itself. Adds a stage to the run; loosens nothing,
skips nothing, and lowers no threshold.
```

#### 4. Self-guard test

**File**: `test/mix/statifier/gate_guard_config_test.exs` (new)
**Changes**: Reads `.quality.exs` and asserts a `custom:` entry with
`key: :gate_guard` exists and that its `args` include `gate.check`. Removing the
registration is itself a `.quality.exs` change the guard would flag, but only if
the guard still runs; this test makes the removal turn the built-in Tests stage
red as well, so the two checks cover each other.

Sabotage note: delete the `custom:` entry, watch it go red, restore.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes and reports the new stage: `mix quality`
- [x] `mix gate.check` exits 0 on the branch as committed
- [x] `mix gate.check --format json` emits a document that `Jason`-free
      `:json` decoding accepts and that carries `summary`, `stats`, `findings`
- [x] `mix quality --profile loop` reports `○ Gate guard: skipped (not in
      profile :loop)` and stays green

#### Manual Verification:
- [x] Lowering `minimum_coverage` in `coveralls.json` makes `mix quality` fail
      the Gate guard stage naming that file; reverted afterwards
- [x] Adding `@tag :skip` to an internal test makes the stage fail naming the
      file and line; reverted afterwards
- [x] Adding a matching ledger entry clears the finding and the stage goes green
- [x] Deleting a pattern from `test/passing_tests.json` fires `ratchet-shrink`;
      reverted afterwards
- [x] The stage's failure output reads as an instruction to a human, not as a
      hint to edit the ledger and move on

**Implementation Note**: Same as Phase 1. The bootstrap ledger entry must be in
the same commit as the `.quality.exs` change, or the guard fails its own commit.

---

## Phase 3: Scoped-Run Attestation and Agent Documentation

### Overview

Closes the issue's third bullet: a scoped or profiled run must not be reportable
as a full gate. Then points the agent-facing documentation at the new commands.

### Changes Required:

#### 1. The verify task

**File**: `lib/mix/tasks/gate.verify.ex` (new)
**Changes**: `Mix.Tasks.Gate.Verify` runs the full gate and attests to its
breadth.

It shells out to `mix quality --format json --report -`, parses the JSON, and
fails unless all of:

- root `status` is `"ok"`
- root `scope` is `"all"`
- root `profile` is absent or null
- no stage has `status: "skipped"` with a run-narrowing reason (`--quick`,
  `--until-first-failure`, `not in profile`, `--skip`)

A stage skipped for a project-level reason (`:credo not installed`, a custom
stage's own `skip_exit_code`) is reported in the output but does not fail the
attestation, because it is a gap in what the project checks rather than a gap in
this run. The distinction is ex_quality's own
(`deps/ex_quality/usage-rules.md:102-105`), and the output states which kind it
found.

Success prints one line:

```
Full gate green: scope all, no profile, 9 stages considered.
```

Failure names the narrowing:

```
Not a full gate: run used profile :loop and scope changed.
```

`opts[:runner]` injects the shell-out for tests, as in `test.regression`.

**File**: `test/mix/tasks/gate_verify_test.exs` (new)
**Changes**: Feeds synthetic report JSON through an injected runner: a full green
report attests; a `profile: "loop"` report fails; a `scope: "changed"` report
fails; a report with a failing stage fails; a report with a stage skipped for a
project-level reason attests and says so. Sabotage notes on each.

#### 2. Agent-facing documentation

**File**: `CLAUDE.md`
**Changes**: In the ExQuality section, under "Never go green by weakening the
check", add that the rule is now enforced by the Gate guard stage, that
`docs/quality-gate-changes.md` is where a legitimate change is recorded, and
that `mix gate.verify` is how to prove a run was a full gate. Cite ADR-0011.

**File**: `.claude/skills/commit/SKILL.md`
**Changes**: Step 0 keeps `mix quality` as the gate and adds `mix gate.verify`
as the check that the gate was not narrowed, replacing the prose-only refusal
condition with a command whose exit status decides it. The auto-mode refusal
list gains the Gate guard case explicitly.

**File**: `docs/workflow.md`
**Changes**: One line in the gate discussion pointing at ADR-0011, the Gate
guard stage, and the ledger.

Grep for other agent-facing files that name the full gate
(`.claude/skills/implement-plan/SKILL.md`, `.claude/skills/merge-request/SKILL.md`,
`AGENTS.md`) and update any that describe how a full gate is confirmed. Do not
rewrite any that merely mention `mix quality` in passing.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `mix gate.verify` exits 0 on the clean branch and prints the attestation
      line
- [x] `mix gate.verify` output names `scope all` and no profile

#### Manual Verification:
- [x] A deliberately scoped run cannot satisfy `mix gate.verify`
- [x] The commit skill's Step 0, read end to end, is consistent with the new
      commands and has no leftover instruction the tasks now supersede
- [x] `CLAUDE.md`'s ExQuality section still reads as rules, not as a tour of the
      implementation

**Implementation Note**: Same as Phase 1. If a documentation-only follow-up edit
is made after the code commit, the commit skill's no-Elixir carve-out applies to
it and must be stated in the report.

---

## Testing Strategy

### Unit Tests:

- `test/mix/statifier/gate_guard_test.exs` - analyzer behavior over synthetic
  diffs: every guarded path, every skip-tag form, gate-relevant versus
  irrelevant `mix.exs` lines, ratchet pattern removal versus reformatting, and
  each ledger clearance rule (naming path, `Approved-by:` present, wrong path).
- `test/mix/tasks/gate_check_test.exs` - task behavior: JSON contract shape,
  exit statuses 0/1/2, the written skip summary.
- `test/mix/tasks/gate_verify_test.exs` - attestation over synthetic report JSON.
- `test/mix/statifier/gate_guard_config_test.exs` - `.quality.exs` still
  registers the stage.

Pattern-matching assertions over multiple `assert`s, per `CLAUDE.md`. Every test
carries a sabotage note; harness plumbing states its exemption rather than
omitting the line.

### Conformance Tests:

None. This issue touches no interpreter behavior, so no SCION or W3C test
changes state and nothing is ratcheted. `test/passing_tests.json`'s
`internal_tests` globs already cover `test/mix/**/*_test.exs`, so the new tests
join the ratchet without an edit to the registry.

### Manual Testing Steps:

1. Lower `minimum_coverage` in `coveralls.json` to 50, run `mix quality`,
   confirm the Gate guard stage fails naming `coveralls.json`. Revert.
2. Add an entry to `docs/quality-gate-changes.md` naming `coveralls.json` with
   an `Approved-by:` line, re-run, confirm the stage is green. Revert both.
3. Add `@tag :skip` above a test in `test/statifier/`, run `mix quality`,
   confirm the finding carries the right file and line. Revert.
4. Delete a glob from `internal_tests` in `test/passing_tests.json`, run
   `mix gate.check`, confirm `ratchet-shrink` fires. Revert.
5. Run `mix quality --profile loop`, confirm the stage reports as skipped naming
   the profile rather than passing silently.
6. Run `mix gate.verify` after a `--profile loop` run to confirm the attestation
   is about the run it performs, not about a previous run's leftovers.
7. From a detached state with no `origin/main` and no `main` reachable, confirm
   `mix gate.check` exits 2 and the stage reports skipped with its own reason.

## Corpus/Ratchet Notes

No corpus regeneration. No `test/passing_tests.json` edit: the existing
`internal_tests` globs (`test/mix/**/*_test.exs`) already cover every test this
plan adds. The `ratchet-shrink` check reads that file but never writes it;
growing it stays `mix test.baseline`'s job.

## References

- Beads issue: `st2-h6p`; policy half: `st2-qw9` (closed, PR #25)
- ADR: `docs/adr/0011-quality-gate-config-not-agent-editable.md`
- ADR: `docs/adr/0009-ex-quality-as-quality-gate.md`
- Custom stage contract: `deps/ex_quality/docs/configuration.md:228-296`,
  `deps/ex_quality/docs/stages.md:179-262`
- Report shape: `deps/ex_quality/docs/reports.md:60-150`,
  `deps/ex_quality/usage-rules.md:182-231`
- Task pattern to follow: `lib/mix/tasks/test.regression.ex:34-59`
- Registry API: `lib/mix/statifier/regression_registry.ex:76`, `:149`, `:193`
- Current gate config: `.quality.exs`, `.credo.exs:12-13`, `coveralls.json`
- Commit-time enforcement point: `.claude/skills/commit/SKILL.md` Step 0
