# ADR-0050: Invoked children inherit the parent's observers by opt-in

Status: accepted (2026-08-18)

## Context

`Statifier.Session` holds its invocation table privately, and a child session
started for an `<invoke>` gets neither the parent's `:trace` setting nor the
parent's subscribers. A child's effects therefore reach only the child's own
subscribers, so an observer of the parent sees `Effect.Invoke`,
`Trace.InvokePass`, and later `done.invoke.<id>`, and nothing else about the
child: not its `Trace.EntrySet`, not its `Trace.ContentExecuted`, not its
`Trace.MacrostepStable`, nothing.

The deciding fact is empirical. `Session.start_link/2` runs
`Interpreter.initialize/2` to quiescence inside `init/1`
(`lib/statifier/session.ex:558`), and the child is started from inside the
parent's own invoke pass - before `start_link/2` returns a pid to anything
outside the session. By the time any accessor can name the child's pid, the
child's initialize burst has already been generated and delivered to
whatever subscribers it had at start. An attach performed after the pid is
knowable - subscribing through some future accessor - can never observe that
burst; there is no window in which a post-hoc attach is equivalent to having
been a subscriber at start.

ADR-0027 decision 3 is the table and monitor topology this builds on: the
invocations table already tracks `{session_id, pid, monitor_ref,
autoforward}` per invoke id, and children are already started as ordinary
monitored processes on the flat registry, not as children of the parent's
supervision tree. ADR-0012 and `docs/observability.md`
constraint 6 name the seam being widened here: today observation happens at
a single session boundary, and this record is the first to describe
observation across an invoke tree. ADR-0029 is why `:record` is not part of
what inherits - a session's replay contract is defined per session, and
handing a child its parent's recording state would blur which fold
`Statifier.Replay` re-drives.

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
   else.** Not `:record` - ADR-0029/ADR-0034's replay contract is defined
   per session, and a child born mid-recording with its parent's record
   state would have no coherent single fold to replay. Not `:invoke_source`
   - ADR-0038 already settles who resolves invoke sources, and that
   question is independent of who is watching. Not
   `:max_macrostep_rounds` and not `:datamodel` - both are already governed
   elsewhere (round budget per ADR-0032, datamodel by 6.4.3), by
   considerations that have nothing to do with observation and every
   reason to be set per child on their own terms.

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
   subscriber sets is not built here.

6. **The accessor and the option are not substitutes for each other. Both
   ship.** Point 5's escape hatch is not equivalent to inheritance, by the
   Context's empirical fact: an attach reached through the accessor is
   necessarily after the child has already initialized, so it can never see
   what inheritance sees. Shipping only the accessor would leave every
   invoke-tree observer blind to birth effects; shipping only the option
   would leave no way to attach to a tree that started without it. Neither
   alone satisfies the bead.

## Consequences

- A subscriber of an inheriting parent now receives messages stamped with
  session ids it never itself subscribed to, and must demultiplex on the
  envelope's `session_id` to tell which session in the tree produced a
  given message. statifier-ui's own ADR-0005 already designs for exactly
  this: one channel shared across an invoke tree, demultiplexed by the
  session envelope field, with parent-child links carried in the
  `session.start` definition message.
- `{:halted, _}` remains end-of-stream *per session id*, not for the
  mailbox as a whole - ADR-0044 decision 2 is unchanged, but a subscriber
  watching an inherited tree now reads it per stream: one child halting
  says nothing about its siblings or its parent.
- `mix adr.judge`'s ADR-0012 scope covers the files this decision touches,
  and `docs/observability.md` constraint 6 gains the invoke-tree sentence
  in Phase 3 of the implementing plan.
- Reopen trigger: a caller that genuinely needs live subscription
  propagation - a parent's later `subscribe/2` reaching already-running
  children - would supersede decision 5 rather than amend it, since a live
  link is a different mechanism from a start-time snapshot, not a
  relaxation of this one.
