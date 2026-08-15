---
date: 2026-08-15
planner: Claude
git_commit: b52208e
branch: st-06b-heredoc-bead-id-sweep
repository: statifier-ex
beads_issue: st-06b
topic: "Sweeping bead IDs out of the doc heredoc bodies the ADR-0018 check can now see"
tags: [plan, docs, adr-0018]
status: ready
---

# Heredoc Bead-ID Sweep Implementation Plan

## Overview

Remove every bead ID that sits inside a doc heredoc body (`@moduledoc`,
`@doc`, `@typedoc`) under `lib/` and `test/`, restating each passage's durable
fact per ADR-0018 point 5 instead of deleting it. st-0ej closed
`Mix.Statifier.AdrGuard`'s mid-heredoc blind spot, so these lines are now
one reflow away from turning a future branch red as unplanned work.

Beads issue: `st-06b`

## Current State Analysis

`mix adr.check --base origin/main` exits 0 on this branch today, and nothing
in the tree is red. The exposure is latent: the ADR-0018 check only examines
lines a diff **adds**, so an existing line is invisible until someone edits
it. After st-0ej the check reads a doc heredoc's extent from the file's
post-image text (`doc_heredoc_body_lines/1`,
`lib/mix/statifier/adr_guard.ex:355-372`), so a body line added below an
unchanged opening `"""` is now classified as doc text and flagged.

**The bead's inventory is stale and must be regenerated, not trusted.** It was
taken at `75e36bb`; HEAD is 19 commits later. A regeneration at `b52208e`
finds **35** offending heredoc lines, not 37, and most line numbers have
shifted (`compiler.ex:132,136` are now `134,138`; `interpreter/datamodel.ex:95,250`
are now `217,372`; `compiler/expressions.ex:99` is now `107`). Two `st-cmq`
sites the bead listed under `lib/statifier/interpreter.ex` no longer exist -
the `st-cmq.6` invoke work reworded them. Every phase below therefore starts
by re-running the scan rather than editing at a recorded line number.

The current counts, by genre:

- **Genre 1, plan-filename citations: 24 lines.** Shape is
  ``(Decision 4, `docs/plans/260812-st-af3.3-....md`)`` appended to a sentence
  that already states the durable fact.
- **Genre 2, bare bead IDs: 11 lines** across 7 files.

### Genre 2 is two sub-genres, and the bead conflates them

The bead calls all of genre 2 "forward-reference seams" that say "this is a
stub until X lands". Reading the eleven passages, only three actually are:

- **Genuinely forward-looking (3):** `lib/statifier/interpreter.ex:115`
  (`st-cmq` will own the external-event queue),
  `lib/statifier/interpreter/datamodel.ex:372` (`st-cmq`'s invoked-session
  `<param>`/`namelist` seeding), `lib/statifier/validator/checks/donedata.ex:17`
  (`st-hyx` goes live when `<param>` is supported). These get the acceptance
  criterion the bead states: the passage must still tell a reader the thing is
  not implemented yet, without the tag.
- **Past-tense origin stories (8):** `interpreter.ex:109` and `:832`
  ("st-af3.2's real `cond` evaluation landed inside `Selection`"),
  `statifier_foreach_test.exs:8,17` and `statifier_if_test.exs:8,18`
  ("until bead **st-af3.8**", "st-af3.8 flipped `conditional_transitions`"),
  `test/support/case.ex:30` ("added to `Effect.Done` in st-k8d Phase 1"),
  `test/support/feature_detector.ex:15` ("landed through st-wju.7"). These are
  exactly ADR-0018 point 4's "origin story of the code", and point 5's protocol
  applies: restate the durable fact in the present tense, or delete when
  restating leaves nothing. Asserting "not implemented yet" about any of them
  would be false - the work landed.

This plan applies the correct protocol per sub-genre and records the
divergence from the bead's wording here rather than editing the bead.

### Key Discoveries:

- `lib/mix/statifier/adr_guard.ex:355-372` - `doc_heredoc_body_lines/1` is the
  reference heredoc-extent logic the acceptance criteria require reusing. It is
  private, so the sweep reuses it through `AdrGuard.analyze/1`.
- `lib/mix/statifier/adr_guard.ex:113` - `@bead_id_pattern` is the exact
  definition of what counts as a bead ID, lookarounds included.
