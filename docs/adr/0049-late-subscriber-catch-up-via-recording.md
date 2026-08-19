# ADR-0049: Late subscribers catch up by replaying the recording

Status: accepted (2026-08-18) - amends nothing; builds on 0029, 0034,
0044, and 0046 as accepted. `docs/observability.md`'s non-goals stand
unedited (decision 4) - the catch-up invariant extended by ADR-0060
(2026-08-19: for a resumed session, the invariant holds over a recording
anchored at the resumed position rather than at
`Interpreter.initialize/2`)

## Context

`Statifier.Session.start_link/2` runs `Statifier.Interpreter.initialize/2`
to quiescence before the process is reachable: `init/1` performs the
initialize call inline and the resulting effects ride a
`{:continue, {:initialize, ...}}` term performed before any message can
reach the process, so a pid added by `subscribe/2` the instant
`start_link/2` returns is still strictly after the whole initialize batch
was notified - there is no window
(`docs/research/260818-st-uqo4-late-subscriber-trace-and-session-header.md`).
Only the `:subscribers` start option sees that burst, and the option is not
always available: a Livebook cell is routinely evaluated after the session
exists, and a LiveView pane reconnects. Nothing in the repo retains an
emitted effect - `notify/2` is an unconditional `send/2` per subscriber
with no copy kept, and the only effect-shaped fields on `%State{}`
(`deferred`, `done_effect`) are a within-`perform/3` work queue and a
single halted-projection value, not a history. That is half (a) of
st-uqo4.

Half (b) asked for a self-describing opening effect naming the session and
the document. Two facts have moved since the bead was filed. First,
st-1xwh landed `Statifier.Effect.DatamodelInit`: the stream now opens with
`{:datamodel_init, _}` - unconditionally, once per `initialize/2`, at
`round: 0`, ahead of the global-script and entry effects at
`Interpreter.initialize/2`'s own return-site concatenation - and its
`datamodel` carries `_sessionid` and `_name`, written by
`SystemVariables.initial/2` before any effect is emitted. Second, the
mirrored bead sui-t36.1 is closed: statifier-ui's ADR-0005 builds its own
`session.start` definition message at its subscription boundary from the
`%Machine{}` it holds, and records that st-uqo4 is not a precondition for
it (re-read and noted on the bead, 2026-08-18).

Four settled decisions bound the shape of any answer:

- **ADR-0046** rejected a session-side stamp on effect structs because
  ADR-0034's `Statifier.Replay` re-derives effects from the core with no
  session behind it, "breaking the stream equality the round-trip suite
  asserts" - literally `result.stream == stream` at
  `test/statifier/replay_round_trip_test.exs:109`. Anything the session
  mints and notifies as an effect faces the same objection. The core
  cannot mint a `sess_` id (ADR-0008), though it holds one in
  `datamodel["_sessionid"]`.
- **ADR-0029 / ADR-0034** already built the one artifact that reproduces
  an emitted stream: a `record: true` session's
  `Statifier.Session.Recording`, replayed by `Statifier.Replay.run/1` as a
  pure fold whose `result().stream` is the subscriber messages with the
  envelope stripped, and whose `status` is `:running` for a recording that
  has not halted - `run/1` does not require a finished run.
- **ADR-0044 decision 1** makes monotone `(macrostep, round)` arrival the
  subscriber-stream contract, matching replay's order; anything delivered
  to a late subscriber must not break it.
- **`docs/observability.md` non-goals** decline "trace persistence/
  rotation" - a sentence whose reading decides whether the session may
  retain a buffer at all (decision 4).

## Decision

**1. A late subscriber catches up by replaying the recording, not from a
retained buffer: `subscribe/3` atomically snapshots the recording and adds
the pid, and the caller re-derives the missed prefix with
`Statifier.Replay.run/1`.** The public shape:

- `Statifier.Session.subscribe(server, pid)` is unchanged: adds the pid,
  returns `:ok`, delivers from now on.
- `Statifier.Session.subscribe(server, pid, catch_up: true)` returns
  `{:ok, recording}` - the session's current
  `Statifier.Session.Recording.t()`, snapshotted in the same
  `handle_call` that adds the pid - or `{:error, :not_recorded}` for a
  session not started with `record: true`, in which case the pid is *not*
  added and the caller falls back to plain `subscribe/2` if live-only is
  acceptable. `catch_up: false` is the default.
- The missed messages are `Statifier.Replay.run(recording)`'s
  `result.stream`, computed by the caller, never inside the session. Its
  elements are exactly the un-enveloped subscriber shapes
  (`{:effect, _} | {:unroutable, _} | {:halted, _}`), so `prefix ++
  mailbox suffix` is one uniform stream.

