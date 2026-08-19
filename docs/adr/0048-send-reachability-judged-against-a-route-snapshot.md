# ADR-0048: Send reachability is judged in the core against a route snapshot

Status: accepted (2026-08-18) - amends 0039 in part (the liveness
foreclosure narrows: the core still never consults the registry and never
holds a process reference, but it may judge reachability against a
caller-declared, point-in-time route snapshot); discharges ADR-0047
decision 6's deferral. ADR-0027 is not amended - the registry seam does not
move. 0051 adopts this record's snapshot-as-value shape for a second
consumer, `Statifier.Invoke.Types`, at a per-session rather than per-drive
cadence.

## Context

ADR-0047 fixed the static half of st-yizi and deferred the liveness half to
this record with a five-bullet agenda: the shape (research shape C, a
route-resolution snapshot passed into the core, versus shape D, a resolver
capability in ADR-0030/0038's pattern, with shape E, suspending the
macrostep, disfavored as a steer); how the answer records and replays under
ADR-0029's four-input tuple and ADR-0034; where ADR-0027's self-addressing
carve-out relocates; staleness; and whether `error.communication` aborts
the block (st-yizi research open question 3).

The failing test is test496
(`test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs`):
`<send ... target="#_scxml_foo"/>` followed by `<raise event="foo"/>` in
one `<onentry>` block. `#_scxml_foo` parses cleanly to `{:session, "foo"}` -
`Statifier.Send.Target.parse/1` deliberately answers nothing about
liveness - and only the registry lookup in `Statifier.Session.deliver/5`
(`lib/statifier/session.ex`) can say it names nothing live. C.1, quoted
from the local spec cache:

> If the target is the special term '#_scxml_sessionid', where sessionid is
> the id of an SCXML session that is accessible to the Processor, the
> Processor MUST add the event to the external queue of that session. The
> set of SCXML sessions that are accessible to a given SCXML Processor is
> platform-dependent.

> If the sending SCXML session specifies a session that does not exist or
> is inaccessible, the SCXML Processor MUST place the error
> error.communication on the internal event queue of the sending session.

The ordering is unrecoverable post-hoc: `Statifier.Interpreter.handle_event/2`
folds `main_event_loop/1` to quiescence before returning
(`lib/statifier/interpreter.ex:436-457`), so by the time
`Statifier.Session.Effects.plan_send/3` plans the effect and `deliver/5`
discovers the miss, the sibling `<raise>`'s `foo` has been dequeued,
matched by `<transition event="*">`, and the machine is in `fail`. No
instruction re-ordering and no ADR-0044 change recovers it - the research
(`docs/research/260817-st-yizi-send-target-validity-block-abort-and-order.md`)
establishes this as finding 4. The answer must exist while the core is
still inside the block, which is the ground ADR-0039's rejected
alternative forecloses and this record amends.

Three constraints bound the shape:

- **ADR-0003 / ADR-0027**: the core is pure and the registry - the only
  source of truth for "does this session id resolve" - lives on the
  embedder side. Whatever the core judges against must be a value it was
  handed, never a lookup it performs.
- **ADR-0029 / ADR-0034**: a recording must reproduce the run by
  re-driving the pure core. Whatever answers reachability must be
  capturable in the recording and re-suppliable by `Statifier.Replay`'s
  pure fold.
- **ADR-0012 constraint 1**: the microstep boundary is a resumable value -
  everything the fold reads lives on `%MachineState{}`, and any
  machine_state value is a complete, inspectable, resumable position.

## Decision

