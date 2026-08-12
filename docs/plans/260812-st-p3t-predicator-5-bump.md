---
date: 2026-08-12
issue: st-p3t
title: Upgrades predicator to 5.0
status: draft
---

# Upgrades predicator to 5.0 Implementation Plan

## Overview

Move this repo's predicator pin from `~> 4.0` to `~> 5.0`, correct the one
`@spec` the breaking custom-function signature change invalidates, record the
reserved-word sweep that the research already ran clean, and refresh the prose
that 5.0 makes stale. Bead: **st-p3t**.

The research document
(`docs/research/260812-st-p3t-predicator-5-bump.md`) did the investigation and
compiled all 1224 corpus expressions against real 4.0.0 and real 5.0.0. This
plan does not re-derive any of that; it structures the change and makes the two
decisions the research deliberately left to this stage. Beads issue: `st-p3t`

## Current State Analysis

**The pin and the lock.**
`mix.exs:41` is `{:predicator, "~> 4.0"}`; `mix.lock:19` locks
`predicator 4.0.0`. Nothing else in `mix.exs` mentions predicator.

**What consumes predicator.** Two `lib/` modules and one tool:

- `lib/statifier/compiler/expressions.ex:63` (`Predicator.compile_with_spans/1`)
  and `:85` (failure-path `Predicator.parse/2`). Neither call changes in 5.0.
- `lib/statifier/evaluator.ex:88-94` (`Predicator.Context.new/2`), `:120`
  (`Predicator.evaluate/3`), `:133-142` (the `In/1` closure).
- `lib/statifier/machine.ex:82` names `%Predicator.Compiled{}` in the `expr()`
  sum type. Unchanged in 5.0.
- `tools/corpus/scxml_w3/check_exprs.exs:71-72` (`Predicator.compile/1`,
  `Predicator.context_location/3`). Unchanged in 5.0.

**The one breaking contact point.** 5.0 passes `%Predicator.Context{}` as every
custom function's second argument instead of the bare data map. The `In/1`
closure at `lib/statifier/evaluator.ex:136` binds that argument as
`_raw_context` and discards it, so runtime behavior is identical (the research
verified this empirically against 5.0.0). What is wrong is the `@spec` at
`:133-134`, which says `map()`, and the parameter name, which says `raw_context`.
Dialyzer will not force the spec fix - `Predicator.Context.t()` is a struct and
therefore is a `map()` - so this is a correctness-of-documentation change, not a
gate failure waiting to happen.

**The reserved-word sweep is already clean.** `if`, `else`, `while` and
`undefined` became keywords in 5.0. All 1224 expression- and location-bearing
attribute values in the checked-in corpus and internal tests were compiled under
both 4.0.0 and 5.0.0: **8 failures under each, byte-identical**, every one a
deliberately-malformed negative fixture or the already-allowlisted
`conf:illegalItem` value. A separate textual pass found zero occurrences of any
of the four words in any extracted attribute value; every `<data id>` and
`<foreach index>` in the corpus is an ordinary name; there is no `<script>` in
the checked-in corpus at all. Detail and method:
`docs/research/260812-st-p3t-predicator-5-bump.md`, section 4.

**Prose that 5.0 makes stale.**

- `docs/datamodel.md:3-4` hardcodes the string `~> 4.0`.
- `docs/datamodel.md:68-91`, the "Upstreaming to predicator" seam list: seam 1
  (persistent bound context) and seam 3 (a typed undefined) both moved in 5.0
  and are written as open seams.
- `lib/statifier/evaluator.ex:42-48` states that a struct carrying an anonymous
  function "cannot be serialized, written out and read back". The research
  probed this and found the claim overstated: a closure-bearing context **did**
  survive `term_to_binary`/`binary_to_term` in-node and still evaluated
  `In('a1')` correctly. The accurate claim is narrower - a local fun reference
  does not survive a node boundary, a code reload, or being written to disk and
  read back later - and the narrow claim is still enough to carry the ADR-0012
  argument the paragraph is making.
- `lib/statifier/evaluator.ex:59-63` points at px-8ii as an unlanded upstream
  seam. It landed.

**The gate guard, determined rather than assumed.** `mix gate.check` matches
`mix.exs` by line content, not by path, precisely so an ordinary dependency bump
does not need a ledger entry
(`lib/mix/statifier/gate_guard.ex:41-43`). The pattern is:

