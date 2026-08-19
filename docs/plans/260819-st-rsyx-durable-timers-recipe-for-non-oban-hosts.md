# Durable Timers Recipe for Non-Oban Hosts Implementation Plan

## Overview

Deliver the one clause of the `statifier_oban` charter that is deliverable
inside this repository: **"the durable-timers pattern is documented for
non-Oban hosts."** Two documentation artifacts, no `lib/` changes, no `test/`
changes - an ADR that records the contract a durable-timer host works to, and
a host-facing recipe document that shows how to work to it.

Bead: **st-ifa3** (`area:docs`), the in-repo half, split from the charter bead
`st-rsyx` so it is not orphaned when the charter transfers to the package repo
- see "Prerequisite: file the in-repo bead" under Implementation Approach.
Every commit made under this plan carries `st-ifa3` in its `Refs` trailer, not
`st-rsyx`.

**Plan status (2026-08-19).** Phases 1 and 2 have already been executed against
an earlier, uncorrected revision of this document. Phase 1 is committed as
`f49559d`; Phase 2's files are written but uncommitted. This revision applies
an independent plan-critic review, and the corrections it makes to Phases 1
and 2 are corrections to a *record of work that landed* - the landed prose is
now wrong in the specific ways Phase 3 enumerates, and Phase 3 exists to fix
it. Do not re-run Phases 1 and 2.

## Current State Analysis

Everything below is established by
`docs/research/260819-st-rsyx-statifier-oban-charter-durable-timers.md`
(uncommitted at the time of writing; it is the primary input to this plan and
is not re-derived here).

**The seam already ships, complete.** A durable-timer host needs four public
things and has all four today:

- `{:send_delayed, %Statifier.Effect.SendDelayed{}}` -
  `lib/statifier/effect/send_delayed.ex:25-54`. `delay_ms` is a **relative**
  `non_neg_integer()` (`:47`), never an absolute deadline. Its own moduledoc
  states the division of labour: "The timer that fires this send is
  `Statifier.Session`'s to schedule; this module only defines the shape it
  schedules" (`:5-7`).
- `{:cancel, %Statifier.Effect.Cancel{}}` - `lib/statifier/effect/cancel.ex:20-30`.
  Carries `send_id` plus `c_index`/`owner` and the three counters, nothing else.
- `Statifier.Session.subscribe/2,3` - `lib/statifier/session.ex:676-719`. Every
  effect is planned to a `{:notify, effect}` in its original position
  (`lib/statifier/session/effects.ex:8-12`), so the subscriber stream is the
  complete, ordered effect list.
- `Statifier.Session.send_event/2` - `lib/statifier/session.ex:530-536`. A fired
  timer's own in-process path, `deliver_fired/4`
  (`lib/statifier/session.ex:1823-1833`), re-enqueues onto the session inbox
  "exactly as `send_event/2` does", so an external scheduler rejoins the exact
  path a native timer rejoins.

A process-less host reads the same effects off the `[effect]` half of
`Statifier.Interpreter`'s return; `docs/extending.md:43-49` already names that
audience.

**What is missing is only prose.** Nothing in `docs/` tells a host to do any
of this. `docs/architecture.md:124-182` mentions that `Statifier.Session`
"owns ... the delayed-send timers" and never names `Process.send_after` or
discusses durability. `docs/extending.md` is host-facing but scoped to
`<invoke>` handlers by its own title (`:1`).

**Three contract questions have no recorded answer.** They are the reason this
plan carries an ADR and not only a guide:

1. *Which vocabulary a timer consumer reads.* `docs/extending.md:57-58`
   declares the instruction vocabulary opaque outside the library, with
   `{:handler, __MODULE__, payload}` the sole exception. `{:schedule, ...}` and
   `{:cancel_timers, ...}` (`lib/statifier/session/effects.ex:161-174`,
   `:206-208`) are therefore off limits - but nothing states that for the
   timer case specifically, and the charter's own scope bullet says "honoring
   cancel (the cancel_timers instruction)", naming the opaque half.
2. *How an external store keys a timer.* `send_counter` starts at 0 for every
   `%MachineState{}` (`lib/statifier/machine_state.ex:349`, ADR-0035), so
   `send_1` is unique only within one run. Nothing in `lib/` scopes it, and
   nothing could.
3. *What replaces spec 6.2's discard-on-termination.* `terminate/2`
   (`lib/statifier/session.ex:1182-1201`) cancels every live ref, which is how
   the library satisfies the clause today. An external scheduler deliberately
   survives process death; that is the entire point of durability.

**Two facts that bound scope.** Oban is not a dependency (`mix.exs:41-56`
lists `predicator`, `saxy`, `telemetry` and nothing else), and the sibling
repository `/Users/johnnyt/repos/github/statifier_oban` holds an initialized
`.git` and nothing else - no mix project, no beads database, zero commits.
The invoke-half idempotency contract already shipped with `st-cmq.8`
(`docs/extending.md:177-189`, ADR-0051 decision 4); there is no in-repo gap
there. The clock-discipline bullet describes the status quo: no wall-clock
read exists under `interpreter/`, `machine/`, or `effect/`.

## Desired End State

Two new files exist and are linked from the places a reader arrives from:

- `docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md` - accepted,
  three-section format, indexed in `docs/adr/README.md`, recording the three
  contract answers above.
- `docs/durable-timers.md` - a host-facing guide in the same register as
  `docs/extending.md`: framing, the two consumption routes, a worked example
  in each, the keying rule, the termination rule, and the gotchas. Linked from
  `README.md` beside the `docs/extending.md` link, cross-linked from
  `docs/extending.md` and from `docs/architecture.md`'s "Sessions and invoke"
  section.

**Verification that the end state is reached:** a reader who has never seen
this codebase can, from `docs/durable-timers.md` alone, name the two effects to
consume, the door to feed events back through, the compound key their job store
must use, and the check they must perform before delivering a fired event -
without reading `lib/`. `git diff --name-only` against the merge base touches
only paths under `docs/` (including the research document, which this branch
also introduces) and `README.md` - no `lib/`, no `test/`, no `mix.exs`, no
`changelog.d/`. `mix quality` and `mix gate.verify` are green; `mix quality
--profile merge` is green.

**What `--profile merge` does and does not buy here.** It is *not* the run that
exercises the ADR judge on this branch. The judge's scopes are `lib/statifier`
and `.claude/wurk/**` plus `.claude/wurk.json` (`lib/mix/statifier/adr_judge.ex:178`,
`:187`, `:198-199`), so a documentation-only diff yields `:no_scoped_changes`
and the stage skips (`lib/mix/tasks/adr.judge.ex:45-46`, `:82`). **No automated
check on this branch reads the new ADR's content at all** - the ADR is verified
by the manual criteria and by human review, and nothing else. `--profile merge`
is still run, because `.claude/wurk/mr.md` runs it unconditionally before every
push and a branch that has never run it is a branch whose first merge-profile
run happens at the least convenient moment.

### Key Discoveries:

- `docs/extending.md:57-58` - the instruction vocabulary is **already declared
  opaque outside the library**. A recipe teaching hosts to intercept
  `{:schedule, ...}` would contradict a shipped contract. The consumption point
  must be the effect pair.
- `lib/statifier/machine/content/send.ex:383-389` - an author-written `id` is
  used verbatim and **never advances the counter**; only a generated id does.
  So one `<send id="x" delay="...">` executed twice produces two live timers
  under one `send_id`.
- `lib/statifier/session/timers.ex:5-9`, `:39-44`, `:51-60` - `put/3` appends
  per `send_id` in scheduling order and `take/2` pops **every** ref under an id,
  because spec 6.3 says a cancel with a given sendid cancels them all. `take/2`
  on an unknown id returns `{[], timers}` - a no-op, not an error.
- Together those two make the charter's phrase "unique per send id" wrong as
  written: `send_id` is a **cancellation** key that legitimately matches many
  rows, not a uniqueness key. See Phase 1 decision 3.
- `lib/statifier/effect/send_delayed.ex:11-13` (ADR-0046) - the
  `macrostep`/`microstep`/`round` counters on a `SendDelayed` are "as they stood
  when the send was scheduled, not when the timer fires". That is what makes a
  per-instance dedup key deterministic across a re-run of the same drive.
- `lib/statifier/session.ex:45-57`, `:970-973`, `:1546-1553` - reaching `:done`
  sets `state.halted` but does **not** stop the process and does **not** cancel
  timers; `handle_continue(:drain, ...)` declines to drain onto a halted
  session, so a fired event sits queued. "Still live" therefore has to mean
  "neither halted nor terminated".
