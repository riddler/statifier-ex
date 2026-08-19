# Durable Timers Recipe for Non-Oban Hosts Implementation Plan

## Overview

Deliver the one clause of the `statifier_oban` charter that is deliverable
inside this repository: **"the durable-timers pattern is documented for
non-Oban hosts."** Two documentation artifacts, no `lib/` changes, no `test/`
changes - an ADR that records the contract a durable-timer host works to, and
a host-facing recipe document that shows how to work to it.

Bead: st-rsyx (charter, `area:docs`). The in-repo half gets its own bead so
it is not orphaned when the charter transfers to the package repo - see
"Prerequisite: file the in-repo bead" under Implementation Approach.

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

- `docs/adr/0052-durable-timers-consume-the-effect-vocabulary.md` - accepted,
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
without reading `lib/`. `git diff --stat` against the merge base touches only
`docs/`, `README.md`, and this plan. `mix quality` and `mix gate.verify` are
green; `mix quality --profile merge` is green, which is the run that exercises
the ADR judge.

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
  re-enabled by `--profile merge`. An ADR phase must run `--profile merge`
  additionally, and `mix gate.verify` still needs an unprofiled run.

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
- **Not retitling or restructuring `docs/extending.md`.** See Phase 2 decision 1.
- **Not backfilling ADR-0051's missing row in `docs/adr/README.md`.** The index
  table ends at 0050; 0051's file exists but was never indexed by the st-cmq.8
  branch. Fixing it here would be an unrelated change in the tree, which the
  CLAUDE.md authority table names as a reason a commit is still unauthorized.
  Report it for its own one-line `area:docs` chore instead. Found during this
  plan's own review pass and declined for that reason, recorded here so the
  decision survives to whoever implements Phase 1.

## Implementation Approach

Two phases, ADR first then guide, because the guide cites the ADR by number and
a guide asserting an unrecorded contract is the thing this repo's ADR habit
exists to prevent. Each phase is documentation-only, touches disjoint files, and
leaves the gate green on its own, so each is independently committable and
independently gate-verifiable.

### Prerequisite: file the in-repo bead

**Decision on research open question 2: yes, the in-repo half gets its own
bead.** `st-rsyx`'s description says "Tracked here until the package repo and
its own beads db exist; transfer this bead then." If it transfers before the
recipe is written, the recipe leaves this tracker with the charter and the
in-repo work has no home in the tracker that owns the files it changes -
exactly the situation ADR-0025's authority rule exists to avoid ("the
repository whose files change owns the decision"). Splitting is also cheap and
reversible.

Before Phase 1, the session that owns this work runs:

```bash
bd create "Durable-timers recipe for non-Oban hosts" \
  --type feature -p 2 -l area:docs \
  -d "Delivers st-rsyx acceptance clause 3 inside statifier-ex: an ADR recording the durable-timer contract (effect vocabulary, compound keying, the substitute for spec 6.2 discard-on-termination) plus a host-facing docs/durable-timers.md recipe. No lib/ or test/ changes. Plan: docs/plans/260819-st-rsyx-durable-timers-recipe-for-non-oban-hosts.md"
bd dep add <new-id> st-cmq.8
bd update st-rsyx --notes "In-repo half split to <new-id> (AC clause 3, the durable-timers recipe). The charter bead keeps clauses 1 and 2 and transfers to statifier_oban when that repo has a mix project and its own beads db."
```

`bd create`/`update`/`note` are authorized "any time" by the CLAUDE.md table.
Commits made under this plan carry the new bead's id in their `Refs` trailer,
not `st-rsyx`'s.

### The ADR number

Phase 1 claims **0052**, the next free number as of this plan's writing
(`docs/adr/` ends at `0051-invoke-handlers-are-registered-per-session.md`). If a
sibling branch has landed an 0052 by the time this phase runs, take the next
free number and adjust every reference in Phase 2 to match. This is a
mechanical check (`ls docs/adr/`), not a decision.

---

## Phase 1: ADR-0052, the durable-timer contract

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

**File**: `docs/adr/0052-durable-timers-consume-the-effect-vocabulary.md`
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
2. **The fired event re-enters through `Statifier.Session.send_event/2`** for a
   live-session host, or through the host's own next `Statifier.Interpreter`
   drive for a process-less one. Not through `interpret/2`: ADR-0029 makes
   `interpret/2` the fourth recorded replay input
   (`lib/statifier/session.ex:604-606`), and a host that chooses it takes on
   that obligation for no gain, because `deliver_fired/4`
   (`lib/statifier/session.ex:1823-1833`) already re-enqueues a `:self` route
   exactly as `send_event/2` does. State the ADR-0029 consequence explicitly so
   a host that *does* pick `interpret/2` knows what it bought.
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
     send_id, macrostep, microstep, round}`, read off the `%SendDelayed{}`
     itself. Those counters are stamped as of scheduling, not firing
     (`lib/statifier/effect/send_delayed.ex:11-13`, ADR-0046), and every
     component is a deterministic counter, so re-executing the same drive after
     a crash produces a byte-identical key and the host's store dedups it.
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
   being discarded. `Statifier.Session.status/1` is the read door for a live
   host; a process-less host reads it off its own persisted position.

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
| [0052](0052-durable-timers-consume-the-effect-vocabulary.md) | Durable timers consume the effect vocabulary; the host owns keying and the 6.2 discard | accepted |
```