- `lib/mix/statifier/adr_guard.ex:337-348` - `doc_context_texts/2` seeds its
  heredoc flag from an OR of a hunk-local half (`entry.previous != nil`) and a
  file-derived half (`body_lines`). A synthetic diff of one hunk per line makes
  `previous` always `nil`, which disables the hunk-local half and leaves the
  file-derived half as the sole classifier. That is the lever the enumerator
  uses.
- ADR-0018 point 2 - ADR numbers, W3C spec and Appendix D citations,
  `# sabotage:` notes, and stable `docs/*.md` paths stay. Several offending
  lines sit inside passages dense with exactly these; they are preserved
  verbatim.
- ADR-0018 point 5 - the rewrite protocol. `Phase 4 populates transitions`
  becomes `the compiler's transition pass populates this`.
- ADR-0018's Consequences - the check has its own marker, `ADR-0018-exempt`,
  precisely so clearing a finding is deliberate. The bead forbids adding one.
- `changelog.d/README.md` - "Do **not** write a fragment for: ...
  documentation". No changelog fragment for any phase.
- `docs/quality-gate-changes.md` is untouched: no phase edits a guarded path,
  adds a `@tag :skip`, or shrinks `test/passing_tests.json`, so `mix gate.check`
  needs no ledger entry.

### The enumerator, and what is committed

Enumeration runs through `Mix.Statifier.AdrGuard.analyze/1` twice over a
synthetic whole-tree diff, and takes the difference:

1. Build, for every `lib/**/*.{ex,exs}` and `test/**/*.{ex,exs}` path except
   `test/scion_tests/` and `test/scxml_tests/`, a synthetic diff with **one
   hunk per line** so every line reads as added and `previous` is always `nil`.
2. Run `analyze(%{diff: diff, files: texts})` - heredoc-aware. Call the
   `adr-0018-bead-id` findings `all`.
3. Run `analyze(%{diff: diff})` with no `:files` map - the file-derived half is
   disabled, so only `#` comments, single-line doc attributes, and `test "..."`
   descriptions classify. Call these `comment_like`.
4. `all - comment_like`, keyed on `{file, line}`, is exactly the heredoc-body
   set. At `b52208e`: `all=105`, `comment_like=70`, `heredoc_only=35`.

The one shape that would leak is a heredoc body line that is *also* comment-shaped
(a markdown `#` heading, or a `test "..." do` inside a doc example) and carries a
bead ID - it would land in both sets and be subtracted away. A one-off
cross-check confirmed **zero such lines exist** in the tree at `b52208e`, and
the final verification in Phase 4 re-runs the same cross-check to confirm it
still holds. This limitation is recorded here so it is not rediscovered.

**Nothing is committed.** The script is a throwaway under the session
scratchpad. Committing a second scanner would create a second definition of
what ADR-0018 means, which is the drift `AdrGuard` exists to prevent; the
guard already enforces this on every branch via `mix adr.check`, which is the
verification each phase actually gates on.

## Desired End State

The heredoc-body scan over `lib/` and `test/` (excluding the generated corpora)
returns zero `adr-0018-bead-id` findings, `mix quality` is green, and
`mix adr.check --base origin/main` exits 0 with the whole sweep in the diff -
meaning every rewritten line was re-presented to the guard as an added line and
cleared it on its own text, not because it was invisible.

Every rewritten passage still carries the fact it carried. No
`ADR-0018-exempt` marker exists anywhere under `lib/` or `test/`. No ADR
number, spec clause, Appendix D name, `docs/*.md` path, or `# sabotage:` note
was disturbed. No line of executable code changed: `git diff origin/main --stat`
names only the swept source files and this plan, and a read of the diff itself
shows every changed line sitting inside a `"""` doc body. The `--stat` half is
mechanical and the content half is a human read - no command can decide the
second, which is why every phase carries it as a manual criterion rather than
an automated one.

Verification: run the scan; run `mix quality`; run
`mix adr.check --base origin/main`; read the diff.

## What We're NOT Doing

- **The 70 comment-shaped bead-ID lines** (`#` comments, single-line doc
  attributes, test descriptions) under `lib/` and `test/`. The guard saw those
  before st-0ej, so they carry no new risk from that change. The bead calls
  folding them in a scoping call; this plan declines it, to keep the diff's
  claim narrow and reviewable.
