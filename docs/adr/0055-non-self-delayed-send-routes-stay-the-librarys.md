# ADR-0055: Non-self delayed-send routes stay the library's

Status: accepted (2026-08-19) - decides the gap ADR-0054's Consequences
recorded ("Non-self-routed delayed sends are not durably schedulable
today"): the limit is standing for `#_parent`, `#_invokeid`, and
`#_internal`, and deferred with a named trigger for the external-session
route; no route field joins `%SendDelayed{}`

## Context

ADR-0054, as amended, scopes durable timers to a `<send delay="...">`
whose target is absent or parses to `:self`, and its Consequences record
the rest as "an open gap, recorded rather than solved." This record
answers the direction question that gap leaves open: should a
durable-timer host ever be able to schedule a delayed send whose target
is not the session itself, and if so, what carries the resolved route to
it?

Three facts from the code bound the answer, and the first one reframes
the question as ADR-0054 posed it.

**1. The resolved route is already visible to a host - the carrier
question is not the real limit.** ADR-0054 decision 2 says a host "can
see `target` as the author wrote it, but not the library's resolution of
it," because `plan_send_delayed/3`
(`lib/statifier/session/effects.ex:270-288`) hands the resolved route to
the opaque `{:schedule, ...}` instruction and never back onto the
`%SendDelayed{}` effect. That is true of the *plumbing*, but the
resolution itself is `Statifier.Send.Target.parse/1`
(`lib/statifier/send/target.ex`): a public, pure, deterministic function
of the target string alone. Its own moduledoc states the division: it
says "*what kind* of destination a target string names, never whether
that destination currently exists." Every `%SendDelayed{}` a host sees
has already passed the core's static target/type checks (ADR-0047
decision 4: "a core-produced `<send>` effect never reaches here with an
invalid target"), so `Target.parse(send.target)` computed by the host is
byte-for-byte the route the planner put on `{:schedule, ...}`. Nothing
needs to carry the route to the host; the host can compute it.

**2. What a host genuinely cannot do is build the event or deliver it.**
The delivered event is constructed session-side: `delivered_event/2`
(`lib/statifier/session/effects.ex:392-399`) stamps `origin` (the
*sending* session's `_ioprocessors` location), `origintype`, and a
`sendid` gated on `id_from_author?`; `#_internal` uses a different
carrier entirely, `internal_event/1` (`effects.ex:414-427`), whose
delivery re-raises through `Statifier.Interpreter.deliver_internal/5`
with a `Cause` rebuilt from the machine's counters at delivery time
(ADR-0039 decision 2). The construction cannot move onto the core effect:
`origin` needs the plan context's `session_id`, which the pure core does
not hold - the ADR-0003/ADR-0027 division puts it session-side on
purpose. And delivery has no public door: `deliver_fired/4`
(`lib/statifier/session.ex:1829-1833`) special-cases `:self`; every other
route goes through the private `deliver/5`, which resolves `:parent` off
`state.invoked_by` - a `{parent_pid, invoke_id}` tuple
(`lib/statifier/session.ex:1781-1790`) - `{:invoke, id}` off
`state.invocations`, the parent-held live-invocation table
(`:1806-1815`), and `{:session, sid}` off the registry (`:1755-1768`).

**3. The miss path is owed to the sender, and only the library can pay
it.** A delayed send's route is resolved at fire time - ADR-0048
decision 6 exempts delayed sends from the plan-time reachability check
outright, and names "a delayed send's route miss at timer-fire time" as
`communication_error/4`'s continuing caseload
(`lib/statifier/session.ex:1870-1874`, `:1887-1896`). C.1, quoted from
the local spec cache:

> If the sending SCXML session specifies a session that does not exist
> or is inaccessible, the SCXML Processor MUST place the error
> error.communication on the internal event queue of the sending
> session.

`communication_error/4` reaches the sender's internal queue through the
private `deliver_internal/6`; no public equivalent exists. Worse, for a
timer that fired hours later precisely because it outlived a node, the
*sending session* may itself be gone - the MUST has no queue to land on,
a situation the in-process design never faces because `terminate/2`
cancels the timers first (spec 6.2's discard, ADR-0054 decision 4).

**Why the routes are not all the same kind of limited.** C.1 defines the
parent and invoke routes relative to a live invocation relationship,
quoted from the local cache:

> If the target is the special term '#_parent', the Processor MUST add
> the event to the external event queue of the SCXML session that
> invoked the sending session, if there is one.

> If the target is the special term '#_invokeid', where invokeid is the
> invokeid of an SCXML session that the sending session has created by
> `<invoke>`, the Processor MUST add the event to the external queue of
> that session.

Both resolve against the sending session's own process bookkeeping - the
`invoked_by` pid tuple and the invocations table - which has no external
name a store could hold and which exists only while the invocation tree
is live. Spec 6.4 adds an obligation only that live bookkeeping can
honor, quoted from the local cache:

> Once it cancels the invoked session, the Processor MUST ignore any
> events it receives from that session. In particular it MUST NOT not
> insert them into the external event queue of the invoking session.

A host redelivering a stored `#_parent` event hours later cannot know
whether the invocation it rode in on has since been cancelled; the
parent's inbox-side discard (ADR-0027 decision 3) is keyed by live
invokeid state. `#_internal` is the same class for a different reason:
the internal queue is a position inside the sending session's own
macrostep processing, and its delivery carrier is rebuilt at delivery
time inside the interpreter - there is nothing to deliver *to* except a
live, drivable sender. These three routes are limited by what they
*mean*, not by missing plumbing.

The external-session route is different in kind. `{:session, sid}`
resolves through `Registry.lookup(Statifier.Registry, sid)` and delivers
by `send_event/2` (`lib/statifier/session.ex:1759-1768`) - both doors
ADR-0054 decision 4 already points hosts at for the liveness check. And
session ids are caller-suppliable (`MachineState.new/2`'s `:session_id`
option, `lib/statifier/machine_state.ex:465`, default a generated `sess_`
UXID), so an embedder *can* hold stable, restart-surviving target ids.
What is missing for this route is exactly items 2 and 3 above: the built
event and the miss path. That is plumbing, not semantics.

## Decision

**1. The limit is standing - permanent, not provisional - for
`#_parent`, `#_invokeid`, and `#_internal`.** These routes name the
sending session's live process bookkeeping (`invoked_by`,
`state.invocations`, the internal queue's position in a drivable run),
which a durable timer by definition outlives. No serialization contract,
public door, or effect enrichment changes that: a store cannot hold a
reference to a pid tuple that no longer exists, and 6.4's
cancelled-invocation ignore is enforceable only by the live parent.
Durable timers are a self-routed-send feature with, at most, a future
external-session extension (decision 3). A document that wants a
durable delayed send to reach its parent or an invoked child should be
restructured to send to itself and react - the self-routed event can
drive an immediate (non-delayed) `<send target="#_parent">` in a
transition, executed by a live session with its bookkeeping in hand.

**2. No resolved-route field joins `%SendDelayed{}`.** The carrier
question this record was asked - "what carries the resolved route to the
host" - dissolves on Context fact 1: `Statifier.Send.Target.parse/1`
already carries it, publicly and deterministically, and every effect a
host sees has passed the core's static checks, so the host's own
`parse/1` call reproduces the planner's route exactly. A duplicate field
on the effect could only ever agree with the function or rot away from
it, and its presence would invite exactly the non-self scheduling
decision 1 forbids. What a future opening actually has to carry is the
delivered *event* (origin/origintype/sendid stamped for the sender), and
that cannot ride the core effect at all - `origin` needs `session_id`,
which lives in the session's plan context by the ADR-0003/ADR-0027
division. `docs/durable-timers.md`'s existing guidance stands: a host
checks `target: nil` and schedules only that.

**3. No public delivery door opens now; the external-session route is
deferred with a named trigger, not foreclosed.** It is the one route
whose limit is plumbing rather than semantics (Context's last paragraph),
but opening it today is mechanism with no caller - the same standing rule
ADR-0027 applied to multiple named runtimes. st-rsyx's charter scopes
`statifier_oban` to self-routed sends, and no embedder has asked for
durable cross-session delivery. The trigger is the first consumer that
needs a durable delayed send between sessions with host-stable ids. The
record that fires on it owes three things this record names so they are
not rediscovered:

- **The event carrier.** A public way to obtain the delivered event as
  the library would have built it - most plausibly a session-side door
  ("build/deliver the fired send for this sender") rather than a field
  on the core effect, per decision 2.
- **The miss semantics when the sender is gone.** C.1's
  `error.communication` MUST names the sending session's internal queue;
  a durably fired miss may find no sender to place it on. Whether the
  host dead-letters it, drops it, or the door itself absorbs the C.1
  obligation is that record's central question (see Consequences, open
  question).
- **The identity story.** Host-stable `:session_id`s make the target
  nameable today, but whether the *sender's* identity (for `origin` and
  the ADR-0054 decision 3 session scope) survives a restart is st-m5c3's
  territory; that record should land on top of, or explicitly ahead of,
  st-m5c3's serialization contract.

Until that trigger fires, ADR-0054 decision 2's host rule is unchanged:
for any non-nil target, leave the timer to the library.

## Consequences

- ADR-0054's recorded gap is decided rather than standing: permanent for
  three routes on semantic grounds, deferred with a trigger for
  `{:session, sid}`. ADR-0054's status line gains a pointer to this
  record, and its Consequences bullet cross-references it; its decisions
  are otherwise untouched - this record narrows nothing 0054 states and
  widens nothing.
- `docs/durable-timers.md`'s pointer at the gap ("see Open Question 1 in
  ADR-0054's Consequences", which named a bullet 0054 does not number)
  now cites this record instead.
- Nothing in `lib/` or `test/` changes. `%SendDelayed{}` keeps its
  ADR-0046 shape; `Target.parse/1`, `deliver/5`, `deliver_fired/4`, and
  the ADR-0048 residual miss path all stand as they are. No conformance
  result moves.
- The decision-1 restructuring advice (self-route the delay, then send
  onward from a transition) is a documentation-level pattern; if
  `statifier_oban`'s docs teach it, they cite this record.
- What would reopen this record: decision 3's trigger (a consumer
  needing durable cross-session delivery); st-m5c3 landing an identity
  contract that makes a stored sender resolvable after restart, which
  removes decision 3's third prerequisite; or an embedder-registrable
  Event I/O Processor set (ADR-0048's own trigger), which would re-pose
  routing per-processor and could carry its own delivery doors.
- Open question, recorded rather than decided: when a durably fired
  non-self send misses *and* the sending session is gone, C.1's
  `error.communication` has no internal queue to land on - the spec's
  model assumes a live sender that the durable design deliberately does
  not. Whether that becomes a host-side dead letter, a silent discard
  mirroring 6.2's termination rule, or a library-absorbed obligation
  belongs to the record that opens the door, and nothing today consumes
  the answer.