Say "append as the last row" rather than "after the 0051 row" deliberately:
**the index table currently ends at 0050.** `docs/adr/0051-invoke-handlers-are-registered-per-session.md`
exists on disk but was never given an index row - a gap left by the st-cmq.8
branch. That gap is **not this plan's to close**: backfilling another bead's
missing row is an unrelated change in the tree, which the CLAUDE.md authority
table names as a reason a commit is still unauthorized. Append 0052 after the
0050 row, leave the 0051 gap exactly as it is, and report it so it can be filed
as its own one-line `area:docs` chore. The numbering is unaffected either way -
0052 is the next free number by the filesystem, which is the authority.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` is the command to run between edits. It is
      explicitly **not** this phase's gate and never satisfies one on its own.
- [x] Full `mix quality` passes.
- [x] `mix gate.verify` exits zero, proving the run was unprofiled, unscoped,
      and not `--skip`-ed.
- [x] `mix quality --profile merge` passes - this is the run that enables the
      ADR judge (`.quality.exs:33`, `:40-42`), and it is the only automated
      check that reads the ADR at all.
- [x] `mix quality --format json --report -` is the invocation to use when the
      executing agent needs to route on stage results programmatically (the
      `--loop` advancement path does).
- [x] `test -f docs/adr/0052-durable-timers-consume-the-effect-vocabulary.md`,
      substituting the number actually claimed if 0052 was taken.
- [x] `grep -q '\[0052\]' docs/adr/README.md` - the index row exists (same
      number substitution).
- [x] `git diff --name-only "$(git merge-base HEAD origin/main)"` lists only
      files under `docs/adr/` and `docs/plans/`; no `lib/`, no `test/`, no
      `mix.exs`.
- [x] `test -z "$(git diff --name-only "$(git merge-base HEAD origin/main)" -- changelog.d/)"`
      - documentation and ADRs get no changelog fragment
      (`changelog.d/README.md`).
- [x] `mix test.regression` and `mix test.baseline add` are **not applicable**
      to this phase and must not be run: the diff contains no Elixir, so no
      conformance result can move. Stated rather than omitted, per
      `.claude/wurk/plan.md`.

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

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` plus `mix gate.verify` plus `mix quality --profile merge` as
the phase gate. In interactive execution, pause here for the human to confirm
the manual review before Phase 2. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via `/wurk:commit
--auto`), and Manual Verification items are deferred and surfaced once at the
end instead of blocking here.

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
   ADR-0003's Consequences as the sanction and ADR-0052 as the contract.
2. **What you consume.** `{:send_delayed, %Statifier.Effect.SendDelayed{}}` and
   `{:cancel, %Statifier.Effect.Cancel{}}`, with each struct's fields shown and
   `delay_ms` called out as relative rather than absolute. State plainly that
   `{:schedule, ...}` and `{:cancel_timers, ...}` are **not** yours to read
   (ADR-0052 decision 1, `docs/extending.md:57-58`), so a reader who has seen
   them in a stack trace does not reach for them.
3. **Route A: a live session.** `Statifier.Session.subscribe/2,3`, the ordered
   complete stream, a worked subscriber that pattern-matches the two effects and
   enqueues/cancels in the host's store, and `Statifier.Session.send_event/2` as
   the door back in. Note that every write door is a `cast` - there is no
   synchronous variant (`lib/statifier/session.ex:530-536`, `:546-549`,
   `:580-583`, `:611-614`).
4. **Route B: a process-less host.** Drive `Statifier.Interpreter` and read the
   `[effect]` half of the return; the fired event goes in as the next drive's
   input. Point at `docs/extending.md:43-49` for the audience framing, and state
   the open dependency honestly: `%MachineState{}` is a complete resumable
   position (`docs/observability.md:36-38`) but **no serialization function for
   it exists in `lib/` today** - persisting it is yours, and `st-m5c3` is the
   bead that owns closing that gap.
