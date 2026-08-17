---
date: 2026-08-16T19:26:28-0600
researcher: Claude
git_commit: 8015033ab029fb81788a2f55b8d014e201cdd03b
branch: st-hgyu-adr-amendment-proposal
repository: statifier-ex
beads_issue: st-hgyu
topic: "Proposed amendments to ADR-0006 (four-function corpus constraint), ADR-0027 decision 1 (start_supervised! test pattern), and the Statifier.Case moduledoc that must agree with the first, implied by st-cmq.9's session harness"
tags: [research, adr, corpus, session, test-harness, amendment-proposal]
status: complete
last_updated: 2026-08-17
last_updated_by: Claude
---

# Proposal: amend ADR-0006 and ADR-0027 for the st-cmq.9 session harness

**Date**: 2026-08-16T19:26:28-0600
**Git Commit**: 8015033ab029fb81788a2f55b8d014e201cdd03b
**Branch**: st-hgyu-adr-amendment-proposal
**Bead**: st-hgyu

## What this document is

st-cmq.9's plan (`docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md`,
"Key Discoveries") named two ADR statements its session-harness design now
reads differently from, and deferred the amendments to a human's call. This
document is that proposal: for each of the two, the current ADR text, what the
code does today, drafted replacement wording a reviewer can paste after
review, the scope that stays untouched, and the arguments both ways.

A third item was found while verifying the first two: the harness moduledoc
that ADR-0006's amendment has to agree with does not currently describe the
session path correctly either. It is written up as Amendment 3.

**This document proposes; it lands nothing.** Per this repo's CLAUDE.md an
ADR edit is a direction-level call that belongs to a human. Neither
`docs/adr/0006-*.md` nor `docs/adr/0027-*.md` is touched on this branch, and
neither is `test/support/case.ex`.

The three questions this document originally left open were reviewed by the
maintainer on 2026-08-17; their resolutions are recorded under "Reviewer
decisions" at the end, and the drafted wording below already reflects them.
Applying that wording is tracked by **st-zebr**, which depends on this bead.

## Verification of the bead's claims

Every claim in st-hgyu's description was checked against the tree at commit
`8015033` rather than restated. Findings:

- **Confirmed: the five session-path functions.** The session driving path in
  `test/support/case.ex` couples to exactly `Statifier.start_session/2`
  (`test/support/case.ex:175`), `Session.send_event/2` (`:182`),
  `Session.snapshot/1` (`:239`), `Session.status/1` (`:240`, `:272`), and
  `Session.stop/2` (`:186`, called as `Session.stop(session)` - `stop/2` with
  its default `:normal` reason, defined at `lib/statifier/session.ex:504-505`).
- **Confirmed: `compile/1` and `active_leaf_states/1` stay shared.** Both
  paths parse through the same `parse_document/1`, which calls
  `Statifier.compile/1` (`test/support/case.ex:358`), and both read leaves
  through the same `observed_state_chart/2` / `active_leaf_states/1` helpers
  (`test/support/case.ex:379`).
- **Confirmed, and exact rather than approximate: the file count.** The bead
  says "~106 session-routed corpus files". A grep for the ten flipped atoms
  across `test/scion_tests` and `test/scxml_tests` matches exactly 106 of the
  281 generated files. (Routing recomputes the feature set from the document
  at run time rather than reading the tags, but the tags were emitted from
  the same detector, so the count holds.)
- **One correction: ADR-0006 does not name the four functions the way the
  bead quotes them.** The bead attributes the module-qualified list
  (`Statifier.compile/1`, `initialize/2`, `send_event/2`,
  `active_leaf_states/1`) to ADR-0006. The ADR's actual text names them
  generically: "a single `Statifier.Case` module needing four functions
  (parse, initialize, send-event, active leaf states)"
  (`docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md:8-9`).
  The module-qualified names live in `test/support/case.ex:16-18`, not in the
  ADR. The bead's paraphrase is substantively right - the "hard API
  constraint" sentence is real and quoted below - but an amendment quoting
  "the ADR's function list" would be quoting the harness moduledoc, not the
  ADR. The proposed wording below quotes what the ADR actually says.
