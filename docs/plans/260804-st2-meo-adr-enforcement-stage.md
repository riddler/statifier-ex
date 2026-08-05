# ADR-Enforcement Custom Stage Implementation Plan

## Overview

Add a custom `mix quality` stage that checks changed code against the ADRs in
`docs/adr/` and flags likely violations or undocumented deviations, so drift
from an accepted architectural decision is caught by the gate instead of
relying on review. Beads issue: st2-meo.

## Current State Analysis

The gate (`mix quality`, ADR-0009) has one project-specific custom stage
today: `gate_guard` (`lib/mix/statifier/gate_guard.ex`,
`lib/mix/tasks/gate.check.ex`), which enforces ADR-0011 (gate config is not
agent-editable) by diffing the branch against its base and flagging edits to
guarded paths with no matching entry in `docs/quality-gate-changes.md`. It is
a pure `analyze/1` over a parsed diff plus a `collect/1` that talks to git via
an injectable `opts[:runner]`, wired into `.quality.exs` as a `kind: :reader`
custom stage, absent from the `:loop` profile.

There is no interpreter code yet - `lib/` contains only the mix-task
machinery above and the `mix new` placeholder `lib/statifier.ex`. The ADRs
this issue is about (0002 literal Appendix D port, 0003 pure core with
effects, 0004 predicator-only datamodel, 0008 UXID identifiers, 0012
debuggability) describe a core that has not been written yet. The stage
being built here is forward-looking infrastructure: it has nothing real to
catch until the interpreter lands, so its correctness has to be established
against synthetic diffs, the same way `gate_guard_test.exs` tests `GateGuard`
without a fixture repository.

### Key Discoveries

- `deps/ex_quality/docs/stages.md`'s custom-stage contract: a `kind: :reader`
  stage prints/parses the same JSON finding shape as any other
  (`file`, `line`, `severity`, `check`, `message`), and `skip_exit_code: 2`
  turns "not applicable" into a skip with its own reason instead of a failure.
- `docs/architecture.md`'s layer list names the interpreter layer explicitly
  ("Interpreter (pure Appendix D core)") and says session/send/invoke IDs are
  UXIDs, session ID immutable per session. This plan's path convention
  (`lib/statifier/interpreter*` for naming, `lib/statifier/` minus
  `lib/statifier/session.ex` for the effects/UXID checks) follows that layer
  naming; it is a convention this plan is establishing now, not one already
  in the code, and the check needs no change once real interpreter files land
  as long as they follow it.
- ADR-0003 names `Statifier.Session` (a GenServer) as *the* production effect
  interpreter, so it is the one core-adjacent module allowed to do I/O; the
  effects check must exclude it by design, not flag it as a violation.
- The issue's own text splits the work: mechanical, deterministic checks for
  ADRs whose rule is a name/pattern/dependency-boundary check (0002, 0003),
  and a narrowly-scoped LLM fallback only for ADRs whose rule is a judgment
  call (its example is exactly this shape). Of the ADR set, 0012
  (debuggability: microstep resumability, trace effects at phase boundaries,
  preserved source locations, step counters) is the one whose rule cannot be
  reduced to a name or call-site pattern - it is about whether a design
  choice preserves seams, which is inherently interpretive. The rest (0001
  meta/process, 0005 storage model, 0006/0007/0009/0010/0011 already covered
  by other stages or process-only) are out of scope; see below.
- The bd notes on this issue add an adversarial-verification requirement for
  the LLM fallback that goes beyond a single pass: a finding must survive an
  independent refute attempt before it gates the build, the same
  propose-then-refute shape `/code-review`'s adversarial-verify step uses.
  That requirement, plus "false positives are expensive in a gate that must
  stay green," is why the LLM stage is scoped to one ADR and skips cleanly
  (rather than failing) when it cannot run.
- No HTTP client dependency exists in `mix.exs` yet. The LLM stage needs one;
  `Req` is the natural choice (small, dev-only, no transitive surprises) and
  does not touch any gate-guarded path (`mix.exs`'s guard pattern matches
  `test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir`,
  none of which a plain dep addition trips).