- ADR-0029 (`lib/statifier/session.ex:604-606`) - feeding the fired event back
  through `send_event/2` stays on the three-input recorded path; injecting
  effects through `interpret/2` instead obligates the fourth replay input.
- ADR-0003's Consequences already name this use case by name -
  "Embedders can supply their own effect interpreter (e.g. queue delayed sends
  into Oban instead of process timers)"
  (`docs/adr/0003-pure-core-with-effects.md:27-28`). The new ADR does not
  reopen it; it discharges it with rules ADR-0003 never stated.
- Spec 6.2, quoted from the local cache
  (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`):
  "If the SCXML session terminates before the delay interval has elapsed, the
  SCXML Processor MUST discard the message without attempting to deliver it."
- `mix.exs:7-28` - no ExDoc `docs:` key and no `extras:` list, so a new doc file
  needs no `mix.exs` registration.
- `changelog.d/README.md` - "Do **not** write a fragment for: ... documentation,
  ADRs, or plans." This branch gets no changelog fragment.
- `.quality.exs:33`, `:40-42` - the ADR judge is disabled in a bare gate and
  re-enabled by `--profile merge`. `mix gate.verify` still needs an unprofiled
  run.
- **The ADR judge does not judge this branch's ADR.** Its judged scopes are
  `lib/statifier` and `.claude/wurk/**` + `.claude/wurk.json`
  (`lib/mix/statifier/adr_judge.ex:178`, `:187`, `:198-199`). A docs-only diff
  produces `:no_scoped_changes` and the task reports a skip
  (`lib/mix/tasks/adr.judge.ex:45-46`, `:82`) whose reason string is "no files
  in this diff are in a judged ADR scope (lib/statifier, .claude/wurk/** and
  .claude/wurk.json)". That string matches neither `gate.project_level_skips`
  (empty) nor `gate.not_applicable_skips` in `.claude/wurk.json:43-49` - the
  `^disabled in \.quality\.exs$` pattern only matches the *bare-gate* skip
  reason, not this one. **An agent running `--profile merge` on this branch
  therefore meets an unclassified `○` line.** It is a run-level skip by
  classification but not a defect: the stage ran, decided it had nothing in
  scope, and said so. Report it in the phase notes as "judge skipped:
  `:no_scoped_changes`, expected for a docs-only diff" and do not treat it as
  red, and do not add a pattern to either list in `.claude/wurk.json` to quiet
  it - per ADR-0011 and ADR-0017 point 6 that is a human's call on the record,
  and a per-diff outcome does not belong in a standing list anyway.
- `lib/statifier/session/effects.ex:270-288` - `plan_send_delayed/3` parses
  `send.target` into `:internal`, `:self`, `#_parent`, `#_invokeid`, or an
  external session id, and the resolved route travels on the opaque
  `{:schedule, ...}` instruction. **The route is not carried on the
  `%SendDelayed{}` effect.** `deliver_fired/4` (`lib/statifier/session.ex:1829-1833`)
  special-cases `:self` only; every other route goes through `deliver/5`. The
  event itself is built in the session, not by the host: `delivered_event/2`
  (`effects.ex:392-399`) sets `origin`, `origintype`, and an
  `id_from_author?`-gated `sendid`, while `internal_event/1` (`:414-427`) is a
  *different* carrier used only for `#_internal`, whose delivery re-raises
  through `Statifier.Interpreter.deliver_internal/5`. This bounds Phase 1
  decision 2 - see Phase 3.
- `lib/statifier/effect/send_delayed.ex:33-34`, `:52` - `%SendDelayed{}` carries
  `c_index` and `owner` (the send's position in its executable-content block)
  as well as `round`. A dedup key omitting `c_index`/`owner` collides whenever
  one block executes two delayed sends, or one author id is reused twice in a
  microstep.
- `lib/statifier/session.ex:644-645` - `Statifier.Session.status/1` is a
  `GenServer.call`. Against a terminated session it **exits**, which is exactly
  the case the spec 6.2 substitute exists to detect, so it cannot be the
  liveness door as written. `lib/statifier/session.ex:155-160` documents
  `Registry.lookup(Statifier.Registry, sid)` (ADR-0027 decision 2) as the
  resolution path for a session id, which is the door that answers
  "terminated?" without exiting.
- `lib/statifier/session.ex:77-83` still says `round` is carried only by
  `Statifier.Effect.Trace.*` and `Statifier.Effect.BudgetExhausted` - a
  statement **ADR-0046 withdrew** ("Every core effect carries `round`"). The
  ordering guarantee itself is at `:67-76` and is still accurate. Cite `:67-76`,
  never `:70-83`.
- `lib/statifier/session.ex:483` and ADR-0044 decision 2 - `{:halted, reason}`
  is promised as **end-of-stream** on the subscriber channel. A Route A
  subscriber must not wait for cleanup effects after it.
- This environment's shell is **fish**. `for f in ...; do ... done` and
  `... | while read -r l; do ... done` are bash syntax and are *syntax errors*
  in fish. Any multi-command shell criterion must be wrapped in
  `bash -c '...'` or decomposed into single `grep -q` invocations.

## What We're NOT Doing

- **Not writing anything into `/Users/johnnyt/repos/github/statifier_oban`, and
  not creating a beads database there.** The CLAUDE.md authority table is scoped
  entirely to this checkout's worktree branch; no row covers acting inside
  another repository, and initializing a tracker there is a new tracker rather
  than a task. This is out of scope for this plan and for every agent executing
  it. **Recommendation for a human, not a phase:** when the sibling repo is
  populated, scaffold its mix project and beads database by hand, then transfer
  `st-rsyx` per its own transfer condition, leaving the in-repo bead (below)
  behind as the record of the delivered half.
- **Not adding Oban as a dependency, and not writing the round-trip tests of
  acceptance clause 1.** They test package code that does not exist
  (`mix.exs:41-56`).
- **Not writing an Oban-backed invoke-handler base** (acceptance clause 2's
  second half). It is package code. The documented half of clause 2 already
  shipped with `st-cmq.8` (`docs/extending.md:177-189`, ADR-0051 decision 4) and
  is not restated here beyond a cross-reference.
- **Not touching `lib/` or `test/`.** The research found no change the recipe
  requires. Specifically not adding a cancel-on-halt behavior to
  `Statifier.Session`: the halted-session gap
  (`lib/statifier/session.ex:970-973`) is documented in the recipe as a fact a
  host must check for, and changing it is a semantics change that would need its
  own bead and its own ADR, not a docs branch.
- **Not mechanizing a "no clock in the pure core" gate check** (research open
  question 7). The invariant holds today by construction and by review; turning
  it into a `mix gate.check` rule is a gate-config change, which ADR-0011 makes
  a human's call on the record. Noted as unmeasured, not proposed.
- **Not writing a changelog fragment.** `changelog.d/README.md` excludes
  documentation and ADRs by name.
- **Not defining a `%MachineState{}` serialization contract.** A process-less
  durable host needs one and none exists in `lib/` (no `Jason.Encoder`, no
  `to_map`/`from_map`); `st-m5c3` owns that gap. The recipe states the
  dependency and points at the bead rather than inventing a format.
- **Not making non-self-routed delayed sends durably schedulable.** ADR-0054
  decision 2 as corrected scopes the contract to a delayed send with no target
  or a `:self` target. Supporting `#_parent`, `#_invokeid`, `#_internal`, or an
  external session id would mean putting the resolved route on `%SendDelayed{}`
  or opening a public delivery door - `lib/` changes, out of scope for a docs
  branch. Recorded as Open Question 1 and named as a gap in ADR-0054's
  Consequences.
- **Not adding a per-execution ordinal to `%SendDelayed{}`** to close the
  `<foreach>` dedup residual. Same reason: a `lib/` change with its own bead.
- **Not retitling or restructuring `docs/extending.md`.** See Phase 2 decision 1.
- **Not backfilling ADR-0051's missing row in `docs/adr/README.md`.** The index
  table ends at 0050; 0051's file exists but was never indexed by the st-cmq.8
  branch. Fixing it here would be an unrelated change in the tree, which the
  CLAUDE.md authority table names as a reason a commit is still unauthorized.
  Report it for its own one-line `area:docs` chore instead. Found during this
  plan's own review pass and declined for that reason, recorded here so the
  decision survives to whoever implements Phase 1.

## Implementation Approach

ADR first, then guide, because the guide cites the ADR by number and a guide
asserting an unrecorded contract is the thing this repo's ADR habit exists to
prevent. Each phase is documentation-only, touches disjoint files, and leaves
the gate green on its own, so each is independently committable and
independently gate-verifiable.

**Phase 3 was added after Phases 1 and 2 had been executed**, when an
independent plan-critic review found three substantive errors in the contract
this plan told those phases to record (decision 2's re-entry claim, decision
3's dedup key, and decision 4's liveness door). Phase 3 amends the landed
ADR-0054 and the written-but-uncommitted `docs/durable-timers.md` to match the
corrected decisions below. It is a third phase rather than an edit to Phases 1
and 2 because those phases are now a record of what was done, and their commits
exist; the corrections to their prose in this document are marked as
corrections and are carried into Phase 3 as the work.

### Prerequisite: file the in-repo bead

**Decision on research open question 2: yes, the in-repo half gets its own
bead.** `st-rsyx`'s description says "Tracked here until the package repo and
its own beads db exist; transfer this bead then." If it transfers before the
recipe is written, the recipe leaves this tracker with the charter and the
in-repo work has no home in the tracker that owns the files it changes -
exactly the situation ADR-0025's authority rule exists to avoid ("the
repository whose files change owns the decision"). Splitting is also cheap and
reversible.

**DONE.** The bead was filed as **`st-ifa3`** before Phase 1 ran, with the
dependency on `st-cmq.8` and the split note on `st-rsyx`. Nothing remains to do
here; the step is kept as the record of why the split exists. Commits made
under this plan carry `st-ifa3` in their `Refs` trailer, not `st-rsyx`'s.
`bd create`/`update`/`note` are authorized "any time" by the CLAUDE.md table.

### The ADR number

Phase 1 originally claimed **0052**, the next free number as of this plan's
writing (`docs/adr/` ended at
`0051-invoke-handlers-are-registered-per-session.md`). The contingency this
section described then fired: by the time the branch came to rebase,
`origin/main` had landed its own `0052` (chart identity and position
serialization) and `0053` (chart test helpers). **Renumbered 2026-08-19 to
0054 and 0055**, and every reference in this plan, in both records, in the
guide, and in the index was adjusted to match. This was the mechanical check
(`ls docs/adr/`) this section always said it was, not a decision.

---

## Phase 1: ADR-0054, the durable-timer contract

### Overview

Record the three contract statements a durable-timer host works to, so the
Phase 2 guide teaches a decided rule rather than asserting one. This phase
also settles research open question 4 (**yes, this warrants an ADR**) and open
questions 5 and 6 (the keying rule and the 6.2 substitute).

**Why an ADR rather than prose alone.** ADR-0003's Consequences sanction the
*pattern* by name, which is why the pattern itself needs no new record. What
ADR-0003 does not state - and nothing else does - is (a) which of the two
vocabularies a timer consumer may read, (b) how an external store keys a timer
given ADR-0035 makes `send_id` run-local, and (c) what obligation replaces spec
6.2's discard when the scheduler outlives the session. Those are contract
statements, and this project puts contract statements in ADRs; each of the
three also constrains what the future `statifier_oban` package may do, which is
precisely the class of statement that should survive in a record rather than in
a guide that could be rewritten for readability.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`
**Changes**: New file. Standard three-section format (Context, Decision,
Consequences) per `docs/adr/README.md`'s closing note. Status line:
`Status: accepted (2026-08-19) - discharges ADR-0003's Consequences for the
delayed-send half; scopes docs/extending.md:57-58's opaque-instruction rule to
the timer consumer; reads ADR-0035's run-local send id as a cancellation key,
not a uniqueness key`.

**Context** must establish, with the `file:line` references given under Key
Discoveries above:

- the seam as it stands (`SendDelayed`/`Cancel` effects, `subscribe/2,3`,
  `send_event/2`, and the process-less `Interpreter` route);
- that `Statifier.Session` is one executor of that seam and not the seam itself
  - `lib/statifier/session.ex:1435-1450` is the library's single
  `Process.send_after/3` call;
- that ADR-0003 already named this use case and never stated its rules;
- the three unrecorded questions, with the evidence that each is genuinely open;
- that decision 3 below does **not** contradict ADR-0035's 2026-08-15
  amendment ("cross-session sendid collision recorded harmless"). That
  amendment is about in-library spec conformance, where two sessions sharing
  `send_1` cannot interfere because each session's timer table is its own. An
  external store is a single shared namespace and has no such separation, so
  the same collision that is harmless inside the library is a correctness bug
  outside it. Say this in as many words; a reviewer who knows ADR-0035 will
  otherwise read decision 3 as reopening it.

**Decision** - four numbered decisions:

1. **A durable-timer host consumes the effect vocabulary, never the instruction
   vocabulary.** The two consumption points are `{:send_delayed, %SendDelayed{}}`
   and `{:cancel, %Cancel{}}` (`lib/statifier/effect.ex:120-147`). `{:schedule,
   ...}` and `{:cancel_timers, ...}` remain opaque, which is
   `docs/extending.md:57-58`'s existing rule applied to this consumer rather
   than a new one. The charter's own scope wording ("honoring cancel (the
   cancel_timers instruction)") is corrected by this decision: it names the
   opaque half, and the effect is what a host sees.
2. **A self-routed delayed send re-enters through
   `Statifier.Session.send_event/2`; every other route is out of scope for this
   ADR.** *(Corrected 2026-08-19 - the landed ADR-0054 over-claims here; see
   Phase 3.)*

   - **Scope.** The claim holds for `<send delay="...">` with **no target**, or
     a target that parses to `:self`. That is the case `deliver_fired/4`
     (`lib/statifier/session.ex:1829-1833`) handles with its own clause, by
     re-enqueuing onto the session inbox exactly as `send_event/2` does. For
     that route, and only that route, a host scheduler can substitute
     `send_event/2` for the library's own timer and rejoin an identical path.
   - **Why the other routes are not covered.** The route is derived in the
     session at plan time and travels on the **opaque** `{:schedule, ...}`
     instruction (`lib/statifier/session/effects.ex:270-288`), which decision 1
     forbids a host from reading. It is not a field on `%SendDelayed{}`. So a
     host holding only the effect can see `target` as the author wrote it, but
     not the library's resolution of it, and it has no public door equivalent to
     `deliver/5` for `#_parent`, `#_invokeid`, or an external session id.
     Furthermore the *event* is built inside the session, not by the host:
     `delivered_event/2` (`effects.ex:392-399`) stamps `origin`,
     `origintype`, and a `sendid` gated on `id_from_author?`, and
     `#_internal` uses an entirely different carrier, `internal_event/1`
     (`effects.ex:414-427`), whose delivery re-raises through
     `Statifier.Interpreter.deliver_internal/5` and rebuilds its `Cause` from
     the machine's counters at delivery time (ADR-0039 decision 2).
   - **What a host must therefore do.** State plainly: a durable-timer host
     supports delayed sends whose target is absent or `:self`. For a delayed
     send with any other target, the host must **leave the timer to the
     library** (do not intercept it) - the effect stream is observational, so
     ignoring a `%SendDelayed{}` costs nothing and the session's own
     `Process.send_after/3` still fires it. Reconstructing a `#_parent`,
     `#_invokeid`, `#_internal`, or external-session delivery from outside is
     not supported today, because the host would have to rebuild a
     `%Statifier.Event{}` with `origin`/`origintype`/`sendid` the library sets
     and then find a public door that does not exist. **This is an open gap,
     recorded rather than solved** - see Open Questions.
   - **Not through `interpret/2`** either way: ADR-0029 makes `interpret/2` the
     fourth recorded replay input (`lib/statifier/session.ex:604-606`), and a
     host that chooses it takes on that obligation for no gain. State the
     ADR-0029 consequence explicitly so a host that *does* pick `interpret/2`
     knows what it bought.
   - A process-less host feeds the fired event in as the next
     `Statifier.Interpreter` drive's input; the same target restriction applies
     for the same reason.
3. **A stored timer is keyed by two different compound keys, and they are not
   the same key.** This is the correction of the charter's "unique per send id":
   - **Cancellation key**: `{session scope, send_id}`. It may legitimately match
     more than one stored row - `Timers.put/3` appends per `send_id`
     (`lib/statifier/session/timers.ex:39-44`) and `take/2` pops every ref under
     an id (`:51-60`) because spec 6.3 cancels them all, and an author-written
     `id` is reused verbatim without advancing the counter
     (`lib/statifier/machine/content/send.ex:383-389`). A cancel deletes every
     match; a cancel that matches nothing is a no-op, not an error, mirroring
     `take/2`'s `{[], timers}`.
   - **Deduplication key** (the at-least-once concern): `{session scope,
     send_id, macrostep, microstep, round, c_index, owner}`, read off the
     `%SendDelayed{}` itself. *(Corrected 2026-08-19 - the landed ADR-0054 omits
     `c_index` and `owner`; see Phase 3.)* The counters are stamped as of
     scheduling, not firing (`lib/statifier/effect/send_delayed.ex:11-13`,
     ADR-0046), and `c_index`/`owner` (`:33-34`) are the send's position inside
     its executable-content block. Every component is a deterministic counter or
     a static position, so re-executing the same drive after a crash produces a
     byte-identical key and the host's store dedups it.

     **Why the position fields are mandatory, not decoration.** Without them the
     key collides whenever one microstep executes two delayed sends that share a
     `send_id` - two `<send id="x" delay="...">` in one `<onentry>` block, since
     an author-written id is used verbatim and never advances the counter
     (`lib/statifier/machine/content/send.ex:383-389`). The library keeps those
     as two live timers (`Timers.put/3` appends,
     `lib/statifier/session/timers.ex:39-44`); a store keyed without `c_index`
     would silently collapse them into one, dropping a timer the state chart
     expects to fire.

     **Residual collision, stated honestly.** Even with `c_index` and `owner`,
     the key is *not* strictly per-instance. A `<send id="x" delay="...">`
     inside a `<foreach>` body executes once per iteration from the **same**
     content position, in the same microstep, under the same author id - so
     every iteration yields an identical key and the store dedups genuine
     distinct timers down to one. The library has no per-iteration ordinal on
     `%SendDelayed{}` to add. **Guidance for a host:** do not put an
     author-written `id` on a `<send delay="...">` inside a `<foreach>` if you
     are running a durable scheduler; let the id be generated, and
     `send_counter` gives each iteration its own `send_1`, `send_2`, ... and the
     key becomes per-instance again. Say this in the ADR as a stated limitation
     with its workaround, rather than claiming the key is unconditionally
     per-instance.
   - **`session scope`** is `ctx.session_id` / spec 5.10's `_sessionid` for a
     live session, or the host's own durable run id for a process-less host.
     Scoping is mandatory, not advisory: `send_counter` restarts at 0 per
     `%MachineState{}` (`lib/statifier/machine_state.ex:349`, ADR-0035), so
     `send_1` collides across runs. The library does not and cannot supply the
     scope, because it has no view of the host's store.
4. **The substitute for spec 6.2's discard-on-termination is a fire-time
   liveness check by the host, with cancel-on-run-end as a best-effort
   optimization only.** Spec 6.2 requires that a message whose session
   terminated first "MUST be discarded without attempting to deliver it", and
   `terminate/2` (`lib/statifier/session.ex:1182-1201`) is how the library
   satisfies it. An external scheduler inverts that by design. A
   cancel-on-run-end hook cannot be the guarantee, because the node death that
   durability exists to survive takes the hook with it; it is worth running to
   keep the store tidy, and it is never load-bearing. The guarantee is
   enforceable only at delivery: **before feeding a fired event back, the host
   MUST establish that the run is still live, and discard the message without
   delivering it otherwise.** "Live" excludes a halted session as well as a
   terminated one - reaching `:done` sets `state.halted` without stopping the
   process or cancelling timers (`lib/statifier/session.ex:45-57`,
   `:1546-1553`), and `handle_continue(:drain, ...)` declines to drain onto a
   halted session (`:970-973`), so an event fed to one sits queued rather than
   being discarded.

   **How "live" is actually observed.** *(Corrected 2026-08-19 - the landed
   ADR-0054 names `Statifier.Session.status/1` as the read door; see Phase 3.)*
   `status/1` is a `GenServer.call` (`lib/statifier/session.ex:644-645`), so
   against a **terminated** session it exits the caller rather than answering -
   and terminated is precisely the case the 6.2 substitute exists to catch. The
   check is therefore two-step, in this order:

   1. **Terminated?** Resolve the session id through the registry:
      `Registry.lookup(Statifier.Registry, session_id)` (ADR-0027 decision 2,
      documented at `lib/statifier/session.ex:155-160`). An empty result means
      no live session under that id - **discard the message**. A host that holds
      a pid rather than an id uses `Process.alive?/1` instead. A host that
      insists on calling `status/1` directly must wrap it so an exit is caught
      and read as "terminated", not propagated - state that explicitly, because
      an uncaught exit here turns a required discard into a crashed worker.
   2. **Halted?** Only once step 1 says a process is there, call
      `Statifier.Session.status/1` and check its `status` field. A halted
      session is live as a process and must still be treated as not-live for
      delivery.

   A process-less host performs both reads off its own persisted position
   instead.

**Consequences** must state at least: this constrains `statifier_oban` before
it is written (its uniqueness design is decided here, not there); the 6.2
guarantee moves from "preserved by construction" to "preserved by a host
check", which is a real weakening a host must be told about in plain words;
process-less hosts additionally need a `%MachineState{}` serialization contract
that does not exist yet (`st-m5c3`); and nothing in `lib/` changes, so no
conformance result moves.

#### 2. The ADR index

**File**: `docs/adr/README.md`
**Changes**: **append one new table row as the new last row** of the table,
matching the existing column shape:

```
| [0054](0054-durable-timers-consume-the-effect-vocabulary.md) | Durable timers consume the effect vocabulary; the host owns keying and the 6.2 discard | accepted |
```

Say "append as the last row" rather than "after the 0051 row" deliberately:
**the index table currently ends at 0050.** `docs/adr/0051-invoke-handlers-are-registered-per-session.md`
exists on disk but was never given an index row - a gap left by the st-cmq.8
branch. That gap is **not this plan's to close**: backfilling another bead's
missing row is an unrelated change in the tree, which the CLAUDE.md authority
table names as a reason a commit is still unauthorized. Append 0054 after the
0050 row, leave the 0051 gap exactly as it is, and report it so it can be filed
as its own one-line `area:docs` chore. The numbering is unaffected either way -
0054 is the next free number by the filesystem, which is the authority.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `mix gate.verify` exits zero, proving the run was unprofiled, unscoped,
      and not `--skip`-ed.
- [x] `mix quality --profile merge` passes. (Its ADR-judge stage will report a
      `:no_scoped_changes` skip; see the Implementation Note.)
- [x] `test -f docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`,
      substituting the number actually claimed (0054; 0054 was taken).
- [x] `grep -q '\[0054\]' docs/adr/README.md` - the index row exists (same
      number substitution).
- [x] Every path in `git diff --name-only "$(git merge-base HEAD origin/main)"`
      is under `docs/` or is `README.md`, and none is under `lib/`, `test/`, or
      is `mix.exs`. As one fish-safe command:
      `bash -c 'git diff --name-only "$(git merge-base HEAD origin/main)" | grep -vE "^(docs/|README\.md$)" && exit 1 || exit 0'`
      *(Corrected 2026-08-19: the earlier form allowed only `docs/adr/` and
      `docs/plans/`, which fails deterministically because this branch also
      introduces `docs/research/260819-st-rsyx-statifier-oban-charter-durable-timers.md`.
      The allow-list now matches the Desired End State. There is no `test/` in
      this diff - the st-xsb1 `test/` commits on this branch are already on
      `origin/main`, so the merge base is above them.)*
- [x] `test -z "$(git diff --name-only "$(git merge-base HEAD origin/main)" -- changelog.d/)"`
      - documentation and ADRs get no changelog fragment
      (`changelog.d/README.md`).

#### Manual Verification:
- [ ] The Context section's every `file:line` reference resolves to what it
      claims, checked by opening each one.
- [ ] Decision 4's spec quotation matches the local cache verbatim - read it
      from
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`,
      not from memory, per the CLAUDE.md convention.
- [ ] Decision 1 does not contradict `docs/extending.md:57-58`; it restates that
      rule for a second consumer, and a reader of both should see one rule, not
      two.
- [ ] Decision 3's dedup key really is deterministic across a re-run - confirm
      by reading `lib/statifier/machine/content/send.ex:383-389` and
      `lib/statifier/effect/send_delayed.ex:11-13` that no clock, no CSPRNG, and
      no pid enters any component.
- [ ] No regressions in related features: nothing in `lib/` or `test/` changed,
      so this is a diff review rather than a behavioral check.

**Implementation Note**: Use `mix quality --profile loop` between edits; it is
explicitly **not** this phase's gate and never satisfies one on its own. Use
`mix quality --format json --report -` when routing on stage results
programmatically (the `--loop` advancement path does). Run the full
`mix quality` plus `mix gate.verify` plus `mix quality --profile merge` as the
phase gate. `mix test.regression` and `mix test.baseline add` are **not
applicable** to this phase and must not be run: the diff contains no Elixir, so
no conformance result can move - stated rather than omitted, per
`.claude/wurk/plan.md`. Expect one unclassified `○` line in the merge-profile
run: the ADR judge skips with `:no_scoped_changes` because its scopes are
`lib/statifier` and `.claude/wurk` and this diff is documentation only. That is
the expected outcome, not a gap to close and not a reason to touch
`.claude/wurk.json`; note it in the phase report and move on. In interactive
execution, pause here for the human to confirm the manual review before Phase 2.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: The `docs/durable-timers.md` recipe

### Overview

Write the host-facing guide that acceptance clause 3 asks for, and wire it into
the three places a reader arrives from. This phase settles research open
question 3.

**Decision on open question 3: a new document, not a widening of
`docs/extending.md`.** The evidence for widening is that extending.md is the
only host-facing doc and already addresses the process-less durable host
(`:43-49`). The evidence against is stronger and structural:

- extending.md's title and every section are about the
  `Statifier.Invoke.Handler` behaviour - callbacks, registration, an
  unregistered type, a naming note. A delayed send has **no behaviour, no
  callbacks, and no registration**; it is consumed from an effect stream. A
  second top-level section would share the audience and nothing else.
- `README.md:36-37` links extending.md as "Registering your own `<invoke>`
  handlers", and ADR-0051 and `docs/datamodel.md` both point at it by that
  scope. Retitling churns three inbound references to buy nothing.
- Two further charters (`st-q6xl` persistence, `st-ewd7` heartbeats) will want
  host-facing docs of their own. A `docs/<topic>.md` per host concern is a shape
  that scales; one ever-widening `extending.md` is not.

### Changes Required:

#### 1. The recipe

**File**: `docs/durable-timers.md`
**Changes**: New file. Same register as `docs/extending.md` - addressed to a
host application author, second person, worked Elixir examples, explicitly not
re-explaining the architecture. Sections, in order:

1. **Why you would want this.** One paragraph: `Statifier.Session` schedules a
   delayed send with `Process.send_after/3`
   (`lib/statifier/session.ex:1435-1450`), so every in-flight timer dies with
   the node. For delays measured in seconds that is fine; for follow-ups,
   escalations, and timeouts measured in hours or days it is not. Name
   ADR-0003's Consequences as the sanction and ADR-0054 as the contract.
2. **What you consume.** `{:send_delayed, %Statifier.Effect.SendDelayed{}}` and
   `{:cancel, %Statifier.Effect.Cancel{}}`, with each struct's fields shown and
   `delay_ms` called out as relative rather than absolute. State plainly that
   `{:schedule, ...}` and `{:cancel_timers, ...}` are **not** yours to read
   (ADR-0054 decision 1, `docs/extending.md:57-58`), so a reader who has seen
   them in a stack trace does not reach for them.
3. **Route A: a live session.** `Statifier.Session.subscribe/2,3`, the ordered
   complete stream, a worked subscriber that pattern-matches the two effects and
   enqueues/cancels in the host's store, and `Statifier.Session.send_event/2` as
   the door back in. Note that every write door is a `cast` - there is no
   synchronous variant (`lib/statifier/session.ex:530-536`, `:546-549`,
   `:580-583`, `:611-614`). State the **target restriction** from ADR-0054
   decision 2 here, not only in section 5: a host schedules a `%SendDelayed{}`
   whose `target` is `nil` or `:self`, and *ignores* (leaves to the library) one
   with any other target, because the resolved route rides on the opaque
   `{:schedule, ...}` instruction and there is no public door to redeliver
   `#_parent`, `#_invokeid`, `#_internal`, or an external session id from
   outside. Also state that `{:halted, reason}` is end-of-stream on this channel
   (ADR-0044 decision 2, `lib/statifier/session.ex:483`), so a subscriber must
   not sit waiting for cleanup effects after a halt.
4. **Route B: a process-less host.** Drive `Statifier.Interpreter` and read the
   `[effect]` half of the return; the fired event goes in as the next drive's
   input. Point at `docs/extending.md:43-49` for the audience framing, and state
   the open dependency honestly: `%MachineState{}` is a complete resumable
   position (`docs/observability.md:36-38`) but **no serialization function for
   it exists in `lib/` today** - persisting it is yours, and `st-m5c3` is the
   bead that owns closing that gap.
5. **Keying your store.** ADR-0054 decision 3, in operational form: the
   cancellation key, the dedup key `{session scope, send_id, macrostep,
   microstep, round, c_index, owner}`, why `send_id` alone collides across runs
   (ADR-0035), why the position fields `c_index`/`owner`
   (`lib/statifier/effect/send_delayed.ex:33-34`) are mandatory rather than
   decoration, and why a cancel may delete more than one row (spec 6.3, and
   `lib/statifier/session/timers.ex:51-60`'s no-op on an unknown id). Include a
   short table of the two keys side by side so the distinction cannot be
   skimmed past. State the `<foreach>` residual collision and its workaround
   (do not hand-write an `id` on a `<send delay>` inside a `<foreach>`) as a
   named limitation.
6. **Termination: what you owe that the library used to give you.** ADR-0054
   decision 4, with the spec 6.2 sentence quoted and the halted-session gap
   spelled out concretely: a halted session neither cancels its timers nor
   drains an event fed to it (`lib/statifier/session.ex:45-57`, `:970-973`,
   `:1546-1553`), so "check the run is live" means checking for halted **and**
   terminated. Show the **two-step** check in the worked example: registry
   lookup (or `Process.alive?/1`) for terminated first, because
   `Statifier.Session.status/1` is a `GenServer.call`
   (`lib/statifier/session.ex:644-645`) that **exits** against a dead session,
   then `status/1` for halted. Do not present `status/1` alone as the liveness
   door.
7. **Correlating a fired job back to its position.** The `macrostep`,
   `microstep`, `round`, `c_index`, and `owner` fields ride on the stored
   `%SendDelayed{}` as of scheduling (ADR-0046), so read them off what you
   stored, never off the delivery.
8. **Ordering guarantees you can rely on.** ADR-0044: a subscriber never sees a
   later round ahead of an earlier one (`lib/statifier/session.ex:67-76`), and
   re-entry effects defer to the outer batch. **Cite `:67-76` and not `:70-83`**
   - `:77-83` still says `round` is carried only by `Statifier.Effect.Trace.*`
   and `Statifier.Effect.BudgetExhausted`, which ADR-0046 withdrew, and which
   would contradict this guide's own dedup key resting on `round` being present
   on `%SendDelayed{}` (it is, `lib/statifier/effect/send_delayed.ex:52`). Say
   in the guide that ADR-0046 puts `round` on every core effect, so the
   moduledoc's caveat no longer applies to what you store. Add that ADR-0044
   decision 2 makes `{:halted, _}` end-of-stream, so no cleanup effects arrive
   after a halt. Say what this does and does not promise about the order your
   jobs fire in - the *stream* is ordered; wall time is not.
9. **Where this is going.** One short paragraph pointing at the chartered
   `statifier_oban` package as the packaged consumer of exactly this recipe,
   and noting that the invoke half's at-least-once contract lives in
   `docs/extending.md:177-189` rather than here.

House style for this file: plain ASCII punctuation, matching `docs/extending.md`
and the surrounding docs.

#### 2. README link

**File**: `README.md`
**Changes**: extend the Development section's closing sentence, which today
reads "Registering your own `<invoke>` handlers:
[docs/extending.md](docs/extending.md)." Add a sibling sentence:

```
Scheduling delayed sends durably, outside the session process:
[docs/durable-timers.md](docs/durable-timers.md).
```

#### 3. Cross-link from `docs/extending.md`

**File**: `docs/extending.md`
**Changes**: one sentence only, in the "What the seam is for" section, pointing
a reader who arrived for the wrong seam at the right one. Do **not** retitle the
document, do not add a section, do not restructure. Something of the shape: "If
what you are after is a durable `<send delay>` rather than an `<invoke>`, that
is a different seam - see `docs/durable-timers.md`."

#### 4. Cross-link from `docs/architecture.md`

**File**: `docs/architecture.md`
**Changes**: in the "Sessions and invoke" section (`:124-182`), where it already
says `Statifier.Session` owns "the delayed-send timers", append one sentence
noting that this ownership is replaceable and pointing at
`docs/durable-timers.md` and ADR-0054. One sentence; this document is
explanation-shaped and contributor-facing, and a recipe does not belong in it.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `mix gate.verify` exits zero.
- [x] `test -f docs/durable-timers.md`.
- [x] All three inbound links exist. Three separate commands, so no shell loop
      is involved and fish runs them unchanged:
      `grep -q 'durable-timers.md' README.md`,
      `grep -q 'durable-timers.md' docs/extending.md`,
      `grep -q 'durable-timers.md' docs/architecture.md`.
      *(Corrected 2026-08-19: the earlier `for f in ...; do ... done` form is a
      bash construct and a syntax error in this environment's fish shell.)*
- [x] `grep -q '0054' docs/durable-timers.md` - the guide cites the ADR it
      teaches (substituting the number Phase 1 actually claimed).
- [x] Every relative link in `docs/durable-timers.md` resolves; there is no
      link-checker stage in the gate, so run one explicitly, wrapped in `bash -c`
      because the pipeline uses a bash `while` loop:
      ```
      bash -c 'grep -oE "\]\([^)]+\)" docs/durable-timers.md | sed -E "s/^\]\((.*)\)$/\1/" | grep -v "^https\?://" | sed "s/#.*//" | grep -v "^$" | while read -r l; do [ -e "docs/$l" ] || [ -e "$l" ] || { echo "broken: $l"; exit 1; }; done'
      ```
      *(Corrected 2026-08-19: the earlier form was bash-only and unwrapped, and
      its `[^)h]` first-character filter silently skipped every relative link
      whose target begins with `h` - `handlers.md`, for instance. The filter is
      now an explicit `https?://` exclusion.)*