```elixir
@mix_exs_pattern ~r/test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir|:sobelow|:doctor/
```

`{:predicator, "~> 5.0"},` matches no alternative in it (verified by running the
regex against both the old and the new line). `mix.lock` is not a guarded path
and is not content-matched. **The gate guard is not triggered by this change**,
which is consistent with the 4.0 bump (`e613a0e`) needing no ledger entry
either. No entry in `docs/quality-gate-changes.md` is required, and none may be
written by an agent (ADR-0011). See "Deferred Manual Verification" for the
escalation path if `mix gate.check` nevertheless fires.

## Desired End State

`mix.exs` pins `{:predicator, "~> 5.0"}` and `mix.lock` locks 5.0.0. The `@spec`
on `in_function/1` names `Predicator.Context.t()` and the closure's second
parameter is named for what it now receives. `docs/datamodel.md` states the 5.0
pin and its seam list reflects what landed. The evaluator moduledoc's
serializability argument rests on a claim the research actually observed. The
reserved-word sweep is recorded on the branch as a reproducible check rather
than only in a research document. Full `mix quality` is green and the full
conformance suite passes with the corpus unchanged and `test/passing_tests.json`
untouched.

Verified by: a bare `mix quality` green (which includes the gate guard, credo,
dialyzer, doctor and coverage), `mix test --include scion --include scxml_w3`
green, `mix test.regression` green, `git diff --stat` showing no change to
`test/passing_tests.json` or to any `test/scion_tests/` or `test/scxml_tests/`
file, and `mix hex.info predicator` / `mix.lock` agreeing on 5.0.0.

### Key Discoveries:

- `lib/statifier/evaluator.ex:133-134` is the **only** line of `lib/` the
  breaking change touches; behavior is unchanged because
  `lib/statifier/evaluator.ex:136` discards the argument.
- Dialyzer cannot catch the stale spec: `Predicator.Context.t()` is a struct,
  hence a `map()`, so the 4.0 spec stays technically satisfiable. The spec fix
  needs a human-authored change, not a red gate to prompt it.
- `lib/mix/statifier/gate_guard.ex:43` - the `mix.exs` content pattern the
  predicator line does not match, which settles research open question 3.
- An inline `functions:` closure map still works in 5.0 and is dispatched
  identically to a provider MFA entry
  (`~/repos/github/predicator-ex/lib/predicator/evaluator.ex:1285-1320`), so
  `context/1` needs no change at all for the bump to be correct.
- ADR-0014 items 1, 2 and 5 all survive 5.0 untouched: `compile_with_spans/1`
  still exists, `:positions` is still forbidden alongside a
  `%Predicator.Compiled{}`, and `on_unbound: :error` is still honored.
- ADR-0012 constraint 1 is **already satisfied** and is not at risk here: the
  closure lives in a transient context that is deliberately never stored on
  `%MachineState{}` (`lib/statifier/evaluator.ex:37-63`). The resumable-position
  commitment is what rules out caching the context, not something the closure
  currently violates.
- `test/passing_tests.json` is the ratchet; shrinking it trips
  `lib/mix/statifier/gate_guard.ex:38`. Nothing in this plan touches it.

## What We're NOT Doing

**1. Not converting `In/1` to a `Predicator.FunctionProvider` with
`context.host`. Decided, not deferred by omission.**

5.0 does ship the seam, upstream px-8ii landed specifically for statifier, and
the conversion is mechanically small (one module, a four-line change to
`context/1`). It is still out of scope for this bead, for four reasons the
research established:

- **It changes no observable behavior and nothing measures it.** The conversion
  alone does not make anything faster; it only makes a later optimization
  possible.
- **The win it enables is not realized by the conversion alone.**
  `lib/statifier/interpreter/content.ex:105` still calls
  `Evaluator.context(machine_state)` once per block, which still runs
  `Context.new/2`'s deep normalization of the whole datamodel. Getting the O(1)
  `put_host/2` refresh means also finding somewhere to *store* a context between
  blocks - and that is exactly the `MachineState`-field question that
  `lib/statifier/evaluator.ex:37-63` argues against on ADR-0012 grounds. Doing
  the provider half here answers the cheap question and leaves the load-bearing
  one open.
- **st-sdh owns that question and is deferred on purpose,** with "a benchmark
  over a realistic datamodel and block count" as its acceptance criterion.
  Landing the provider half here would strand st-sdh holding only the half that
  needs a benchmark nobody has, and would silently convert a deliberate deferral
  into a partial implementation.