- **`test/scion_tests/` and `test/scxml_tests/`.** Generated corpus,
  regenerated by `mise run corpus`; editing them by hand would be reverted by
  the next generation.
- **Plan phase numbers and plan Decision numbers that do not sit on an
  offending line.** ADR-0018 point 1 bans both, and the tree carries plenty
  (`interpreter.ex:822`'s "(Decision 2, revised)",
  `interpreter/datamodel.ex:378`'s "Decision 2/3 unchanged",
  `feature_detector.ex:14`'s "the Phase 1 engine surface"). The guard cannot
  check them - ADR-0018's Consequences say so explicitly, and they stay a
  review matter. Where such a number sits *inside a sentence a phase is already
  rewriting*, dropping it is free and the rewrite drops it; where it stands
  alone, it is left for a separate sweep.
- **Bead-ID-free dated filenames** such as `bench/results/260814-macrostep.md`
  in `machine/content/foreach.ex`. Whether ADR-0018 point 1 reaches them is an
  open human-review matter recorded in
  `docs/research/260815-st-0ej-bench-results-under-adr-0018.md`, and this bead
  does not settle it.
- **The maintained guides under `docs/`** (`docs/architecture.md`,
  `docs/datamodel.md`, `docs/testing.md`, `docs/observability.md`). ADR-0018
  point 4 binds them, but they are outside the guard's `lib/`/`test/` scope and
  outside this bead's.
- **Amending ADR-0018, editing `.quality.exs`, or adding any
  `ADR-0018-exempt` marker.** If a line genuinely cannot be reworded, the phase
  stops and reports it rather than applying a marker.
- **Committing the enumerator.** Reasoning above.

## Implementation Approach

Four phases, split first by genre (mechanical versus judgment) and then along
the pipeline's module boundaries, per `.claude/wurk/plan.md`. Every phase is
documentation-string text only, so each is independently committable by
construction: a partially-swept tree compiles, tests identically, and passes
`mix adr.check` for the subset already done, because the guard evaluates each
added line on its own.

The rewrite protocol is uniform:

1. Re-run the enumerator, scoped to the phase's file set, to get current line
   numbers.
2. For each line, read the whole enclosing paragraph - not the line.
3. Identify the durable fact the process reference was standing in for.
4. Restate it in project-neutral present tense. Prefer, in order: an existing
   ADR number, a W3C spec clause or Appendix D name, a stable `docs/*.md` path,
   or the bare invariant stated on its own.
5. If restating leaves nothing, delete the clause (ADR-0018 point 5's last
   line).
6. Preserve every allowed citation already in the paragraph verbatim.
7. Re-run the enumerator on the phase's file set; it must return empty.

## Phase 1: Genre 1 in the Document, Machine, compiler, lowering and validator layer

### Overview

The mechanical bulk: 15 plan-filename citations across 12 files in the
non-interpreter half of `lib/`. Each is an appended parenthetical on a sentence
that already states the fact, so most rewrites delete the parenthetical or
replace it with the invariant it cited.

### Changes Required:

#### 1. Compiler and lowering
**Files**: `lib/statifier/compiler.ex` (3 sites, ~61/134/138),
`lib/statifier/compiler/expressions.ex` (~107),
`lib/statifier/lowering/builders.ex` (~650)

**Changes**: Drop the `docs/plans/...` citation and the `Decision N` label that
usually precedes it, keeping the sentence's claim. `compiler.ex:58-63` reads
"...is captured onto the compiled `Statifier.Machine.Data` node as
`{:invalid, error}` rather than failing `compile/1` (Decision 2,
`docs/plans/260812-st-af3.3-...md`), so a document with a bad `cond` *and* a bad
`<data expr>` reports only the `cond`'s error." The parenthetical carries
nothing the sentence does not already say; it goes, and the sentence stands.

```
-  node as `{:invalid, error}` rather than failing `compile/1` (Decision 2,
-  `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`), so a
+  node as `{:invalid, error}` rather than failing `compile/1`, so a
```

#### 2. Document and Machine structs
**Files**: `lib/statifier/document/foreach.ex` (~31),
`lib/statifier/event_data.ex` (~7),
`lib/statifier/executable_content.ex` (2 sites, ~17/25),
`lib/statifier/machine.ex` (~42),
`lib/statifier/machine/content/assign.ex` (~10),
`lib/statifier/machine/content/if.ex` (~17),
`lib/statifier/machine/data.ex` (~15)

**Changes**: Same protocol. `machine.ex:40-44` cites "Decision 4
(`docs/plans/260812-st-af3.3-...md`) for why it lives both here (document order,
dense) and on `Statifier.Machine.State.data` (per-state membership)" - the
durable fact is the two-way membership, which the sentence's own parentheticals
already state; the citation goes and the "see ... for why" becomes the
statement itself. `event_data.ex:7` cites a plan for work that has since landed;
restate in the present tense or delete per ADR-0018 point 5.

#### 3. Validator checks
**Files**: `lib/statifier/validator/checks/enums.ex` (~25),
`lib/statifier/validator/checks/ids.ex` (~7)

**Changes**: Same protocol. Both cite the same `st-af3.3` plan for a datamodel
invariant; state the invariant.

### Success Criteria:

#### Automated Verification:
- [x] The enumerator, scoped to this phase's 12 files, returns zero
      `adr-0018-bead-id` heredoc findings.
- [x] `mix adr.check --base origin/main` exits 0.
- [x] Full `mix quality` passes (use `mix quality --profile loop` while
      iterating; a loop run alone does not satisfy this phase).
- [x] `git diff origin/main --stat` names only the 12 files this phase lists
      plus this plan document.
- [x] `grep -r "ADR-0018-exempt" lib/statifier test` returns nothing.

#### Manual Verification:
- [ ] Each rewritten paragraph still states the fact its citation stood in for,
      and reads as prose rather than as a sentence with a hole in it.
- [ ] Every ADR number, W3C spec clause, Appendix D name and `docs/*.md` path in
      the touched paragraphs is byte-identical to before.
- [ ] Spec conformance (`.claude/wurk/plan.md`'s standing criterion for
      `lib/statifier/`): the touched moduledocs still describe the code
      accurately against the W3C Appendix D pseudocode. No function bodies
      change in this phase, so the criterion is a documentation-accuracy read
      rather than a re-derivation.
- [ ] Read this phase's `git diff origin/main` hunk by hunk: every changed line
      sits inside a `"""` doc body, and no executable line moved. (This is the
      manual half of the check `git diff --stat` above can only bound by
      filename.)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Genre 1 in the interpreter and the test tree

### Overview

The remaining 9 plan-filename citations: 5 in `lib/statifier/interpreter/`
(where the surrounding prose is densest with spec citations that must survive)
and 4 under `test/`.

### Changes Required:

#### 1. Interpreter
**Files**: `lib/statifier/interpreter.ex` (~1498),
`lib/statifier/interpreter/content.ex` (2 sites, ~53/110),
`lib/statifier/interpreter/datamodel.ex` (2 sites, ~54/217)

**Changes**: Same protocol as Phase 1, with extra care: these paragraphs quote
normative spec text (5.3.2, 6.4.3, B.2.2) and name Appendix D procedures. Only
the `docs/plans/...` citation and any `Decision N` label glued to it are
removed. `datamodel.ex:54` and `:217` both cite the `st-af3.3` early/late
binding plan; the durable statement is the binding rule itself, which the
surrounding prose already grounds in spec 5.3.2 - cite the clause, drop the
plan.

#### 2. Conformance driver moduledocs
**Files**: `test/statifier/statifier_foreach_test.exs` (~5),
`test/statifier/statifier_if_test.exs` (~4)

**Changes**: Both open "Drives the N corpus documents ... named under
'Corpus/Ratchet Notes' in `docs/plans/260813-st-af3.X-...md`". Both moduledocs
already enumerate the exact corpus files further down, so the durable fact is
already present twice - name the documents, drop the plan reference.

```
-  Drives the five corpus documents named under "Corpus/Ratchet Notes" in
-  `docs/plans/260813-st-af3.5-if-elseif-else-conditional-executable-content.md`
-  through the real engine, end to end, without going through
+  Drives the five `<if>`/`<elseif>`/`<else>` corpus documents listed below
+  through the real engine, end to end, without going through
```

#### 3. Test support harness
**Files**: `test/support/context_recorder.ex` (~18),
`test/support/test_content.ex` (~15)

**Changes**: Same protocol.

### Success Criteria:

#### Automated Verification:
- [x] The enumerator, scoped to this phase's 7 files, returns zero
      `adr-0018-bead-id` heredoc findings.
- [x] `mix adr.check --base origin/main` exits 0.
- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating).
- [x] `mix test` passes with the internal suite - the two conformance driver
      files are real tests and must still run.
