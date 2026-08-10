---
date: 2026-08-10
issue: st-a89
status: draft
---

# Strip process terminology from comments and maintained guides

## Overview

ADR-0018 rules that process artifacts - bead IDs, plan phase and step numbers,
plan-document decision numbers, plan filenames, and `wurk`/beads tooling jargon
- do not belong in comments, moduledocs, doc strings or test descriptions under
`lib/` and `test/`, nor in the four maintained guides under `docs/`. The tree
predates the record and does not comply. This plan sweeps it, subsystem by
subsystem, using ADR-0018 point 5's rewrite protocol: restate the durable fact
the reference was standing in for rather than deleting the sentence.

Beads issue: `st-a89`

## Current State Analysis

Measured on this branch at `2143243`, with a bead-ID pattern tightened to avoid
false positives (see "The regex trap" below):

- **102 files** under `lib/` and `test/` carry at least one offending
  reference, **443 lines** in total.
- The heaviest concentrations are the interpreter and its supporting structs:
  `lib/statifier/interpreter/exit_entry.ex` (43 lines),
  `lib/statifier/interpreter/selection.ex` (27),
  `lib/statifier/machine_state.ex` (26), `lib/statifier/effect.ex` (26),
  `lib/statifier/validator/error.ex` (17), `lib/statifier/machine/state.ex` (15).
- Four shapes dominate. Plan-decision numbers are the most common
  (`## Return shapes (Decision 2)`, `## Ordering (Decision 4)` as moduledoc
  section headings in `exit_entry.ex`). Bead IDs are next
  (`st-wju.1's own kind field is unconstrained by this bead`). Numbered phases
  appear as table columns (`lib/statifier/machine/state.ex` lines 21-32 tag every
  struct field with `Phase 2`/`Phase 4`/`Phase 5`). Tooling jargon is rarer but
  present (`the core-engine epic (st-wju)` in `lib/statifier/effect.ex:39`,
  `this bead` in ten places).
- Of the four bound guides, `docs/architecture.md` and `docs/datamodel.md` are
  already clean. `docs/observability.md` and `docs/testing.md` are not.

### The regex trap

The obvious pattern `st-[a-z0-9]{3}` matches hyphenated English:
`te**st-cou**nt`, `d**st-pre**fix`, `wide**st-sco**ped`, `--te**st-sco**pe`,
`te**st-onl**y`, `fir**st-fai**lure`, `adr-judge-te**st-git**-repo`. A naive
grep reports ~20 phantom offenders across `lib/mix/`, `test/mix/` and
`test/support/`. Every grep in this plan uses the tightened pattern:

```
(^|[^A-Za-z0-9])st-[0-9a-z]{3}([.][0-9]+)?([^A-Za-z0-9]|$)|\b(Phase|Step) [0-9]|\b[Dd]ecision [0-9]+|docs/(plans|research)/|wurk:|this bead|\bepic\b
```

Run it through `bash -c` rather than the interactive fish shell, which mangles
the bracket groups.

### Key Discoveries

- **ADR-0018 point 2 names four categories that must survive untouched**: ADR
  numbers, W3C SCXML spec sections and Appendix D function names, the
  `# sabotage:` note (including the `# sabotage: n/a - ...` form), and stable
  `docs/*.md` paths. The unnumbered English word "phase" also survives -
  `Statifier.Compiler`'s "This phase interns every state to a flat tuple" is
  describing a compiler pass, not citing a plan.
- **ADR-0018 point 3 makes tooling modules bound but not violations.**
  `Mix.Statifier.AdrGuard`, `Mix.Statifier.AdrJudge` and
  `Mix.Statifier.GateGuard` may name `.claude/wurk/**`, `docs/adr/` and the gate
  ledger, because those are their own inputs. Their *narrative asides* are
  bound: `lib/mix/statifier/adr_judge.ex:28` (`st-6f7 Phase 4 ran the fixture
  corpus`) goes; the same file naming `docs/adr/` as a path it scans stays.
  The test is whether removing the reference removes information about what the
  code does.
- **Test data is not a comment.** `test/mix/statifier/gate_guard_test.exs`
  lines 98, 195 and 209 embed `st-xyz` and `st-h6p` inside string literals that
  are the *simulated diff and ledger content the guard is being run against*.
  Rewriting them would break the tests and would remove nothing from any
  comment. They stay. This is the single largest source of wrongly-flagged
  lines after the regex trap.
- **`docs/testing.md` lines 65-75 stay in full.** ADR-0018 point 4's borderline
  rule is that a citation is allowed when the cited document is the evidence
  for a claim and banned when it is the origin story of the code. The ADR-judge
  false-negative table is keyed to the plan phases that produced each prompt
  revision; the numbers are uninterpretable without them. That block keeps its
  `Phase 2`/`Phase 4` column labels, its `st-6f7 Phase 2` prose at line 68, and
  its `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` citation at line
  75.
- **`docs/observability.md`'s offender is structural, and the fix is already
  decided.** Lines 146-169 are a `## Implementation checklist` section of `- [x]`
  boxes, each tagged with the bead that owns the seam. st-a89's notes record a
  DECIDED resolution (2026-08-10): convert the section, do not merely strip the
  tags. This plan executes that decision in Phase 9; it is not reopened.
- **`docs/testing.md:42` carries an offender the bead notes did not list**:
  "plus st-c8c's reason on top". It is an origin story of the same shape as
  lines 174 and 179 and is in scope.
- **No `lib/` behavior changes anywhere in this plan.** Every phase is a
  comments-and-prose diff. That is what makes `mix quality` a meaningful but
  cheap per-phase gate: a green gate proves the sweep did not accidentally edit
  code, delete a `# sabotage:` note that a convention test asserts on, or break
  a doctest.

## Desired End State