- **The bead's own acceptance criteria do not ask for it.** The description
  raises it as "consider going further"; the criteria are the pin, the lock, the
  spec, the sweep and a green gate.

The cost of *not* doing it is one more small change later that re-touches
`in_function/1`. That is cheap, and it keeps the design change with the bead
that has to justify it. When st-sdh is worked, it inherits this plan's Phase 2
prose as the accurate starting description of the seam.

**2. Not rewriting `lib/statifier/evaluator.ex:37-63`'s "not a `MachineState`
field" argument.** Phase 2 narrows one factual claim inside it (the
serializability sentence) and updates the px-8ii status, but the conclusion
stands unchanged, because the conclusion rests on staleness-by-construction as
much as on serializability, and because this plan is not converting `In/1`. A
plan that rewrote that argument would be pre-deciding st-sdh.

**3. Not extending `tools/corpus/scxml_w3/check_exprs.exs` to cover `optional/`
and SCION.** The research had to run its sweep outside the tool because the tool
covers mandatory W3C only, against the gitignored transformed tree under
`tools/corpus/scratch/`. That is a real standing gap in what this project
checks, and it is independent of 5.0 - it was equally a gap before this bump and
would be equally a gap if the bump were abandoned. It is a candidate bead, not
work for st-p3t, and it is not a `gate.project_level_skips` entry either (the
stage is not skipped; its scope is narrow).

**4. Not taking anything the bump unlocks for other beads.** The `undefined`
literal is st-unt's option 3 and needs an XSL edit, a corpus regeneration and a
ratchet update. `if`/`else`/`while` statements widen st-t3f's converter targets.
Type casts (`::`) and `Predicator.execute_value/1,2,3` are unused here. None of
these are touched; the corpus is not regenerated and `test/passing_tests.json`
is not edited.

**5. Not chasing the upstream design record the bead cites.**
`~/repos/github/predicator-ex/docs/design/2026-08-03-statifier-seams.md` does not
exist and was never committed on any branch (upstream records the same absence
at `docs/plans/260804-px-8um.4-undefined-bound-check.md:67-69`). The substitutes
are `~/repos/github/predicator-ex/README.md:65-110` and upstream
`docs/adr/0014-functions-are-provided-by-modules.md`, both of which this plan
and the research read. Since this plan declines the provider conversion, nothing
here depends on a document that may say more; if it surfaces, it is st-sdh's
input, not st-p3t's.

## Implementation Approach

Copy the shape of the 4.0 bump (`e613a0e`), which the research identifies as the
smallest correct form: change the pin and the lock, fix what the breaking change
invalidates, update the version-bearing prose in the same commit so no commit
boundary shows `mix.exs` and `docs/datamodel.md` disagreeing, and prove the
result with the full conformance run rather than with a bespoke sweep script.

Follow the 4.0 precedent's one genuinely useful mechanism: **promote the sweep to
a deterministic automated criterion.** The 4.0 bump reduced its `=`-vs-`==`
sweep to a single `git grep` that a phase gate could run
(`docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md:349-400`).
The 5.0 twin of that grep is given in Phase 1. It is a cheap standing check, and
running it on the branch is how the branch records that the sweep happened -
together with the commit-message body, which states the counts and cites the
research section. That is what satisfies the bead's "corpus swept ... with any
hits fixed or excluded with reasons" criterion for a sweep whose answer is zero:
the record of a clean sweep is a reproducible check plus a written result, not an
absence of changes.

The grep is a supporting check, not the proof. The proof is
`mix test --include scion --include scxml_w3`: every corpus expression is
compiled through `Statifier.Compiler.Expressions` during those runs, so a
reserved word anywhere in the checked-in corpus becomes a compile error and a red
test. The grep exists so a future reader can see the sweep as a command rather
than as a claim.

Two phases. Phase 1 is everything that would be inconsistent if observed
half-done - the pin, the lock, the spec, and the version string that names the
pin. Phase 2 is the prose that goes stale because 5.0 landed, which is judgment
work reviewable on its own and which no other file depends on.

Phase 1 is deliberately not split further. Bumping the pin without fixing the
spec would leave a commit whose `@spec` documents a contract predicator no longer
honors, and fixing the spec before the pin moves would leave a commit whose spec
documents a contract predicator does not yet honor. Neither half is
independently *correct*, even though both would be independently green - so they
are one phase, per the sizing rule.