The property that makes this exact rather than approximate is an
invariant this record names and the implementing branch must assert:
**between GenServer callbacks, `Replay.run/1` over the session's current
recording produces exactly the messages the session has notified so far.**
It holds because each callback is atomic in the effects' terms: the
callback records its input and notifies every resulting effect - including
ADR-0044's deferred re-entry batches, drained before the callback returns,
which is why `deferred` is documented always-`[]` between callbacks - so a
`subscribe` call, serialized between callbacks, observes a recording whose
replay is precisely the notified prefix, and everything the new pid
subsequently receives is precisely the suffix. No overlap, no gap, no
dedup key needed, and ADR-0044's monotone-arrival contract holds across
the seam: the prefix is replay's own order and the suffix continues it.
This extends the round-trip equality the suite already asserts at
end-of-run to every quiescent point; it is a strengthening the existing
machinery already satisfies, not new behavior.

Four alternatives are rejected:

- **An unbounded retained buffer of notified messages** on `%State{}`
  answers the acceptance criterion directly but grows O(effects) for the
  life of the session, duplicates the recording's information in a second
  O(run) structure, and is the exact artifact decision 4 reads the
  non-goal as declining.
- **A bounded buffer** trades that for a worse contract: a consumer
  cannot know whether it got everything, which turns "obtain the effects
  it missed" into "obtain some suffix of them" with no marker saying
  which.
- **Retaining only the initialize burst** (bounded by construction,
  serves the motivating case without `record: true`) creates a second,
  partial mechanism with a seam at macrostep 1: a subscriber attaching
  later cannot compose "initial burst + live from now" into anything
  complete, and the repo would carry two catch-up stories where one
  honest one suffices.
- **Session-side backfill** (the session sends the replayed prefix to the
  new pid itself) either blocks the session for an O(run) core
  re-derivation inside `handle_call`, or delegates the sending to another
  process and loses ordering - the BEAM guarantees message order per
  sender pair, so a helper's backfill and the session's live sends would
  interleave arbitrarily, breaking ADR-0044 decision 1 for exactly the
  subscriber this feature exists for. Returning the recording as a value
  keeps the session's cost at one map put plus one struct reference and
  makes the prefix/suffix split race-free by construction.

**2. `record: true` is the gate, deliberately.** A session not recording
has nothing to re-derive from, and this record adds no second retention
mechanism to compensate; `{:error, :not_recorded}` is the honest answer.
The gate is acceptable because the motivating scenarios control start
*options* even when no subscriber pid exists yet: the Livebook user starts
the session in one cell and subscribes from another; the LiveView
application starts the session and its panes reconnect later. What they
lack at start time is a pid, not a keyword. And `record: true` is already
the repo's "this run is reconstructible" knob (ADR-0029) - late-join
catch-up is precisely a reconstruction want, so gating it there reuses an
existing meaning instead of minting a `retain:`/`buffer:` sibling with
overlapping semantics. The memory bill is the recording's own,
O(inputs) - already accepted by ADR-0029 - and the compute bill is
`Replay.run/1`'s O(run) per catch-up, paid by the caller that wants it.
A subscriber that only needs the current picture, not the history, keeps
using `snapshot/1` and `status/1` with a plain `subscribe/2`; nothing here
replaces them.

A halted session composes for free: the recording is complete, replay
yields the full stream ending `{:halted, reason}`, the live suffix is
empty, and `Replay.run/1`'s `status` says so - post-mortem attachment is
the same call as late attachment.

**3. No header effect and no new envelope shape; half (b) is declined,
not deferred.** This settles the effect-versus-envelope question by
choosing neither, on four grounds:

- A session-minted header effect fails on ADR-0046's replay ground
  exactly as the rejected `round` stamp did: replay has no session behind
  it, so the effect would exist live and not replayed, and
  `result.stream == stream` - now load-bearing for decision 1's catch-up
  exactness, not just for the test suite - would be false for every run.
  A core-emitted header would replay (the recorded opts carry
  `:session_id`, and the core already holds it in
  `datamodel["_sessionid"]`), so coexistence is *possible* - but the
  effect would either restate values `{:datamodel_init, _}` already opens
  the stream with, or carry machine facts that
  `docs/observability.md` constraint 3 keeps off payloads by design, the
  same grounds on which st-1xwh's decision 6 kept `binding` and declared
  ids off `DatamodelInit`.
- The stream already opens as self-describingly as constraint 3 permits:
  `{:datamodel_init, _}` first, unconditionally, `round: 0`, its
  `datamodel` carrying `_sessionid` and `_name`; and every message's
  envelope is `{:statifier, session_id, message}`, so a mid-stream joiner
  learns the session id from its first message - which is how
  statifier-ui's subscriber actually does it.
- "The document being traced" has no identity to name: `%Machine{}`
  carries no source path, filename, or text - `name` is the whole of it,
  and it is already in the datamodel as `_name`. Inventing a document
  identity is a separate feature with no consumer behind it.