The tightened grep over `lib/`, `test/`, `docs/architecture.md`,
`docs/datamodel.md`, `docs/testing.md` and `docs/observability.md` returns only
lines on the allowed-residual list this plan enumerates (test data literals in
`gate_guard_test.exs`, and `docs/testing.md` lines 65-75). Every rewritten
comment states its fact without needing a bead, a plan or the tracker to make
sense. `mix quality` is green. No `# sabotage:` note, ADR citation, W3C spec
citation or Appendix D function name was removed or altered anywhere in the
sweep.

Verify with:

```bash
bash -c 'grep -rEn "(^|[^A-Za-z0-9])st-[0-9a-z]{3}([.][0-9]+)?([^A-Za-z0-9]|$)|\b(Phase|Step) [0-9]|\b[Dd]ecision [0-9]+|docs/(plans|research)/|wurk:|this bead|\bepic\b" lib/ test/ docs/architecture.md docs/datamodel.md docs/testing.md docs/observability.md'
git diff --stat main...HEAD    # every changed line is a comment, docstring, or .md prose
mix quality
```

## What We're NOT Doing

- **Not adding the AdrGuard bead-ID check.** ADR-0018's consequences call for it
  and st-wjg tracks it separately, deliberately, so it can constrain new code
  while this sweep is still walking the backlog. It is gate-relevant and needs
  an ADR-0011 ledger entry; this sweep touches no gate configuration and needs
  no ledger entry.
- **Not touching the exempt documents.** `docs/adr/`, `docs/plans/`,
  `docs/research/`, `docs/quality-gate-changes.md`, `changelog.d/`, and
  `docs/workflow.md` all keep their bead IDs. In the first five the bead ID *is*
  the entry; in the last the process is the subject.
- **Not rewriting `docs/testing.md` lines 65-75.** See Key Discoveries.
- **Not changing any executable code.** If a rewrite appears to require a code
  change (renaming a function whose name encodes a phase, say), stop and report
  rather than widening the diff.
- **Not editing `docs/architecture.md` or `docs/datamodel.md`.** They are bound
  by ADR-0018 point 4 but already comply; they are named in the final
  verification grep and nothing else.
- **Not adding a changelog fragment.** No user-facing behavior changes
  (`changelog.d/README.md`).
- **Not backfilling comments that are merely thin.** The sweep restates facts
  that are already there. Improving a comment beyond removing its process
  reference is a separate concern and inflates a review that is otherwise
  mechanical to check.

## Implementation Approach

Ten phases: eight over `lib/`/`test/` split along the pipeline's module
boundaries (lowering, compiler/machine, three interpreter slices, effects,
validator, tooling), one over the two non-compliant guides, and a final
verification sweep. Each phase pairs a subsystem's `lib/` files with its own
tests, because the same reference usually appears on both sides and a reviewer
wants to see them together.

Each phase is independently committable and independently gate-verifiable:
nothing in phase N depends on phase N+1, and every phase leaves the tree
compiling and green on its own. The phases can also be run out of order.

### The rewrite protocol, applied per comment

ADR-0018 point 5 is the normative protocol and it requires judgment per comment,
never find-and-replace. For each offending line:

1. **Read the surrounding comment in full.** The reference is usually load
   bearing for a sentence, not a parenthetical.
2. **Recover the WHY from git.** Run
   `git log -S'<distinctive phrase from the comment>' --oneline -- <file>` or
   `git blame -L <line>,<line> -- <file>` to find the introducing commit. Read
   its message: `wurk:commit` writes the bead and the functional change into
   every commit, so the message usually states the fact the comment abbreviated.
3. **Where the comment cites a plan or research document, open it.** For
   `plan Decision N` references, the plan document's numbered decision states
   the invariant in full. Fold the WHY-relevant part of that decision into the
   comment, then strip the citation. Do not leave a comment that is thinner than
   what it replaced.
4. **Restate the fact.** `Phase 4 populates transitions` becomes
   `the compiler's transition pass populates this`. `st-af3 replaces
   condition_match/2's stub` becomes `condition_match/2 is a stub returning
   true; the datamodel evaluation that replaces it is not yet implemented`.
   `plan Decision 10: ids are unique and non-empty` becomes the invariant stated
   on its own.
5. **If restating leaves nothing, delete.** Point 5's escape hatch: the comment
   was about the process.

### What must survive every phase, checked before the phase's commit

- Every `# sabotage:` line, unchanged, including `# sabotage: n/a - ...`
  (CLAUDE.md and `docs/testing.md` require them, and a convention test asserts
  on their presence).
- Every `ADR-00NN` citation.
- Every W3C SCXML section reference and every Appendix D function name in
  snake_case (`selectTransitions`/`select_transitions`, `exitStates`,
  `enterStates`, `computeExitSet`, and friends). ADR-0002 makes the spec
  normative and these are the highest-value comments in the tree.
- Every stable `docs/*.md` path citation.
- The unnumbered English word "phase" where it describes a pipeline pass.

Per-phase check:

```bash
git diff -U0 -- <phase paths> | grep -E '^-' | grep -E 'sabotage|ADR-0[0-9]{3}|Appendix D|w3\.org|docs/[a-z]+\.md'
```

Any output is a line the sweep removed that it should not have. Expected result:
either empty, or only lines that also appear as `+` additions (a reflow).

### Commits

One commit per phase, s-form title under 50 chars, body wrapped at 72, naming
the subsystem and what was restated. `Refs: st-a89`. Per the repo's authority
table, commit on this worktree branch after a full green `mix quality`; do not
push, do not open a request, do not close the bead.

---

## Phase 1: Lowering, parser, and Document structs

### Overview

21 files, 78 offending lines. The lowering layer and the `Document` structs it
produces. Concentrated in `lib/statifier/document/state.ex` (14) and
`lib/statifier/lowering/error.ex` / `builders.ex` (8 each).

### Changes Required:

#### 1. Lowering and parser
**Files**: `lib/statifier/lowering.ex`, `lib/statifier/lowering/attributes.ex`,
`lib/statifier/lowering/builders.ex`, `lib/statifier/lowering/error.ex`,
`lib/statifier/lowering/namespace.ex`, `lib/statifier/parser.ex`,
`lib/statifier/parser/markup.ex`
**Changes**: Strip `Decision N` citations, bead IDs, `docs/plans/` filenames and
numbered phases from moduledocs and inline comments, restating each fact per the
protocol. `lib/statifier/lowering/namespace.ex` mixes all four shapes and needs
the plan document read before rewriting.

#### 2. Document structs
**Files**: `lib/statifier/document.ex`, `lib/statifier/document/content.ex`,
`lib/statifier/document/donedata.ex`, `lib/statifier/document/initial.ex`,
`lib/statifier/document/state.ex`, `lib/statifier/document/transition.ex`
**Changes**: `document/state.ex:34` reads `st-wju.1's own kind field is
unconstrained by this bead` - two process references in one sentence. Restate as
what constrains `kind` and what does not, in terms of the compiler pass that
sets it.

#### 3. Tests
**Files**: `test/statifier/document_test.exs`,
`test/statifier/document/initial_test.exs`,
`test/statifier/document/layer_test.exs`,
`test/statifier/document/transition_test.exs`,
`test/statifier/lowering/coverage_test.exs`,
`test/statifier/lowering/layer_test.exs`,
`test/statifier/lowering/location_test.exs`,
`test/statifier/lowering/unsupported_test.exs`
**Changes**: Same protocol applied to comments and `test`/`describe`
descriptions. Leave every `# sabotage:` line byte-identical.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (`mix quality --profile loop` between edits, not
      as the phase gate)
- [x] The tightened grep over `lib/statifier/lowering* lib/statifier/document*
      lib/statifier/parser* test/statifier/lowering test/statifier/document*`
      returns zero hits
- [x] `git diff -U0` over the phase paths removes no `sabotage`, `ADR-0`,
      `Appendix D`, `w3.org` or `docs/*.md` line (the check above)
- [x] `git diff` over the phase paths shows no change to any executable line -
      comments, `@moduledoc`/`@doc`/`@typedoc` and test descriptions only

#### Manual Verification:
- [ ] Each rewritten comment reads correctly to someone who has never seen the
      bead or the plan: it states a fact about the code, not about the work
- [ ] Where a `Decision N` citation was removed, the invariant that decision
      recorded is now stated in the comment itself
- [ ] Comments touching `lib/statifier/` still describe behavior that matches
      the W3C spec; no Appendix D name or spec section was altered

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full gate as the phase gate. In interactive execution, pause here for the human
to confirm the manual review before moving on. In looped (`--loop`) execution,
the Automated Verification list gates advancement via `/wurk:commit --auto` and
the Manual Verification items are deferred and surfaced once at the end.

---

## Phase 2: Compiler and Machine

### Overview

15 files, 72 offending lines. Note that `test/statifier/compiler_test.exs` is
*not* in this list: its four apparent hits are the regex trap
("te**st-cou**nt" and friends), and it needs no edit.
`lib/statifier/machine/state.ex` alone carries a
15-row struct table whose right-hand column is `Phase 2` / `Phase 4` / `Phase 5`
(lines 21-32), plus line 35's "left at their empty defaults until Phase 4
populates them".

### Changes Required:

#### 1. Machine.State's field table
**File**: `lib/statifier/machine/state.ex`
**Changes**: The `Phase N` column is answering "which compiler pass writes this
field". Replace the column values with the pass, not the plan phase - for
example `Phase 2` becomes `interning pass`, `Phase 4` the transition pass,
`Phase 5` the executable-content pass. Confirm each mapping against
`lib/statifier/compiler.ex` rather than assuming the numbering; the compiler is
the authority for what its passes are called. Line 23's `(plan Decision 3)`
aside on `last` states the self-inclusive descendant range invariant - keep the
invariant, drop the citation. Line 35 becomes a sentence about which pass
populates the fields.

#### 2. Compiler
**Files**: `lib/statifier/compiler.ex`, `lib/statifier/compiler/error.ex`,
`lib/statifier/compiler/expressions.ex`
**Changes**: `compiler.ex` carries 12 lines mixing numbered phases and decision
numbers. Take care to preserve the unnumbered-"phase" prose ADR-0018 point 2
explicitly protects - `compiler.ex` uses "this phase interns every state" as
ordinary English and it stays. `compiler/expressions.ex` cites ADR-0014 near its
`Decision N` references; the ADR citation survives.