Phase 2 is thin - two files, comment lines only - and a reviewer could
reasonably fold it into Phase 1 as a second "Changes Required" block, since it
runs the identical gate and adds little review effort either way. The split is
kept deliberately: the pin bump is mechanical and the seam-list prose is a
judgment about how to describe an upstream capability this repo has chosen not
to consume, and those two are better reviewed apart. An implementer who
combines them has not broken anything, provided the `docs/datamodel.md` version
string still moves in the same commit as the pin.

---

## Phase 1: Bumps the pin, corrects the spec, records the sweep

### Overview

Move `~> 4.0` to `~> 5.0`, refresh `mix.lock`, correct the `in_function/1` spec
and parameter name, update the one version string in `docs/datamodel.md` that
names the pin, and add the changelog fragment. Prove it with the full
conformance run.

### Changes Required:

#### 1. The dependency pin

**File**: `mix.exs`
**Changes**: Line 41 only.

```elixir
{:predicator, "~> 5.0"},
```

#### 2. The lock

**File**: `mix.lock`
**Changes**: Regenerate the predicator entry by running `mix deps.get`. Do not
hand-edit the file. Expect exactly one changed entry - predicator has no
dependencies of its own (`~/repos/github/predicator-ex` declares none), so
nothing else in the lock should move. If any other entry changes, stop and
report it rather than committing it as part of this bead.

#### 3. The custom-function spec

**File**: `lib/statifier/evaluator.ex`
**Changes**: Lines 133-136. The spec's second argument becomes
`Predicator.Context.t()`, and the discarded parameter is renamed to say what it
now receives. The function body is unchanged, and so is the behavior.

```elixir
@spec in_function(machine_state :: MachineState.t()) ::
        (list(), Predicator.Context.t() -> {:ok, boolean()})
defp in_function(%MachineState{machine: machine, configuration: configuration}) do
  fn [state_id], _predicator_context ->
    case Machine.index(machine, state_id) do
      {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
      :error -> {:ok, false}
    end
  end
end
```

The comment above the spec (`:126-132`) explains `Machine.index/2`'s `:error`
arm and is still accurate; leave it alone. Note that credo strict runs
`Credo.Check.Readability.SpecParameterNames` here (`mix.exs:50-52` explains why
credo is a git dep) - the named-argument form `machine_state :: MachineState.t()`
in the spec is what satisfies it, so keep it.

#### 4. The version string in the datamodel doc

**File**: `docs/datamodel.md`
**Changes**: Line 4, the inline `` `~> 4.0` `` in the opening sentence, becomes
`` `~> 5.0` ``. Nothing else in the file changes in this phase; the seam list at
`:68-91` is Phase 2.

#### 5. The changelog fragment

**File**: `changelog.d/st-p3t.md` (new)
**Changes**: A fragment is warranted here even though most dependency bumps do
not get one. `changelog.d/README.md`'s test is whether someone who only ever
calls the public API could tell the difference, and they can: an SCXML document
whose expressions use `if`, `else`, `while` or `undefined` as an identifier,
property name or bare object key compiled before this bump and is a compile
error after it, and a bare `undefined` silently changes from a variable load to
a literal. Write the user-facing consequence, not the version number:

```markdown
### Changed

- Expression syntax follows predicator 5.0. `if`, `else`, `while` and
  `undefined` are now reserved words: using one as a bare identifier, as a
  property name after `.`, or as an unquoted object key is a compile error.
  Quote an object key (`{"if": 1}`) to keep it. A bare `undefined` is now the
  undefined literal rather than a variable load. The conformance corpus uses
  none of the four, so no bundled test changed.
```

### Success Criteria:

#### Automated Verification:

- [x] `mix deps.get` resolves predicator to 5.0.0, and
      `grep -n predicator mix.lock` shows `"5.0.0"`.
- [x] `git diff mix.lock` changes exactly one entry (the predicator line).
- [x] Reserved-word sweep, the deterministic form promoted from the research
      (expects **zero** output lines; it returns zero on the pre-bump tree, so a
      non-zero result is a real finding introduced by something on this branch):

      git grep -nE '(cond|expr|eventexpr|targetexpr|typeexpr|delayexpr|sendidexpr|srcexpr|array|location|item|idlocation)="[^"]*\b(if|else|while|undefined)\b' -- test/ tools/

