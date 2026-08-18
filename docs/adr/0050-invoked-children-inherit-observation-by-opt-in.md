# ADR-0050: Invoked children inherit the parent's observers by opt-in

Status: accepted (2026-08-18) - builds on 0049 (single-session late-subscriber
catch-up) as accepted, and answers the question 0049 decision 5 delegated to
st-fd7n: whether `:record` joins the inherited set. It does not.

## Context

`Statifier.Session` holds its invocation table privately, and a child session
started for an `<invoke>` gets neither the parent's `:trace` setting nor the
parent's subscribers. A child's effects therefore reach only the child's own
subscribers, so an observer of the parent sees `Effect.Invoke`,
`Trace.InvokePass`, and later `done.invoke.<id>`, and nothing else about the
child: not its `Trace.EntrySet`, not its `Trace.ContentExecuted`, not its
`Trace.MacrostepStable`, nothing.

The per-session timing fact is empirical. `Session.start_link/2` runs
`Interpreter.initialize/2` to quiescence inside `init/1`, and the child is
started from inside the parent's own invoke pass - before `start_link/2`
returns a pid to anything outside the session. By the time any accessor can
name the child's pid, the child's initialize burst has already been generated
and delivered to whatever subscribers it had at start. A post-hoc attach
therefore never sees that burst *live*. It is no longer unrecoverable,
though: ADR-0049 added `subscribe(server, pid, catch_up: true)`, which
returns `{:ok, recording}` for a session started with `record: true` and
`{:error, :not_recorded}` - without adding the pid - for one that was not, so
a late subscriber to a *recording* session can re-derive the missed prefix
with `Statifier.Replay.run/1`.

What that mechanism does not do is compose into observation of an invoke
tree, for three reasons that hold independently of each other:

1. **The gate.** Catch-up recovers a prefix only from a session started with
   `record: true`. Children are started by the parent's invoke pass, not by
   the observer, so a child records only if something makes it - which is
   exactly the question ADR-0049 decision 5 delegated here, and decision 3
   below answers it "no".
2. **The discovery race, and the reaped child.** An invoked child is created
   and stopped by the parent's own effect processing: `start_child` on the
   invoke pass, `{:stop_child, invoke_id}` on cancellation or completion. An
   observer polling the accessor can miss a short-lived child entirely, and
   a child that has completed is a process that has exited - its ADR-0029
   recording was in-process state and died with it, so there is no server
   left for `subscribe/3` to be called on. Catch-up's window is per session
   and needs a live, nameable server; an invoke tree systematically destroys
   both preconditions.
3. **Shape and cost.** The motivating consumer (statifier-ui's ADR-0005) is
   built around one shared channel demultiplexed by the envelope's
   `session_id` - which is inheritance's own output shape - rather than N
   per-child attaches, each paying an O(run) `Replay.run/1` re-derivation.

ADR-0027 decision 3 is the table and monitor topology this builds on: the
invocations table already tracks `{session_id, pid, monitor_ref,
autoforward}` per invoke id, and children are already started as ordinary
monitored processes on the flat registry, not as children of the parent's
supervision tree. ADR-0012 and `docs/observability.md` constraint 6 name the
seam being widened here: before this record, observation happened at a single
session boundary.

## Decision

1. **The accessor is public and narrow.** `Statifier.Session.invocations/1`
   returns `[%{invoke_id, session_id, pid}]` sorted by `invoke_id`. Not
   `monitor_ref` - that is the parent's own handle on a process it owns, not
   a fact about the invocation. Not `autoforward` - that is an `<invoke>`
   attribute already visible on the `Effect.Invoke` the caller already
   received. Sorted, rather than "in no particular order", because the
   caller is a session-tree pane: a UI that re-renders in a different order
   on every poll because the underlying map iterated differently is a
   defect in that use, not a detail the accessor can leave unspecified.

2. **Inheritance is opt-in and defaults to off.** `:inherit_observers` on
   `start_link/2`, default `false`. A default-on inheritance would start
   sending a parent's existing subscribers a second session's stream on an
   upgrade, with no caller having asked for it - a behavior change hiding
   inside what looks like a routine dependency bump. Today's behavior (a
   child's stream stays private unless something explicitly subscribes to
   it) is preserved exactly for every caller that does not opt in.