#### 3. Machine structs and tests
**Files**: `lib/statifier/machine.ex`, `lib/statifier/machine/block.ex`,
`lib/statifier/machine/content.ex`, `lib/statifier/machine/content/log.ex`,
`lib/statifier/machine/content/raise.ex`, `lib/statifier/machine/donedata.ex`,
`lib/statifier/machine/transition.ex`,
`test/statifier/compiler/acceptance_test.exs`,
`test/statifier/machine_test.exs`, `test/statifier/machine/content_test.exs`,
`test/statifier/machine/transition_test.exs`
**Changes**: `machine.ex`'s moduledoc is ADR-0018's own worked example ("Phase 4
populates `transitions`" -> "the compiler's transition pass populates this");
use the ADR's wording.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] The tightened grep over `lib/statifier/compiler* lib/statifier/machine.ex
      lib/statifier/machine test/statifier/compiler* test/statifier/machine*`
      returns zero hits
- [ ] The removed-line check over the phase paths is clean
- [ ] No executable line changed in the phase's diff

#### Manual Verification:
- [ ] Every `Phase N` in `machine/state.ex`'s table maps to the compiler pass
      that actually writes that field, verified against `compiler.ex`
- [ ] The unnumbered word "phase" survives wherever it described a compiler pass
- [ ] Comments touching `lib/statifier/` still match the W3C spec; no Appendix D
      name or spec citation was altered

**Implementation Note**: As Phase 1.

---

## Phase 3: Interpreter selection and name matching

### Overview

5 files, 37 offending lines. `lib/statifier/interpreter/selection.ex` carries 20
`Decision N` citations and 7 bead IDs; `name_match.ex` carries 2.
`test/statifier/interpreter/selection_acceptance_test.exs:243` says "the exact
v1 gap this bead names".

### Changes Required:

#### 1. Selection
**Files**: `lib/statifier/interpreter/selection.ex`,
`lib/statifier/interpreter/name_match.ex`
**Changes**: `selection.ex`'s moduledoc uses `(Decision N)` as section-heading
suffixes. Retitle the headings to name the thing they describe and fold each
decision's substance into the section body. This module is one of ADR-0012's
named seams and `docs/observability.md` cites it by module name - that citation
is a stable `docs/*.md` reference and is allowed in both directions.

#### 2. Tests
**Files**: `test/statifier/interpreter/selection_test.exs`,
`test/statifier/interpreter/selection_acceptance_test.exs`,
`test/statifier/interpreter/selection_domain_test.exs`
**Changes**: `selection_acceptance_test.exs:243` refers to a behavioral gap in
the v1 engine at `../statifier` (read-only reference). Read v1 only if the
comment is not self-explanatory after the git-history step; restate as the
concrete matching behavior (`["foo", "*"]` comparison semantics), not as a bead's
scope.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] The tightened grep over `lib/statifier/interpreter/selection.ex
      lib/statifier/interpreter/name_match.ex test/statifier/interpreter/selection*`
      returns zero hits
- [ ] The removed-line check over the phase paths is clean
- [ ] No executable line changed in the phase's diff

#### Manual Verification:
- [ ] `selection.ex`'s moduledoc section headings name the behavior rather than
      a decision number, and each section still states its invariant
- [ ] `select_transitions`/`selectTransitions` and every other Appendix D name
      and spec section in the module is untouched, and the surrounding prose
      still matches the pseudocode line for line (ADR-0002)

**Implementation Note**: As Phase 1.

---

## Phase 4: Interpreter exit and entry

### Overview

4 files, 57 offending lines - the densest single module in the tree.
`lib/statifier/interpreter/exit_entry.ex` accounts for 43 of them, mostly
`Decision N` references, with 9 bead-ID lines and 3 `this bead` mentions among
them, including six moduledoc section
headings of the form `## Return shapes (Decision 2)`, `## Ordering (Decision 4)`,
`## The content seam (Decision 6)`, `## History recording (Decision 7)`,
`## The entry set (Decision 3)`.

### Changes Required:

#### 1. ExitEntry
**File**: `lib/statifier/interpreter/exit_entry.ex`
**Changes**: Line 10 reads "(`docs/observability.md` constraint 1, plan Decision
3 for this bead)" - the `docs/observability.md` half is an allowed stable-path
citation and stays; the rest goes. The `(Decision N)` heading suffixes come off
and each section's invariant is stated in its body. Line 106's "the boundary
decision this bead's own note" needs the introducing commit and the plan's
Decision 4 read before rewriting: the durable fact is the ordering rule, and the
comment must state it.

#### 2. Tests
**Files**: `test/statifier/interpreter/exit_entry_acceptance_test.exs`,
`test/statifier/interpreter/exit_entry_enter_test.exs`,
`test/statifier/interpreter/exit_entry_exit_test.exs`
**Changes**: `exit_entry_acceptance_test.exs:485` reads `AC: "a microstep
worked" - the closest this bead can get without ...`. Restate as what the test
actually proves and what it cannot yet reach, without the acceptance-criterion
framing or the bead.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] The tightened grep over `lib/statifier/interpreter/exit_entry.ex
      test/statifier/interpreter/exit_entry*` returns zero hits
- [ ] The removed-line check over the phase paths is clean
- [ ] No executable line changed in the phase's diff

#### Manual Verification:
- [ ] Each of the six retitled moduledoc sections still states the invariant its
      decision number stood for; the module reads as a specification of the two
      functions, not as a plan summary
- [ ] `exit_states/2` and `enter_states/2` still describe the Appendix D
      `exitStates`/`enterStates` pseudocode line for line, and `computeExitSet`
      and every other spec name survives unchanged (ADR-0002)
- [ ] `docs/observability.md`'s "constraint 1" citation on line 10 survives

**Implementation Note**: As Phase 1.

---

## Phase 5: Interpreter content and MachineState

### Overview

6 files, 47 offending lines. `lib/statifier/machine_state.ex` (26),
`lib/statifier/interpreter/content.ex` (11), and their tests.

### Changes Required:

#### 1. MachineState and interpreter content
**Files**: `lib/statifier/machine_state.ex`,
`lib/statifier/interpreter/content.ex`
**Changes**: `machine_state.ex:40` reads "a caller, rather than this bead adding
it as a placeholder" - restate as why the field is caller-supplied rather than
defaulted. ADR-0018's own consequences flag `machine_state.ex`'s `(st-cmq)`
sitting directly below an ADR-0003 citation: remove the bead, keep ADR-0003.

#### 2. Tests
**Files**: `test/statifier/interpreter/content_test.exs`,
`test/statifier/interpreter/content_acceptance_test.exs`,
`test/statifier/machine_state_test.exs`,
`test/statifier/machine_state_acceptance_test.exs`
**Changes**: `content_acceptance_test.exs:292-294` describes a round trip "this
bead can reach without st-wju.6" - the durable fact is that the macrostep loop
is not yet implemented, so the test asserts the enter/queue round trip instead.
State that. `machine_state_acceptance_test.exs` has the ADR-0003-plus-`(st-cmq)`
shape on one line; keep the ADR.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] The tightened grep over `lib/statifier/machine_state.ex
      lib/statifier/interpreter/content.ex test/statifier/interpreter/content*
      test/statifier/machine_state*` returns zero hits
- [ ] The removed-line check over the phase paths is clean
- [ ] No executable line changed in the phase's diff

#### Manual Verification:
- [ ] Every ADR-0003 citation that sat beside a removed bead ID survives
- [ ] Comments describing what is not yet implemented say so as a fact about the
      code, with no bead named as the thing that will implement it
- [ ] The touched `lib/statifier/` functions still match Appendix D line for
      line and their spec citations are intact

**Implementation Note**: As Phase 1.

---

## Phase 6: Effects, events, and executable content

### Overview

20 files, 63 offending lines. `lib/statifier/effect.ex` (26) dominates; the
`Effect.Trace.*` modules carry one `Decision N` each.

### Changes Required:

#### 1. Effect and trace types
**Files**: `lib/statifier/effect.ex`, `lib/statifier/effect/cancel.ex`,
`lib/statifier/effect/done.ex`, `lib/statifier/effect/invoke.ex`,
`lib/statifier/effect/log.ex`, `lib/statifier/effect/send.ex`,
`lib/statifier/effect/send_delayed.ex`,
`lib/statifier/effect/trace/content_executed.ex`,
`lib/statifier/effect/trace/done.ex`, `lib/statifier/effect/trace/entry_set.ex`,
`lib/statifier/effect/trace/event_dequeued.ex`,
`lib/statifier/effect/trace/exit_set.ex`,
`lib/statifier/effect/trace/macrostep_stable.ex`,
`lib/statifier/effect/trace/transitions_selected.ex`
**Changes**: `effect.ex` lines 22-35 carry a 13-row `## The vocabulary` table
whose third column, `Produced by (today / eventually)`, is a bead ID on every
row (`st-cmq`, `st-wju.3` through `st-wju.6`). This is the structural twin of
`machine/state.ex`'s `Phase N` column in Phase 2 and gets the same treatment:
the column reduces to the *producer and its status*, verified against the
current tree rather than against the bead that will eventually add one. Retitle
the column `Produced by` and give each row either the function that emits it
today (`exit_interpreter`, `<log>` execution, `select_transitions` returning)
or `not yet produced` for the variants nothing constructs yet - the
parenthetical already on each row is most of that answer. Confirm each row
against the actual callers in `lib/statifier/interpreter/` before writing it;
do not carry the bead's forward-looking claim over as fact.

`effect.ex:39-42` then says "The core-engine epic (st-wju) only ever produces
`:log` and `:done` itself ... until st-cmq gives them a caller - that is the
point of this bead (Decision 14)": four process references in one sentence. The
durable fact is that the interpreter today produces only `:log` and `:done`, and
that the `<send>`/`<cancel>`/`<invoke>` effects are defined but unproduced
because nothing constructs them yet. `effect/log.ex:15` repeats the same "epic"
phrasing and takes the same restatement. `effect/send_delayed.ex:7`
says "this bead only defines the shape it schedules" - restate as the module
defining the effect shape, with the scheduling side not yet implemented.
The trace modules are ADR-0012's vocabulary and each cites it; keep every
ADR-0012 citation.

#### 2. Events and executable content
**Files**: `lib/statifier/event.ex`, `lib/statifier/event/cause.ex`,
`lib/statifier/executable_content.ex`,
`lib/statifier/executable_content/context.ex`,
`test/statifier/event_test.exs`,
`test/statifier/executable_content_test.exs`
**Changes**: `event/cause.ex` mixes bead IDs with a `docs/plans/` filename; read
the plan for the cause-metadata rationale (ADR-0012's identity-plus-step
requirement) and fold it in before stripping.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] The tightened grep over `lib/statifier/effect* lib/statifier/event*
      lib/statifier/executable_content* test/statifier/event_test.exs
      test/statifier/executable_content_test.exs` returns zero hits
- [ ] The removed-line check over the phase paths is clean
- [ ] No executable line changed in the phase's diff

#### Manual Verification:
- [ ] Every ADR-0012 and ADR-0003 citation in the effect and trace modules
      survives
- [ ] The statements about which effect variants exist today are true of the
      current tree, not copied from a stale comment
- [ ] Touched `lib/statifier/` comments still match the spec and Appendix D

**Implementation Note**: As Phase 1.

---

## Phase 7: Validator

### Overview

19 files, 51 offending lines. `lib/statifier/validator/error.ex` (17) and
`context.ex` (5) lead; the twelve `checks/` modules carry one to three each,
almost all `Decision N` citations naming the invariant each check enforces.

### Changes Required:

#### 1. Validator core
**Files**: `lib/statifier/validator.ex`, `lib/statifier/validator/context.ex`,
`lib/statifier/validator/error.ex`
**Changes**: `error.ex` mixes bead IDs, a `docs/plans/` filename and nine
`Decision N` citations; the plan document is worth opening once here since most
of the `checks/` modules cite the same numbering.

#### 2. Checks
**Files**: `lib/statifier/validator/checks/boilerplate.ex`, `content.ex`,
`default_entry.ex`, `default_transition.ex`, `enums.ex`, `final.ex`,
`history.ex`, `ids.ex`, `initial_element.ex`, `initial_targets.ex`,
`targets.ex` (all under `lib/statifier/validator/checks/`)
**Changes**: The dominant shape is `plan Decision N: <invariant>` - ADR-0018
point 5's third worked example. Keep the invariant, drop the citation; the check
depends on the invariant and not on the document that chose it.
`checks/default_transition.ex:30` reads "st-l5k.4's contract, not this bead's" -
restate as which module owns the contract.

#### 3. Tests
**Files**: `test/statifier/validator_test.exs`,
`test/statifier/validator/checks/boilerplate_test.exs`,
`final_test.exs`, `history_test.exs`, `ids_test.exs` (all under
`test/statifier/validator/checks/`)
**Changes**: Same protocol; leave `# sabotage:` lines untouched.
`test/statifier/validator/checks/default_entry_test.exs` is a regex-trap false
positive and needs no edit.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] The tightened grep over `lib/statifier/validator*
      test/statifier/validator*` returns zero hits
- [ ] The removed-line check over the phase paths is clean
- [ ] No executable line changed in the phase's diff

#### Manual Verification:
- [ ] Each check module states the invariant it enforces without naming a
      decision number, and the invariant matches what the code actually checks
- [ ] Touched `lib/statifier/` comments still match the spec's validation
      requirements and every spec citation survives

**Implementation Note**: As Phase 1.

---

## Phase 8: Mix tasks, test support, and fixtures

### Overview

12 files, 34 offending lines - but this is the phase with the most judgment per
line, because ADR-0018 point 3 governs it and because most of the
false-positive shapes live here.

### Changes Required:

#### 1. Tooling modules (ADR-0018 point 3)
**Files**: `lib/mix/statifier/adr_guard.ex`, `lib/mix/statifier/adr_judge.ex`,
`lib/mix/tasks/test.regression.ex`
(`lib/mix/statifier/gate_guard.ex` and `lib/mix/tasks/gate.verify.ex` are
regex-trap false positives - `d**st-pre**fix`, `--te**st-sco**pe`,
`fir**st-fai**lure` - and need no edit)
**Changes**: Strip only the narrative asides. `adr_judge.ex:28` and `:32`
(`st-6f7 Phase 4 ran the fixture corpus`, `grounding the refute prompt (Phase 2)`)
are the model-choice measurement's origin story in a moduledoc - the durable
fact is that `@default_model` was chosen on measured wall time with no accuracy
difference, and `docs/testing.md` holds the numbers, so cite that stable path
instead. `adr_judge.ex:119` and `:156` cite
`docs/plans/260807-st-laz-adr-judge-multi-adr.md` for a survey; fold the
survey's conclusion into the comment and drop the filename. `adr_judge.ex:167`
is the ADR-0018-flagged line where `st-6yb` and `ADR-0015` share one line -
remove the bead, keep ADR-0015. `adr_judge.ex:215` and `:647`, and
`adr_guard.ex:18`, `test.regression.ex:103` follow the same pattern. What must
NOT change: any mention of `.claude/wurk/**`, `docs/adr/`, or
`docs/quality-gate-changes.md` as paths these modules operate on - point 3 makes
those the code's own inputs.

#### 2. Tooling tests
**Files**: `test/mix/statifier/adr_judge_test.exs`,
`test/mix/statifier/adr_judge_corpus_test.exs`,
`test/mix/statifier/gate_guard_test.exs`,
`test/mix/tasks/adr_judge_test.exs`
(`test/mix/statifier/adr_guard_test.exs` and
`test/mix/tasks/test_regression_test.exs` are regex-trap false positives and
need no edit)
**Changes**: Comment-only. `test/mix/tasks/adr_judge_test.exs:318` is the
second ADR-0018-flagged line where a bead sits directly above an ADR-0015
citation - remove the bead, keep the ADR.
**MUST NOT CHANGE**: `test/mix/statifier/gate_guard_test.exs` lines 98, 195 and
209. Those `st-xyz` and `st-h6p` strings are the simulated diff and ledger
*input* the guard is run against; they are test data, not comments, and editing
them changes what the test exercises.

#### 3. Test support and fixtures
**Files**: `test/support/case.ex`, `test/support/test_content.ex`,
`test/support/tmp_dir.ex`, `test/statifier/tmp_dir_test.exs`,
`test/fixtures/adr_judge/manifest.exs`
**Changes**: `test/support/case.ex:16` and `:125` name "the Phase 1/2 engine
API"; line 125 is inside a runtime message string a developer reads when a
helper is unimplemented. Both become a description of the engine API being
waited on, by module and function rather than by phase number.
`test/statifier/tmp_dir_test.exs:156`'s assertion message carries `(st-0vz)` -
restate as the failure mode (concurrent runs computing byte-identical scratch
paths). `test/support/tmp_dir.ex` lines 9, 14 and 67 are the same incident;
`docs/testing.md` will state the failure mode after Phase 9, so cite that stable
path if a pointer is wanted. `test/fixtures/adr_judge/manifest.exs:6`'s `note:`
is prose surfaced in a test failure message and its sibling notes describe the
fixture rather than its origin - drop the `st-6f7` prefix, keep "live repro:".

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] The tightened grep over `lib/mix test/mix test/support
      test/statifier/tmp_dir_test.exs test/fixtures` returns exactly three
      hits: `test/mix/statifier/gate_guard_test.exs` lines 98, 195 and 209
- [ ] The removed-line check over the phase paths is clean
- [ ] `mix test test/mix test/statifier/tmp_dir_test.exs` passes (the assertion
      message rewrites are asserted on by the tests themselves)

#### Manual Verification:
- [ ] `AdrGuard`, `AdrJudge` and `GateGuard` still name every `.claude/wurk/**`,
      `docs/adr/` and gate-ledger path they operate on - point 3's "the code's
      own inputs"
- [ ] Every ADR-0015 citation that sat beside a removed bead ID survives
- [ ] `gate_guard_test.exs`'s simulated diff and ledger strings are byte
      identical to before

**Implementation Note**: As Phase 1. This phase touches no `lib/statifier/`
module, so the Appendix D conformance criterion does not apply.

---

## Phase 9: The maintained guides

### Overview

`docs/observability.md` and `docs/testing.md`. `docs/architecture.md` and
`docs/datamodel.md` are bound by ADR-0018 point 4 but already comply and are not
edited.

### Changes Required:

#### 1. docs/observability.md - convert the checklist
**File**: `docs/observability.md` lines 146-169
**Changes**: Execute the resolution recorded on st-a89 (2026-08-10). Each
checklist line does three jobs with three lifetimes: the seam requirement
(permanent, ADR-0012's substance - KEEP), the module that satisfies it (as
durable as the code - KEEP), the bead tag `st-wju.N` (dead on close - DROP), and
the `- [x]` checkbox (duplicates bead state - DROP).

Retitle the `Implementation checklist` heading to `Where the seams live`, delete
the `For the Phase 1 interpreter work and its reviews:` preamble along with the
checkbox framing, and render the entries as a two-column table under that new
heading. The worked example, as recorded on the bead:

```
| Seam | Where it lives |
|---|---|
| Appendix D query functions take and return plain values, unfused | `Statifier.Interpreter.Selection` |
| Compiled expressions carry their span table with the instructions (ADR-0014) | `Statifier.Compiler.Expressions.compile/3`, storing `%Predicator.Compiled{}` whole |
| `microstep` step function exists; macrostep folds over it | not yet implemented |
```

All eight existing entries carry over, each keeping its parenthetical module
list as the right-hand column. The ADR-0014 citation survives - ADR-0018 point 2
allows ADR numbers. The one unticked box renders as `not yet implemented`, and
**no bead reference is added to it**: that phrase is a true statement about the
code in a document ADR-0012 makes normative about these seams, and it rots the
way any doc sentence about code rots. A bead tag rots into meaninglessness
instead, which is the distinction ADR-0018 draws.

#### 2. docs/testing.md - restate three origin stories
**File**: `docs/testing.md` lines 42, 174, 179
**Changes**:
- Line 42: "plus st-c8c's reason on top" - restate the reason (the `:test`
  build's `@default_caller` raises on a forgotten `opts[:caller]`, so only the
  corpus module opts into the real CLI, visibly, at its own call site). The
  following lines already say this; the fix is to drop the ID and let the
  sentence carry itself.
- Line 174: `(st-0vz)` after the `rm_rf!`/`mkdir_p!` race - restate as the
  failure mode the incident exposed (two concurrent runs of the same test
  compute byte-identical paths and race).
- Line 179: `(st-iao; test/statifier/tmp_dir_test.exs itself used to do exactly
  that, mutating STATIFIER_TMP_ROOT process-globally mid-run)` - drop the ID,
  keep the parenthetical's substance, which is a real cautionary fact about the
  helper.

**MUST NOT CHANGE**: `docs/testing.md` lines 65-75 in their entirety - the
table's `Phase 2` / `Phase 4` row labels, the `st-6f7 Phase 2` prose at line 68,
and the `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` citation at
line 75. ADR-0018 point 4 allows a citation when the cited document is the
evidence for a claim, and those numbers are uninterpretable without knowing
which prompt revision produced them.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes (no Elixir changed; the gate confirms the docs
      edit broke nothing that reads these files)
- [ ] The tightened grep over `docs/architecture.md docs/datamodel.md
      docs/testing.md docs/observability.md` returns hits only on
      `docs/testing.md` lines 65-75
- [ ] `git diff docs/testing.md` shows no change within lines 65-75
- [ ] `docs/observability.md` contains `## Where the seams live` and no `- [ ]`
      or `- [x]` in that section

#### Manual Verification:
- [ ] Every seam listed in the old checklist appears as a table row, with the
      same modules named - no seam silently dropped in the conversion
- [ ] ADR-0012's normative claims about the seams read the same after the
      conversion as before; the table is a rendering change, not a weakening
- [ ] The `not yet implemented` row names no bead
- [ ] The three `docs/testing.md` rewrites each state the failure mode the
      incident exposed, so the paragraph is complete without the tracker

**Implementation Note**: As Phase 1. No `lib/statifier/` module is touched, so
the Appendix D conformance criterion does not apply.

---

## Phase 10: Final verification sweep

### Overview

The counts in this plan are a snapshot at `2143243`. Sibling branches land while
a sweep runs, and the per-phase greps are path-scoped. This phase runs the
whole-tree grep once, fixes any straggler with the same protocol, and records
the residual list.

### Changes Required:

#### 1. Whole-tree grep and residual audit
**Files**: whatever the grep turns up
**Changes**: Run the Desired End State grep across `lib/`, `test/` and the four
guides. Every remaining hit must be on the allowed-residual list:

| Residual | Why it stays |
|---|---|
| `test/mix/statifier/gate_guard_test.exs:98,195,209` | simulated diff/ledger input, not a comment |
| `docs/testing.md:65-75` | measurement provenance, ADR-0018 point 4 |

Anything else is a straggler: rewrite it per the protocol. If the grep and the
guard-survival check are both clean and nothing needed rewriting, this phase
produces no diff and makes no commit - it is satisfied by the recorded grep
output alone.

#### 2. Guard-survival audit over the whole sweep
**Changes**: Run the removed-line check against the full branch diff rather than
one phase's paths:

```bash
git diff -U0 main...HEAD | grep -E '^-' | grep -E 'sabotage|ADR-0[0-9]{3}|Appendix D|w3\.org|docs/[a-z]+\.md'
```

Every line it prints must have a matching `+` addition in the same hunk (a
reflow). Any line that was removed outright and not re-added is a violation of
ADR-0018 point 2 and must be restored.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes
- [ ] `mix gate.verify` confirms the run was a full, unprofiled, unscoped gate
- [ ] The whole-tree grep returns only the residuals in the table above
- [ ] `git diff main...HEAD` changes no executable line - the whole branch is
      comments, docstrings, test descriptions, and `.md` prose
- [ ] The whole-branch guard-survival check leaves no unmatched removal

#### Manual Verification:
- [ ] Spot-check ten rewritten comments across different phases: each reads
      correctly with no knowledge of beads, plans, or this sweep
- [ ] The `# sabotage:` note count is unchanged from `main`
      (`git grep -c 'sabotage:' | wc -l` on both sides)
- [ ] Interpreter comments still describe the Appendix D pseudocode line for
      line and every spec section reference is intact (ADR-0002)

**Implementation Note**: As Phase 1. If this phase's diff is empty, do not
create an empty commit; report the clean grep instead.

---

## Testing Strategy

### Unit Tests:

No new tests. This sweep changes no behavior, so there is nothing to sabotage
and no test to add - and adding one would be the wrong move, since ADR-0018's
mechanical enforcement is st-wjg's AdrGuard check, deliberately filed separately
so it can constrain new code while the sweep runs.

The existing suite is load bearing in three specific ways, and each phase's gate
exercises them:

- **Convention tests.** `test/statifier/tmp_dir_test.exs` scans every `.exs` for
  ExUnit's built-in `:tmp_dir` tag and asserts on a message string this sweep
  edits (Phase 8). The sabotage-note convention is likewise asserted by the
  suite; the gate catches a note removed by accident.
- **Doctests.** Elixir compiles `@doc` examples into tests. A moduledoc rewrite
  that mangles an example block goes red on the phase gate.
- **Compilation.** A botched heredoc or unbalanced `"""` in a moduledoc fails
  the gate's compile stage before any test runs, which is the main mechanical
  risk of a comment-only sweep of this size.

### Manual Testing Steps:

1. For each phase, read the phase's diff end to end. The reviewable question is
   the same on every hunk: does the new sentence state a fact about the code,
   and would a reader with no access to the tracker understand it?
2. Confirm no hunk removes an ADR number, a spec citation, an Appendix D name,
   or a `# sabotage:` line without re-adding it.
3. After Phase 9, read `docs/observability.md`'s new `## Where the seams live`
   section against the old checklist side by side and confirm every seam
   survived the conversion.
4. After Phase 10, run the whole-tree grep and confirm the only survivors are
   the two documented residuals.

## Judgment Calls Recorded

These were decided during planning rather than left to the implementer. Each is
noted so the reason survives into review.

1. **`docs/observability.md`'s checklist is converted, not merely de-tagged.**
   Decided on st-a89 (2026-08-10) and executed in Phase 9. Stripping the tags
   alone leaves a checklist of ticked boxes, which is bead state duplicated into
   a maintained guide - the thing point 4 is about, one level up from the tags.
2. **Developer-facing message strings are treated as bound.**
   `test/statifier/tmp_dir_test.exs:156` and `test/support/case.ex:125` carry
   process references inside runtime strings a developer reads on failure, not
   inside comments. Point 1's letter names comments, docstrings and test
   descriptions. Point 1's reason - authored prose whose reference rots - covers
   these identically, and rewriting them costs nothing, so Phase 8 rewrites
   them.
3. **`gate_guard_test.exs`'s `st-xyz`/`st-h6p` strings are not bound.** They are
   the input data the guard is exercised against; the reference has the same
   lifetime as the test, and removing it changes what the test checks.
4. **`test/fixtures/adr_judge/manifest.exs:6` is rewritten.** Its `note:` is
   surfaced in a failure message and its sibling notes all describe the fixture
   rather than its origin, so consistency and the point 5 protocol both point
   the same way.
5. **`docs/testing.md:42` is in scope** even though st-a89's notes list only
   lines 174 and 179. It is the same origin-story shape, and the sentence
   already carries its own reason in the lines beneath it.

## Open Questions (decided; recorded for override)

Nothing here blocks implementation - both items have a decision recorded in
"Judgment Calls Recorded" above and the plan is executable as written. They are
restated separately because each reads ADR-0018 slightly wider than its literal
enumeration, and that is a call a human may want to reverse. Each names the
exact revert.

1. **Message strings (Judgment Call 2).** ADR-0018 point 1's table names
   comments, `@moduledoc`, `@doc`, `@typedoc` and test descriptions. Runtime
   message strings are not on that list. This plan reads the rule by its stated
   reason rather than its enumeration and rewrites them. If the intent was the
   narrower reading, revert the two lines in Phase 8; nothing else in the plan
   depends on the choice.
2. **`docs/testing.md:42` (Judgment Call 5).** In scope by this plan's reading,
   though not named in the bead's notes. If the notes' list was meant to be
   exhaustive, drop that one line from Phase 9's changes.

## References

- Bead: `st-a89`
- Normative record: `docs/adr/0018-no-process-jargon-in-code-comments.md`
  (point 1 bans, point 2 allows, point 3 tooling modules, point 4 documents,
  point 5 the rewrite protocol)
- Related ADRs: `docs/adr/0002-*` (spec is normative - protects the Appendix D
  and W3C citations), `docs/adr/0012-*` (the observability seams
  `docs/observability.md` is normative about), `docs/adr/0011-*` (gate-change
  ledger - why st-wjg and not this sweep needs an entry)
- Bound guides: `docs/architecture.md`, `docs/datamodel.md`, `docs/testing.md`,
  `docs/observability.md`
- Conventions: `CLAUDE.md` (sabotage notes, commit format), `docs/testing.md`
  (the sabotage convention in full)
- Follow-on, deliberately not in this plan: `st-wjg` (the AdrGuard bead-ID
  check)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Each rewritten comment reads correctly to someone who has never seen the
      bead or the plan: it states a fact about the code, not about the work
- [ ] Where a `Decision N` citation was removed, the invariant that decision
      recorded is now stated in the comment itself
- [ ] Comments touching `lib/statifier/` still describe behavior that matches
      the W3C spec; no Appendix D name or spec section was altered

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full gate as the phase gate. In interactive execution, pause here for the human
to confirm the manual review before moving on. In looped (`--loop`) execution,
the Automated Verification list gates advancement via `/wurk:commit --auto` and
the Manual Verification items are deferred and surfaced once at the end.

---