- [x] `git diff origin/main --stat` names only this phase's 7 files, Phase 1's
      12 files, and this plan document.

#### Manual Verification:
- [ ] Every quoted spec clause, section number and Appendix D procedure name in
      the touched interpreter paragraphs is byte-identical to before.
- [ ] Spec conformance (`.claude/wurk/plan.md`'s standing criterion): the
      touched interpreter moduledocs still describe the ported functions
      accurately against the W3C Appendix D pseudocode. No function bodies
      change, so no new deviation is introduced.
- [ ] The two conformance-driver moduledocs still explain why the file exists
      alongside the generated harness.
- [ ] Read this phase's `git diff origin/main` hunk by hunk: every changed line
      sits inside a `"""` doc body, and no executable line moved.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Genre 2 seams in `lib/`

### Overview

The five bare bead IDs under `lib/`, each needing a judgment call. Three are
genuinely forward-looking and must keep saying "not implemented yet"; two are
past-tense origin stories and must not.

### Changes Required:

#### 1. Forward-looking seams - keep the gap, drop the tag
**Files**: `lib/statifier/interpreter.ex` (~115),
`lib/statifier/interpreter/datamodel.ex` (~372),
`lib/statifier/validator/checks/donedata.ex` (~17)

**Changes**: State the unimplemented thing by name, in project-neutral terms.

- `interpreter.ex:113-118` - "the pure core takes one external event per call,
  and the session that drives it (st-cmq) owns the waiting external events and
  their queue." The session is `Statifier.Session`, which ADR-0003 already
  names as *the* production effect interpreter, and it is cited two lines
  above. Rewrite to name the module rather than the bead:

```
-    the pure core takes one external event per call, and the session that
-    drives it (st-cmq) owns the waiting external events and their queue.
+    the pure core takes one external event per call, and the session that
+    drives it owns the waiting external events and their queue.
```

- `interpreter/datamodel.ex:369-372` - "an invoked session's
  `<param>`/`namelist` values arrive as exactly this environment seed, so
  without this guard a late-bound invoked child would silently discard the
  values its parent passed it (st-cmq)." The bead tag is redundant; the
  sentence already names the mechanism and cites spec 6.4.3. Drop the tag and,
  if the "not yet" is worth keeping, say `<invoke>` is not implemented yet -
  which `docs/datamodel.md` and ADR-0004 already frame as the escape hatch.
- `validator/checks/donedata.ex:16-19` - "This arm discharges bead **st-hyx**,
  whose own description settles that it becomes live 'the moment `<param>` is
  supported' and 'should land with it rather than being rediscovered then.'"
  Replace with the durable statement: this arm is inert until `<param>` is
  supported, and it is written now so it lands with `<param>` rather than being
  rediscovered then. Same content, no tracker reference.

#### 2. Past-tense origin stories - restate in the present, or delete
**File**: `lib/statifier/interpreter.ex` (~109, ~832)

**Changes**: Both say "st-af3.2's real `cond` evaluation landed inside
`Selection`". The durable fact is what the code does now.

- `:105-112` - the bullet is "**The machine_state `Selection` returns is
  threaded, never discarded.**" and the bead sentence is evidence that the
  design absorbed a later change. Restate as the present-tense property: the
  `cond` evaluation lives inside `Selection`, which reshaped that module's
  private walk while both entry points kept their signatures and this module
  did not change.
- `:830-835` - "The two `Selection` entry points enqueue `error.execution` on a
  failed `cond` (st-af3.2)". Drop the parenthetical outright; the sentence is
  complete and correct without it.

Note that `:822`'s "(Decision 2, revised)" and `:832`'s neighbourhood also
carry plan Decision numbers. Those sit outside the sentences being rewritten
and stay, per "What We're NOT Doing".

### Success Criteria:

#### Automated Verification:
- [x] The enumerator, scoped to `lib/statifier/interpreter.ex`,
      `lib/statifier/interpreter/datamodel.ex` and
      `lib/statifier/validator/checks/donedata.ex`, returns zero
      `adr-0018-bead-id` heredoc findings.
- [x] `mix adr.check --base origin/main` exits 0.
- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating).
- [x] The enumerator run above is the authority for this phase and is already
      listed; no `grep` stands in for it. A plain `grep -n "st-"` over these
      files is *not* a gate - `st-` is a substring of ordinary English
      (`test-`, `first-`, `context-`), so a non-empty result means "lines to
      eyeball", never "phase failed". Use `grep -nP '(?<![a-zA-Z0-9])st-[a-z0-9]+(?:\.[a-z0-9]+)*(?![a-zA-Z0-9])'`
      - `AdrGuard`'s own `@bead_id_pattern` - if a cross-read is wanted, and
      expect legitimate hits in `#` comments, which are out of scope.