- Both new custom stages are additions to `.quality.exs`, a gate-guarded path
  under ADR-0011/`gate_guard`. Each phase's `.quality.exs` edit needs its own
  `docs/quality-gate-changes.md` entry in the same diff, following the
  `st2-h6p` precedent entry already in that file, or `gate_guard`'s own stage
  will fail the gate on this branch's work.

## Desired End State

`mix quality` reports two additional stages:

- **ADR guard** (`mix adr.check`): a fast, deterministic, offline stage that
  flags likely violations of ADR-0002 (Appendix D naming), ADR-0003 (pure
  core / effects boundary), ADR-0004 (no eval, no ECMAScript), and ADR-0008
  (UXID identifiers) in the diff against the branch's base, unless the flagged
  line carries an inline comment citing the ADR or "deviation" as the
  mechanical reason (matching the existing CLAUDE.md convention for citing
  deviations inline). It runs in the full gate, not in `--profile loop`.
- **ADR judge** (`mix adr.judge`): an LLM-backed stage scoped to ADR-0012,
  gated on `ANTHROPIC_API_KEY` being set and on the diff touching
  `lib/statifier/` files. A candidate finding only reaches gate-failure status
  if an independent refute pass fails to overturn it; otherwise it is
  dropped. Without an API key, or with no core files in the diff, the stage
  reports itself skipped with a specific reason rather than failing or
  silently passing.

Verify by running `mix quality` on this branch (both stages report, neither
fails against the branch's own diff, since this branch does not touch
`lib/statifier/`), and by the unit test suites for both stages passing
against synthetic diff/response fixtures with no real interpreter code
required.

## What We're NOT Doing

- No AST-based analysis. Both stages are line/diff based, the same
  granularity `gate_guard` already uses; an AST pass is a larger investment
  this issue's mechanical checks do not need.