- **Confirmed: ADR-0027 decision 1's sentence.** "Tests `start_supervised!`
  the same supervisor." appears verbatim at
  `docs/adr/0027-embedder-placed-session-runtime.md:83-84` - the sentence
  spans two lines, opening with "Tests" at the end of `:83`, which is the
  paste target rather than `:84` alone.
- **Confirmed: the run-scoped placement.** `test/test_helper.exs:1-9` places
  `Statifier.Supervisor.start_link([])` once, before `ExUnit.start/1`, with a
  comment block explaining why (fixed module-qualified child names, one
  runtime per node, `async: true` corpus files sharing it). No
  `start_supervised!(Statifier.Supervisor)` call remains anywhere under
  `test/`.
- **One nuance the bead elides: the moduledoc half is already fixed.** The
  bead's source discovery said `lib/statifier/supervisor.ex`'s moduledoc
  "repeats" the `start_supervised!` claim. st-cmq.9 already rewrote it: the
  moduledoc now says "The test suite places one runtime for the whole run in
  `test/test_helper.exs`, for the same one-instance reason"
  (`lib/statifier/supervisor.ex:43-45`). Only the ADR still states the old
  mechanism, which narrows Amendment 2 to exactly one file.
- **One correction found while verifying, not raised by the bead at all: the
  harness moduledoc undercounts the session coupling.**
  `test/support/case.ex:48-58` is headed "Two driving paths, one four-function
  contract" and says the session path "replaces two of the four - `initialize`
  becomes `Statifier.start_session/2`, `send_event` becomes
  `Statifier.Session.send_event/2` - while `Statifier.compile/1` and
  `Statifier.active_leaf_states/1` stay exactly as they were." That accounts
  for two of the five session calls and is silent on `Session.snapshot/1`,
  `Session.status/1` and `Session.stop/2`, which the same file calls at
  `:186`, `:239`, `:240` and `:272`. The session path is seven functions, not
  four-with-two-substituted. This matters here because it is the document
  Amendment 1 has to agree with: ADR-0006 amended to the honest set would
  contradict the moduledoc as written. Written up as Amendment 3.
- **Confirmed independently: the count.** 281 generated files under
  `test/scion_tests` and `test/scxml_tests`, of which 106 name one of the ten
  atoms. Worth recording for whoever re-checks it: some `required_features:`
  tags are emitted multi-line, so grepping the tag line alone undercounts -
  the 106 is a content-wide match for the atom names, which appear nowhere
  else in a generated file.

## The amendment convention this repo already has

ADR-0001 says a decision is "amended by a new ADR that supersedes it, not by
rewriting history" (`docs/adr/0001-record-architecture-decisions.md:16`), but
the practiced convention has two established forms, and the second is not a
new ADR:

1. **Amended by a later ADR**, with a `Status:` suffix and an
   `**Amendment note.**` block at the top pointing at the amending record -
   ADR-0004 (`0004:3-15`, amended by ADR-0026), ADR-0019 (`0019:3-15`,
   amended by ADR-0020), ADR-0016 (amended by ADR-0017).
2. **Amended in place by a bead**, when the change is too small to warrant a
   record of its own: a `Status:` suffix naming the date and a short label,
   inline `*(Amended <date>.)*` markers on the changed clauses, and the
   original wording preserved visibly in an italic note - ADR-0002's
   predicate-naming amendment (`0002:3`, `0002:30`) and ADR-0008's two
   2026-08-15 amendments (`0008:3`, `0008:28-32`), which even keep the
   original sentence quoted: "*(This section originally read ... The
   2026-08-15 amendment replaces that sentence with ...)*".

Both forms honor ADR-0001's real point - the path taken stays visible; the
record is never silently rewritten. Neither of this proposal's changes
reverses a decision or needs new argumentation of ADR size (ADR-0006's change
is a scope clarification; ADR-0027's is a mechanism swap under an unchanged
principle), so **form 2 is proposed for both**, in the ADR-0008 style with
the original text preserved. The reviewer took this on 2026-08-17; see
"Reviewer decisions".

---

## Amendment 1: ADR-0006's four-function constraint reads per driving path