- [x] `git diff origin/main --stat` names only this phase's 3 files, the files
      Phases 1 and 2 touched, and this plan document.

#### Manual Verification:
- [ ] Each of the three forward-looking passages still tells a reader the thing
      is not implemented yet, and names *what* is missing rather than *who* will
      add it.
- [ ] Neither rewritten `st-af3.2` passage now claims something is unimplemented
      that in fact landed.
- [ ] Spec conformance (`.claude/wurk/plan.md`'s standing criterion): the
      touched `Statifier.Interpreter` moduledoc bullets still describe
      `main_event_loop/1`, `microstep/1` and the `Selection` entry points
      accurately against the W3C Appendix D pseudocode, including the existing
      "not a deviation" note on `statesToInvoke.sort(entryOrder)`.
- [ ] Read this phase's `git diff origin/main` hunk by hunk: every changed line
      sits inside a `"""` doc body, and no executable line moved.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 4: Genre 2 seams in `test/`, and whole-tree verification

### Overview

The six remaining bare bead IDs, all past-tense origin stories in harness and
driver moduledocs, plus the final whole-tree scan that discharges the bead's
first acceptance criterion.

### Changes Required:

#### 1. Conformance driver moduledocs
**Files**: `test/statifier/statifier_foreach_test.exs` (~8, ~17),
`test/statifier/statifier_if_test.exs` (~8, ~18)

**Changes**: Both files carry the same two-paragraph story: "until bead
**st-af3.8**, all eight ... corpus files also tripped `conditional_transitions`
... so these flunked", then "st-af3.8 flipped `conditional_transitions` to
`:supported`, ran the full conformance suites, and ratcheted
`test/passing_tests.json`". Both paragraphs are historical. The durable facts
are (a) `Statifier.Case.test_scxml/4` flunks rather than skips a document
naming an unsupported feature, and (b) these documents are now feature-clean
and also run through the generated harness, so this file is not a duplicate.
Restate both in the present tense with no dates and no tags. `mix test.baseline
add` and `test/passing_tests.json` are project mechanics documented in
`docs/testing.md`, not workflow-tooling jargon, so they may stay.

```
-  That was deliberate, not an oversight: until bead **st-af3.8**, all eight
-  `foreach_elements` corpus files also tripped `conditional_transitions`
+  That was deliberate, not an oversight: these eight `foreach_elements`
+  corpus files also trip `conditional_transitions`
```

#### 2. Harness moduledocs
**Files**: `test/support/case.ex` (~30), `test/support/feature_detector.ex` (~15)

**Changes**:

- `case.ex:27-33` - "restores that effect's `configuration` (added to
  `Effect.Done` in st-k8d Phase 1)". The durable fact is that `Effect.Done`
  carries a `configuration` field; drop the provenance parenthetical entirely.
  This also removes a plan phase number for free.