5. **Keying your store.** ADR-0052 decision 3, in operational form: the
   cancellation key, the dedup key, why `send_id` alone collides across runs
   (ADR-0035), and why a cancel may delete more than one row (spec 6.3, and
   `lib/statifier/session/timers.ex:51-60`'s no-op on an unknown id). Include a
   short table of the two keys side by side so the distinction cannot be
   skimmed past.
6. **Termination: what you owe that the library used to give you.** ADR-0052
   decision 4, with the spec 6.2 sentence quoted and the halted-session gap
   spelled out concretely: a halted session neither cancels its timers nor
   drains an event fed to it (`lib/statifier/session.ex:45-57`, `:970-973`,
   `:1546-1553`), so "check the run is live" means checking for halted **and**
   terminated. Show the check in the worked example rather than only describing
   it.
7. **Correlating a fired job back to its position.** The `macrostep`,
   `microstep`, and `round` fields ride on the stored `%SendDelayed{}` as of
   scheduling (ADR-0046), so read them off what you stored, never off the
   delivery.
8. **Ordering guarantees you can rely on.** ADR-0044: a subscriber never sees a
   later round ahead of an earlier one (`lib/statifier/session.ex:70-83`), and
   re-entry effects defer to the outer batch. Say what this does and does not
   promise about the order your jobs fire in - the *stream* is ordered; wall
   time is not.
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
`docs/durable-timers.md` and ADR-0052. One sentence; this document is
explanation-shaped and contributor-facing, and a recipe does not belong in it.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` is the command to run between edits. It is
      explicitly **not** this phase's gate.
- [ ] Full `mix quality` passes.
- [ ] `mix gate.verify` exits zero.
- [ ] `mix quality --format json --report -` is the invocation to use when the
      executing agent needs to route on stage results programmatically.
- [ ] `test -f docs/durable-timers.md`.
- [ ] `for f in README.md docs/extending.md docs/architecture.md; do grep -q
      'durable-timers.md' "$f" || exit 1; done` - all three inbound links exist.
- [ ] `grep -q '0052' docs/durable-timers.md` - the guide cites the ADR it
      teaches (substituting the number Phase 1 actually claimed).
- [ ] Every relative link in `docs/durable-timers.md` resolves; there is no
      link-checker stage in the gate, so run one explicitly:
      `grep -o '](\([^)h][^)]*\))' docs/durable-timers.md | sed 's/](\(.*\))/\1/'
      | sed 's/#.*//' | while read -r l; do [ -e "docs/$l" ] || [ -e "$l" ] ||
      { echo "broken: $l"; exit 1; }; done`
- [ ] `git diff --name-only "$(git merge-base HEAD origin/main)"` adds only
      `docs/durable-timers.md`, `README.md`, `docs/extending.md`, and
      `docs/architecture.md` on top of Phase 1's files.
- [ ] `test -z "$(git diff --name-only "$(git merge-base HEAD origin/main)" -- changelog.d/)"`
      - no changelog fragment (`changelog.d/README.md` excludes documentation).
- [ ] `mix test.regression` and `mix test.baseline add` are **not applicable**:
      the diff contains no Elixir and no conformance result can move.

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
- [ ] The guide contradicts nothing in ADR-0052 - read them side by side.
- [ ] The `docs/extending.md` edit is genuinely one sentence and the document's
      scope is unchanged.
- [ ] No regressions in related features: the diff is documentation only.

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` plus `mix gate.verify` as the phase gate. `--profile merge`
is not required here (no ADR changes in this phase) but is what `/wurk:mr` will
run before pushing. In interactive execution, pause here for the human to
confirm the manual review. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically, and Manual Verification
items are deferred to the end.

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
   the liveness check. Compare against ADR-0052's decisions 1-4.
2. Open each Elixir snippet's referenced function in `lib/` and confirm the name,
   arity, and field names match.
3. Open each `file:line` reference in ADR-0052 and confirm it says what the ADR
   claims it says.
4. Follow every relative link in both new files and confirm it lands on an
   existing file and the right section.
5. Confirm `git diff --stat` against the merge base touches only `docs/`,
   `README.md`, and this plan.

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
- Bead: `st-rsyx` (charter); the in-repo bead filed per "Prerequisite" above is
  the one this plan's commits reference
- Dependency bead: `st-cmq.8` (invoke handler registry; merged via PR #191)
- Related beads: `st-q6xl` (statifier_persistence charter), `st-m5c3` (Machine
  identity / serialization contract), `st-ewd7` (heartbeats charter)
- Related ADRs: `docs/adr/0003-pure-core-with-effects.md` (the warrant, names
  Oban at `:27-28`), `docs/adr/0029-session-interpret-stays-public.md`,
  `docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md`,
  `docs/adr/0035-send-id-is-a-machinestate-counter.md`,
  `docs/adr/0044-re-entry-effects-defer-to-the-outer-batch.md`,
  `docs/adr/0046-round-on-every-core-effect.md`,
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

### Phase 1

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

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` plus `mix gate.verify` plus `mix quality --profile merge` as
the phase gate. In interactive execution, pause here for the human to confirm
the manual review before Phase 2. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via `/wurk:commit
--auto`), and Manual Verification items are deferred and surfaced once at the
end instead of blocking here.

---
