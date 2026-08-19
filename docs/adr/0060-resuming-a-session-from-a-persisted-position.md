# ADR-0060: Resuming a session from a persisted position

Status: accepted (2026-08-19) - consumes ADR-0052's identity and position
codec without amending any of its decisions; amends ADR-0057 in part
(decision 4's format-version door, walked through for `Recording`) and
ADR-0049 in part (the catch-up invariant now holds over an anchored
recording as well as an unanchored one); the first identity refusal in the
session API

## Context

`Statifier.Position.to_binary/1` / `from_binary/2` are a complete,
format-versioned, identity-checked position contract (ADR-0052), and
`Statifier.MachineState` is already closure-free and structurally trusted by
every advance entry (`handle_event/2`, `deliver_internal/5`, `microstep/1`,
`macrostep/1`) - the pure core has no state outside the threaded struct. Yet
nothing in the library feeds a decoded position into a `Statifier.Session`:
`Session.start_link/2` has eleven options, none of them a position, and
`init/1` unconditionally calls `Interpreter.initialize(machine, machine_opts)`
(`lib/statifier/session.ex`, `init/1`, as it stood before this record). The only sanctioned recovery path today is
replay via `Statifier.Session.Recording` - O(history) per resume, and it
requires persisting the whole compiled `%Machine{}` inside the recording
blob. Production embedders that persist long-running charts across deploys
and crashes need O(1) recovery from a saved position instead.

`docs/research/260819-st-5yhl-resume-from-persisted-machine-state.md`
established the current state and left seven open questions; the
implementation plan
(`docs/plans/260819-st-5yhl-resume-a-session-from-a-persisted-position.md`)
answered each against the code, and this record is where those answers
become a decision rather than an assertion, ahead of any code citing them.

Three structural facts about the neighboring records bound every answer
here:

- **`%State{}.session_id == machine_state.datamodel["_sessionid"]` is a load-
  bearing invariant**, read independently by ADR-0048 route stamping,
  `Statifier.Session.Telemetry`, and `Recording.new/2`'s `opts[:session_id]`
  contract.
- **`Recording` embeds the whole `%Machine{}` and replays from a single
  anchor**, `Interpreter.initialize(Recording.machine(r), Recording.opts(r))`
  (`Statifier.Replay.run/1`, as it stood before this record; ADR-0034,
  ADR-0057). ADR-0057 decision 4
  already named its envelope shape a format-version decision for any future
  widening.
- **Timer handles, invocation pids, and monitor refs are process-owned and
  none of them serialize.** `delay_ms` on `%Effect.SendDelayed{}` is relative
  with no stored deadline (ADR-0034 decision on no clock, carried into
  ADR-0054); invocation pids and monitor refs live only in
  `Session.Invocations` (`lib/statifier/session/invocations.ex:70-76`), never
  in `%MachineState{}`.

## Decision

**1. `Session.start_link/2` gains one `:resume` option accepting a position
blob or a `%MachineState{}`; the `%Machine{}` stays positional.** The blob
form calls `Position.from_binary(blob, machine)` and inherits the full
ADR-0052 identity gate for free. The struct form exists for the migration
path `Position.import/2` already offers - a `%MachineState{}` deliberately
unchecked against a specific chart, because crossing a revision on purpose is
what migration story B (`docs/persistence.md`) means - and is checked instead
against the *positional* `%Machine{}` via decision 2 below, so one identity
rule governs both forms rather than two. The option is named `:resume`, not
`:machine_state`, because it accepts either shape and `machine_state:` would
misdescribe the blob form. No `Statifier.resume/2` facade function is added:
the pure-core rehydration composition is two calls
(`Position.from_binary/2` plus any advance entry), and a wrapper around that
is surface for a composition, not a capability.

**2. Resume requires an identified chart on both sides and refuses
`identity: nil` - the first identity refusal in the session API.** The blob
form refuses via `Position.from_binary/2` already; the struct form is made to
refuse identically, checking that `machine_state.machine` is identified and
that `Machine.Identity.matches?/2` holds against the positional `%Machine{}`.
Every other persistence codec in this library already refuses an unidentified
chart (ADR-0052 decisions 3-4, ADR-0057 decision 3); the session API has had
no reason to before, because `Session.start_link/2` never previously touched
a persisted artifact. Accepted consequence: a `%Machine{}` produced by
`Statifier.Compiler.compile/1` directly, or resolved at invoke time via
`:invoke_source` (ADR-0038), is not resumable. That is correct rather than a
gap - an `:invoke_source` child is started by the library and never resumed
by a host, and a host that wants a resumable chart uses `Statifier.compile/2`
(ADR-0052's identified path) from the start.

**3. A resumed session keeps the position's `_sessionid` by default;
`:session_id` may override it, and doing so rewrites both sides.** The
resumed `%State{}.session_id` and `datamodel["_sessionid"]` stay equal - the
existing invariant, not a new one - by reusing the persisted id unless the
caller supplies `:session_id`, in which case the position's
`datamodel["_sessionid"]` is rewritten to agree before the session comes up.
Reusing the id rather than minting a fresh one is deliberate: id continuity
across a resume is what keeps `#_scxml_<sessionid>` addressing and any
external reference to the session working across a deploy or crash, which is
the entire point of resuming instead of restarting. `Statifier.Registry`
already tolerates a stale prior registration - `register_session/1` rescues
and ignores every registration failure, leaving the session merely
unregistered rather than crashing (`register_session/1` in
`lib/statifier/session.ex`) - so
re-registering an id whose previous holder is dead costs nothing new.
ADR-0027 decision 4's "a restart generates a fresh `sess_` id" governs
restarts, not resumes, and is not amended by this.

**4. Resume refuses a non-quiescent position and a terminated position.** A
position with a non-empty internal event queue
(`MachineState.internal_queue_empty?/1` false) is refused with
`{:error, {:resume, :position_not_quiescent}}`: booting mid-macrostep would
produce effects with no input boundary behind them, and ADR-0048 requires a
route snapshot taken *at* an input boundary for every drive - there is none
to take here. `Position.export/1` already refuses a non-quiescent position
for the same underlying reason; `:resume` is deliberately no more lenient
than the codec it drives, even though it could technically drain the queue
before notifying anyone. A position with `running: false` (`status: :done`)
is refused with `{:error, {:resume, :position_not_running}}`: booting a
`GenServer` that is already terminated, will notify nobody, and starts with
`halted: nil` is the surprising outcome, not the useful one - a host that
wants to inspect a finished position uses `Position.from_binary/2` and
`Statifier.active_leaf_states/1` directly, no session required. Both refusals
make `:resume` stricter than `Position.from_binary/2`, which decodes either
position without complaint; the driver enforces a session-boot precondition
the codec has no reason to.

**5. `active_invocations` is carried forward verbatim on resume; the process
table starts empty; re-establishing live children is the host's, via the
invoke handler registry (st-cmq.8).** Clearing `active_invocations` on resume
would change what the position means and break the `invoke_id` stability
`docs/extending.md:152-160` already promises across a persist/reload cycle,
and would leave it disagreeing with `states_to_invoke` and `configuration` -
worse than the alternative. The alternative is safe today because
`{:stop_child, invoke_id}` already treats an unknown id as a silent no-op
(`Invocations.pop/2` returning `{nil, invocations}`,
`lib/statifier/session/invocations.ex`, popped by the `{:stop_child, _}`
clause of `perform_instruction/3` in `lib/statifier/session.ex`): a `<cancel>` or an exit sweep over a
not-yet-re-established invocation stops nothing and crashes nothing rather
than raising. Actually re-establishing the pids behind those ids - starting
or reattaching invoked children - is out of scope here; it is ADR-0051's
handler-registry mechanism, exercised by the host per st-cmq.8, and this
record only makes the divergence between recorded intent
(`active_invocations`) and live process state (`Session.Invocations`, empty
at boot) an explicit, documented one instead of a silent one.

**6. A recording made by a resumed session is anchored at the resumed
position: `Recording` gains an `anchor` field holding a position blob, and
`Replay.run/1` gains a start-here branch that decodes it via
`Position.from_binary/2` before folding.** Without this, a recording begun on
a resumed session would still replay from
`Interpreter.initialize(Recording.machine(r), Recording.opts(r))` - the
chart's initial configuration, not the position the session actually started
from - which breaks ADR-0049's catch-up invariant for exactly the sessions
this feature exists to serve, rather than merely producing a longer prefix.
Anchoring instead of refusing `record: true` on a resumed session is required
because the bead's acceptance criteria demand the two compose; anchoring with
a position blob rather than a `%MachineState{}` or a `%Machine{}` is chosen
because a blob is what `Recording.to_binary/1` already knows how to carry (no
compiled term written a second time, consistent with ADR-0057 decision 3) and
because it gets the identity check for free by calling
`Position.from_binary(anchor, Recording.machine(recording))` on decode -
`Replay.run/1` needs no second verification mechanism. `Recording` had no
prior notion of a starting point other than the chart's initial
configuration, so this is additive: an unanchored recording is unaffected,
and `anchor: nil` (or its absence) means "start at
`Interpreter.initialize/2`," exactly as today. With the anchor in place,
ADR-0049's invariant holds *literally* rather than approximately for a
resumed session: a resumed session emits no initialization effects at all
(decisions 1 and 4 skip `initialize/2` entirely), so its notified prefix is
exactly what anchored replay reproduces from the same starting position.

**7. Timers, invoked children, and the external inbox are not restored by
resume, each for a reason already on record elsewhere - this decision names
them together rather than leaving the gap to be rediscovered per-artifact.**

- *Delayed-send timers.* No scheduling deadline is ever stored: `delay_ms` on
  `%Effect.SendDelayed{}` is relative, and no wall-clock instant is written
  anywhere a position could carry (ADR-0034's no-clock decision, carried
  forward by ADR-0054/0055/0059's durable-timer design, which assigns
  scheduling durability to the host rather than the library). A resumed
  session starts with `Session.Timers.new()` and an empty `timer_refs` map;
  re-arming timers for the position's remaining in-flight sends is the
  durable host's job, driven off the same `SendDelayed`/`Cancel` effect
  vocabulary ADR-0054 already publishes.
- *Invoked children.* Pids, monitor refs, and child session ids are
  process-local and were never part of `%MachineState{}` to begin with; they
  cannot be recovered from a position because they were never in one.
  Decision 5 carries `active_invocations` (the record of *what* was invoked)
  forward; re-establishing the *processes* behind those ids is ADR-0051's
  handler-registry mechanism (st-cmq.8), not this record's.
- *The external inbox.* `Session.Inbox` lives outside `%MachineState{}` for
  the mechanical reason ADR-0002's core/session split already gives
  (`lib/statifier/machine_state.ex:21-31`): anything queued but not yet
  dequeued at persist time is lost with the process that held it, the same
  as it would be for any other unpersisted mailbox. This record changes
  nothing about that boundary; it only states plainly that a resume does not
  reach past it.

Not draining a non-quiescent position on boot (decision 4) and not adding a
`Statifier.resume/2` facade (decision 1) are the two considered-and-rejected
alternatives on this ground; both are recorded above rather than left as
silent omissions.

## Consequences

- `Recording.format_version` goes `1 -> 2`. A recording written before this
  change decodes under version 1 exactly as before (`anchor: nil`, replay
  starts at `Interpreter.initialize/2`); a recording made by a resumed
  session is only ever written under version 2. This is the exact mechanism
  ADR-0057 decision 4 named in advance for a future widening of the
  envelope, and ADR-0052 decision 2's precedent (a bump at one call site) is
  reused rather than re-argued.
- A `%Machine{}` resolved via `:invoke_source` (ADR-0038) or built directly
  via `Statifier.Compiler.compile/1` becomes non-resumable by this record
  (decision 2): `Session.start_link/2` with `resume:` against either refuses
  with an identity error rather than booting a silently-wrong session. A host
  that wants a resumable chart compiles it through `Statifier.compile/2`
  from the start.
- The `:resume` driver is deliberately stricter than
  `Position.from_binary/2`: the codec decodes any well-formed, identity-
  matching position, quiescent or not, running or done; `:resume` additionally
  refuses a non-quiescent or a terminated one (decision 4). A caller that
  wants to inspect either uses the codec directly, not a session.
- `Session.start_link/2` gains a new error shape,
  `{:error, {:resume, reason}}`, alongside its existing option-validation
  errors, for `reason` in `:position_not_quiescent` and
  `:position_not_running`, plus whatever `Position.from_binary/2` or
  `Machine.Identity.matches?/2` itself returns for an identity mismatch.
- `active_invocations` and the live `Session.Invocations` table can disagree
  for the lifetime of a resumed session until the host re-establishes each
  child (decision 5) - an accepted, documented divergence rather than a
  defect, made safe by `{:stop_child, _}`'s existing no-op-on-unknown-id
  behavior.
- Implementation is sized separately on this bead's remaining phases (this
  record changes no code): `MachineState.put_invoke_types/2`, the documented
  pure-core rehydration path in `Statifier.Interpreter`'s moduledoc, the
  `Recording.anchor` field and `Replay.run/1`'s anchored branch, the
  `Session.start_link/2` `:resume` option and its `init/1` branch, and
  `docs/persistence.md`'s host-facing "Resuming a session" narrative
  (including the non-restoration list from decision 7).
- What would reopen this record: a durable-timer host gaining a way to
  recover an absolute deadline (would revisit decision 7's timer half, and is
  ADR-0034/0054's territory to reopen first); `Session.Invocations` gaining
  any serializable representation of a live child (would revisit decision 5,
  and is ADR-0051's territory); or a demonstrated need to resume from a
  non-quiescent position (would revisit decision 4's refusal, weighed against
  the same route-snapshot argument ADR-0048 already made).

## Related

- ADR-0052 (chart identity, the position codec and its format-version
  precedent this record's blob form inherits)
- ADR-0057 (`Recording`'s envelope shape and its named format-version door,
  walked through by decision 6)
- ADR-0049 (the catch-up invariant this record extends to anchored replay)
- ADR-0034 (replay re-drives the core from recorded inputs; the no-clock
  decision decision 7's timer half depends on)
- ADR-0054 / ADR-0055 / ADR-0059 (the durable-timer effect vocabulary the
  host uses to re-arm what decision 7 does not restore)
- ADR-0051 (the invoke handler registry the host uses to re-establish
  children behind decision 5's carried-forward `active_invocations`)
- ADR-0048 (the route-snapshot input-boundary requirement behind decision
  4's non-quiescent refusal)
- ADR-0027 (session runtime and registry; decision 3's id-reuse contrasted
  against decision 4's restart-mints-a-fresh-id)
- ADR-0002 (the core/session split behind decision 7's external-inbox
  boundary)
- ADR-0038 (`:invoke_source` resolution; the non-resumable case named in
  decision 2)
