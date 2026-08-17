---
date: 2026-08-16T19:26:28-0600
researcher: Claude
git_commit: 8015033ab029fb81788a2f55b8d014e201cdd03b
branch: st-hgyu-adr-amendment-proposal
repository: statifier-ex
beads_issue: st-hgyu
topic: "Proposed amendments to ADR-0006 (four-function corpus constraint) and ADR-0027 decision 1 (start_supervised! test pattern) implied by st-cmq.9's session harness"
tags: [research, adr, corpus, session, test-harness, amendment-proposal]
status: complete
last_updated: 2026-08-16
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

**This document proposes; it lands nothing.** Per this repo's CLAUDE.md an
ADR edit is a direction-level call that belongs to a human. Neither
`docs/adr/0006-*.md` nor `docs/adr/0027-*.md` is touched on this branch.

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
  `docs/adr/0027-embedder-placed-session-runtime.md:84`.
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
  mechanism, which narrows this proposal to exactly one file per amendment.

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
the original text preserved.

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
Status: accepted (2026-08-02) - amended 2026-08-16 (st-hgyu: the four-function constraint binds the synchronous driving path; session-routed files couple to the ADR-0027/0029 session surface)
```

The Consequences bullet at `0006:32-33` becomes:

```
- `Statifier.Case`'s four-function contract is a hard API constraint on the v2
  surface - deliberately so. *(Amended 2026-08-16, st-hgyu: this constraint now
  binds per driving path rather than corpus-wide. st-cmq.9 gave `test_scxml/4`
  a second path: a document detecting any of the ten send/invoke feature atoms
  (106 of the 281 generated files at that commit) drives through a live
  `Statifier.Session`, because real delivery, wall-clock timers, and child
  sessions have no synchronous equivalent. The synchronous path - every other
  document, including all files ratcheted before st-cmq.9 - still couples to
  exactly the four functions. The session path couples to five functions on
  the already-public session surface: `Statifier.start_session/2`,
  `Session.send_event/2`, `Session.snapshot/1`, `Session.status/1`,
  `Session.stop/2` (ADR-0027, ADR-0029), while `Statifier.compile/1` and
  `Statifier.active_leaf_states/1` stay shared by both paths. The constraint's
  purpose is unchanged: the corpus still cannot widen the library surface,
  because every function either path touches is public API carried by its own
  record.)*
```

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

**Against, worth a reviewer's attention.** The original one-line constraint
had teeth precisely because it was blunt: any new function call in
`Statifier.Case` was a violation on its face. "Per driving path" is a softer
rule - a future harness change could add a third path and cite this amendment
as precedent for widening again. If the reviewer wants the teeth kept sharp,
the amendment could instead enumerate the closed set (four synchronous + five
session + two shared) and state that adding any function to either list
reopens the record. The drafted wording above names the exact five for that
reason; a reviewer preferring the stricter closed-set phrasing can tighten
"the already-public session surface" to "exactly these five and no others".

---

## Amendment 2: ADR-0027 decision 1's `start_supervised!` sentence

### The current text

`docs/adr/0027-embedder-placed-session-runtime.md:84`, the last sentence of
decision 1:

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

## Open questions for the reviewer

Recorded rather than resolved, since no human was available during this pass:

1. **In-place amendment vs. a new ADR.** ADR-0001:16 says decisions are
   "amended by a new ADR that supersedes it"; practice (ADR-0002, ADR-0008)
   has bead-driven in-place amendments for changes below ADR size, with the
   original text preserved. This proposal recommends the in-place form for
   both amendments on that precedent, but if the reviewer reads ADR-0001
   strictly, both amendments could instead ride one small new ADR
   ("Corpus driving paths and the test-placed session runtime") that amends
   0006 and 0027 the way ADR-0026 amends ADR-0004. The content above is
   usable either way.
2. **How sharp to keep ADR-0006's teeth.** See "against" under Amendment 1:
   the drafted wording sanctions "the already-public session surface"; a
   stricter reviewer may prefer an enumerated closed set whose growth reopens
   the record. Both phrasings are drafted-for above; the choice is a
   direction call.
3. **The amendment dates.** Both drafts use 2026-08-16 (this proposal's
   date). If the human lands them later, the status-line and inline dates
   should be the landing date, per the ADR-0008 precedent of dating the
   amendment, not the triggering work.