- `feature_detector.ex:13-18` - "The registry reflects what v2 actually supports
  today: the Phase 1 engine surface landed through st-wju.7 - basic/compound/
  parallel/final/history states, ...". The list is the durable content; the
  provenance is not. Restate as "The registry reflects what v2 actually
  supports today: basic/compound/parallel/final/history states, ...". The
  paragraph's closing pointer to `feature_registry/0` as the authoritative list
  stays.

#### 3. Whole-tree verification (no file changes)
**Changes**: Re-run the enumerator over the full `lib/` + `test/` set and
confirm `heredoc_only == 0`. Re-run the one-off cross-check for the leak shape
described under "The enumerator, and what is committed" and confirm it still
reports nothing. Neither script is committed.

### Success Criteria:

#### Automated Verification:
- [x] The enumerator over the full scope (`lib/**` and `test/**` minus
      `test/scion_tests/` and `test/scxml_tests/`) reports
      `heredoc_only = 0`.
- [x] The cross-check reports no heredoc body line that is also comment-shaped
      and carries a bead ID, confirming the subtraction did not hide anything.
- [x] `mix adr.check --base origin/main` exits 0 with all four phases in the
      diff.
- [x] Full `mix quality` passes.
- [x] `mix test` passes; `mix test --include scion --include scxml_w3` shows no
      change against `test/passing_tests.json`, and `mix test.regression`
      passes.