**1. Shape C wins: the session declares a route snapshot, a plain value,
and the core judges reachability against it inside
`Statifier.Machine.Content.Send.execute/2`, beside ADR-0047's static
check.** The snapshot is a struct in the neutral namespace ADR-0047
decision 3 established - working name `Statifier.Send.Routes` - carrying
exactly what `Statifier.Session.deliver/5` resolves today: the set of
reachable session ids (the registry's keys plus the declaring session's
own id), whether a parent exists (`invoked_by` is set), and the set of
live invoke ids (the invocations table's keys). `:self` and `:internal`
routes need no entry; they are reachable by construction. The check covers
every route the snapshot can answer - `{:session, sid}`, `:parent`, and
`{:invoke, invokeid}` - one rule, not a test496-shaped special case.

Shape D - a resolver function in the shape of ADR-0030's `In()` provider
and ADR-0038's `invoke_source` - loses on three grounds:

- **The precedents do not actually cover it.** ADR-0030's provider reads
  `context.host`, data the core itself supplied - it is pure. ADR-0038's
  resolver runs session-side, after the core has returned control -
  "an ordinary call rather than a coroutine", in that record's own words.
  Neither accepted record runs impure code inside a core drive; shape D
  would be the first, and its purity would be by convention ("the caller
  promised the function is safe") rather than by construction. Shape C
  keeps ADR-0003's property structural: a value cannot perform a lookup.
- **Replay cost.** A resolver consulted mid-fold is a fifth input whose
  answers must be captured call by call and re-stubbed in order -
  st-yizi research open question 5. A snapshot is one recordable value
  per drive (decision 3 below), and `Statifier.Replay` stays the pure
  fold ADR-0034 built, unchanged in kind.
- **The freshness advantage is illusory.** A resolver answers at check
  time, not at dispatch time; the target can still die between the core's
  check and the session's actual delivery. Both shapes are point-in-time
  truth with a time-of-check/time-of-use window - shape D only narrows
  the window, at the full price above, and decision 5 has to exist either
  way.

Shape E - suspend `handle_event/2` at the `<send>` and let the session
resume it - is rejected, confirming ADR-0047's steer as a decision: its
suspension point is mid-block, inside `Statifier.Interpreter.Content`'s
fold, not the microstep boundary ADR-0012 constraint 1 makes resumable. A
suspended-at-`<send>` position is not a `%MachineState{}` value today, and
reifying block-fold position onto the struct is the largest change of the
three with no precedent and no second consumer.

**2. The snapshot rides on `%MachineState{}`, stamped by the caller before
every core drive; `nil` means "no determination".** ADR-0012 constraint 1
is the reason it is a struct field and not a threaded parameter: the block
fold reads it, so a paused microstep's resumable position must contain it,
and `microstep/1` stays the unit of progress with no second argument. The
session stamps a fresh snapshot immediately before each drive -
`initialize`, each `handle_event/2`, and each
`Interpreter.deliver_internal/5` re-entry - so an ADR-0044 mid-macrostep
re-entry gets current truth, not the macrostep-opening read. The exact
stamping API (a `MachineState.put_routes/2`, or an opt on the entry
points) is implementation detail; the contract is: stamped per drive, part
of the struct, `nil` when the driver declares nothing.

ADR-0030's grounds against storing a context do not carry over, and the
distinction is worth stating since that record is the nearest "no fields
on MachineState" precedent. Its ground 2 (staleness as a silent
exhaustiveness obligation) does not apply: the snapshot has exactly one
write site - drive entry - and no obligation to track anything between
writes, because point-in-time is its definition, not its failure mode. Its
ground 3 (duplicating state the struct already holds) does not apply
either: no other `%MachineState{}` field holds session liveness.
(`active_invocations` is the algorithm's view of which invocations are
active, not whether their processes are alive - the snapshot's invoke set
is the session's live table, deliberately a different fact.)

With a `nil` snapshot the core makes no reachability determination and
behavior is exactly today's: the effect is emitted and the boundary
detects the miss. That keeps the sync corpus path, bare
`Interpreter` drivers, and ADR-0029's public `interpret/2` seam working
unchanged, and it is why decision 6's residual path must stay.

**3. Recording and replay: the snapshot is an attribute of each recorded
drive, not a fifth input.** ADR-0029's four-input tuple - (machine,
initial data, external event log, `interpret/2` batches) - is unchanged in
kind: no new entry type crosses the session's serialized input path. Each
recorded entry that triggers a core drive (an external event, an internal
delivery per ADR-0039's recording obligation, and the session-start
initialization) widens to carry the snapshot stamped for that drive, the
same way the entry already carries the event itself. `Statifier.Replay`
re-drives the core passing each entry's recorded snapshot and stays a pure
fold; ADR-0034 is untouched. `docs/observability.md` constraint 6 gains
one sentence naming the widened entry shape, on the implementing branch.
ADR-0029's body needs no amendment - the recording's *entries* get richer;
the set of recorded input kinds does not grow.

**4. ADR-0027's self-addressing carve-out does not relocate; it gains a
mirror.** The registry seam does not move: the core never consults
`Statifier.Registry`, the session still owns lookup, delivery, monitors,
and the invocations table, so ADR-0027 is not amended. The carve-out - a
session is accessible to itself whether or not it is registered - is
honored in snapshot construction: the session always includes its own
`session_id` in the snapshot's session set, so the core finds
self-addressed sends reachable with no registry involved, and
`deliver/5`'s existing self-clause still performs the actual enqueue. Same
rule, now applied at two layers by the same owner (the session builds
both).

**5. Staleness is accepted and its failure mode is named: a stale
"reachable" degrades to today's behavior, never to a lost error.** The
snapshot is truth at drive start. A target session dying mid-drive makes
the core's "reachable" wrong; the session then fails the actual dispatch
and the existing ADR-0039 path raises `error.communication` through
`deliver_internal/5` - late, post-hoc, exactly the pre-this-record
ordering, which is the spec-conformant asynchronous-discovery case
(decision 6). A session *appearing* mid-drive that the snapshot missed
produces a spurious `error.communication`; C.1's "the set of SCXML
sessions that are accessible to a given SCXML Processor is
platform-dependent" sanctions both windows - the registry read the session
performs today is point-in-time truth with the same property, just a
narrower window. No retry, no double-check, no second read mid-drive.

**6. Core-detected unreachability aborts the block; session-detected
dispatch failure never does. st-yizi research open question 3 is decided,
not deferred, and the answer is split by detection window.** 4.9, quoted
from the local cache:

> The SCXML processor MUST execute the elements of a block in document
> order. If the processing of an element causes an error to be raised, the
> processor MUST NOT process the remaining elements of the block. (The
> execution of other blocks of executable content is not affected.)

Under shape C the reachability answer is produced *while processing the
element* - the `<send>` node itself raises the error, synchronously,
inside its own `execute/2` - so 4.9's text covers it and the block aborts.
Mechanically this is ADR-0047's channel with a second error name: the send
id is minted and `idlocation` written first (5.10.1, test332's guard),
then the composite `{:error, context, reason}` form halts
`Statifier.Interpreter.Content`'s fold, and the conversion site raises
`error.communication` (6.2.4's "unable to dispatch" arm, known in advance)
instead of `error.execution`, carrying the minted `sendid`. The conversion
site widening - the fatal channel learning to carry an event name as well
as a sendid - is the same ADR-governed widening ADR-0047 decision 1
performed, extended by one field; the concrete encoding stays
implementation detail.

The residual session-detected failures - a stale snapshot (decision 5), a
`nil`-snapshot drive, an `interpret/2`-injected effect, and a delayed
send's route miss at timer-fire time - do not abort anything: the block
completed long before the discovery, 4.9's window has closed, and there is
no block to abort. That is the asynchronous reading the research
identified, adopted here for exactly the cases that are genuinely
asynchronous. Note test496 itself does not force the abort half: with the
error enqueued at the `<send>`'s position it passes whether or not the
`<raise>` runs. The abort is decided on 4.9's text, not on the test.

Delayed sends get no plan-time reachability check at all: 6.2.3 governs
*argument* evaluation at element-evaluation time, and reachability is not
an argument - the route is resolved when the timer fires, as
`plan_send_delayed/3` already documents, and a fire-time miss is the
residual path above.

**7. ADR-0039 is amended in part, a second scoping in the same direction
as ADR-0047's; ADR-0047's own placement stands.** The foreclosure is
restated as: the core never *consults* the registry, never holds a pid or
a monitor, and never observes live processes - but it may judge
reachability against a caller-declared snapshot value, because reading a
value the caller vouched for at drive start makes the core aware of a
*claim about* live sessions, not of live sessions. What ADR-0039 settled
survives whole: `deliver_internal/5` remains the single write-back door
for every failure the session detects, and decision 5's residual path is
its continuing caseload, not a vestige. ADR-0047's static check stays in
`execute/2`, and this record adds the reachability check beside it rather
than moving anything - the supersession trigger ADR-0047 named ("wants the
static check somewhere other than `execute/2`") does not fire.

## Consequences

- st-72dn implements: the `Statifier.Send.Routes` struct, the
  `%MachineState{}` field and per-drive stamping, the reachability arm in
  `lib/statifier/machine/content/send.ex` beside ADR-0047's check, the
  event-name-carrying widening of the fatal conversion in
  `lib/statifier/interpreter/content.ex`, snapshot construction in
  `lib/statifier/session.ex` before each drive, the recording-entry and
  replay widening (decision 3), and tests - test496 goes green and enters
  the ratchet via `mix test.baseline add`; test332 and test159 remain the
  regression guards for the mint-before-reject ordering and the
  `error.execution` half.
- ADR-0039's status line gains "amended in part by 0048"; its body stands
  as written, with this record as the second scoping. ADR-0027, ADR-0029,
  and ADR-0034 need no edits: the registry seam, the recorded input kinds,
  and replay's pure-fold shape are all unchanged. `docs/observability.md`
  constraint 6 gains the widened-entry sentence on the implementing
  branch.
- The session's `deliver/5` miss path (`communication_error/4`) stays -
  like ADR-0047 decision 4's planner arms, it is a boundary check with a
  real caseload (decision 5's residual list), not dead code. Its comment
  should cite this record.
- Snapshot construction cost is the accepted price: enumerating
  `Statifier.Registry`'s keys is O(live sessions) per core drive. At
  today's scale (test runs, small session populations) this is noise;
  no benchmark gates it. Named reopen trigger: a measured embedder
  workload where the per-drive enumeration is material - the re-argument
  would weigh a narrower snapshot (only routes the document can name is
  impossible with `targetexpr`, but a lazily-built or embedder-scoped set
  is not) against shape D's call-capture replay cost, in a new record.
- Open question, recorded rather than decided: whether the core-raised
  `error.communication` should carry a trace/cause distinction from the
  session-raised one, so tooling can tell a predicted miss from a
  dispatch-time miss. Nothing consumes the distinction today; the cause
  metadata (constraint 4) already differs naturally (content origin versus
  ADR-0039 origin), and naming it a contract belongs to the first
  consumer.
- What would reopen this record: the snapshot-cost trigger above; an
  embedder-registrable Event I/O Processor set (ADR-0047 decision 5's
  trigger - a registrable processor set would make reachability
  per-processor and re-open the shape question); or a demonstrated need
  for dispatch-time truth inside the block, which is shape D's one honest
  advantage and would have to be argued against decision 1's replay
  grounds.