### The current text

`docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md:32-33`
(the final Consequences bullet):

> `Statifier.Case`'s four-function contract is a hard API constraint on the v2
> surface - deliberately so.

with the four functions named in Context at `0006:8-9`:

> ... whose only coupling to the library is a single `Statifier.Case` module
> needing four functions (parse, initialize, send-event, active leaf states) ...

### What the code does today

`Statifier.Case.test_scxml/4` routes each document on its detected feature
set (`test/support/case.ex:129-137`). A document detecting any of the ten
send/invoke atoms in `@session_features` (`test/support/case.ex:83-94`) -
106 of the 281 generated corpus files - drives through a live
`Statifier.Session`, because real delivery, wall-clock timers, and child
sessions have no synchronous equivalent. That path couples to five functions
on the session surface: `Statifier.start_session/2`, `Session.send_event/2`,
`Session.snapshot/1`, `Session.status/1`, `Session.stop/2`
(`test/support/case.ex:175,182,186,239,240,272`). Every other document keeps
the synchronous four-function path unchanged, and `Statifier.compile/1` and
`Statifier.active_leaf_states/1` are shared by both paths
(`test/support/case.ex:358,379`). The harness moduledoc already states this
two-path contract (`test/support/case.ex:48-58`); only the ADR still reads
corpus-wide.

