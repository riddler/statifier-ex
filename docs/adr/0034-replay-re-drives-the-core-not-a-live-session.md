# ADR-0034: Replay re-drives the core, not a live session

Status: accepted (2026-08-15)

## Context

`docs/observability.md` constraint 6 promises that a session is reproducible
from its recorded inputs. ADR-0029 fixed what a sound recording must contain
- (machine, initial data, external event log, `interpret/2` batches) - and
named the recorder st-dtm's work, deliberately leaving open how replay
consumes that recording. Nothing records and nothing replays yet; constraint
6 has been a constraint on code shape with no consumer.

Building the replayer surfaces a seam the recorder alone does not: timers are
wall-clock, and a session that scheduled a `:send_delayed` armed a real timer
with `Process.send_after/3`. A recording holds two things about that timer -
the `{:interpret, effects}` entry that scheduled it and the later
`{:timer, send_id, event}` entry recording its firing. Feeding that same
recording into a live `Statifier.Session` re-plans the `:send_delayed` effect
to a `{:schedule, ...}` instruction, which arms a second, real timer. That
second timer eventually fires too, delivering the event a second time: once
from the timer the replay run itself armed, once from the firing already
sitting in the recording waiting to be re-injected. A live session cannot be
the target of replay without solving that double delivery, and nothing in
the codebase today resolves it.

A second, smaller question sits beside the first: whether the recording
should read a clock at all. `Statifier.Session` is the only place in the
library that touches wall-clock time (`Process.send_after/3`,
`Process.cancel_timer/1`, `make_ref/0`, `Process.monitor/1`), and the
`Mix.Statifier.AdrGuard` allowlists exactly that one file for the
process-shaped calls that make it necessary (ADR-0018's neighbor concern -
keeping that vocabulary out of comments - is separate from keeping the calls
themselves off the pure core). A recorder that stores a real timestamp would
be the library's first clock read outside that one allowlisted file, and it
would be storing a value replay has no use for: the bead's acceptance
criterion is reproducing firing *order* and *relative* timing, not re-waiting
the original delays.

## Decision

**1. Replay re-drives the pure core and `Session.Effects.plan/1` directly,
with no process and no timer. It is not a live `Statifier.Session`, and the
session gains no replay mode.**

`Statifier.Replay` is a pure fold over a recording's entries. It reuses every
deciding component a live session uses - `Interpreter.initialize/2`,
`Interpreter.handle_event/2`, `Interpreter.cancel/1`,
`Session.Effects.plan/1`, and `Session.Inbox` - unchanged. What it does not
reuse is the three instruction clauses that touch a process:
`{:schedule, ...}` (which calls `Process.send_after/3`) and
`{:notify, ...}` / `{:unroutable, ...}` (which deliver to subscribers).
Replay records those effects into its own return value instead of performing
them.

The rationale has three parts:

- **It dissolves the double-delivery seam instead of patching it.** The seam
  exists only because arming a timer is a wall-clock act with its own,
  independent firing. A replayer that never arms one receives each recorded
  firing exactly once, at its recorded position, which is exactly what "do
  not re-wait the delays" requires.
- **The part replay replaces is exactly the part that is nondeterministic.**
  `Statifier.Session` already documents itself as split between deciding what
  to do (the pure core) and performing it (the one process-shaped module),
  and ADR-0003 is the warrant for that split existing at all. Replay is that
  split read literally: it keeps everything above the line and replaces only
  what sits below it.
- **The alternatives cost more.** A replay mode built into the session - a
  flag that suppresses `{:schedule, ...}` when set - puts a permanent
  test-shaped branch into the one module the ADR guard allowlists for
  process-shaped code, and it is still replacing the performing half, only
  less honestly, and inside production code rather than a dedicated replay
  module. Cancelling each re-armed timer immediately after injecting it is a
  race by construction (a short delay can fire before the cancel lands), and
  it would additionally plan a `{:cancel, ...}` instruction the original run
  never had, corrupting the very effect stream the round-trip test compares.

