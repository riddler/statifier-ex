---
date: 2026-08-12
planner: Claude
git_commit: fff279bf2add606288c70cbb6ea8e4d2441cf0b5
branch: st-unt-boundness-sentinel-collision
repository: statifier-ex
beads_issue: st-unt
topic: "Respell the corpus boundness sentinel as predicator 5.0's undefined literal"
status: ready
last_updated: 2026-08-12
last_updated_by: Claude
---

# Boundness Sentinel -> `undefined` Literal Implementation Plan

## Overview

The conformance corpus writes boundness as a comparison against
`_statifier_unbound`, an identifier no generated document binds. Under
`on_unbound: :error` (ADR-0014 item 5, set at `lib/statifier/evaluator.ex:101`)
loading that identifier is itself an `UndefinedVariableError`, so every
boundness cond in the corpus is guaranteed to fail once `cond` is wired.
predicator 5.0.0 - already locked on this branch by st-p3t - adds an
`undefined` literal, which is a direct boundness test that never consults
`on_unbound`.

This plan replaces the sentinel with that literal across the seven emitting XSL
templates, regenerates the W3C corpus, and guards the notation with a test. It
deliberately stops at the notation. Beads issue: `st-unt`.

## Current State Analysis

Everything below is established by
`docs/research/260812-st-unt-boundness-sentinel-vs-on-unbound-error.md`; it is
restated here only where the plan turns on it.

- **The sentinel is emitted by seven templates** in
  `tools/corpus/scxml_w3/conf_predicator.xsl`: `conf:emptyEventData` (`:448`),
  `conf:isBound` (`:477`), `conf:unboundVar` (`:482`),
  `conf:systemVarIsBound` (`:487`), `conf:noValue` (`:492`),
  `conf:eventFieldsAreBound` (`:507`), `conf:eventFieldHasNoValue` (`:517`).
  All seven already emit `===` / `!==`.
- **The header comment at `:3-15`** documents the sentinel design and says
  "Revisit if predicator grows a typed undefined (docs/datamodel.md seam 3)".
  It has grown one, so that comment is part of what changes.
- **Checked-in inventory**: `grep -rn _statifier_unbound test/` -> 25 lines
  across 24 files, all under `test/scxml_tests/mandatory/` (test330 carries
  two). Re-verified against this worktree: 25 lines, 24 files.
- **`on_unbound: :error` fires on root loads only.** A property access on a
  bound root yields `:undefined` without error. That splits the 25 conds:
  - 9 property-shaped conds in 8 files (`_event.<field> ...`), plus test319's
    root-shaped `_event`, all against roots `SystemVariables.initial/2` seeds.
    **Verified to evaluate correctly once respelled.**
  - 15 root-shaped `Var<n>` conds in 15 files. These evaluate correctly only if
    a declared `<data id="VarN"/>` is seeded into the datamodel bound to `nil`
    or `:undefined`.
- **`<data>` is not implemented at all.** `data` and `datamodel` are absent
  from the lowering dispatch map (`lib/statifier/lowering.ex:52-67`), and an
  unrecognized element is a hard lowering error
  (`lib/statifier/lowering.ex:144`), so the 15 root-shaped documents do not
  lower today. The seeding question is not decided anywhere in `lib/`.
- **Nothing here is red today and nothing goes green today.**
  `Selection.condition_match/2` still returns `{:error, {:unsupported, :cond}}`
  for any written cond (st-af3.2 wires it), and `test_helper.exs:1` excludes
  the `:scxml_w3` and `:scion` tags from the default run, so the gate never
  executes these files. This change is a prerequisite being put in place, not a
  fix that moves a test count.
- **Regeneration mechanics.** `corpus:transform` (`mise.toml:129-146`) re-runs
  Saxon over every `.txml` whenever the XSL is newer than the emitted `.scxml`,
  so an XSL edit forces a full retransform of ~198 documents.
  `corpus:emit` (`mise.toml:148-165`) `rm -rf`s **both** `$CORPUS_W3_OUT` and
  `$CORPUS_SCION_OUT` and regenerates both. Generation is deterministic
  (sorted input, no timestamps, `Code.format_string!/1`), with a verified
  byte-identical cold-run diff recorded at `tools/corpus/README.md:108-115`.
