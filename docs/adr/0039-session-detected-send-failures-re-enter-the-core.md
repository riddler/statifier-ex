# ADR-0039: Session-detected send failures re-enter the core

Status: accepted (2026-08-15) - amended in part by ADR-0047 (2026-08-17:
the rejected "move target routing into the core" alternative is scoped to
liveness; static target/type classification runs in the core)

## Context

Spec 6.2.4 and C.1 both put `<send>`'s two runtime failures - an unreachable
or nonexistent target, and an unsupported `type` - on the *internal* event
queue of the *sending* session, not the receiving one:

> If the SCXML session specified in the target field is unable to accept an
> event, e.g. due to erroneous configuration information such as an
> unreachable or otherwise invalid target URI, the Processor MUST place the
> error error.communication on the internal event queue of the sending
> session.

> If a Processor implementing the SCXML Event I/O Processor receives a
> `<send>` element with a `type` attribute value that it does not support
> ... the Processor MUST place the error error.execution on the internal
> event queue of the sending session.

Under ADR-0003 the interpreter's core is pure and produces `Effect.Send` for
the caller to perform; under ADR-0027 the caller that performs it, and the
one place that can see whether a `#_scxml_<sessionid>` target resolves, is
`Statifier.Session` - it holds the registry lookup, and only it knows what a
`type` this deployment does not support means. Both failures are therefore
discovered *after* the core has already handed the effect off, in
`Session`'s process, not the core's.

`Session` has no path back into the queue it needs to write to. Its only
inputs into a running `%MachineState{}` are `Statifier.Interpreter.handle_event/2`
and `Statifier.Interpreter.cancel/1` (`lib/statifier/interpreter.ex:430-453`
and its neighbor), and `handle_event/2` hardcodes `from: :external` in its
dequeue trace and treats its argument as an `Statifier.Event.t()` bound for
the *external* queue - there is no argument that says "this is already an
internal event, skip the external queue and go straight to the round." The
existing internal-queue writers, `MachineState.raise_internal/4` and
`MachineState.raise_platform/4` (`lib/statifier/machine_state.ex:587-636`),
are pure functions on `%MachineState{}` with no caller outside the core
itself - `<raise>`'s executable content and `done.state.*` generation. Appendix
D has no equivalent split to begin with: its `mainEventLoop` never returns,
so a failure discovered while sending is just another loop iteration, not a
boundary a host process has to cross back over.

## Decision

**One new pure entry point, `Statifier.Interpreter.deliver_internal/5`,
taking `(machine_state, kind, name, origin, opts)` with `kind :: :internal |
:platform`, is the sole path `Statifier.Session` uses to write a
session-detected failure onto `%MachineState{}`'s internal queue.** It
delegates to `MachineState.raise_internal/4` or `raise_platform/4` by `kind` -
the same two functions the core's own executable content already uses, so no
third writer is introduced - and then runs `main_event_loop/1` to quiescence,
returning exactly `handle_event/2`'s own shape: `{:ok, machine_state,
effects} | {:error, :not_running}`. `Session` never touches
`%MachineState{}`'s queues directly; every write to the machine, whether the
event originated outside the session or was discovered by the session itself,
crosses this or `handle_event/2`.

Two alternatives were considered and rejected:

- **`Session` calls `MachineState.raise_platform/4` (or `raise_internal/4`)
  itself and re-drives `main_event_loop/1` inline.** This works today, but it
  puts the queue write outside any core entry point: the two raise functions
  become reachable from two different kinds of caller with no shared
  chokepoint between them, so a future invariant this project wants to attach
  to "something was enqueued" (a trace effect, a recording hook, a counter
  assertion) has nowhere to attach without touching every call site
  separately. Naming the seam as one function is cheaper now than
  discovering the missing chokepoint later.
- **Move target routing into the core**, so the core itself decides whether a
  target resolves and raises the failure inline during `handle_event/2`.
  This is foreclosed outright: ADR-0003's pure core knows nothing about which
  sessions are live, and ADR-0027 places the registry - the only source of
  truth for "does this session id resolve" - on the embedder side of the
  session boundary. Teaching the core to consult it would make the core
  aware of live sessions, which both records already forbid.

## Consequences

- `deliver_internal/5` is a recordable session-side input under ADR-0029:
  `Statifier.Session.Recording` gains an entry for it, and
  `docs/observability.md` constraint 6's four-input replay tuple accounts for
  it the same way it already accounts for `interpret/2` batches - a call the
  recorder must capture at its position in the session's serialized input
  order, not something replay can re-derive from the external event log
  alone, because the failure that triggers it happened in `Session`, not in
  the core.
- The same seam is the delivery path for `<send target="#_internal">`, not
  only for the two spec-6.2.4 failures: anything the session needs to place
  directly on the internal queue - self-targeted send included - goes through
  `deliver_internal/5` with `kind: :internal`, and `done.state.*`-shaped
  platform deliveries go through it with `kind: :platform`. `:internal` and
  `:platform` share one seam rather than each growing its own.
- The deviation from Appendix D is mechanical, not semantic, per ADR-0002:
  Appendix D's loop never exits mid-send, so nothing in the pseudocode
  dictates a re-entry shape, and `deliver_internal/5`'s definition site gets
  an inline comment citing this record so the "diff against the pseudocode"
  habit still finds an explanation instead of a gap.
- Whoever implements the target router (this bead, later phases) writes it
  as the thing that decides *whether* to call `deliver_internal/5` and with
  which `name`/`opts`; this record settles only that the write-back, once a
  failure is decided, has exactly one door.