- [x] `grep -rn "ADR-0018-exempt" lib test` returns nothing.
- [x] `git diff origin/main --stat` lists only `lib/` and `test/` source files
      plus this plan; no `.quality.exs`, `.credo.exs`, `coveralls.json`,
      `.sobelow-conf`, `.doctor.exs`, `mix.exs` or `test/passing_tests.json`
      change, so `mix gate.check` needs no ledger entry.

#### Manual Verification:
- [ ] The two driver moduledocs still explain, without dates or tags, why each
      file exists alongside the generated corpus tests.
- [ ] `feature_detector.ex`'s support list is unchanged in content - only the
      provenance clause was removed.
- [ ] A read of `git diff origin/main` confirms no executable line changed
      anywhere in the branch.
- [ ] Three rewritten paragraphs read cold - one each from Phases 1, 3 and 4 -
      each explain the code rather than reading as a sentence with a citation
      surgically removed from it.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

No corpus regeneration and no `test/passing_tests.json` change. Two of the
touched files (`statifier_foreach_test.exs`, `statifier_if_test.exs`) *discuss*
the ratchet in their moduledocs, and `feature_detector.ex` holds the feature
registry the corpus harness reads, but no phase edits the registry, a corpus
file, or the baseline. Phase 4 runs `mix test.regression` and a full
conformance pass purely to prove the ratchet did not move; a change there would
be a defect in this plan's execution, not an expected outcome.

## The Appendix D rule

No deviation from the Appendix D pseudocode is introduced or removed, because
no executable line changes. The rule still binds this plan negatively: several
rewritten paragraphs sit around Appendix D citations and the existing
"`statesToInvoke.sort(entryOrder)` - so this is not a deviation" note in
`Statifier.Interpreter`. Those citations are what ADR-0018 point 2 explicitly
protects and they are preserved byte-for-byte; a rewrite that dropped one would
be a real regression, which is why each phase's manual criteria check for it.

## Testing Strategy

### Unit Tests:
- No new tests. This is documentation-string text only under `lib/` and
  `test/`, so there is no `lib/` behavior to assert and therefore no
  `# sabotage:` note to write (`CLAUDE.md`'s sabotage convention applies to
  tests that assert `lib/` behavior).
- The existing `test/mix/statifier/adr_guard_test.exs` suite already covers the
  heredoc-extent logic this sweep relies on; st-0ej landed it. This plan does
  not extend it, because the sweep changes no guard behavior.
- The two conformance driver files (`statifier_foreach_test.exs`,
  `statifier_if_test.exs`) are real tests whose moduledocs are edited; `mix
  test` must keep passing them unchanged.

### Manual Testing Steps:
1. Run the enumerator over the full scope and confirm `heredoc_only = 0`.
2. Run `mix adr.check --base origin/main` and confirm exit 0.
3. Run `mix quality` and confirm a full green (not `--profile loop`, not
   `--quick`); confirm with `mix gate.verify` per `CLAUDE.md`.
4. Read `git diff origin/main` end to end. For each hunk, confirm the removed
   text's durable fact survives in the added text, and that no ADR number, spec
   clause, Appendix D name, `docs/*.md` path or `# sabotage:` note was
   disturbed.