- [x] Every path in `git diff --name-only "$(git merge-base HEAD origin/main)"`
      is under `docs/` or is `README.md`:
      `bash -c 'git diff --name-only "$(git merge-base HEAD origin/main)" | grep -vE "^(docs/|README\.md$)" && exit 1 || exit 0'`
      On top of Phase 1's files this phase adds `docs/durable-timers.md`,
      `README.md`, `docs/extending.md`, and `docs/architecture.md`.
- [x] `test -z "$(git diff --name-only "$(git merge-base HEAD origin/main)" -- changelog.d/)"`
      - no changelog fragment (`changelog.d/README.md` excludes documentation).

#### Manual Verification:
- [ ] Each Elixir snippet in the guide is checked by hand against the real
      signatures - `subscribe/2,3` (`lib/statifier/session.ex:676-719`),
      `send_event/2` (`:530-536`), and the two effect structs
      (`lib/statifier/effect/send_delayed.ex:25-54`,
      `lib/statifier/effect/cancel.ex:20-30`). The snippets are illustrative and
      are not compiled by the gate, so a wrong arity or a renamed field ships
      silently; this check is the only thing standing between the reader and
      that.
- [ ] The end-state acceptance read: someone who has not seen `lib/` can name,
      from this document alone, the two effects, the door back in, the compound
      key, and the liveness check.