- The consumer that wanted the header built its own: statifier-ui
  ADR-0005's `session.start` definition message is produced at its
  subscription boundary from the `%Machine{}` it holds, and sui-t36.1
  closed recording that st-uqo4 is not a precondition. A wire-format
  header for consumers holding no `%Machine{}` is this repo's stated
  "no wire format" non-goal and, per ADR-0025, statifier-ui's half of the
  mirror.

An envelope sibling (`{:hello, _}` beside `{:effect, _}` / `{:halted, _}`)
would dodge the replay objection but inherits grounds two through four
whole: it would carry nothing a consumer cannot already get sooner.

**4. The non-goal is read, stated, and left unedited: "no trace
persistence/rotation story" declines retained effect logs, and
re-derivation is not retention.** The sentence's subject is the fate of
emitted trace effects - whether this repo stores them, bounds them,
rotates them. An unbounded in-session buffer would be that story's first
installment (and would eventually demand the rotation policy the sentence
declines), so decision 1's rejection of buffers is this reading enforced.
The ADR-0029 recording is not in tension with it: the recording stores
*inputs*, a different artifact with its own accepted cost, and catch-up
derives effects from it transiently, on the caller's dime, retaining
nothing. The non-goals list therefore needs no amendment - which is the
test this record applies to itself: a design that had required editing the
non-goal would have been evidence for the other reading.

**5. Ownership split with st-fd7n: this record owns single-session
catch-up; st-fd7n owns option inheritance down the invoke tree.**
st-fd7n's deciding fact - "a post-hoc attach can never observe a child's
initialize burst" - is narrowed by this record: a post-hoc attach *can*
obtain any session's initialize burst, child included, provided that
session records. What remains genuinely st-fd7n's is whether and how a
child inherits the parent's start options (`:trace`, `:subscribers`), and
- consequential from this record, flagged here as input rather than
decided across the boundary - whether `:record` joins that inheritance
set, since a non-recording child is exactly the session decision 2's gate
leaves unanswerable. Neither bead skips the child case: st-uqo4 makes the
mechanism session-shape-agnostic; st-fd7n decides which children have the
gate open.

**6. Documentation edits this record directs**, on the implementing
branch: `docs/observability.md` constraint 6 gains a sentence naming the
catch-up recipe and the between-callbacks invariant (the non-goals list is
untouched, decision 4); `Statifier.Session`'s moduledoc subscriber-stream
section documents `subscribe/3`, the `{:error, :not_recorded}` contract,
and the prefix-then-mailbox consumption pattern;
`Statifier.Replay.run/1`'s doc gains the mid-run use case it already
supports.

## Consequences

- Implementation, sized separately (this record changes no code): the
  `subscribe/3` head and its `handle_call` clause in
  `lib/statifier/session.ex` (snapshot + add, or error without adding);
  no change to `notify/2`, `%State{}`'s fields,
  `lib/statifier/effect.ex`'s vocabulary or `trace?/1`,
  `lib/statifier/session/effects.ex`'s planner,
  `lib/statifier/session/telemetry.ex` (catch-up emits no events, and
  replay fires none, ADR-0040), `lib/statifier/session/recording.ex`, or
  `lib/statifier/replay.ex`.
- Tests the implementing plan owes, each with its sabotage line per
  `docs/testing.md`: a late `subscribe/3` whose replayed prefix plus
  drained live suffix equals a from-start subscriber's full stream (the
  acceptance test for half (a)); a mid-run round-trip asserting the
  between-callbacks invariant of decision 1 directly; the
  `{:error, :not_recorded}` path leaving the pid unsubscribed; and a
  post-halt attach recovering the complete stream.
- The bead's acceptance criterion needs amending, which is the claiming
  session's call to record, not this document's edit: the first clause
  ("can obtain the effects emitted before it attached") is met under
  `record: true` via `subscribe/3` + `Replay.run/1`; the second clause
  ("the stream opens with an effect naming the session id and the
  document being traced") is superseded by decision 3 - the stream
  already opens with `{:datamodel_init, _}` carrying `_sessionid` and
  `_name`, and no further header effect is added.
- Because `result.stream == stream` is now load-bearing for a public
  feature rather than only for the test suite, any future change that
  would break live/replay stream equality inherits a second veto from
  this record on top of ADR-0046's.
- Open questions recorded rather than decided: whether a convenience
  wrapper (one call returning the derived prefix instead of the
  recording) is worth its API surface - deferred until a consumer asks,
  since the two-line recipe serves Elixir callers; and whether `:record`
  inherits down the invoke tree, which is st-fd7n's per decision 5.
- What would reopen this record: a demonstrated consumer for whom
  `record: true` is genuinely unavailable at start time (not merely
  unset), which would force the bounded-retention argument to be re-had;
  a measured workload where per-catch-up `Replay.run/1` cost is material
  (the re-argument would weigh incremental replay checkpoints, not
  buffers); or a change to ADR-0029's recording shape or ADR-0034's pure
  fold, whose records own those moves.