The honest cost of this choice is drift: `Statifier.Replay`'s instruction
handling could diverge from `Statifier.Session`'s over time, since the two
now live in different modules with no shared code enforcing agreement. Two
things keep that drift visible rather than silent. First, the round-trip
test compares a live run against a replayed one directly, so any divergence
in how the two handle an instruction reddens the gate on its own. Second,
`Statifier.Replay`'s fold matches on `Session.Effects.instruction()` with no
catch-all clause, so a new instruction kind is a `FunctionClauseError` at the
first test that produces one, not a silently skipped case.

Replay also gains a check a live session has no way to make: a recorded
timer firing whose `send_id` was never scheduled, from replay's own point of
view, means the recording is inconsistent with the machine it is being
replayed against. Replay returns
`{:error, {:unscheduled_timer_firing, send_id}}` in that case rather than
proceeding, turning what would otherwise be a silent divergence into a loud
one.

That check has to tolerate one case a live session can produce honestly, or
it would reject correct recordings. `Process.cancel_timer/1` returns `false`
when the delay has already elapsed and the delayed-send message is already
sitting in the mailbox: the cancel does not unsend it, and the session
enqueues it unconditionally when it arrives. So a recording can legitimately
hold a firing entry for a `send_id` *after* the effect that cancelled that
same id - the cancel and the fire raced, and the fire won. Replay mirrors
that outcome instead of rejecting it: cancelling a timer moves its pending
count from a `pending` map into a second `raced` map rather than deleting it,
and a firing draws credit from `pending` first and from `raced` second,
delivered normally either way. Only a firing with credit in neither map is
the inconsistency the error is for. This is the one place replay has to
model a mechanic of `Process.cancel_timer/1` itself, rather than a mechanic
of the pure core.

**2. The recording carries ordinal order only. It does not read a clock.**

Each entry's position in the recording's list is the entire ordering
information, and it is sufficient: the bead requires reproducing firing
*order*, and it explicitly rules out re-waiting the original delays, so a
wall-clock reading would record a value replay is obligated to ignore.
Relative timing is not lost by leaving it out, either - it stays derivable,
because every delayed firing's originating `delay_ms` is already present in
the recording, carried on the `:send_delayed` effect inside the
`interpret/2` batch that scheduled it (and, once the document-side producer
lands, on the core-derived batch that will replace it). A reader who wants
to know how long a firing was scheduled to wait reads that field; nothing
about the recording's own shape needs to answer the question.

## Consequences

- `docs/observability.md` constraint 6's Replay bullet is amended: "with
  session timestamps" is replaced by language describing ordinal, serialized
  input order, and this record is cited beside ADR-0029.
- `Statifier.Replay` is public API, proven by a round-trip test that records
  a live run, replays it, and asserts the replayed effect stream and
  terminal snapshot match the original - once for a run that used
  `interpret/2` and once for one that did not.
- `MapSet.to_list/1` feeds entry ordering in the interpreter's exit-set and
  selection code and is not an explicit document-order sort. Two runs
  compared within one test process agree, because iteration order is a
  function of set contents on one BEAM build, but a recording replayed on a
  different OTP release could in principle order those entries differently.
  This is a pre-existing property of the interpreter that this work did not
  introduce and does not fix; it is named here as an accepted risk so a
  future reader finds it stated rather than rediscovers it.
- The `Process.cancel_timer/1` cancel/fire race is the one live-runtime
  mechanic replay has to model rather than reuse from the core, via the
  `raced` credit map described above. Every other instruction replay handles
  is either reused byte for byte from the deciding half or a direct
  recording of what the performing half would otherwise have done.
- What would reopen this record: a replay requirement that genuinely needs
  the performing half exercised - for example, a timer bug reproducible only
  through a real `Process.send_after/3` call, where re-driving the pure core
  cannot surface the failure. That would be argued here, as a new decision,
  rather than patched into `Statifier.Replay` piecemeal.