`Statifier.Session` and `Statifier.start_session/2` are already public API
with their own records (ADR-0027 for the runtime shape, ADR-0029 for the
session's public seam), so the session path exposes nothing undocumented.
What changed is the *scope* of ADR-0006's constraint, not the library
surface.

### Proposed wording

Status line (`0006:3`) becomes:

```
Status: accepted (2026-08-02) - amended 2026-08-16 (st-hgyu: the four-function constraint binds the synchronous driving path; the session path's coupling is a closed nine-function set)
```

The Consequences bullet at `0006:32-33` becomes:

```
- `Statifier.Case`'s four-function contract is a hard API constraint on the v2
  surface - deliberately so. *(Amended 2026-08-16, st-hgyu: this constraint now
  binds per driving path rather than corpus-wide, and each path's set is closed.
  st-cmq.9 gave `test_scxml/4` a second path: a document detecting any of the
  ten send/invoke feature atoms (106 of the 281 generated files at that commit)
  drives through a live `Statifier.Session`, because real delivery, wall-clock
  timers, and child sessions have no synchronous equivalent. The synchronous
  path - every other document, including every file ratcheted before st-cmq.9 -
  still couples to exactly the four. The sanctioned driving surface is these
  nine functions and no others: shared by both paths, `Statifier.compile/1` and
  `Statifier.active_leaf_states/1`; synchronous path only,
  `Statifier.initialize/2` and `Statifier.send_event/2`; session path only,
  `Statifier.start_session/2`, `Statifier.Session.send_event/2`,
  `Statifier.Session.snapshot/1`, `Statifier.Session.status/1` and
  `Statifier.Session.stop/2` (ADR-0027, ADR-0029). One assertion-side read sits
  outside that set by declaration rather than by exception:
  `Statifier.MachineState.active_leaf_states/1`, read to compare cardinality
  against the id-translated set, inspects a value the harness already holds and
  is not a way to drive the chart. Adding a function to any of these lists, or
  adding a third driving path, reopens this record - it is not a harness change
  to be made in passing. The constraint's purpose is unchanged: the corpus
  still cannot widen the library surface, because every function either path
  touches is public API carried by its own record.)*
```

The nine are enumerated rather than delegated to "the public session surface"
on the reviewer's 2026-08-17 call - see "Reviewer decisions" below, and the
"against" argument that decided it.

### What stays untouched

- The synchronous path and its four-function coupling, byte for byte - it is
  still the default and still drives every pre-st-cmq.9 ratcheted file.
- `Statifier.compile/1` and `Statifier.active_leaf_states/1`, shared by both
  paths.
- Everything else in ADR-0006: the corpus reuse, the committed generator, the
  never-skip rule, the ratchet.
- The constraint's *purpose*: the corpus as an API ratchet. The amendment
  restates the mechanism (public-API-only coupling, per path) rather than
  loosening it.

### For and against

**For.** The ADR as written is now false as a description of the corpus: 106
files do not, and cannot, satisfy a four-function coupling, because four
synchronous functions cannot express a wall-clock timer or a child session.
Leaving the record unamended makes the next reader either distrust the ADR or
distrust the harness; ADR-0001 exists so that neither happens. The amendment
is also cheap: it reverses nothing, and every function it adds to the
sanctioned coupling set is already public API under ADR-0027/0029.

**Against, and how it was resolved.** The original one-line constraint had
teeth precisely because it was blunt: any new function call in
`Statifier.Case` was a violation on its face. "Per driving path" is a softer
rule - a future harness change could add a third path and cite the amendment
as precedent for widening again. The first draft of this proposal delegated
the session half to "the already-public session surface (ADR-0027, ADR-0029)",
which carries that risk.

The verification pass produced the evidence that settled it: the harness
moduledoc had *already* softened the constraint by understating it, describing
a seven-function path as "two of the four" substituted (Amendment 3). A rule
that leaks in the very file it governs, before the ADR is even amended, is not
a rule with teeth. The reviewer's 2026-08-17 call is therefore the enumerated
closed set, which the wording above now carries: nine named functions, one
declared assertion-side carve-out, and an explicit statement that growth or a
third path reopens the record.

The cost of that choice, stated so it is not a surprise later: a sixth session
call in the harness now requires an ADR edit rather than a code review. That
is the intended friction, but it is friction, and it will be paid by whoever
next extends the session path.

---

## Amendment 2: ADR-0027 decision 1's `start_supervised!` sentence

### The current text

`docs/adr/0027-embedder-placed-session-runtime.md:83-84`, the last sentence of
decision 1 (it opens at the end of `:83`, so the paste target is both lines,
not `:84` alone):

> Tests `start_supervised!` the same supervisor.

### What the code does today

`test/test_helper.exs:1-9` places one `Statifier.Supervisor` for the whole
test run, before `ExUnit.start/1`:

```elixir
{:ok, _runtime} = Statifier.Supervisor.start_link([])

ExUnit.start(exclude: [:scion, :scxml_w3, :adr_judge_corpus])
```

No `start_supervised!(Statifier.Supervisor)` call remains anywhere under
`test/` (verified by grep at this commit; st-cmq.9 removed all ~30 sites).
The reason is structural, not stylistic: `start_supervised!` binds the
runtime's lifetime to one test process, `Statifier.Supervisor`'s children are
fixed module-qualified names so exactly one instance can exist per node, and
the generated corpus is `use Statifier.Case, async: true` unconditionally -
so no two corpus files could ever share a `start_supervised!`-placed runtime,
and a second placement raises. Sessions are `restart: :temporary` and
registered under unique UXID ids, so one shared runtime is safe.

The moduledoc half of the stale claim is already fixed:
`lib/statifier/supervisor.ex:43-45` states the run-scoped placement. Only the
ADR sentence remains.

### Proposed wording

Status line (`0027:3`) becomes:

```
Status: accepted (2026-08-14) - amended 2026-08-16 (st-hgyu: the test suite places one run-scoped runtime in test_helper.exs; start_supervised! could not be shared by async corpus files)
```

The sentence at `0027:84` becomes:

```
   unreachable orphans (and per decision 4 they do not come back as
   amnesiacs; the embedder observes the loss through monitors). One
   default-named instance; multiple named runtimes are mechanism with no
   caller and stay out, per the same standing rule that kept
   `states_to_invoke` off `MachineState` until st-cmq.6. The test suite is
   itself an embedder under this decision: it places one runtime for the
   whole run in `test/test_helper.exs`, before `ExUnit.start/1`. *(Amended
   2026-08-16, st-hgyu: this sentence originally read "Tests
   `start_supervised!` the same supervisor." st-cmq.9's corpus harness made
   that mechanism impossible to keep: `start_supervised!` binds the runtime's
   lifetime to one test process, the children are fixed module-qualified
   names so only one instance can exist per node, and the generated corpus is
   `async: true` unconditionally, so no two corpus files could share a
   runtime placed that way. The principle is untouched - the embedder places
   the runtime, the library never does, and nothing in `lib/` starts a
   process; only the stated test mechanism moved.)*
```

### What stays untouched

- Decision 1's actual decision: no `mod:` in `mix.exs`; the embedder places
  `Statifier.Supervisor`. The test suite placing the runtime in its own
  helper *is* that decision applied to the test suite as an embedder.
- Decisions 2-4 (registry, ownership protocol, `restart: :temporary`), the
  guard-amendment paragraph, and every consequence.
- The invariant that nothing in `lib/` starts a process - the placement moved
  from per-test to per-run entirely within `test/`.

### For and against

**For.** The sentence is a factual claim about the test suite that has been
false since st-cmq.9 landed, and it sits inside a numbered decision, where a
reader is most entitled to take it literally. The amendment is the narrowest
possible: one sentence, mechanism only, principle restated as untouched. It
also records *why* the mechanism moved, which is the part a future reader
(tempted to "restore" `start_supervised!` for test isolation) most needs.

**Against, worth a reviewer's attention.** The sentence being amended was
arguably illustrative rather than decisional - decision 1's operative content
is the no-`mod:` rule, and one could leave a passing illustration stale
rather than amend a record for it. The counterargument, and why this proposal
still recommends amending: the illustration prescribes a concrete test
pattern, st-cmq.9's plan had to name its deviation from it explicitly
("Key Discoveries", `docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md:280-290`),
and every future test author reading the ADR would face the same
contradiction with `test/test_helper.exs`. A sentence that keeps generating
recorded deviations is doing decision work, and should say the true thing.

---

## Amendment 3: the harness moduledoc must agree with the amended ADR-0006

This one is not in the bead. It surfaced during the 2026-08-17 verification
pass and is included on the reviewer's call, because Amendment 1 cannot land
correctly without it: the moduledoc is where a test author actually reads the
constraint, and an ADR that disagrees with it just moves the contradiction.

### The current text

`test/support/case.ex:48-58`, the section headed "Two driving paths, one
four-function contract":

> The session path replaces two of the four - `initialize` becomes
> `Statifier.start_session/2`, `send_event` becomes
> `Statifier.Session.send_event/2` - while `Statifier.compile/1` and
> `Statifier.active_leaf_states/1` stay exactly as they were. Either way the
> corpus still cannot widen the library surface beyond those calls (ADR-0006).

### What the code does today

Five session functions, not two. Beyond `Statifier.start_session/2` (`:175`)
and `Session.send_event/2` (`:182`), the same path calls `Session.stop/2`
(`:186`), `Session.snapshot/1` (`:239`), and `Session.status/1` (`:240`,
`:272`). Counting the shared `Statifier.compile/1` and
`Statifier.active_leaf_states/1`, the session path touches seven functions
against the synchronous path's four.

The heading's claim - "one four-function contract" - and the closing sentence
"the corpus still cannot widen the library surface beyond those calls" are
both true in spirit and false as written: the surface is wider than the four,
it is simply still all public API. That is exactly the distinction Amendment 1
makes precise.

### Proposed change

Retitle the section from "Two driving paths, one four-function contract" to
"Two driving paths, one closed contract", and replace the substitution
sentence with the honest set, deferring to the ADR as the authority:

```
The session path keeps `Statifier.compile/1` and
`Statifier.active_leaf_states/1` exactly as they were and replaces the other
two with five: `initialize` becomes `Statifier.start_session/2`, `send_event`
becomes `Statifier.Session.send_event/2`, and driving a live session
additionally needs `Statifier.Session.snapshot/1` to read a configuration,
`Statifier.Session.status/1` to know when it has settled, and
`Statifier.Session.stop/2` to tear it down. Nine functions across the two
paths, enumerated in ADR-0006 and closed: adding a tenth, or a third driving
path, reopens that record rather than being a harness change. Either way the
corpus still cannot widen the library surface, because every one of the nine
is public API carried by its own record.
```

The `assert_every_leaf_named/2` carve-out already documented at `:35-40` is
correct as written and stays - Amendment 1's wording adopts its reasoning
rather than replacing it.

### What stays untouched

- Every other section of the moduledoc, including the four-function opening
  at `:15-18` (which describes the synchronous path and is accurate for it)
  and the `MachineState.active_leaf_states/1` carve-out at `:35-40`.
- All harness behavior. This is a comment change; no function moves.

### For and against

**For.** The moduledoc is the proximate cause of the drift this whole bead
exists to fix: it is what a test author reads, and it currently licenses a
belief ("the session path is just two substitutions") that the code has never
matched. Landing ADR-0006's enumerated set while leaving the moduledoc at
"two of the four" would put the repo's two statements of the same constraint
in open disagreement, which is worse than the single stale statement it
started with.

**Against, worth a reviewer's attention.** This is the one item of the three
that touches a file under `test/`, so it carries a real quality gate rather
than riding the docs carve-out, and it widens the bead past the two ADRs its
title names. A reviewer who wants st-hgyu to stay exactly the ADR bead it was
filed as could split this into its own bead instead - the write-up above is
self-contained enough to move. The recommendation is to keep it here, because
the correction is only discoverable from the enumeration work Amendment 1 did,
and separating them invites landing the ADR without it.

---

## Reviewer decisions (2026-08-17)

The three questions below were left open by the 2026-08-16 pass because no
human was available. They were reviewed on 2026-08-17 and are recorded here
with their resolutions; the drafted wording above already reflects them.

1. **In-place amendment vs. a new ADR -> in-place, both records.** ADR-0001:16
   says decisions are "amended by a new ADR that supersedes it", but the
   practiced convention has two forms and the second is bead-driven in-place
   amendment for changes below ADR size, with the original text preserved
   (ADR-0002:3 and `:30`; ADR-0008:3 and `:28-32`, the latter driven by
   st-mvna and quoting the sentence it replaced). Neither of these amendments
   reverses a decision or needs new argumentation of ADR size, so both take
   the in-place form in the ADR-0008 style. ADR-0001's real point - that the
   path taken stays visible and the record is never silently rewritten - is
   honored by the preserved-original notes.
2. **How sharp to keep ADR-0006's teeth -> the enumerated closed set.** The
   softer "already-public session surface" phrasing was rejected on the
   evidence that the harness moduledoc had already leaked under exactly that
   kind of rule. The amendment names nine functions, one declared
   assertion-side carve-out, and states that growth or a third path reopens
   the record. The cost is recorded under Amendment 1's "against": a sixth
   session call now needs an ADR edit.
3. **The amendment dates -> unchanged, and still the landing date.** The
   drafts carry 2026-08-16. That is deliberate placeholder text, not a claim:
   per the ADR-0008 precedent of dating the amendment rather than the
   triggering work, whoever lands these stamps the date they land, in both the
   status lines and the inline `*(Amended ...)*` markers.

**Landed 2026-08-17 by st-zebr.** All three amendments above are applied:
`docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md`'s status
line and Consequences bullet, `docs/adr/0027-embedder-placed-session-runtime.md`'s
status line and decision 1's `start_supervised!` sentence, and
`test/support/case.ex:48-58`'s moduledoc section, all dated 2026-08-17 rather
than this document's 2026-08-16 placeholders.

**Landing is tracked by st-zebr**, which depends on this bead: "Land the
ADR-0006/0027 amendments and the `Statifier.Case` moduledoc fix". It carries
the paste targets, the acceptance criteria, and the reminder to stamp the
landing date rather than this document's 2026-08-16 placeholders. That bead
exists because a proposal with no successor is how decided-but-unlanded
wording rots: the drift this document describes stays in the tree until
someone applies the wording above, and merging this document does not do
that. Note that st-zebr puts `test/support/case.ex` in its diff, so unlike
this branch it carries a full `mix quality` run rather than the docs-only
carve-out.

The rejected alternative is kept on the record for whoever revisits this: both
amendments could instead have ridden one small new ADR ("Corpus driving paths
and the test-placed session runtime") amending 0006 and 0027 the way ADR-0026
amends ADR-0004. The content above is usable that way with no rewriting, if
the in-place form is ever judged to have been the wrong call.