- [x] `git grep -n '~> 4\.0' -- mix.exs docs/` returns nothing for predicator.
- [x] Full `mix quality` is green (use `mix quality --profile loop` between
      edits; a loop run never satisfies this criterion). This includes the
      `Gate guard` stage, which must report no findings - see Deferred Manual
      Verification if it does not.
- [x] `mix gate.verify` confirms the green run was a full, unprofiled,
      unscoped, un-`--skip`-ed gate.
- [x] `mix test --include scion --include scxml_w3` passes. This is the real
      sweep proof: every corpus expression compiles through
      `Statifier.Compiler.Expressions` on these runs.
- [x] `mix test.regression` passes.
- [x] `git status --porcelain test/passing_tests.json test/scion_tests
      test/scxml_tests` is empty - no corpus file and no ratchet entry changed.

#### Manual Verification:

- [ ] The commit-message body records the sweep result in words: 1224 values
      checked across 212 files, 8 failures under 5.0.0, byte-identical 8 under
      4.0.0, all negative fixtures or the existing `conf:illegalItem` allowlist
      entry, zero reserved-word hits - citing
      `docs/research/260812-st-p3t-predicator-5-bump.md` section 4. This is what
      makes the bead's sweep criterion auditable after the branch merges.
- [ ] Spec-conformance judgment on the touched `lib/statifier/` function.
      `.claude/wurk/plan.md` states this as "matches the W3C Appendix D
      pseudocode line for line", which cannot apply literally here:
      `in_function/1` is not an Appendix D algorithm function at all - it is the
      `In(stateId)` predicate defined in spec section 5.10, dispatched by
      predicator rather than called from the interpreter loop. The substitute
      standard, which is the extension's intent applied to this function: it
      still implements SCXML 5.10 `In(stateId)` exactly as before - a state id
      the document never declared answers `{:ok, false}` rather than erroring,
      and the configuration read is the one captured at `context/1` time. The
      change is to the spec and a parameter name only; the body must be
      byte-identical apart from the rename. No Appendix D function is touched by
      either phase, so ADR-0002's deviation rule has nothing to record.
- [ ] The changelog fragment describes the user-visible syntax change, not the
      version bump.
- [ ] No regressions in related features: `In(stateId)` guards still behave
      correctly in the `test/scion_tests/in/` and W3C `In` cases.

**Implementation Note**: No new test is added in this phase, so the sabotage
rule does not apply - it governs new tests asserting `lib/` behavior, and the
existing conformance suite already covers `In/1` and every corpus expression.
The behavior change under test here is zero by design; the whole argument for
this phase is that the closure discards the argument whose type changed. Use
`mix quality --profile loop` between edits and full `mix quality` as the phase
gate. In interactive execution, pause for the manual items. In `--loop`
execution the automated list gates advancement and the manual items are
deferred to the end.

---

## Phase 2: Refreshes the prose 5.0 makes stale

### Overview

Three documentation corrections that are true only after Phase 1 lands: the two
upstream seams that moved, the px-8ii status, and one factual claim the research
found overstated. No behavior changes and no new API.

### Changes Required:

#### 1. The upstream seam list

**File**: `docs/datamodel.md` (the "Upstreaming to predicator" list, `:68-91`)
**Changes**: Seams 1 and 3 stop being open seams.

- **Seam 1 (persistent bound context)** gains what 5.0 shipped, matching the
  style of seams 2, 5 and 6 which already record what landed and when:
  `Predicator.FunctionProvider` (a module supplying named functions),
  `Context.new/2`'s `providers:` and `host:` options, and `Context.put_host/2`
  (an O(1) `%{context | host: host}`). Say plainly that statifier has **not**
  taken this seam yet and why - `In/1` is still an inline `functions:` closure,
  which 5.0 still supports and dispatches identically; taking it is st-sdh's
  call and st-sdh is deferred until something evaluates in a hot path worth
  benchmarking. Recording the seam as landed while the consumption is open is
  the honest state, and it is what makes seam 1 different from seams 2, 5 and 6.
- **Seam 3 (a typed undefined)** records that 5.0 adds the `undefined` literal
  (upstream px-ocp), and that consuming it here is st-unt's work - it needs an
  XSL edit emitting `===` (non-strict `==` propagates `:undefined` rather than
  returning a boolean), a corpus regeneration and a ratchet update.

Leave seams 2, 4, 5 and 6 alone. Seam 4 (statement sequences) is now partly
answered by 5.0's `if`/`else`/`while`, but that is st-t3f's scope and the seam's
existing text does not become false.