5. Confirm `grep -rn "ADR-0018-exempt" lib test` is empty.
6. Spot-read three rewritten paragraphs cold - one from each of Phases 1, 3 and
   4 - and confirm each reads as an explanation of the code rather than a
   sentence with a citation surgically removed from it.

## References

- Bead: `st-06b`
- Related ADRs: `docs/adr/0018-no-process-jargon-in-code-comments.md` (the
  rule; points 1, 2, 4 and 5 and the Consequences are all load bearing),
  `docs/adr/0011-quality-gate-config-not-agent-editable.md` (gate-guard ledger,
  not triggered here),
  `docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md` (the
  corpus coupling surface `test/support/case.ex` documents),
  `docs/adr/0002-literal-w3c-appendix-d-port.md`,
  `docs/adr/0003-pure-core-with-effects.md` and
  `docs/adr/0004-predicator-as-the-datamodel.md` (the citations the rewrites
  must preserve)
- Reference implementation: `lib/mix/statifier/adr_guard.ex:113` (bead-ID
  pattern), `:300-314` (`bead_id_findings/2`), `:337-372`
  (`doc_context_texts/2` and `doc_heredoc_body_lines/1`)
- Guard task: `lib/mix/tasks/adr.check.ex`
- Prior plan that created this follow-up:
  `docs/plans/260815-st-0ej-adrguard-heredoc-blind-spot.md`
- Prior sweep precedent: `docs/research/260810-st-a89-strip-process-terms-from-comments.md`
- Open review matter this bead does not settle:
  `docs/research/260815-st-0ej-bench-results-under-adr-0018.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [x] Each rewritten paragraph still states the fact its citation stood in for,
      and reads as prose rather than as a sentence with a hole in it.
- [x] Every ADR number, W3C spec clause, Appendix D name and `docs/*.md` path in
      the touched paragraphs is byte-identical to before.
- [x] Spec conformance (`.claude/wurk/plan.md`'s standing criterion for
      `lib/statifier/`): the touched moduledocs still describe the code
      accurately against the W3C Appendix D pseudocode. No function bodies
      change in this phase, so the criterion is a documentation-accuracy read
      rather than a re-derivation.
- [x] Read this phase's `git diff origin/main` hunk by hunk: every changed line
      sits inside a `"""` doc body, and no executable line moved. (This is the
      manual half of the check `git diff --stat` above can only bound by
      filename.)

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [x] Every quoted spec clause, section number and Appendix D procedure name in
      the touched interpreter paragraphs is byte-identical to before.
- [x] Spec conformance (`.claude/wurk/plan.md`'s standing criterion): the
      touched interpreter moduledocs still describe the ported functions
      accurately against the W3C Appendix D pseudocode. No function bodies
      change, so no new deviation is introduced.
- [x] The two conformance-driver moduledocs still explain why the file exists
      alongside the generated harness.
- [x] Read this phase's `git diff origin/main` hunk by hunk: every changed line
      sits inside a `"""` doc body, and no executable line moved.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 3

- [x] Each of the three forward-looking passages still tells a reader the thing
      is not implemented yet, and names *what* is missing rather than *who* will
      add it.
- [x] Neither rewritten `st-af3.2` passage now claims something is unimplemented
      that in fact landed.
- [x] Spec conformance (`.claude/wurk/plan.md`'s standing criterion): the
      touched `Statifier.Interpreter` moduledoc bullets still describe
      `main_event_loop/1`, `microstep/1` and the `Selection` entry points
      accurately against the W3C Appendix D pseudocode, including the existing
      "not a deviation" note on `statesToInvoke.sort(entryOrder)`.
- [x] Read this phase's `git diff origin/main` hunk by hunk: every changed line
      sits inside a `"""` doc body, and no executable line moved.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 4

- [x] The two driver moduledocs still explain, without dates or tags, why each
      file exists alongside the generated corpus tests.
- [x] `feature_detector.ex`'s support list is unchanged in content - only the
      provenance clause was removed.
- [x] A read of `git diff origin/main` confirms no executable line changed
      anywhere in the branch.
- [x] Three rewritten paragraphs read cold - one each from Phases 1, 3 and 4 -
      each explain the code rather than reading as a sentence with a citation
      surgically removed from it.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