- **This worktree's scratch tree does not exist** (`tools/corpus/scratch/` is
  absent): no cached `.txml`, no Saxon jar, no SCION clone. A JRE is provided
  by mise (`mise.toml:13`). A usable W3C mirror exists locally at
  `~/repos/github/ex_statechart/test/scxml_w3/cases` in exactly the layout
  `CORPUS_W3_MIRROR` expects.
- **Ratchet: nothing is obliged.** Re-verified in this worktree: none of the 24
  sentinel files appears in `test/passing_tests.json`. The gate guard's ratchet
  check fires only on a *shrink* (`lib/mix/statifier/gate_guard.ex:206-236`),
  and this change removes no pattern, so no `docs/quality-gate-changes.md`
  entry is obliged.
- **`exclusions.exs:8-11`** names only the `conf:emptyEventData` trio
  (test343/488/528) as the sentinel-dependent set, where the real scope is 24
  files, and states a premise ("holds only if the engine represents absent
  event data as undefined rather than `%{}`") that st-af3.1's `_event` seeding
  and predicator 5.0 have now settled.

## Desired End State

`_statifier_unbound` does not appear anywhere in the repository. Every
boundness cond in `test/scxml_tests/` is spelled with the `undefined` literal
under a strict comparison (`===` / `!==`), the XSL and `exclusions.exs`
comments describe the design that is actually in force, and a test in
`test/corpus/` fails if either property regresses.

Verify by:

- `grep -rn _statifier_unbound . --exclude-dir=.git --exclude-dir=docs` returns
  nothing.
- `grep -rEn '(^|[^!=])== *undefined' test/scxml_tests/` returns nothing (no
  non-strict comparison against the literal).
- `git status` after regeneration shows changes confined to
  `test/scxml_tests/`.
- Full `mix quality` green, and `mix test.regression` green.

### Key Discoveries:

- `undefined` is a literal in predicator 5.0: `x === undefined` never consults
  `on_unbound`, but a genuinely unbound **root** still errors, because the load
  of `x` fails before the comparison runs (research section 2).
- Non-strict `==` is not a boundness test: `_event.data == undefined` ->
  `{:ok, :undefined}`, not a boolean. **The XSL must keep emitting `===` /
  `!==`** (research section 2, "Boundary behaviors").
- `undefined` appears zero times in the current corpus
  (`docs/research/260812-st-p3t-predicator-5-bump.md` section 5), so
  introducing it collides with nothing.
- Seeding a declared `<data>` to `nil` makes the 15 root-shaped conds correct
  with no further corpus change and **no ADR amendment** (research finding 3).
- Every option that keeps `on_unbound: :error` leaves ADR-0014 intact
  (research section 7). This plan keeps it.
- `exclusions.exs` feeds *generation*, not test-time filtering: moving a test
  there deletes its generated file (`tools/corpus/scxml_w3/cases.exs:179-223`).

## What We're NOT Doing

**The scoping decision, stated as a decision.** st-unt's acceptance criteria
are "a decision is recorded (ADR amendment or corpus regeneration); the
conf:emptyEventData trio and the other sentinel-using tests either pass under
the wired cond path or are moved to `exclusions.exs` with a reason". Neither
disjunct of the second clause is reachable on this branch: `cond` is stubbed
until st-af3.2, and the 15 root-shaped documents cannot lower until st-af3.3,
so **no sentinel test can be observed passing today** - and exclusion is the
wrong answer for tests whose only defect is a notation this branch can fix.

So this plan takes the narrower half: **research option A, the notation.**
Respell, regenerate, correct the prose, guard the notation. That is the whole
of what is committable and gate-verifiable now, and it is a strict prerequisite
of every wider option, so nothing here is wasted if a later bead goes further.
The acceptance criteria are satisfied by the first disjunct (corpus
regeneration, decision recorded here and in the XSL header) plus the handoffs
below; whether the tests then pass is observable only on st-af3.2 / st-af3.3,
which is where it is checked.

Specifically out of scope:

- **The `<data>` seeding decision** (research option B). It belongs to
  **st-af3.3** ("Parses and binds `<datamodel>`/`<data>` with early and late
  binding"), whose description already says late binding leaves "the id
  defaulting to undefined before that". This plan answers research open
  question 1: no new bead is filed, because st-af3.3 already owns the
  decision; the corpus's exact requirement has been recorded as a note on it
  (key present and bound to `nil`, not absent, with the probe table and the
  15 affected files).
- **Boundness for roots that do not come from `<data>`** - test150 `Var4` and
  test151 `Var5` (`<foreach item=/index=>`, st-af3.6) and test245's `Var2`
  (invoked child session via `namelist`, st-cmq.6/st-cmq.7). Same requirement,
  different owners; recorded on st-af3.3's note so it travels with the
  decision.
- **Excluding any test** (research option E). None of the 24 files has a defect
  that exclusion would describe honestly, and excluding them would delete 15+
  generated files and shrink conformance coverage for a notation problem this
  branch fixes.
- **Amending ADR-0014 item 5** (research option D). Not required: no option
  that keeps `on_unbound: :error` touches the ADR, and item 5's named-variable
  diagnostic is the payoff ADR-0012 item 3 exists for.
- **Respelling root-shaped conds against a bound root** (research option C,
  e.g. `_ioprocessors`). It would work without `<data>`, but the emitted cond
  would stop reading as the boundness test it is, and it would have to be
  unwound once st-af3.3 lands. The `undefined` literal is the notation the XSL
  header itself named as the real fix.
- **Making test330 pass, or claiming it works.** test330 has a second,
  independent cause: `SystemVariables.event/1`
  (`lib/statifier/evaluator/system_variables.ex:62-79`) leaves `sendid`,
  `origin`, `origintype`, and `invokeid` `nil` because `Statifier.Event` does
  not carry them, so its 7-way conjunction evaluates `{:ok, false}` even when
  respelled. It also uses `<send>`. No phase here claims otherwise.
- **Ratcheting anything into `test/passing_tests.json`.** Nothing newly passes,
  so there is nothing to add. st-af3.8 is the bead that flips datamodel
  features and ratchets.
- **A changelog fragment.** `changelog.d/README.md:30-36` excludes "test
  harness, corpus tooling, or conformance fixtures" explicitly, and this change
  is invisible to anyone calling the public API. No `changelog.d/st-unt.md`.
- **Attributing the three `=== _statifier_unbound` root conds to
  `conf:unboundVar` versus `conf:noValue`** (research open question 2). The two
  templates emit byte-identical strings and are respelled identically, so the
  distinction is immaterial to this work.

## Implementation Approach

Phase 1 is one commit because the XSL and the corpus it generates cannot be
split: a commit holding an edited generator with unregenerated output is an
inconsistent tree that no gate stage would catch, which is exactly the
intermediate state the phase-sizing rule exists to prevent. Phase 2 is separate
because it adds a check rather than changing the corpus, and is committable and
gate-verifiable on its own once the corpus is respelled.

**Regeneration is scoped to the W3C tree by construction.** `mise run corpus`
would also wipe and rewrite `test/scion_tests/` from a fresh SCION clone, and
since `tools/corpus/scratch/` is absent here that clone would be of today's
upstream HEAD - any drift since the corpus was recorded would land in this
branch's diff as unrelated churn. This change touches no SCION input, so
Phase 1 runs `corpus:transform` (which needs only Saxon and the W3C sources)
and then the W3C emitter directly, leaving `test/scion_tests/` untouched. The
stale-exclusions `System.halt(1)` at `tools/corpus/scxml_w3/cases.exs:225-234`
is not a hazard for this because the emitter is given the **complete** W3C
input set, not a subset - it fires only when an `exclusions.exs` key matches
nothing in the input.

**Emitted files are never hand-edited.** If regeneration cannot run (no
network for the Saxon download), the phase stops and reports; it does not
produce the same diff by editing heredocs, which would decouple the corpus
from its generator.

---

## Phase 1: Respell the sentinel and regenerate the W3C corpus

### Overview

Replace `_statifier_unbound` with the `undefined` literal in all seven
emitting XSL templates, bring the two explanatory comments in line with the
design that is now in force, and regenerate `test/scxml_tests/` so the checked-
in corpus matches its generator.

### Changes Required:

#### 1. The seven sentinel-emitting templates

**File**: `tools/corpus/scxml_w3/conf_predicator.xsl`
**Changes**: `_statifier_unbound` -> `undefined` in each cond string.
Comparison operators are unchanged: every one of the seven already emits
`===` or `!==`, and **must continue to** - `==` against `undefined` propagates
`:undefined` instead of testing boundness.

| Line | Template | Emitted cond after the change |
|---|---|---|
| `:448` | `conf:emptyEventData` | `_event.data === undefined` |
| `:477` | `conf:isBound` | `Var<n> !== undefined` |
| `:482` | `conf:unboundVar` | `Var<n> === undefined` |
| `:487` | `conf:systemVarIsBound` | `<var> !== undefined` |
| `:492` | `conf:noValue` | `Var<n> === undefined` |
| `:507` | `conf:eventFieldsAreBound` | 7-way `_event.<field> !== undefined` conjunction |
| `:517` | `conf:eventFieldHasNoValue` | `_event.<field> === undefined` |

#### 2. The XSL header comment

**File**: `tools/corpus/scxml_w3/conf_predicator.xsl:3-15`
**Changes**: the boundness paragraph currently describes predicator 3.5 having
no undefined literal and says "Revisit if predicator grows a typed undefined".
It has (5.0, st-p3t), so the paragraph is replaced by one stating the current
design: boundness is `=== undefined` / `!== undefined` against predicator 5.0's
`undefined` literal; the comparison must stay strict because `==` propagates
`:undefined` rather than returning a boolean; and the literal does not rescue a
genuinely unbound **root**, which still raises `UndefinedVariableError` under
ADR-0014 item 5 - so a `Var<n>` cond depends on the datamodel seeding declared
`<data>` (st-af3.3). Leave the ECMAScript paragraph at `:12-15` as it stands.
Follow the file's existing prose style.

#### 3. The exclusions note

**File**: `tools/corpus/scxml_w3/exclusions.exs:8-11`
**Changes**: the NOTE names three tests where the sentinel scope was 24 files,
and rests on a premise that is now settled. Replace it with a note that no
boundness test is excluded, that boundness is spelled `=== undefined` against
a root the datamodel binds, and that a `Var<n>` boundness cond depends on
st-af3.3 seeding declared `<data>` rather than on an exclusion. Do not add or
remove any map entry; the 14 existing entries are unrelated
(`:needs_script` / `:needs_basichttp`).

#### 4. Regenerate `test/scxml_tests/`

**Files**: 24 files under `test/scxml_tests/mandatory/` (generated - do not
hand-edit).

```bash
# from the worktree root
export CORPUS_W3_MIRROR=~/repos/github/ex_statechart/test/scxml_w3/cases
mise run corpus:transform    # fetches Saxon (network) + seeds W3C sources from the mirror
mise run corpus:check        # asserts every transformed expression compiles under predicator 5.0

rm -rf test/scxml_tests && mkdir -p test/scxml_tests
find tools/corpus/scratch/scxml_w3/cases -type f -iname '*.scxml' -print0 \
  | sort -z | xargs -0 elixir tools/corpus/scxml_w3/cases.exs \
      test/scxml_tests tools/corpus/scratch/scxml_w3/cases
```

`CORPUS_W3_MIRROR` points at a sibling checkout that exists on this developer's
machine, not at anything a fresh clone or a CI runner has. If that path does not
resolve, omit the export entirely and let `corpus:fetch:w3` pull from
`w3.org` - 198 sequential requests that `tools/corpus/README.md:31-45` warns
can 429, so expect to re-run the task until it completes (it skips `.txml`
already on disk, so a throttled run resumes cheaply). Do not substitute a
different mirror without checking it holds only upstream `.txml`/`.description`/
`manifest.xml` and no third party's `.scxml`, which would make
`corpus:transform` skip its own work (`mise.toml:74-76`).

The last two commands are `corpus:emit`'s W3C half verbatim
(`mise.toml:148-165`), minus the SCION half - same wipe, same `sort -z` input
ordering, so the output is identical to what `mise run corpus` would produce
for this tree. Use `mise run corpus` instead only if `test/scion_tests/` is
also meant to be refreshed, which this bead does not want.

Expected diff: the 24 sentinel files and nothing else. Any change to a
non-sentinel file, or any file under `test/scion_tests/`, is a signal to stop
and investigate before committing - not something to accept.

### Success Criteria:

#### Automated Verification:

- [ ] `mise run corpus:check` reports no unexpected failures and no stale
      allowlist entry (this is what proves `undefined` and the respelled conds
      compile under predicator 5.0).
- [ ] `grep -rn _statifier_unbound . --exclude-dir=.git --exclude-dir=docs`
      returns nothing.
- [ ] `grep -rEn '(^|[^!=])== *undefined' test/scxml_tests/` returns nothing.
- [ ] `grep -rl 'undefined' test/scxml_tests/ | wc -l` is exactly 24, matching
      the previously-sentinel file list.
- [ ] `git status --porcelain` shows changes only under `test/scxml_tests/`,
      `tools/corpus/scxml_w3/conf_predicator.xsl`,
      `tools/corpus/scxml_w3/exclusions.exs`, and `docs/plans/`.
- [ ] Full `mix quality` is green, attested by `mix gate.verify` (not a
      `--profile loop` or scoped run). Use `mix quality --profile loop` while
      iterating.
- [ ] `mix test.regression` is green (it must be unaffected: none of the 24
      files is in `test/passing_tests.json`).
- [ ] `test/passing_tests.json` is unmodified, so the gate guard raises no
      ratchet finding and no `docs/quality-gate-changes.md` entry is needed.

#### Manual Verification:

- [ ] Read the emitted diff for at least one file per template family
      (test528 `conf:emptyEventData`, test223 `conf:isBound`, test277
      `conf:unboundVar`/`noValue`, test319 `conf:systemVarIsBound`, test330
      `conf:eventFieldsAreBound`, test333 `conf:eventFieldHasNoValue`) and
      confirm each cond changed only in the identifier, never the operator.
- [ ] Confirm the diff contains no `@tag required_features` churn beyond what
      the cond change explains, and no reordering or reformatting of unrelated
      files - i.e. that regeneration reproduced the recorded deterministic
      output.
- [ ] Read the rewritten XSL header and `exclusions.exs` note and confirm each
      describes what the file now does, including the root-load caveat.

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual review of the generated diff before Phase 2. In
looped (`--loop`) execution, the Automated Verification above gates
advancement via `/wurk:commit --auto`, and the Manual items are surfaced once
at the end. Reviewing a 24-file generated diff is genuinely a human step; a
looped run should treat it as deferred, not as satisfied.

---

## Phase 2: Guard the boundness notation with a corpus test

### Overview

The sentinel is gone, but two silent regressions remain possible: a future XSL
edit could reintroduce a never-bound identifier, or - the hazard the research
flags - could write `== undefined`, which parses, compiles, and evaluates to
`:undefined` instead of a boolean. Neither is caught by `corpus:check` (both
compile) nor by the suite (the `:scxml_w3` tag is excluded by default). A small
test over the emitted corpus makes both mechanical.

### Changes Required:

#### 1. A notation guard over the emitted W3C corpus

**File**: `test/corpus/boundness_notation_test.exs` (new)
**Changes**: an ordinary `async: true` ExUnit case, in the ordinary suite (no
`:scxml_w3` tag - it reads the files, it does not run the state charts), that
walks `test/scxml_tests/**/*_test.exs` and asserts:

- no file contains `_statifier_unbound`;
- no file contains a non-strict comparison against the literal - a regex with
  a lookbehind such as `~r/(?<![!=])==\s*undefined/` matches `== undefined`
  while allowing `=== undefined` and `!== undefined`;
- at least one file does contain `=== undefined`, so the test cannot pass
  vacuously if the corpus tree is ever empty or relocated.

Model the shape on the existing corpus guards in `test/corpus/` -
`emitted_paths_test.exs` is the closest precedent (it walks both emitted trees
and asserts a structural property). Failure messages should name the offending
file and line.

Each test carries its sabotage line per `docs/testing.md`. These assert corpus
notation rather than `lib/` behavior, so the honest sabotage is at the corpus:
temporarily revert one emitted cond to `_statifier_unbound` (and separately to
`== undefined`), confirm red, revert. Record that as the one-line note, e.g.
`# sabotage: revert test528's cond to _statifier_unbound -> red`.

### Success Criteria:

#### Automated Verification:

- [ ] `mix test test/corpus/boundness_notation_test.exs` passes.
- [ ] Full `mix quality` is green, attested by `mix gate.verify`. Use
      `mix quality --profile loop` while iterating.
- [ ] The new test runs in the default suite (it appears in `mix test` output
      without `--include scxml_w3`).
- [ ] `test/passing_tests.json` is unmodified; `internal_tests`' existing globs
      already cover `test/corpus/`, so `mix test.regression` picks the new test
      up with no registry edit.

#### Manual Verification:

- [ ] Each sabotage claimed in a comment was actually performed and observed
      red, then reverted.
- [ ] The failure message on a seeded violation names the file and is
      actionable for someone who has never read this plan.
- [ ] No regressions in related features: the other `test/corpus/` guards still
      pass and the new test does not duplicate what
      `emitted_paths_test.exs` already asserts.

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause for the human
to confirm the sabotage evidence. In looped execution, the Automated
Verification gates advancement and the Manual items are deferred.

---

## Corpus/Ratchet Notes

- **Regeneration is required, and scoped to `test/scxml_tests/`.** The XSL
  mtime guard (`mise.toml:138`) forces a retransform of all ~198 documents, but
  only the 24 sentinel files can change content.
- **`test/passing_tests.json` is untouched.** None of the 24 files is in it
  (re-verified in this worktree), the change removes no pattern, and the gate
  guard's ratchet check fires only on removals
  (`lib/mix/statifier/gate_guard.ex:206-236`). **No
  `docs/quality-gate-changes.md` entry is obliged** - and one would be a
  human's call to write, not an agent's (ADR-0011).
- **Nothing is ratcheted in.** No sentinel test can pass before st-af3.2 wires
  `cond`; the 15 root-shaped files additionally need st-af3.3. `mix
  test.baseline --add` is not run in either phase.
- **Prerequisites for the regeneration**: a JRE (mise provides Temurin 21) and
  network access for the one-time Saxon download from SourceForge. The W3C
  sources come from the local mirror at
  `~/repos/github/ex_statechart/test/scxml_w3/cases` via `CORPUS_W3_MIRROR`,
  avoiding the 198 sequential `curl`s that `tools/corpus/README.md:31-45` warns
  can 429. No SCION clone is needed, because `test/scion_tests/` is not
  regenerated.

## Testing Strategy

### Unit Tests

- `test/corpus/boundness_notation_test.exs` (Phase 2) is the only new test.
  It covers: the sentinel is absent; no non-strict comparison against
  `undefined` exists; the strict form is present somewhere (non-vacuity).
- No `lib/` behavior changes in this plan, so no `lib/` test changes are
  needed. Predicator 5.0's `undefined` semantics are already characterized by
  `docs/research/260812-st-p3t-predicator-5-bump.md` and by this bead's
  research; re-asserting a dependency's behavior in this suite would be
  testing predicator, not statifier.
- The 24 regenerated conformance files remain excluded from the default run by
  `test/test_helper.exs:1` and remain failing for reasons this plan does not
  address (stubbed `cond`; absent `<data>` lowering). That is the expected
  state at the end of this plan.

### Manual Testing Steps

1. Regenerate a second time after Phase 1's commit and confirm `git status` is
   clean - the determinism `tools/corpus/README.md:108-115` records should hold
   for this tree too.
2. Read `test/scxml_tests/mandatory/system_variables/test319_test.exs` and
   confirm the cond reads `_event !== undefined`, which the research verified
   evaluates `{:ok, false}` and takes the `<else>` branch test319 asserts.
3. Read `test/scxml_tests/mandatory/data/test277_test.exs` and confirm the cond
   reads `Var1 === undefined`, and that it is understood to still error at
   runtime until st-af3.3 seeds `<data>` - the failure mode moved from "unbound
   sentinel" to "unbound `Var1`", which is the strictly better failure this
   plan is buying.

## References

- Source document:
  `docs/research/260812-st-unt-boundness-sentinel-vs-on-unbound-error.md`
- Predecessor research: `docs/research/260812-st-p3t-predicator-5-bump.md`
  (section 5: `undefined` ground truth, and why the XSL must emit `===`)
- Origin of the idiom: `docs/research/260803-st2-qjs-predicator-path-assign.md`
- The templates' original spec:
  `docs/plans/260802-st2-00p.5-w3c-xsl-predicator-datamodel.md` section 5
- Where the collision was found:
  `docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md`
- Related ADRs: `docs/adr/0014-expression-spans-in-cond-diagnostics.md`
  (item 5, kept intact), `docs/adr/0004-predicator-as-the-datamodel.md`,
  `docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`
- Similar implementation: `test/corpus/emitted_paths_test.exs` (the corpus
  guard Phase 2 models), `tools/corpus/scxml_w3/check_exprs.exs:100-140`
- Bead: st-unt. Handoffs: st-af3.2 (wires `cond`), st-af3.3 (`<data>` seeding -
  carries the corpus requirement as a note), st-af3.6 and st-cmq.6/st-cmq.7
  (non-`<data>` roots), st-af3.8 (ratchets what then passes).
