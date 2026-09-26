# ADR-0074: Delayed sends across a persisted resume: the host records the fire time, a cancel commits with the step's position, and the host drops a stale fire

Status: proposed (2026-09-26) - decides three points that ADR-0060
decision 7, ADR-0054 and ADR-0069's 2026-09-23 Note leave to the durable
host without stating them; amends none of their decisions; changes no
function, struct, effect field or position field; the one `lib/` change is
a pointer in `Statifier.Send.Processor`'s moduledoc

## Context

A session resumed from a persisted position does not restore its
delayed-send timers. ADR-0060 decision 7 makes re-arming them the durable
host's job, driven off the `%Statifier.Effect.SendDelayed{}` and
`%Statifier.Effect.Cancel{}` effects ADR-0054 publishes. ADR-0069's
2026-09-23 Note adds that routing a `<cancel>` for a registered-type send
handed out before the save is the host's too, and
`Statifier.Send.Processor`'s moduledoc states the same rule. A host doing
that job has to answer three questions none of those records answers:

1. **Where the fire time lives.** `%Statifier.Effect.SendDelayed{}`
   carries `delay_ms`, a relative `non_neg_integer()`, and no absolute
   instant (`Statifier.Effect.SendDelayed`'s struct and type). The
   library has no clock in the core (ADR-0034), and `%MachineState{}`
   carries no pending-send table: its struct has `send_counter` and
   `timer_counter` and no field naming an armed send
   (`Statifier.MachineState`'s `defstruct`). The live session's timer
   table is session state (`Statifier.Session`'s `timers` field) and a
   resumed session starts it empty (ADR-0060 decision 7). A host that
   re-arms from the effect at resume, as `now + delay_ms`, fires up to one
   full delay late.
2. **Which transaction a cancel joins.** Nothing says whether the host's
   removal of a cancelled send must commit together with the persisted
   position of the step that ran the `<cancel>`, or may land before or
   after it.
3. **Who drops a stale fire.** A fire can race a cancel, or arrive after
   the session has left the state that armed it. Nothing says whether the
   engine drops such a fire or the host checks before delivering.

The SCXML specification (read from the local cache,
`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`)
says, in 6.2: "If the SCXML session terminates before the delay interval
has elapsed, the SCXML Processor MUST discard the message without
attempting to deliver it." In 6.3: "The Processor SHOULD make its best
attempt to cancel all delayed events with the specified id. Note, however,
that it can not be guaranteed to succeed, for example if the event has
already been delivered by the time the <cancel> tag executes." It says
nothing about a save and a resume, and nothing ties a pending delayed send
to the state whose content sent it.

Every `lib/` cite in this record was read at `eb114947`.

## Decision

**1. The absolute fire time lives in the host's timer store, computed by
the host once, when it is first handed the send.** When a host (or a
registered processor, ADR-0069 decision 4) is handed a
`%Statifier.Effect.SendDelayed{}`, it reads its own clock and stores
`due_at = now + delay_ms` on the row it writes for that send, beside the
dedup key's components (ADR-0054 decision 3, with ADR-0059's `ordinal`).
Re-arming after a resume reads `due_at` from that row and never recomputes
it from `delay_ms`. A row whose `due_at` has already passed when the host
re-arms fires at once: late, never dropped for lateness, because 6.2 names
termination, not lateness, as the reason to discard.

The library still computes and stores no instant. ADR-0060 decision 7's
statement that no deadline is written "anywhere a position could carry"
stands: the deadline lives in the host's store, never in
`Statifier.Position`'s blob, and `delay_ms` stays the only timing field on
the effect. A host that reads `delay_ms` again at resume time has no
correct answer to compute; the row it wrote at hand-off is the only place
the instant can be recovered from.

**2. A host's timer-store writes for a step commit in the same transaction
as the persisted position that step produced; a cancel is one of them.**
The removal of every row under ADR-0054 decision 3's cancellation key,
`{session scope, send_id}`, for a `%Statifier.Effect.Cancel{}` commits in
the transaction that saves the position after the step whose effects
carried that cancel. The insert of a `%Statifier.Effect.SendDelayed{}`
row, with its `due_at` from decision 1, commits in the same transaction
for the same reason. The rule holds whether the cancel reaches the host
off the effect stream or through `c:Statifier.Send.Processor.cancel/2`.

Both orders apart from one transaction lose something:

- *Position first, cancel after.* A crash between the two leaves a saved
  position past the `<cancel>` with the send's row still pending. A resume
  from that position does not run the `<cancel>` again: a resumed session
  starts at the saved, quiescent position and emits no initialization
  effects (ADR-0060 decisions 4 and 6), so nothing re-emits the cancel and
  the cancelled send fires.
- *Cancel first, position after.* A crash between the two leaves the row
  removed while the saved position is the one before the step. If the step
  is re-driven, the re-emitted cancel matches nothing, which is a no-op
  (ADR-0054 decision 3); if it is not, the position waits on a send that
  can no longer fire.

A host whose timer store and position store cannot share a transaction
does not meet this decision, and says so to its own users; the library
cannot close the gap for it, because it sees neither store.

**3. The host drops a stale fire, on the cancellation key; the engine does
not.** Before the host delivers a fired send, it checks, in this order:

1. **The send's own row is still pending, and the fire claims it
   atomically.** The row is found by its dedup key, whose first two
   components are the cancellation key `{session scope, send_id}`. The
   claim moves the row out of the pending set in one write, so a cancel
   that committed first (decision 2) has already removed it and the fire
   is dropped, and a cancel that commits after the claim matches nothing
   and loses the race, which is the loss 6.3 allows. The session scope is
   `_sessionid`, which a resumed session keeps by default (ADR-0060
   decision 3), so the key is the same on both sides of a resume.
2. **The execution is live.** ADR-0054 decision 4's two-step check,
   unchanged: terminated or halted, the message is discarded without
   delivery (6.2).

The host does **not** check the session's current configuration. A
delayed send is not scoped to the state whose content sent it: 6.2 and 6.3
make `<cancel>` and termination the only ways to stop one, so a fire that
arrives after the session left the arming state is delivered. A chart that
wants the send scoped to a state writes the `<cancel>` in that state's
`<onexit>`, and decision 2 makes that cancel durable.

The engine cannot make this check, for three reasons read at `eb114947`:

- The persisted position carries no set of armed sends to check a fire
  against (`Statifier.MachineState`'s `defstruct`); the live session's
  tables, `timers` and `held_sends`, are session state and start empty on
  resume (ADR-0060 decision 7, ADR-0069's 2026-09-23 Note).
- A fired self-routed send re-enters as an ordinary event through
  `Statifier.Session.send_event/2` (ADR-0054 decision 2), and the built
  event names its send only when the author wrote the id:
  `Statifier.Send.Event.build/3` sets `sendid` from `id_from_author?`
  (C.1's empty-`sendid` rule), and `%Statifier.Event{}` carries no
  `ordinal`. The engine cannot tell a fire from any other event, or one
  send from another.
- Giving the engine that view would add a pending-send field to the
  position and a fire door carrying the key: new public surface. This
  record rejects it; the host already holds the row the check needs.

No engine test pins a drop, because the engine drops nothing. What the
host checks is the list above.

## Consequences

- A host that re-arms from `delay_ms` at resume is nonconformant with
  decision 1, and one that commits a cancel outside the step's position
  transaction is nonconformant with decision 2. Both were unstated before
  this record.
- `Statifier.Send.Processor`'s moduledoc points at this record from its
  `cancel/2` section; a registered processor that owns a delayed send
  owns all three decisions for it.
- Nothing else in `lib/` moves. No effect, position or recording field is
  added, and no conformance result moves.
- The host-side code these decisions call for lives in the durable host
  packages, not here: storing `due_at` at hand-off, committing timer rows
  with the step's position, and the atomic claim at fire time. Whether a
  given package already does each is that package's to verify.
- What would reopen this record: the position gaining a pending-send
  table or the effect gaining an absolute instant (reopens decisions 1 and
  3, and is ADR-0034's and ADR-0060's territory first); a fired send
  gaining a public door that carries its dedup key (reopens decision 3's
  engine half).

## Related

- ADR-0060 (decision 7: timers are not restored by resume; decision 3:
  the kept `_sessionid`; decisions 4 and 6: a resumed session starts at a
  quiescent position and emits no initialization effects)
- ADR-0054 (decision 3: the cancellation key and the dedup key; decision
  4: the fire-time liveness check this record's decision 3 keeps)
- ADR-0059 (the `ordinal` the dedup key carries)
- ADR-0069 (decision 4 and its 2026-09-23 Note: registered-type delayed
  sends and the cancel a resumed session no longer routes)
- ADR-0034 (no clock in the core)