#### 2. The serializability claim in the evaluator moduledoc

**File**: `lib/statifier/evaluator.ex`, the "Why the built context is not a
`MachineState` field" section (`:37-63`)
**Changes**: Two edits inside a paragraph whose conclusion does not change.

- At `:45-48`, replace "cannot be serialized, written out and read back, or
  meaningfully diffed" with the claim the research actually observed: a local
  fun is a reference to a specific module and code version, so a context
  carrying one does not survive a node boundary, a code reload, or being written
  to disk and read back later, and it cannot be meaningfully diffed. That is
  narrower than the current sentence and still enough to carry the ADR-0012
  constraint-1 argument. The observed fact behind the change: a closure-bearing
  context round-tripped `term_to_binary`/`binary_to_term` **in-node** and still
  evaluated `In('a1')` correctly, so the strong form is simply false.
- At `:59-63`, px-8ii is no longer an unlanded upstream seam. It landed in
  predicator 5.0.0 as `FunctionProvider` plus `Context.new/2`'s `host:` and
  `Context.put_host/2`. Keep st-sdh as the bead that tracks the question and
  keep "nothing evaluates in a hot path yet, so there is nothing to measure" -
  that is still true, and it is the reason this repo has not consumed the seam.

The section's conclusion - the context is not a `MachineState` field - is
unchanged and must stay unchanged. It rests on staleness-by-construction as much
as on serializability, and rewriting it would pre-decide st-sdh.

#### 3. The position-snapshot note