- [ ] The guide contradicts nothing in ADR-0054 - read them side by side.
- [ ] The `docs/extending.md` edit is genuinely one sentence and the document's
      scope is unchanged.
- [ ] No regressions in related features: the diff is documentation only.

**Implementation Note**: Use `mix quality --profile loop` between edits; it is
explicitly **not** this phase's gate. Use `mix quality --format json --report -`
when routing on stage results programmatically. Run the full `mix quality` plus
`mix gate.verify` as the phase gate. `--profile merge` is not required here but
is what `/wurk:mr` runs before pushing. `mix test.regression` and
`mix test.baseline add` are **not applicable**: the diff contains no Elixir and
no conformance result can move. Every shell criterion above that uses a loop is
wrapped in `bash -c` - this environment's shell is fish, where a bare `for ...
do ... done` or `... | while read` is a syntax error rather than a failing
check. In interactive execution, pause here for the human to confirm the manual
review. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically, and Manual Verification items are deferred to
the end.

---

## Phase 3: Remediate the landed ADR-0054 and the written recipe

### Overview

Phases 1 and 2 were executed against an earlier revision of this plan whose
decisions 2, 3, and 4 were partly wrong and whose citation in Phase 2 section 8
pointed at a withdrawn statement. This phase brings the already-written prose
into line with the corrected decisions above. It changes documentation only,
touches the same file set the earlier phases did, and is independently
committable and gate-verifiable on the same terms.

The corrections themselves are argued in place above (Phase 1 decisions 2, 3,
4; Phase 2 sections 3, 5, 6, 7, 8) and are not re-argued here. This section is
the checklist of what has to change and where.

### Changes Required:

#### 1. `docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md` (committed in `f49559d`)

**Changes**: amend, and **mark the amendment the way this repo marks every
other one**. ADR-0001's Decision says an ADR "is amended by a new ADR that
supersedes it, not by rewriting history", and the practice that has grown
around it - 0002, 0004, 0008, 0014, 0019, 0020, 0030, 0035, 0039, 0040, 0041,
0046, 0047, 0048 - is a dated amendment note rather than a fresh superseding
record for a correction of this size. Follow the practice, not a silent
rewrite: this is a correction of fact inside an accepted record, and reading
ADR-0001 to require a whole superseding ADR for it would leave 0054 accepted
and wrong until 0055 landed. Do **not** rewrite the decisions as though they
had always read this way; the marker is what keeps the change from being the
history-rewriting ADR-0001 forbids.

Concretely, matching the ADR-0035 pattern
(`docs/adr/0035-send-id-is-a-machinestate-counter.md:3`, `:84`):

- The Status line gains `- amended 2026-08-19 (st-ifa3: decision 2 scoped to
  self-routed sends; decision 3's dedup key gains the position fields;
  decision 4's liveness door corrected)`.
- Each corrected decision carries an inline `*(Amended 2026-08-19, st-ifa3.)*`
  marker at the point the text changes, so a reader sees which claims moved.
- `docs/adr/README.md`'s 0054 row's status column becomes
  `accepted (amended 2026-08-19: decisions 2, 3, and 4 corrected)`, matching
  the shape of the 0008 and 0014 rows.

Do not renumber and do not supersede. Four edits to the body:

- **Decision 2** currently claims, without qualification, that "the fired event
  re-enters through `Statifier.Session.send_event/2`". Rewrite it to the scoped
  form in Phase 1 decision 2 above: the claim holds for a delayed send with no
  target or a `:self` target, and for nothing else. Add the evidence
  (`lib/statifier/session/effects.ex:270-288` derives the route into the opaque
  `{:schedule, ...}` instruction; `lib/statifier/session.ex:1829-1833` clauses
  `:self` separately and routes the rest through `deliver/5`;
  `effects.ex:392-399` and `:414-427` build the event inside the session). Add
  the host instruction: leave a non-self-targeted `%SendDelayed{}` to the
  library. Name `#_internal`, `#_parent`, `#_invokeid`, and external session
  ids as explicitly out of scope, and record the gap in the ADR's Consequences.
- **Decision 3's dedup key** currently reads `{session scope, send_id,
  macrostep, microstep, round}`. Add `c_index` and `owner`
  (`lib/statifier/effect/send_delayed.ex:33-34`), with the two-sends-in-one-block
  collision as the reason, and add the honest residual: a `<send>` inside a
  `<foreach>` reuses the same `c_index` every iteration, so the key is
  per-instance only when the id is generated rather than author-written.
  Replace any unqualified "per-instance" wording with the qualified claim.
- **Decision 4** currently names `Statifier.Session.status/1` as the read door.
  Replace with the two-step check: registry lookup (ADR-0027 decision 2,
  `lib/statifier/session.ex:155-160`) or `Process.alive?/1` for terminated,
  then `status/1` for halted; and state that `status/1` is a `GenServer.call`
  (`:644-645`) that exits against a terminated session, so using it alone turns
  a required discard into a crashed worker.
- **Consequences**: add the decision-2 gap (non-self routes are not durably
  schedulable today) as a named consequence, so it is discoverable from the
  record rather than only from this plan.

#### 2. `docs/durable-timers.md` (written, uncommitted)

**Changes**: bring sections 3, 5, 6, 7, and 8 into line with the amended ADR,
per the corrected wording in Phase 2's section list above. Concretely:

- Section 3 gains the target restriction and the `{:halted, _}`
  end-of-stream note (ADR-0044 decision 2, `lib/statifier/session.ex:483`).
- Section 5's dedup key gains `c_index` and `owner`, the reason they are
  mandatory, and the `<foreach>` limitation with its workaround. The side-by-side
  key table is updated to match.
- Section 6's worked example shows the two-step liveness check, terminated
  before halted, and never presents `status/1` alone as the door.
- Section 7 lists `c_index` and `owner` alongside the three counters.
- Section 8's citation moves from `lib/statifier/session.ex:70-83` to `:67-76`,
  and the text states that ADR-0046 puts `round` on every core effect so the
  moduledoc's `:77-83` caveat does not apply to a stored `%SendDelayed{}`.

Any worked example that schedules a `%SendDelayed{}` unconditionally must gain
the target guard, or the guide teaches a host to swallow sends it cannot
redeliver.

#### 3. `docs/adr/README.md`

**Changes**: the 0054 row's status column only, from `accepted` to
`accepted (amended 2026-08-19: decisions 2, 3, and 4 corrected)`. Leave the
0051 gap exactly as it is - still not this plan's to close.

#### 4. `README.md`, `docs/extending.md`, `docs/architecture.md`

**Changes**: none expected. Their edits are one-sentence cross-links and no
finding touches them. Re-read them only to confirm that.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] `mix gate.verify` exits zero.
- [x] `mix quality --profile merge` passes.
- [x] The dedup key gained the position fields in **both** documents, and the
      old five-field spelling is gone from both. A bare `grep -q 'c_index'`
      passes falsely - both files already print `c_index` inside the struct
      listing - so match the key itself:
      `grep -q 'round, c_index, owner' docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`,
      `grep -q 'round, c_index, owner' docs/durable-timers.md`,
      `bash -c '! grep -q "microstep, round}" docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md'`,
      `bash -c '! grep -q "microstep, round}" docs/durable-timers.md'`
      (today those last two would fail: `0054...md:115` and
      `durable-timers.md:188` both carry the five-field key).
- [x] `grep -q 'Statifier.Registry' docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`
      and `grep -q 'Statifier.Registry' docs/durable-timers.md` - decision 4 and
      the guide's section 6 name the registry door rather than `status/1` alone
      (today `docs/durable-timers.md:225` says "`Statifier.Session.status/1` is
      the read door for a live host").
- [x] `grep -q ':67-76' docs/durable-timers.md` and
      `bash -c '! grep -q ":70-83" docs/durable-timers.md'` - the ordering
      citation was narrowed off the withdrawn paragraph (today the guide carries
      `:70-83`, so this criterion is red until Phase 3 runs).
- [x] `grep -q '_parent' docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`
      - decision 2 names the out-of-scope routes.
- [x] The amendment is marked, per ADR-0001 and the repo's amendment practice:
      `bash -c 'grep -q "^Status:.*amended 2026-08-19" docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md'`,
      `grep -c 'Amended 2026-08-19' docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`
      returns at least 3 (one inline marker per corrected decision), and
      `bash -c 'grep "\[0054\]" docs/adr/README.md | grep -q "amended 2026-08-19"'`.
- [x] Every path in `git diff --name-only "$(git merge-base HEAD origin/main)"`
      is under `docs/` or is `README.md`:
      `bash -c 'git diff --name-only "$(git merge-base HEAD origin/main)" | grep -vE "^(docs/|README\.md$)" && exit 1 || exit 0'`
- [x] `test -z "$(git diff --name-only "$(git merge-base HEAD origin/main)" -- changelog.d/)"`
      - still no changelog fragment.

#### Manual Verification:
- [ ] Amended decision 2 is read against `lib/statifier/session/effects.ex:270-288`,
      `lib/statifier/session.ex:1829-1833`, and `effects.ex:392-399`/`:414-427`
      side by side, and claims nothing those four passages do not support.
- [ ] Amended decision 3 is read against `lib/statifier/effect/send_delayed.ex:33-34`
      and `lib/statifier/machine/content/foreach.ex:320-340`, confirming that
      `c_index` is a static document-order identity and therefore that the
      `<foreach>` residual is real rather than hypothetical.
- [ ] Amended decision 4's two-step check is read against
      `lib/statifier/session.ex:644-645` and `:155-160`, confirming that the
      first step never calls into a possibly-dead process.
- [ ] The guide and the amended ADR are read side by side and agree on all four
      decisions - the same check Phase 2 made against the pre-correction pair.
- [ ] The amendment markers read like the ones already in the corpus - compare
      against `docs/adr/0035-send-id-is-a-machinestate-counter.md:3` and `:84`,
      and against the 0008 and 0014 rows in `docs/adr/README.md`. A marker that
      says an amendment happened but not which claims moved is not enough.
- [ ] No regressions in related features: the diff is documentation only,
      nothing in `lib/` or `test/` changed, so this is a diff review rather
      than a behavioral check.

**Implementation Note**: Use `mix quality --profile loop` between edits; it is
explicitly **not** this phase's gate. Use `mix quality --format json --report -`
when routing on stage results programmatically. Run the full `mix quality` plus
`mix gate.verify` plus `mix quality --profile merge` as the phase gate.
`mix test.regression` and `mix test.baseline add` are **not applicable**: the
diff contains no Elixir. The merge-profile run will again report the ADR judge
as an unclassified `:no_scoped_changes` skip; that is expected for a docs-only
diff and is not a gap to close. In interactive execution, pause here for the
human to confirm the manual review. In looped (`--loop`) execution, this
phase's Automated Verification gates advancement automatically, and Manual
Verification items are deferred to the end.

---

## Open Questions

Recorded rather than resolved, because no human was available when this
revision was written and none of them blocks Phase 3.

1. **Non-self-routed durable delayed sends.** ADR-0054 decision 2, as corrected,
   supports a delayed send whose target is absent or `:self` and no other. A
   durable host cannot today redeliver a `#_parent`, `#_invokeid`, `#_internal`,
   or external-session delayed send, because the resolved route rides on the
   opaque `{:schedule, ...}` instruction and the delivered `%Statifier.Event{}`
   is built inside the session. Closing this would mean either putting
   the resolved route on `%SendDelayed{}` or opening a public delivery
   door - both `lib/` changes, both needing their own bead and their own ADR. **Recommended
   follow-up:** file an `area:docs`-adjacent `lib/` bead for it. Not filed here,
   because filing it is a scoping decision about the seam rather than a
   correction to this plan.

   **Settled (2026-08-19):** Decided at the direction level and recorded as
   ADR-0055, `docs/adr/0055-non-self-delayed-send-routes-stay-the-librarys.md`.
   `#_parent`, `#_invokeid`, and `#_internal` stay the library's permanently, on
   semantic grounds: each names the sending session's live process bookkeeping,
   which a durable timer outlives by definition. The external-session route is
   deferred behind a named trigger rather than foreclosed. No resolved-route
   field joins `%SendDelayed{}` - `Statifier.Send.Target.parse/1` is already
   public, pure, and deterministic, so a host can reproduce the planner's
   resolution; what is genuinely missing is the delivered-event construction and
   the delivery/miss doors, not route visibility. ADR-0055 carries its own open
   question about `error.communication` when a fired non-self send misses and
   the sending session is gone.