3. **What is inherited is `:trace` and the subscriber set, and nothing
   else.** Not `:record`, which is the question ADR-0049 decision 5 left to
   this record. A child inheriting `record: true` *would* build a coherent
   per-session recording of its own - ADR-0029's contract is per session, so
   there is no incoherent-fold objection - but `:inherit_observers` is an
   observation knob and `:record` is ADR-0049's "this run is reconstructible"
   knob, and coupling them would impose O(inputs) retention on every node of
   an unbounded tree for every caller who only wanted live traces, turning
   ADR-0029's per-session opt-in into an unasked-for tax. Inheritance already
   delivers birth effects live, so the motivating case needs no recording at
   all. Not `:invoke_source` - ADR-0038 already settles who resolves invoke
   sources, and that question is independent of who is watching. Not
   `:max_macrostep_rounds` and not `:datamodel` - both are already governed
   elsewhere (round budget per ADR-0032, datamodel by 6.4.3), by
   considerations that have nothing to do with observation and every reason
   to be set per child on their own terms.

   Reopen trigger for the `:record` half: a consumer that needs per-child
   late or post-mortem catch-up *inside* a tree would motivate `:record`
   joining the inherited set, or a sibling flag beside it. That is an
   extension of this decision, not a reversal of it.

4. **Inheritance is transitive.** A child started with
   `inherit_observers: true` receives that same flag in its own start
   options, so one opt-in at the root of an invoke tree descends the whole
   tree, not just its immediate children. A depth-one design would leave a
   grandchild's initialize burst just as unobservable as before this
   record, for a caller who has no way to know in advance how deep a given
   document's invocations will nest.

5. **Inheritance is a snapshot at child start, not a live link.** The child
   gets the parent's subscriber pids as of the moment
   `{:start_child, _, _}` is performed. A subscriber added to or removed
   from the parent afterward, via `subscribe/2` or `unsubscribe/2`, does
   not propagate to any already-running child. Reaching an already-running
   child is decision 1's accessor (to name its pid) plus `subscribe/2` on
   the child directly - a live propagation channel between parent and child
   subscriber sets is not built here. That hatch is live-only by default:
   because decision 3 leaves children non-recording, `subscribe/3` with
   `catch_up: true` on one answers `{:error, :not_recorded}` and does not
   add the pid.

6. **The accessor and the option are not substitutes for each other, in
   either direction. Both ship.** The accessor path is not a substitute for
   the option even with ADR-0049's catch-up available, by the Context's three
   reasons: the gate (children do not record), the discovery race (a
   short-lived child is never listed), and the reaped child (a completed one
   has no server left to subscribe to). The option is not a substitute for
   the accessor either: a tree that started without the flag still needs some
   way to attach, decision 5's targeted subscribe needs a pid to aim at, and
   drawing the session tree at all needs the topology the accessor reports -
   the sui-t36.1 finding was precisely that a pane cannot otherwise find a
   child's pid or session id. Neither alone satisfies the bead.

## Consequences

- A subscriber of an inheriting parent now receives messages stamped with
  session ids it never itself subscribed to, and must demultiplex on the
  envelope's `session_id` to tell which session in the tree produced a
  given message. statifier-ui's own ADR-0005 already designs for exactly
  this: one channel shared across an invoke tree, demultiplexed by the
  session envelope field, with parent-child links carried in the
  `session.start` definition message.
- Those inherited effects carry interned indexes, so resolving them needs
  the *child's* identity tables. statifier-ui's ADR-0005 builds them at its
  own subscription boundary from the `%Machine{}` its bridge holds via
  `invoke_source`. That composition works today and is sui's half under
  ADR-0025 - named here so nobody later reads it as a gap on this side.
- `{:halted, _}` remains end-of-stream *per session id*, not for the
  mailbox as a whole - ADR-0044 decision 2 is unchanged, but a subscriber
  watching an inherited tree now reads it per stream: one child halting
  says nothing about its siblings or its parent.
- Nothing here forks ADR-0049's catch-up mechanism for children. That
  mechanism stays session-shape-agnostic, exactly as its decision 5 framed
  it; this record only decides that a child's recording gate stays shut by
  default, which is what makes catch-up unavailable inside a tree rather
  than merely unused.
- `mix adr.judge`'s ADR-0012 scope covers the files this decision touches,
  and `docs/observability.md` constraint 6 carries the invoke-tree sentence.
- Reopen trigger: a caller that genuinely needs live subscription
  propagation - a parent's later `subscribe/2` reaching already-running
  children - would supersede decision 5 rather than amend it, since a live
  link is a different mechanism from a start-time snapshot, not a
  relaxation of this one.