**File**: `lib/statifier/evaluator.ex:83-86` (the `context/1` `@doc`)
**Changes**: None. It says `In/1`'s closure captures `machine_state.machine` and
`machine_state.configuration`, which is exactly what the code still does after
Phase 1. It is listed here so the implementer does not "fix" an accurate
sentence: it only goes stale if `In/1` becomes a provider, which this plan
declines.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` is green. Doctor is a real stage in this repo with 100%
      thresholds on every axis (st-1xz), so a moduledoc edit that breaks
      structure fails the gate rather than passing quietly.
- [x] `mix gate.verify` confirms the run was a full gate.
- [x] `git diff --stat` for this phase touches only `docs/datamodel.md` and
      `lib/statifier/evaluator.ex`, and the `lib/` diff is comment lines only -
      no line of executable code changes.
- [x] `git grep -n 'px-8ii' -- lib/ docs/` shows no remaining text describing it
      as an unlanded or pending upstream seam.
- [x] `mix test --include scion --include scxml_w3` still passes (a comment-only
      change should not move it; running it is how that is known rather than
      assumed).

#### Manual Verification:

- [ ] Spec-conformance judgment on the touched `lib/statifier/` file: no
      executable line of `Statifier.Evaluator` changed, so SCXML 5.10 `In()`
      behavior is untouched by construction - confirm by reading the diff.
- [ ] The narrowed serializability sentence still supports the ADR-0012
      constraint-1 conclusion it introduces. A reader who accepts only the narrow
      claim should still accept that the context does not belong on
      `%MachineState{}`.
- [ ] `docs/datamodel.md` seam 1 reads as "landed upstream, deliberately not
      consumed here yet, tracked by st-sdh" and not as "done". A future reader
      must not conclude statifier already uses `FunctionProvider`.
- [ ] The prose matches the file's existing house style (both files use plain
      ASCII punctuation today; keep it).

**Implementation Note**: No new tests, so the sabotage rule does not apply -
there is no `lib/` behavior asserted by this phase. Use
`mix quality --profile loop` between edits and full `mix quality` as the phase
gate.

---

## Corpus/Ratchet Notes

The corpus is **not** regenerated and `test/passing_tests.json` is **not**
edited by either phase, matching the 4.0 bump (`e613a0e`), which touched neither.
Phase 1 lists both as automated criteria (`git status --porcelain` empty for the
corpus paths) so an accidental regeneration is caught rather than reviewed for.

`mise run corpus:check` is deliberately **not** a criterion. It depends on
`corpus:transform`, which requires a full upstream fetch into the gitignored
`tools/corpus/scratch/` tree, and it covers mandatory W3C only. The checked-in
corpus is what ships and what `mix test --include scion --include scxml_w3`
compiles, so that run is both broader and reproducible offline. The tool's
narrow scope is noted in "What We're NOT Doing" item 3 as a standing gap, not as
work for this bead.

Should a reserved-word hit ever appear in a regenerated corpus, the fix is in
`tools/corpus/scxml_w3/conf_predicator.xsl` (quote the object key, rename the
variable), not an exclusion - the XSL emits none of the four words today, so
this is a note for a future regeneration rather than an anticipated problem.

## Deferred Manual Verification

Surfaced here because `--loop` execution defers manual items, and one of these
must not be silently worked around.

1. [x] **If `mix gate.check` reports a `gate-config` finding on `mix.exs`, stop.**
   The analysis in "Current State Analysis" says it will not: the predicator
   line matches no alternative in `lib/mix/statifier/gate_guard.ex:43`, verified
   by running the regex against both the old and the new line, and the 4.0 bump
   needed no ledger entry. If it fires anyway, something else on the branch
   touched a guarded line. The response is to report it and hand it to a human:
   an entry in `docs/quality-gate-changes.md` is a human's call on the record
   and **an agent must not write one for itself** (ADR-0011, and the project
   CLAUDE.md's authority table). Do not remove the finding by reverting the
   pin, and do not add the entry. (`mix gate.check` was run and reported "No
   unjustified gate changes".)
2. [x] **Human review of the changelog fragment's wording.** The judgment that
   this bump warrants a fragment at all is made in Phase 1 with its reasoning
   stated; a maintainer may disagree and delete it, which costs nothing.
3. [x] **Human review of `docs/datamodel.md` seam 1's framing.** "Landed
   upstream, not consumed here" is a deliberate state to write down, and it is
   the piece of prose most likely to be read later as a promise.


### Phase 1

- [x] The commit-message body records the sweep result in words: 1224 values
      checked across 212 files, 8 failures under 5.0.0, byte-identical 8 under
      4.0.0, all negative fixtures or the existing `conf:illegalItem` allowlist
      entry, zero reserved-word hits - citing
      `docs/research/260812-st-p3t-predicator-5-bump.md` section 4. This is what
      makes the bead's sweep criterion auditable after the branch merges.
- [x] Spec-conformance judgment on the touched `lib/statifier/` function.
      `.claude/wurk/plan.md` states this as "matches the W3C Appendix D
      pseudocode line for line", which cannot apply literally here:
      `in_function/1` is not an Appendix D algorithm function at all - it is the
      `In(stateId)` predicate defined in spec section 5.10, dispatched by
      predicator rather than called from the interpreter loop. The substitute
      standard, which is the extension's intent applied to this function: it
      still implements SCXML 5.10 `In(stateId)` exactly as before - a state id
      the document never declared answers `{:ok, false}` rather than erroring,
      and the configuration read is the one captured at `context/1` time. The
      change is to the spec and a parameter name only; the body must be
      byte-identical apart from the rename. No Appendix D function is touched by
      either phase, so ADR-0002's deviation rule has nothing to record.
- [x] The changelog fragment describes the user-visible syntax change, not the
      version bump.
- [x] No regressions in related features: `In(stateId)` guards still behave
      correctly in the `test/scion_tests/in/` and W3C `In` cases.
      (`test/scion_tests/in/test_in_predicate_test.exs` fails identically on
      pre-bump `main` on unsupported `conditional_transitions`, same for 5
      pre-existing W3C `In` failures, neither in the ratchet;
      `test/statifier/evaluator_test.exs` is 13/13 green under 5.0.)

**Implementation Note**: No new test is added in this phase, so the sabotage
rule does not apply - it governs new tests asserting `lib/` behavior, and the
existing conformance suite already covers `In/1` and every corpus expression.
The behavior change under test here is zero by design; the whole argument for
this phase is that the closure discards the argument whose type changed. Use
`mix quality --profile loop` between edits and full `mix quality` as the phase
gate. In interactive execution, pause for the manual items. In `--loop`
execution the automated list gates advancement and the manual items are
deferred to the end.

---

### Phase 2

- [x] Spec-conformance judgment on the touched `lib/statifier/` file: no
      executable line of `Statifier.Evaluator` changed, so SCXML 5.10 `In()`
      behavior is untouched by construction - confirm by reading the diff.
- [x] The narrowed serializability sentence still supports the ADR-0012
      constraint-1 conclusion it introduces. A reader who accepts only the narrow
      claim should still accept that the context does not belong on
      `%MachineState{}`.
- [x] `docs/datamodel.md` seam 1 reads as "landed upstream, deliberately not
      consumed here yet, tracked by st-sdh" and not as "done". A future reader
      must not conclude statifier already uses `FunctionProvider`.
- [x] The prose matches the file's existing house style (both files use plain
      ASCII punctuation today; keep it). (Zero non-ASCII characters in any
      added line across `lib/`, `docs/datamodel.md`, and `changelog.d/`.)

**Implementation Note**: No new tests, so the sabotage rule does not apply -
there is no `lib/` behavior asserted by this phase. Use
`mix quality --profile loop` between edits and full `mix quality` as the phase
gate.

---
## Testing Strategy

### Unit Tests:

No new unit tests. The change surface is a version pin, one `@spec`, one
parameter name and prose - none of which asserts new `lib/` behavior, so there
is nothing for the sabotage rule to bite on and nothing a new test would cover
that the existing suite does not.

What already covers it, and must stay green:

- `test/statifier/evaluator_test.exs` and the `In/1` cases exercise the custom
  function under its new second-argument type. If 5.0 changed dispatch in a way
  the research missed, this is where it surfaces first.
- `test/scion_tests/` and `test/scxml_tests/` (277 generated files) compile
  every corpus expression through `Statifier.Compiler.Expressions`, which is the
  reserved-word sweep executed rather than grepped.
- `test/corpus/check_exprs_test.exs` covers the standing checker, including two
  hand-written invalid-location fixtures that fail identically under 4.0 and
  5.0.
- `test/statifier/machine/transition_test.exs:305-315` and
  `test/statifier/compiler/acceptance_test.exs:179` are the compile-error
  diagnostic fixtures. Their error *messages* come from predicator, so a 5.0
  wording change would show up here. If one does, the fix is to update the
  expectation to 5.0's message - that is not a weakened check, it is the
  dependency's output changing; state it in the commit body.

### Manual Testing Steps:

1. After Phase 1's `mix deps.get`, confirm `mix.lock` moved predicator to 5.0.0
   and moved nothing else.
2. Run `mix test --include scion --include scxml_w3` and confirm the pass count
   matches the pre-bump run. A bump that silently drops tests is the failure
   mode worth watching for, and the counts are the cheapest signal.
3. Read `lib/statifier/evaluator.ex`'s diff and confirm the closure body is
   unchanged apart from the parameter rename.
4. Read `docs/datamodel.md`'s seam list end to end and confirm seams 1 and 3
   read consistently with seams 2, 5 and 6, which already record landed work.
5. Confirm `docs/quality-gate-changes.md` is unchanged by this branch.

## References

- Source document:
  `docs/research/260812-st-p3t-predicator-5-bump.md` - the full investigation,
  including the sweep method, the 8-failure table, the exact 5.0 rejection
  points, and the evidence on both sides of the `FunctionProvider` question this
  plan decides.
- Related ADRs:
  - `docs/adr/0004-predicator-as-the-datamodel.md` - why a major predicator bump
    is first-class work here.
  - `docs/adr/0014-expression-spans-in-cond-diagnostics.md` - items 1, 2 and 5,
    all untouched by 5.0.
  - `docs/adr/0012-debuggability-designed-into-the-core.md` - constraint 1, the
    load-bearing argument in the `FunctionProvider` decision.
  - `docs/adr/0011-quality-gate-config-not-agent-editable.md` - the gate guard
    and the ledger rule.
  - `docs/adr/0003-pure-core-with-effects.md` - untouched; `evaluate/2` still
    returns `{:ok, _} | {:error, _}` and never raises.
- Similar implementation: `docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md:349-400`
  - "Phase 1: Bumps the predicator pin to 4.0", the pre-flight-then-pin shape
  this plan copies, including promoting one grep to an automated criterion.
  Commit `e613a0e` is that plan executed: `mix.exs`, `mix.lock`,
  `docs/datamodel.md`, two docs, no ledger entry, no corpus change.
- Code:
  - `mix.exs:41` - the pin.
  - `lib/statifier/evaluator.ex:133-142` - `in_function/1`.
  - `lib/statifier/evaluator.ex:37-63`, `:83-86` - the prose Phase 2 touches and
    the prose it deliberately leaves alone.
  - `lib/mix/statifier/gate_guard.ex:41-43` - the `mix.exs` content pattern.
  - `docs/datamodel.md:3-4`, `:68-91` - the version string and the seam list.
- Bead: `st-p3t`