2. **The `<foreach>` dedup residual.** The workaround (do not author an `id` on
   a `<send delay>` inside a `<foreach>`) is a documented constraint on the
   state chart author, not a property of the library. Whether the library should
   grow a per-execution ordinal on `%SendDelayed{}` is a `lib/` question for its
   own bead.

   **Settled (2026-08-19):** Filed as `st-q6b6` (P3, `area:interpreter`),
   which depends on `st-ifa3`. The documented constraint stands in ADR-0054
   and `docs/durable-timers.md` until that bead decides otherwise.
3. **ADR-0051's missing index row** in `docs/adr/README.md`, found during the
   original plan review and declined as an unrelated change (see "What We're NOT
   Doing"). Still open, still declined here, still wants its own one-line
   `area:docs` chore.

   **Settled (2026-08-19):** Filed as `st-8pya` (P4, `area:docs`). Still
   declined on this branch - backfilling it here is the unrelated change the
   plan refused, and it needs its own branch.

---

## Testing Strategy

### Unit Tests:

**None, deliberately.** This plan adds no `lib/` code and no `test/` code, so
there is nothing to sabotage and no test to write - the CLAUDE.md sabotage
convention applies to "every new test that asserts `lib/` behavior", and this
branch adds no such test. The corresponding entry in the honest column is that
the guide's Elixir snippets are **not compiled or executed by anything**, which
is why Phase 2's manual criteria make hand-checking them against real signatures
a named step rather than an implied one.

If a future branch wants those snippets mechanically checked, the shape would be
a doctest-style compiled example module under `test/`, which is a change to
`test/` and therefore a separate bead - not this one.

### Manual Testing Steps:

1. Read `docs/durable-timers.md` top to bottom as a host author would, with
   `lib/` closed. Write down, from the document alone, the two effects to
   consume, the function to call to feed an event back, the compound key, and
   the liveness check. Compare against ADR-0054's decisions 1-4.
2. Open each Elixir snippet's referenced function in `lib/` and confirm the name,
   arity, and field names match.
3. Open each `file:line` reference in ADR-0054 and confirm it says what the ADR
   claims it says.
4. Follow every relative link in both new files and confirm it lands on an
   existing file and the right section.
5. Confirm `git diff --name-only` against the merge base touches only paths
   under `docs/` (the ADR, the plan, the research document, the new guide, and
   the two cross-linked docs) and `README.md`.
6. After Phase 3, re-read the amended decisions 2, 3, and 4 against the code
   passages named in Phase 3's manual criteria, and re-read the guide against
   the amended ADR.

## Corpus/Ratchet Notes

**No corpus impact, and none is possible.** This plan adds no Elixir, so no
SCION or W3C test can change outcome and `test/passing_tests.json` does not
move. `mix test.regression` and `mix test.baseline add` are therefore not run
in either phase - stated explicitly rather than omitted, because
`.claude/wurk/plan.md` asks for them "whenever a phase can move conformance
results" and silence would leave the implementer guessing whether the omission
was considered.

The same reasoning covers two other extension requirements. The **Appendix D
rule** does not engage: no phase touches `lib/statifier/interpreter*`, so there
is no pseudocode deviation to declare. The **spec-conformance manual
criterion** the extension requires "for every phase touching
`lib/statifier/`" likewise does not engage, because no phase touches it. What
replaces it is Phase 1's manual criterion that the spec 6.2 quotation be read
from the local cache verbatim rather than from memory, which is the one place
this branch makes a claim about the spec at all.

## References

- Source document: `docs/research/260819-st-rsyx-statifier-oban-charter-durable-timers.md`
- Bead: `st-ifa3` (the in-repo half, and the id every commit under this plan
  references); `st-rsyx` (the charter it was split from)
- Dependency bead: `st-cmq.8` (invoke handler registry; merged via PR #191)
- Related beads: `st-q6xl` (statifier_persistence charter), `st-m5c3` (Machine
  identity / serialization contract), `st-ewd7` (heartbeats charter)
- Related ADRs: `docs/adr/0001-record-architecture-decisions.md` (why Phase 3
  marks its amendment
  rather than rewriting 0054 in place),
  `docs/adr/0003-pure-core-with-effects.md` (the warrant, names
  Oban at `:27-28`), `docs/adr/0029-session-interpret-stays-public.md`,
  `docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md`,
  `docs/adr/0035-send-id-is-a-machinestate-counter.md`,
  `docs/adr/0044-re-entry-effects-defer-to-the-outer-batch.md`,
  `docs/adr/0046-round-on-every-core-effect.md` (why `lib/statifier/session.ex:77-83`
  is stale and the ordering citation must be `:67-76`),
  `docs/adr/0027-embedder-placed-session-runtime.md` (decision 2, the registry
  lookup that answers "terminated?" without a `GenServer.call`),
  `docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`
  (decision 2; why `#_internal` rebuilds its `Cause` at delivery time),
  `docs/adr/0051-invoke-handlers-are-registered-per-session.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md` (why the clock-check
  idea is not proposed here), `docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md`
  (why the in-repo half gets its own bead)
- Prior plan that scoped this charter out by name:
  `docs/plans/260818-st-cmq.8-handler-registry-invoke-as-an-extension.md:425-430`
- Similar implementation (register, tone, and structure to model the guide on):
  `docs/extending.md`
- Spec: W3C SCXML 6.2 (delayed send discard on termination) and 6.3 (a cancel
  cancels every send with that sendid), read from
  `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

**Order matters now that Phase 3 exists.** Phases 1 and 2 ran against the
uncorrected plan, so confirming their items against the *pre-amendment* ADR and
guide would sign off on prose Phase 3 is about to change. Run Phase 3 first,
then confirm Phase 1's and Phase 2's items against the amended documents,
then Phase 3's own.

### Phase 1

- [x] The Context section's every `file:line` reference resolves to what it
      claims, checked by opening each one.
- [x] Decision 4's spec quotation matches the local cache verbatim - read it
      from
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`,
      not from memory, per the CLAUDE.md convention.
- [x] Decision 1 does not contradict `docs/extending.md:57-58`; it restates that
      rule for a second consumer, and a reader of both should see one rule, not
      two.
- [x] Decision 3's dedup key really is deterministic across a re-run - confirm
      by reading `lib/statifier/machine/content/send.ex:383-389` and
      `lib/statifier/effect/send_delayed.ex:11-13` that no clock, no CSPRNG, and
      no pid enters any component.
- [x] No regressions in related features: nothing in `lib/` or `test/` changed,
      so this is a diff review rather than a behavioral check.

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` plus `mix gate.verify` plus `mix quality --profile merge` as
the phase gate. In interactive execution, pause here for the human to confirm
the manual review before Phase 2. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via `/wurk:commit
--auto`), and Manual Verification items are deferred and surfaced once at the
end instead of blocking here.

---

### Phase 2

- [x] Each Elixir snippet in the guide is checked by hand against the real
      signatures - `subscribe/2,3` (`lib/statifier/session.ex:676-719`),
      `send_event/2` (`:530-536`), and the two effect structs
      (`lib/statifier/effect/send_delayed.ex:25-54`,
      `lib/statifier/effect/cancel.ex:20-30`). The snippets are illustrative and
      are not compiled by the gate, so a wrong arity or a renamed field ships
      silently; this check is the only thing standing between the reader and
      that.
- [x] The end-state acceptance read: someone who has not seen `lib/` can name,
      from this document alone, the two effects, the door back in, the compound
      key, and the liveness check.
- [x] The guide contradicts nothing in ADR-0054 - read them side by side.
- [x] The `docs/extending.md` edit is genuinely one sentence and the document's
      scope is unchanged.
- [x] No regressions in related features: the diff is documentation only.

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` plus `mix gate.verify` as the phase gate. `--profile merge`
is not required here (no ADR changes in this phase) but is what `/wurk:mr` will
run before pushing. In interactive execution, pause here for the human to
confirm the manual review. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically, and Manual Verification
items are deferred to the end.

---

### Phase 3

- [x] Amended decision 2 is read against `lib/statifier/session/effects.ex:270-288`,
      `lib/statifier/session.ex:1829-1833`, and `effects.ex:392-399`/`:414-427`
      side by side, and claims nothing those four passages do not support.
- [x] Amended decision 3 is read against `lib/statifier/effect/send_delayed.ex:33-34`
      and `lib/statifier/machine/content/foreach.ex:320-340`, confirming that
      `c_index` is a static document-order identity and therefore that the
      `<foreach>` residual is real rather than hypothetical.
- [x] Amended decision 4's two-step check is read against
      `lib/statifier/session.ex:644-645` and `:155-160`, confirming that the
      first step never calls into a possibly-dead process.
- [x] The guide and the amended ADR are read side by side and agree on all four
      decisions.
- [x] The amendment markers read like the ones already in the corpus - compare
      against `docs/adr/0035-send-id-is-a-machinestate-counter.md:3` and `:84`,
      and against the 0008 and 0014 rows in `docs/adr/README.md`.
- [x] No regressions in related features: the diff is documentation only.

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` plus `mix gate.verify` plus `mix quality --profile merge` as
the phase gate. Expect the ADR judge to skip with `:no_scoped_changes`. In
interactive execution, pause here for the human to confirm the manual review. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically, and Manual Verification items are deferred to the
end.

---