- No coverage of ADR-0001 (records the ADR process itself), ADR-0005 (storage
  model - there is no `Machine`/config code yet to check against, and the
  rule is a data-structure choice more suited to review than a diff grep),
  ADR-0006 (corpus/ratchet reuse - already the regression-ratchet custom
  stage's job), ADR-0007 (beads for issue tracking - process, not code
  shape), ADR-0009/ADR-0011 (already `gate_guard`'s job), or ADR-0010
  (worktrees - process, not code shape).
- Not adding either stage to the `:loop` profile. `gate_guard` sets this
  precedent: a pre-commit concern, not an every-edit one, and the LLM stage
  in particular should not add network latency to the inner loop.
- Not validating either stage against real interpreter code, because none
  exists. Both are tested against hand-written diff/response fixtures via
  injectable collaborators (`opts[:runner]` for git, `opts[:caller]` for the
  LLM calls), the same pattern `gate_guard_test.exs` uses.
- Not building a general "ask an LLM whether this diff violates any ADR"
  stage. The LLM path is scoped to ADR-0012 specifically; extending it to
  another judgment-call ADR is a registry entry, not a redesign, but that
  extension is left for a future issue when a second such ADR exists.
- Not retrofitting `gate_guard`'s diff-parsing into a shared module. Both new
  modules need a small, similar git-diff collector; duplicating the ~50 lines
  is the lower-risk choice given `gate_guard` is already shipped, tested, and
  in production use as of st2-h6p - refactoring it is a separate concern from
  adding this stage.

## Implementation Approach

Two independent stages, two phases. Phase 1 is the mechanical stage: pure,
offline, no new runtime dependency beyond what `gate_guard` already
established as a pattern. Phase 2 is the LLM stage: it depends on nothing
Phase 1 built (separate module, separate mix task, separate `.quality.exs`
entry) so it can be its own gate-verifiable, committable increment, and so a
reviewer can accept the mechanical stage without also having to reason about
network calls and API keys in the same diff.

Both stages follow `gate_guard`'s shape: a pure `analyze/1` over parsed input,
a `collect/1` that gathers that input via an injectable collaborator, and a
thin `Mix.Tasks.*` wrapper that turns the result into the ExQuality JSON
finding contract.

## Phase 1: Mechanical ADR guard (ADR-0002, 0003, 0004, 0008)

### Overview

A `kind: :reader` custom stage that diffs the branch against its base (same
base-resolution order as `gate_guard`: `--base`, then `origin/main`, then
`main`) and flags lines added under `lib/` that look like a likely violation
of one of the four mechanically-checkable ADRs, unless an inline comment on
or immediately above the line cites the ADR number or the word "deviation".

### Changes Required

#### 1. `Mix.Statifier.AdrGuard`

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: New module, structured like `GateGuard`.

```elixir
defmodule Mix.Statifier.AdrGuard do
  @moduledoc """
  Flags likely violations of the mechanically-checkable ADRs in `docs/adr/`
  in the current branch's diff against its base.

  Covers ADR-0002 (Appendix D naming), ADR-0003 (pure core / effects
  boundary), ADR-0004 (no eval, no ECMAScript), and ADR-0008 (UXID
  identifiers). Each check is a name or call-site pattern over lines the
  diff adds - deliberately not an AST pass - so a false positive is cleared
  the same way an inline deviation is cited elsewhere in this project: a
  comment on or above the flagged line naming the ADR or the word
  "deviation".

  `analyze/1` is pure; `collect/1` talks to git via `opts[:runner]`, mirroring
  `Mix.Statifier.GateGuard`.
  """

  @core_prefix "lib/statifier/"
  @effect_interpreter_paths ["lib/statifier/session.ex"]
  @interpreter_pattern ~r{^lib/statifier/interpreter}

  @appendix_d_names ~w(
    main_event_loop select_transitions select_eventless_transitions
    remove_conflicting_transitions get_transition_domain compute_exit_set
    compute_entry_set add_descendant_states_to_enter
    add_ancestor_states_to_enter microstep enter_states exit_states
    exit_interpreter is_in_final_state
  )

  @naming_similarity_threshold 0.90

  @effect_call_pattern ~r/\b(GenServer\.|use\s+GenServer\b|Process\.(send|send_after|exit)\(|
                           :timer\.|Logger\.\w+\(|IO\.(puts|write|inspect)\(|File\.\w+\(|
                           System\.cmd\(|Node\.\w+\(|:ets\.|Agent\.\w+\(|
                           Task\.(start|async)\(|\bspawn\(|\breceive\b)/x

  @eval_call_pattern ~r/\bCode\.eval_(string|quoted)\(/

  @uxid_adhoc_pattern ~r/(:crypto\.strong_rand_bytes|UUID\.uuid4|Ecto\.UUID\.generate|
                          System\.unique_integer|:erlang\.unique_integer)\(/x

  @escape_pattern ~r/ADR-0\d{3}|deviation/i

  # ... parse_diff/collect/git plumbing mirrors GateGuard; see that module.

  def analyze(source) do
    files = parse_diff(source.diff)

    naming_findings(files) ++
      effects_findings(files) ++
      eval_findings(files) ++
      uxid_findings(files)
  end
end
```

Each `*_findings/1` function:

- **naming_findings/1** - scoped to paths matching `@interpreter_pattern`.
  For each added `def`/`defp` line, normalizes the name (strip `?`/`!`,
  remove underscores, downcase) and skips it if the normalized form exactly
  matches a normalized Appendix D name (compliant) or has no near match at
  all (unrelated function). Flags it when the normalized name is *close but
  not exact* - `String.jaro_distance/2` against every normalized canonical
  name, threshold `@naming_similarity_threshold` - which is exactly the
  "independent re-derivation with heuristic naming" shape ADR-0002's context
  describes, not exact spec spelling and not an unrelated helper.
- **effects_findings/1** - scoped to `@core_prefix` minus
  `@effect_interpreter_paths`, flags added lines matching
  `@effect_call_pattern`.
- **eval_findings/1** - scoped to all of `lib/` (an eval is a violation
  wherever it appears, not just in the core), flags added lines matching
  `@eval_call_pattern`.
- **uxid_findings/1** - scoped to `@core_prefix` (session.ex included - it is
  exactly where session IDs are generated per ADR-0008), flags added lines
  matching `@uxid_adhoc_pattern`.

Every finding is dropped if the added line, or the line immediately before it
in the same hunk, matches `@escape_pattern` - the inline-citation escape
hatch CLAUDE.md already documents for Appendix D deviations, generalized to
all four checks here.

`finding.check` is `"adr-0002-naming"`, `"adr-0003-effects"`,
`"adr-0004-eval"`, or `"adr-0008-uxid"` so a failure names which ADR, per the
issue's "report per-ADR, not just pass/fail" requirement.

#### 2. `Mix.Tasks.Adr.Check`

**File**: `lib/mix/tasks/adr.check.ex`
**Changes**: New mix task, structured like `Mix.Tasks.Gate.Check` - same
`--base`/`--format json` switches, same `{:ok, ...} | {:skip, ...} |
{:error, ...}` shape, `skip_exit_code` 2 when no base ref resolves.

#### 3. Wire into the gate

**File**: `.quality.exs`
**Changes**: Add a second entry to `custom:`:

```elixir
[
  key: :adr_guard,
  name: "ADR guard",
  command: "mix",
  args: ["adr.check", "--format", "json"],
  kind: :reader,
  skip_exit_code: 2
]
```

Not added to the `:loop` profile's `stages:` list, matching `gate_guard`.

#### 4. Ledger entry

**File**: `docs/quality-gate-changes.md`
**Changes**: New `## 2026-08-04 - st2-meo` section, `Approved-by:` line,
`- .quality.exs: registers the adr_guard custom stage` bullet, and a reason
(adds a stage; loosens nothing).

### Success Criteria

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `mix test test/mix/statifier/adr_guard_test.exs test/mix/tasks/adr_check_test.exs`
      passes on its own

#### Manual Verification:
- [ ] Feeding a synthetic diff that adds `defp exitset(...)` inside
      `lib/statifier/interpreter.ex` produces an `adr-0002-naming` finding;
      adding `defp compute_exit_set(...)` (exact spec name) produces none
- [ ] A synthetic diff adding `GenServer.call(...)` inside
      `lib/statifier/interpreter.ex` produces an `adr-0003-effects` finding;
      the same line inside `lib/statifier/session.ex` produces none
- [ ] A finding is cleared when the added line carries a trailing `# ADR-0003:
      ...` comment or the previous line does
- [ ] `mix adr.check --format json` on a diff with no `lib/` changes reports
      zero findings, not a skip (this stage only skips on no-base-ref, unlike
      `adr_judge` in Phase 2)

**Implementation Note**: Use `mix quality --profile loop` between edits;
`mix quality` as the phase gate. Sabotage each new test per CLAUDE.md's
testing convention (flip a pattern or threshold, confirm red, revert, note
the mutation in a one-line comment above the test, mirroring
`gate_guard_test.exs`'s existing sabotage comments).

---

## Phase 2: LLM-based ADR judge (ADR-0012) with adversarial verification

**Split out to its own issue, `st2-qcc` (2026-08-04).** It is local-only by
design - it makes model calls, so it never runs in CI or in `--profile loop` -
and keeping it off st2-meo lets the mechanical, offline guard in Phase 1 land
and be reviewed without network calls and API keys in the same diff. The rest
of this section stands as that issue's design.

### Overview

A `kind: :reader` custom stage scoped to ADR-0012 (debuggability), the one
ADR in scope whose rule - does this change preserve the seams future step
tooling needs (resumable microstep state, trace effects at phase boundaries,
preserved source locations, stamped step counters/causes) - is a judgment
call, not a name or call-site pattern. A candidate finding is generated by
one model call, then challenged by an independent second call prompted to
refute it; the finding is only reported (and so only gates the build) if the
refute pass fails to overturn it. The stage skips cleanly, rather than
failing, when it has nothing to check or no key is configured.

### Changes Required

#### 1. Add an HTTP client dependency

**File**: `mix.exs`
**Changes**: Add `{:req, "~> 0.5", only: :dev, runtime: false}` to `deps/0`.
Does not touch any gate-guarded path or match `gate_guard`'s `mix.exs`
pattern, so no ledger entry needed for this line.

#### 2. `Mix.Statifier.AdrJudge`

**File**: `lib/mix/statifier/adr_judge.ex`
**Changes**: New module.

```elixir
defmodule Mix.Statifier.AdrJudge do
  @moduledoc """
  Judges the current branch's diff against ADR-0012 (debuggability designed
  into the core) using two independent model calls: one proposes violations,
  a second is prompted to refute each one. Only a proposed violation the
  refute pass fails to overturn becomes a finding - a single pass reporting
  whatever it first notices is exactly what the adversarial-verification
  requirement on this check rules out, because a false positive here blocks
  a commit (CLAUDE.md: "never go green by weakening the check" means the fix
  for a bad finding has to be "the check was wrong," not "disable the
  check" - so the bar to reach gate-failure status is higher than an FYI).

  `analyze/2` is pure given a diff and an `opts[:caller]` (a function from a
  prompt to a response, real calls going through `Req` in production, a stub
  in tests). `collect/1` gathers the diff the same way
  `Mix.Statifier.GateGuard` and `Mix.Statifier.AdrGuard` do.
  """

  @core_prefix "lib/statifier/"
  @adr_path "docs/adr/0012-debuggability-designed-into-the-core.md"
  @api_key_env "ANTHROPIC_API_KEY"
  @default_model "claude-haiku-4-5-20251001"

  # ... collect/1 (git plumbing, shared shape with GateGuard/AdrGuard),
  # propose_prompt/2, refute_prompt/2, response parsing.
end
```

- `collect/1` returns `:no_base_ref` (mirrors the other two guards),
  `:no_api_key` when `System.get_env(@api_key_env)` is unset, or
  `:no_core_changes` when the diff touches no `lib/statifier/` files - all
  three become a skip in the task, not a failure.
- The propose prompt includes the full text of ADR-0012 and the diff hunks
  touching `lib/statifier/`, and asks for a list of candidate violations,
  each naming a `file`, `line`, and a one-sentence claim.
- For each candidate, the refute prompt asks the model to argue against the
  claim being a real ADR-0012 violation, defaulting to "not a violation" on
  an ambiguous verdict (the adversarial pattern's stated default, matching
  `/code-review`'s propose-then-refute stages: refute wins ties).
- A candidate becomes a finding (`check: "adr-0012-debuggability"`) only when
  the refute pass explicitly fails to overturn it.
- Model name is `System.get_env("STATIFIER_ADR_JUDGE_MODEL", @default_model)`
  so a stronger model can be substituted without a code change.

#### 3. `Mix.Tasks.Adr.Judge`

**File**: `lib/mix/tasks/adr.judge.ex`
**Changes**: New mix task mirroring `Mix.Tasks.Gate.Check`'s shape:
`{:ok, ...} | {:skip, ...} | {:error, ...}`, `--format json`, `skip_exit_code`
2 for all three `collect/1` skip reasons above, each with its own
human-readable reason string (`"ANTHROPIC_API_KEY not set"`,
`"no lib/statifier/ files in this diff"`, the existing no-base-ref reason).

#### 4. Wire into the gate

**File**: `.quality.exs`
**Changes**: Add a third `custom:` entry:

```elixir
[
  key: :adr_judge,
  name: "ADR judge",
  command: "mix",
  args: ["adr.judge", "--format", "json"],
  kind: :reader,
  skip_exit_code: 2
]
```

Not added to the `:loop` profile.

#### 5. Ledger entry

**File**: `docs/quality-gate-changes.md`
**Changes**: New `## 2026-08-04 - st2-meo` section (or a second bullet under
Phase 1's, if these land in the same commit's diff against main - one bullet
per guarded path changed, per that file's own format), naming
`.quality.exs: registers the adr_judge custom stage`, reason: adds a stage;
loosens nothing.

### Success Criteria

#### Automated Verification:
- [ ] Full quality gate passes: `mix quality`
- [ ] `mix test test/mix/statifier/adr_judge_test.exs test/mix/tasks/adr_judge_test.exs`
      passes on its own, using a stub `opts[:caller]` - no real network call
      in the suite

#### Manual Verification:
- [ ] With `ANTHROPIC_API_KEY` unset, `mix adr.judge` reports skipped with
      reason `"ANTHROPIC_API_KEY not set"`, not a failure
- [ ] With the key set but a diff touching only `docs/`, reports skipped with
      reason `"no lib/statifier/ files in this diff"`
- [ ] With the key set and a hand-crafted diff that drops a phase-boundary
      trace effect from a stubbed interpreter function, `mix adr.judge
      --format json` against a real API call produces exactly one
      `adr-0012-debuggability` finding naming that file/line
- [ ] The same setup with a refute-model stub that overturns the candidate
      produces zero findings, confirming the adversarial gate actually
      suppresses a single-pass false positive rather than always agreeing
      with the propose pass

**Implementation Note**: Use `mix quality --profile loop` between edits;
`mix quality` as the phase gate (Dialyzer sees the new `Req` dep; the PLT
rebuild is expected on the first run after this phase per
`deps/ex_quality/docs/stages.md`'s Dialyzer section). Sabotage each new pure
test the same way as Phase 1.

---

## Testing Strategy

### Unit Tests

- `test/mix/statifier/adr_guard_test.exs`: one test group per check
  (`adr-0002-naming`, `adr-0003-effects`, `adr-0004-eval`, `adr-0008-uxid`),
  each with a synthetic diff via a stub `opts[:runner]` (same helper shape as
  `gate_guard_test.exs`'s `runner/1`/`resolving/1`), covering: a violation
  fires, an exact/compliant name or an excluded path (`session.ex`) does not
  fire, and the inline-comment escape hatch clears a finding.
- `test/mix/tasks/adr_check_test.exs`: argument parsing, JSON vs. prose
  output, `--base` override, no-base-ref skip - mirrors
  `gate_check_test.exs`.
- `test/mix/statifier/adr_judge_test.exs`: pure `analyze/2` tests driven by
  a stub `opts[:caller]` returning canned propose/refute responses -
  violation survives refute -> finding; violation overturned by refute -> no
  finding; propose finds nothing -> no findings.
- `test/mix/tasks/adr_judge_test.exs`: the three skip paths
  (no key, no core changes, no base ref), plus JSON output shape.
- Sabotage line above each new test asserting `lib/` behavior, per
  CLAUDE.md's testing convention.

### Conformance Tests

None - this issue does not touch the interpreter or the conformance corpus.

### Manual Testing Steps

1. Run `mix quality` on this branch; confirm both new stages appear (ADR
   guard passing with zero findings, ADR judge skipped for the reason that
   applies in this environment) and no existing stage regresses.
2. Manually construct a small diff (e.g. a scratch file under `lib/statifier/interpreter.ex`
   with a near-miss function name) and run `mix adr.check --format json`
   against it directly to see a real finding end-to-end, then delete the
   scratch file.
3. With a real `ANTHROPIC_API_KEY` exported, run `mix adr.judge --format
   json` against a hand-crafted diff that removes a trace-effect call from a
   stubbed interpreter function, to see the propose/refute pipeline produce
   (or correctly withhold) a finding end-to-end against the real API.

## Performance Considerations

`adr.check` is a diff parse plus regex scans over added lines - comparable
cost to `gate.check`, negligible next to Dialyzer/coverage. `adr.judge` makes
up to `1 + N` model calls (one propose, one refute per candidate); it is
excluded from `--profile loop` for exactly this reason, and skips outright
when there is nothing in `lib/statifier/` to send.

## Corpus/Ratchet Notes

None - no conformance corpus interaction.

## References

- Beads issue: `st2-meo`
- Sibling custom-stage effort (guards the gate config itself, not ADR
  conformance): `st2-h6p`, `lib/mix/statifier/gate_guard.ex`,
  `lib/mix/tasks/gate.check.ex`
- ADRs enforced: `docs/adr/0002-literal-w3c-appendix-d-port.md`,
  `docs/adr/0003-pure-core-with-effects.md`,
  `docs/adr/0004-predicator-as-the-datamodel.md`,
  `docs/adr/0008-uxid-for-identifiers.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`
- ADR governing the gate-config edits this plan itself makes:
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/quality-gate-changes.md`
- Custom-stage contract: `deps/ex_quality/docs/stages.md#custom-stages`,
  `deps/ex_quality/docs/configuration.md#custom-stages`
- Layer/module naming convention the path globs follow: `docs/architecture.md`
