---
date: 2026-08-17T17:05:38-0600
researcher: Claude
git_commit: 3a7655aaa03774504d2dcfda2589c95cd7195662
branch: st-yizi-send-block-abort
repository: statifier-ex
beads_issue: st-yizi
topic: "Where <send> target/type validity is decided, and why it breaks 4.9 block abort (test159) and internal-queue document order (test496)"
tags: [research, codebase, interpreter, send, executable-content, corpus]
status: complete
last_updated: 2026-08-17
last_updated_by: Claude
---

# Research: send target/type validity, block abort, and internal-queue order

**Date**: 2026-08-17T17:05:38-0600
**Git Commit**: 3a7655aaa03774504d2dcfda2589c95cd7195662
**Branch**: st-yizi-send-block-abort
**Bead**: st-yizi

## Research Question

st-yizi reports that a `<send>`'s target/type validity is decided in
`Statifier.Session.Effects.plan_send/3` - session-level, after the pure core
has already finished the whole macrostep containing the `<send>`. Two W3C
mandatory tests fail as a result: test159 (spec 4.9 block abort) and test496
(the send's `error.communication` lands on the internal queue behind a later
sibling `<raise>`).

What this document establishes: exactly where each validity check lives
today, exactly which of them is decidable without a live session, what the
existing record (ADR-0003, 0027, 0028, 0036, 0039, 0044) does and does not
forbid, and which fix shapes the code and the record leave open.

## Summary

Six findings, in the order they matter.

1. **There are two different checks, not one.** `Statifier.Session.Target.parse/1`
   is a pure string classifier that needs no registry: `target="baz"` is
   `{:invalid, "baz"}` from the string alone. Reachability is a separate
   question that `parse/1` deliberately does not answer: `#_scxml_foo` parses
   cleanly to `{:session, "foo"}` and only a `Statifier.Registry` lookup in
   `Statifier.Session.deliver/5` can say it names nothing live. The two failures
   also carry different event names - `error.execution` for the invalid target
   or unsupported type (6.2.4, 6.2.5), `error.communication` for the
   unreachable-but-well-formed one (6.2.4, C.1).

2. **Both checks nonetheless run in the same place today**, `plan_send/3`
   (`lib/statifier/session/effects.ex:158-176`), which the session reaches only
   after `Statifier.Interpreter.handle_event/2` has returned. Placement of the
   *static* check there is a locality choice made by st-cmq.5's plan, not
   something any ADR required.

3. **The core already has the exact machinery test159 needs.**
   `Statifier.Interpreter.Content` is spec 4.9's block runner: it folds a block
   with `Enum.reduce_while/3` and halts on the first `{:error, _}` a node
   returns, then converts that into `error.execution` at the failing node's
   position (`lib/statifier/interpreter/content.ex:169-190`, `:226-236`).
   `Statifier.Machine.Content.Send.execute/2` already uses that channel for
   ADR-0036's argument failures. A statically-invalid target returned as
   `{:error, _}` from that same `with` chain would abort the block and enqueue
   `error.execution` for free.

4. **test496 cannot be fixed post-hoc at all.** `handle_event/2` runs
   `main_event_loop/1` to quiescence before returning
   (`lib/statifier/interpreter.ex:436-457`). By the time `Session` sees any
   effect, the `<raise event="foo"/>` has been enqueued, dequeued, matched by
   `<transition event="*">` and the machine has already entered `fail`. No
   re-ordering of the session's instruction list, and no change to ADR-0044's
   deferral, can recover the ordering: the decision has to be made while the
   core is still inside the block.

5. **ADR-0039's rejected alternative is narrower than it first reads.** It
   forecloses "the core itself decides whether a target *resolves*", grounded
   entirely on liveness and the registry. It says nothing about a pure,
   registry-free classification of a target *string*. Fixing test159 needs no
   amendment. Fixing test496 does touch the foreclosed ground and would need
   an amendment or a superseding record.

6. **Neither test is in the ratchet.** `test/passing_tests.json` contains no
   entry for test159 or test496, so both are currently-red candidates that
   `mix test.baseline` would ratchet in once they pass. Nothing is silenced.

## Detailed Findings

### The two failing tests, confirmed red at this commit

`mix test --include scxml_w3` on both files at commit
`3a7655a`:

```
1) test test159 (SCXMLTest.EvaluationofExecutableContent.Test159)
   Expected active states ["pass"], but got []
2) test test496 (SCXMLTest.ScxmlEventProcessor.Test496)
   Expected active states ["pass"], but got ["fail"]
```

- `test/scxml_tests/mandatory/evaluationof_executable_content/test159_test.exs:19` -
  `<onentry>` holds `<send event="thisWillFail" target="baz"/>` then
  `<assign location="Var1" expr="Var1 + 1"/>`; `<transition cond="Var1==1" target="fail"/>`
  precedes the unconditional `<transition target="pass"/>`. The observed empty
  configuration is consistent with entering the top-level `<final id="fail">`
  and exiting the interpreter: the assign ran, so `Var1==1` selected `fail`.
- `test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs:16` -
  `<onentry>` holds `<send type="...#SCXMLEventProcessor" event="event" target="#_scxml_foo"/>`
  then `<raise event="foo"/>`; `<transition event="error.communication" target="pass"/>`
  precedes `<transition event="*" target="fail"/>`.

Both documents route through `Statifier.Case.drive_through_session/3`
(`test/support/case.ex:179-197`), because `:send_elements` makes them
session-required - the session layer is where the failure is produced, so the
sync path is not an alternative reading of the same bug.

### Where the checks live today

`Statifier.Session.Target` (`lib/statifier/session/target.ex`) is pure and
holds both classifiers:

- `parse/1` (`lib/statifier/session/target.ex:46-69`) maps a target string to
  `:self` (nil target), `:internal` (`#_internal` / `_internal`), `:parent`
  (`#_parent` / `_parent`), `{:session, sid}` (`#_scxml_<sid>`),
  `{:invoke, invokeid}` (any other `#_`-prefixed value), or `{:invalid, other}`.
  Its moduledoc states outright that it never decides reachability
  (`lib/statifier/session/target.ex:9-12`, `:63-66`).
- `supported_type?/1` (`lib/statifier/session/target.ex:81-84`) accepts `nil`,
  the short form `"scxml"`, and the long-form processor URI. Fully decidable
  from the string.

`Statifier.Session.Effects.plan_send/3`
(`lib/statifier/session/effects.ex:158-176`) applies both, in order: the type
gate first (`:159`), then `parse/1` (`:160`), and either failure produces
`execution_error/1` (`lib/statifier/session/effects.ex:227-231`), the
instruction `{:raise, :platform, "error.execution", {:content, c_index, owner}, sendid: ...}`.
`plan_send_delayed/3` (`:183-203`) runs the identical pair at plan time, per
6.2.3, and only defers route resolution to the timer firing.

Reachability is decided later still, in `Statifier.Session.deliver/5`
(`lib/statifier/session.ex:1270-1348`), whose miss path is
`communication_error/4` (`lib/statifier/session.ex:1389-1404`).

Both paths write back through ADR-0039's single door:
`Statifier.Session.deliver_internal/6` (`lib/statifier/session.ex:1433-1449`)
calls `Statifier.Interpreter.deliver_internal/5`
(`lib/statifier/interpreter.ex:483-502`), and per ADR-0044 appends the returned
effects to `state.deferred` rather than performing them inline
(`lib/statifier/session.ex:1439-1443`, drained by `drain_deferred/1` at
`:989-996`).

### Why the session sees the effect too late

`Statifier.Interpreter.handle_event/2`
(`lib/statifier/interpreter.ex:436-457`) is one macrostep end to end:
`begin_macrostep` -> invoke passes -> `select_transitions` -> `run_selected` ->
`main_event_loop/1` to quiescence, returning
`dequeued ++ invoke_pass_effects ++ selected_effects ++ loop_effects`. The
session's `drain_event/2` (`lib/statifier/session.ex:892-903`) calls it and
only then hands the list to `perform/3` (`:966-971`), which runs
`Effects.plan/2` and then `drain_deferred/1`.

For test496 that ordering is fatal in the strict sense: `<raise event="foo"/>`
executes inside the same `<onentry>` block, so `foo` is on the internal queue
before `main_event_loop/1` even starts folding; the loop dequeues it, matches
`<transition event="*">`, enters `fail`, and quiesces - all before
`plan_send/3` has been called once. The `error.communication` that
`deliver/5` eventually produces arrives at a machine that is already in `fail`.

For test159 the same shape produces the block-abort failure: the sibling
`<assign>` at `c_index 1` runs inside `Statifier.Interpreter.Content`'s fold
because the `<send>` at `c_index 0` returned `{:ok, context, [{:send, ...}]}` -
the core has no idea the target is bad.

### The block runner is already 4.9-shaped

`Statifier.Interpreter.Content` (`lib/statifier/interpreter/content.ex`) is
the single seam every `<onentry>`, `<onexit>`, and transition block goes
through, from `Statifier.Interpreter.ExitEntry`'s four call sites
(`lib/statifier/interpreter/exit_entry.ex:250-261`, `:333-339`, `:758-769`,
`:825-833`).

- `execute_block/3` (`lib/statifier/interpreter/content.ex:137-159`) builds one
  `%ExecutableContent.Context{}` per block (ADR-0028) and calls `run_nodes/2`.
- `run_nodes/2` (`:169-190`) is `Enum.reduce_while/3`. `{:ok, ctx, effects}`
  continues; `{:error, reason}` (leaf) and `{:error, ctx, reason}` (composite)
  both `{:halt, ...}` with the failing `c_index`. No later node in the block is
  dispatched.
- `raise_execution_error/4` (`:226-236`) is the sole errors-are-events
  conversion site for content: `MachineState.raise_platform/4` with name
  `"error.execution"` and origin `{:content, c_index, owner}`.
- Sibling blocks are untouched, because each `execute_block/3` call is its own
  fold (moduledoc `:1-13`).

Node types that already abort a block by returning `{:error, _}`: `<assign>`
(`lib/statifier/machine/content/assign.ex:82-110`), `<send>`
(`lib/statifier/machine/content/send.ex:111-150`), `<cancel>`
(`lib/statifier/machine/content/cancel.ex:59-75`), `<if>`
(`lib/statifier/machine/content/if.ex:167-184`), `<foreach>`
(`lib/statifier/machine/content/foreach.ex:230-248`, `:326-343`), `<script>`
(`lib/statifier/machine/content/script.ex:58-96`), and `<log>` on a bad `expr`
(`lib/statifier/machine/content/log.ex:66-68`). `<raise>`
(`lib/statifier/machine/content/raise.ex:27-44`) is the one element with no
error clause at all.

There is also a second, non-fatal channel: `context.pending_errors`, recorded
by a leaf and drained by `run_nodes/2` after *every* node through the same
`raise_execution_error/4` (`lib/statifier/interpreter/content.ex:192-209`).
It enqueues `error.execution` at (just after) the node's position without
halting the block. The moduledoc documents its own ordering caveat at
`:92-110`: the drain happens after the node returns, so a 5.9.1 error is
queued behind any event the node itself raised.

### What `<send>`'s own `execute/2` already does

`Statifier.Machine.Content.Send.execute/2`
(`lib/statifier/machine/content/send.ex:111-150`) is a `with` chain resolving
`event`, `target`, `type`, `delay`, `namelist ++ params`, and `<content>`, then
minting the send id (`:120`, `generate_send_id/2:253-261`), optionally writing
`idlocation` (`:269-281`), and building `{:send, %Effect.Send{}}` or
`{:send_delayed, %Effect.SendDelayed{}}` (`build_effect/6:325-372`). Any
argument failure falls out of the `with` as `{:error, reason}` and produces no
effect at all - ADR-0036's discard-the-message rule, which reaches
`error.execution` and block abort through the runner above.

So the *target string* is already resolved to a binary inside this function,
at `:115`, one line of a `with` away from where an invalid one would have to be
rejected. The value `Target.parse/1` consumes exists in the core today; only
the call does not.

### The ADR record, precisely

- **ADR-0003** (pure core with effects). "The core interpreter is pure:
  `(state, event) -> {state, [effect]}`", effects interpreted outside, with
  `Statifier.Session` as the production interpreter. It bars the core from
  consulting external live state. It does not bar a pure string classification.
- **ADR-0027** (embedder-placed session runtime). Puts the `Registry` and
  session supervisor on the embedder side; `#_scxml_<sid>` resolution is
  `Registry.lookup/2`, an empty result taking 6.2's `error.communication` path.
  One carve-out already exists: a session addressing *itself* is resolved
  ahead of the registry lookup.
- **ADR-0028** (blocks thread one context). Governs the per-block
  `datamodel_context`; no bearing on where validity is decided.
- **ADR-0036** (a failed `<send>` argument discards the message). "A failure
  while evaluating any of `<send>`'s arguments ... raises `error.execution` and
  discards the message: `execute/2` returns `{:error, reason}`, the block
  runner converts it to `error.execution` (its sole such site), and no
  `Effect.Send` or `Effect.SendDelayed` is produced for that `<send>`." Scoped
  to *evaluation* failures. It does not claim the invalid-target case, and it
  does not forbid it either - it establishes exactly the mechanism such a case
  would use.
- **ADR-0039** (session-detected send failures re-enter the core). Settles the
  write-back door only. Its own closing sentence: "Whoever implements the
  target router (this bead, later phases) writes it as the thing that decides
  *whether* to call `deliver_internal/5` and with which `name`/`opts`; this
  record settles only that the write-back, once a failure is decided, has
  exactly one door."
- **ADR-0044** (re-entry effects defer to the outer batch). Explicitly leaves
  0039 alone: "ADR-0039 is unchanged: the seam stays the single door, crossed
  at the same position; only *when the returned effects are notified* moves."

### Reading ADR-0039's rejected alternative against the two cases

The rejected alternative, in full:

> **Move target routing into the core**, so the core itself decides whether a
> target resolves and raises the failure inline during `handle_event/2`. This
> is foreclosed outright: ADR-0003's pure core knows nothing about which
> sessions are live, and ADR-0027 places the registry - the only source of
> truth for "does this session id resolve" - on the embedder side of the
> session boundary. Teaching the core to consult it would make the core aware
> of live sessions, which both records already forbid.

Every load-bearing phrase is about liveness: "whether a target **resolves**",
"which sessions are **live**", "the **registry** - the only source of truth for
'does this session id resolve'", "aware of **live sessions**". The prohibition
is on the core making a liveness determination, which requires the registry.

Applied to the two failures:

- **test159, `target="baz"`.** Decided by `Target.parse/1` from the string
  alone. No registry, no liveness, no awareness of any session. The rejected
  alternative's stated ground does not reach it on its own text. Whether the
  *phrase* "target routing" is read broadly enough to cover it is the one
  judgment call in this document; the argument recorded under it is not. A fix
  that calls `Target.parse/1` (or an equivalent pure classifier) from
  `Machine.Content.Send.execute/2` needs no amendment to 0039, and would be a
  straightforward instance of ADR-0036's already-accepted mechanism. A one-line
  clarification in 0039's Consequences saying so would keep the record legible,
  but nothing in 0039 has to be reversed.
  - Same reasoning covers `supported_type?/1`: it too is a pure string test
    with no registry involvement, and 6.2.5's failure is also `error.execution`.
    Whether the deployment's supported-type set is genuinely static is the open
    question below.
- **test496, `target="#_scxml_foo"`.** Requires a registry lookup to know it is
  unreachable, and 6.2.4/C.1 require the resulting `error.communication` to sit
  on the internal queue at the send's position - which, per the ordering finding
  above, means the answer must be known while the core is still inside the
  block. This lands squarely on 0039's foreclosed ground. Any fix here amends
  0039 (and, if the mechanism is a passed-in resolver or snapshot, engages
  ADR-0027's placement of the registry too). ADR-0036 and ADR-0044 add nothing
  further either way.

### Existing precedent for handing the core a capability

Two accepted records already hand the core a caller-supplied capability rather
than letting it reach out:

- **ADR-0030** - `In()` becomes a provider, and the context stays off
  `MachineState`.
- **ADR-0038** - `<invoke src>` resolves at the session boundary through an
  embedder-supplied `invoke_source` resolver; the library never fetches `src`
  itself.

Neither was written about `<send>` targets, and neither is authority for
reversing 0039. They are the shape a fix for test496 would most plausibly
take, and the shape whose reconciliation with 0039 an amendment would have to
argue.

### The ratchet's treatment

`test/passing_tests.json` holds no entry matching `test159` or `test496` in
either `w3c_tests` or elsewhere; both are outside the registry and therefore
outside `mix test.regression`. `docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md`
and `docs/plans/260816-st-u2h4-start-session-init-deadlock-deferred-invoke.md`
both assign these two reds to st-yizi by name and record that nothing is
silenced and no tag gates them out (ADR-0011). Making them pass is therefore
additive: `mix test.baseline add` on the two files, per `docs/testing.md`'s
ratchet section.

## Spec clauses, quoted from the local cache

Quotations are from `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`.

**Block abort is section 4.9 "Evaluation of Executable Content", not 5.7.**
The bead and the corpus directory name both say "executable content"; the REC
numbers the clause 4.9. (`5.7` in the current REC is `<param>`.) The clause:

> Wherever executable content is permitted, an arbitrary number of elements
> MAY occur. Such a sequence of elements of executable content is called a
> block. ... The SCXML processor MUST execute the elements of a block in
> document order. If the processing of an element causes an error to be
> raised, the processor MUST NOT process the remaining elements of the block.
> (The execution of other blocks of executable content is not affected.)
> Events raised during the processing of executable content are treated like
> any other events. Note in particular, that error events will not be removed
> from the queue and processed until all events preceding them in the queue
> have been processed.

That last sentence is FIFO processing of a queued error, not license about
insertion position - the same reading `Statifier.Interpreter.Content`'s
moduledoc already records at `lib/statifier/interpreter/content.ex:104-110`.

**6.2.4, the target:**

> If the value of the 'target' or 'targetexpr' attribute is not supported or
> invalid, the Processor MUST place the error error.execution on the internal
> event queue. If it is unable to dispatch the message, the Processor MUST
> place the error error.communication on the internal event queue.

**6.2.5, the type:**

> If neither the 'type' nor the 'typeexpr' is defined, the SCXML Processor
> MUST assume the default value of http://www.w3.org/TR/scxml/#SCXMLEventProcessor.
> If the SCXML Processor does not support the type that is specified, it MUST
> place the event error.execution on the internal event queue.

**C.1, the unreachable session:**

> If the sending SCXML session specifies a session that does not exist or is
> inaccessible, the SCXML Processor MUST place the error error.communication
> on the internal event queue of the sending session.

**3.12.2, the two error names:**

> Two error events are defined in this specification: 'error.communication'
> and 'error.execution'. The former cover errors occurring while trying to
> communicate with external entities, such as those arising from `<send>` and
> `<invoke>`, while the latter category consists of errors internal to the
> execution of the document, such as those arising from expression evaluation.

Note what these clauses do *not* say: none of them states that a
`error.communication` from a failed dispatch aborts the rest of the block. 4.9
speaks of "an error ... raised" during "the processing of an element", which
covers the synchronously-known case; a dispatch failure discovered later is
outside that window. test496 does not discriminate: if the
`error.communication` is enqueued before `foo`, the test passes whether or not
the block aborts.

## Candidate fix shapes

Recorded as the shapes the code and the record leave open, not as a
recommendation. The planning stage decides.

**For test159 (static invalidity):**

- **A. Reject in the core's `<send>` leaf.** Call a pure classifier from
  `Statifier.Machine.Content.Send.execute/2`'s `with` chain, right after the
  target resolves (`lib/statifier/machine/content/send.ex:115`) and after the
  type resolves (`:116`), returning `{:error, reason}` on `{:invalid, _}` or an
  unsupported type. Block abort and `error.execution` at the right position both
  come for free from `Statifier.Interpreter.Content`. Cost: `Target.parse/1`
  currently lives under `lib/statifier/session/`, so either the core calls into
  a session-namespaced pure module or the classifier moves to a neutral home
  (`Statifier.Send.Target`, say) with the session's routing table kept where it
  is. Requires deciding whether the session planner then keeps its own
  `{:invalid, _}` arm as dead-but-defensive code or drops it.
- **B. Leave the check in the planner and give the core a deferred-abort
  signal.** The core would have to be told, mid-block, that a produced effect
  is fatal - which is the thing the current architecture cannot express, since
  the effect list is not read until the macrostep is over. This shape only
  works with a synchronous callback (see D), so it is not independently viable.

**For test496 (reachability):**

- **C. A route-resolution snapshot passed into the core.** The session computes
  the set of resolvable routes (registry contents, `invoked_by`, the
  invocations table) at the start of the macrostep and passes it as an opt to
  `handle_event/2`; the core decides reachability against that data. The core
  gains no registry access and no process awareness - it reads a plain value.
  Tradeoff: a snapshot can go stale within one macrostep (a target session can
  die mid-block), and the registry read is a point-in-time truth regardless.
  Amends ADR-0039's rejected alternative; interacts with ADR-0027's carve-out
  for self-addressing, which the core would now be doing itself.
- **D. A resolver capability passed into the core**, in the shape ADR-0030's
  `In()` provider and ADR-0038's `invoke_source` resolver already use: a
  function the caller supplies, invoked by the core at the `<send>` node. Same
  amendment exposure as C, plus a purity argument (the function is impure from
  the core's point of view even though the core stays syntactically clean), and
  an ADR-0034 replay question - a recorded run must reproduce the resolver's
  answers.
- **E. Suspend the macrostep at the `<send>`.** `handle_event/2` returns a
  suspended value; the session resolves the route and resumes. Preserves purity
  strictly and needs no snapshot, but the suspension point is mid-block, not at
  the microstep boundary ADR-0012 constraint 1 makes resumable, so it is the
  largest change of the five and touches the observability contract.
- **F. Accept the abort-only half.** Note again that test496 passes if the
  `error.communication` merely precedes `foo`; nothing requires the block to
  abort. So C, D, and E are about *position*, and a shape that only aborts the
  block (without knowing reachability) would not fix test496 at all - it would
  need reachability to know whether to abort.

## Code References

- `lib/statifier/session/target.ex:46-69` - `parse/1`, the pure target
  classifier, `{:invalid, _}` arm at `:69`
- `lib/statifier/session/target.ex:81-84` - `supported_type?/1`
- `lib/statifier/session/effects.ex:158-176` - `plan_send/3`, both checks
- `lib/statifier/session/effects.ex:183-203` - `plan_send_delayed/3`, same
  checks at plan time
- `lib/statifier/session/effects.ex:227-231` - `execution_error/1`
- `lib/statifier/session.ex:892-903` - `drain_event/2`
- `lib/statifier/session.ex:966-996` - `perform/3`, `perform_batch/3`,
  `drain_deferred/1`
- `lib/statifier/session.ex:1270-1348` - `deliver/5`, registry resolution
- `lib/statifier/session.ex:1389-1404` - `communication_error/4`
- `lib/statifier/session.ex:1433-1449` - the session's `deliver_internal/6`,
  sole caller of the core seam, ADR-0044 deferral at `:1439-1443`
- `lib/statifier/interpreter.ex:436-457` - `handle_event/2`, folds to
  quiescence before returning
- `lib/statifier/interpreter.ex:483-502` - `deliver_internal/5`, ADR-0039's door
- `lib/statifier/interpreter/content.ex:137-159` - `execute_block/3`
- `lib/statifier/interpreter/content.ex:169-190` - `run_nodes/2`, the
  reduce_while short-circuit
- `lib/statifier/interpreter/content.ex:192-209` - `drain_pending/2`, the
  non-fatal channel
- `lib/statifier/interpreter/content.ex:226-236` - `raise_execution_error/4`
- `lib/statifier/interpreter/exit_entry.ex:250-261`, `:333-339`, `:758-769`,
  `:825-833` - the four block call sites
- `lib/statifier/machine/content/send.ex:111-150` - `<send>`'s `execute/2`
- `lib/statifier/machine/content/send.ex:325-372` - `build_effect/6`
- `lib/statifier/machine/content/raise.ex:27-44` - `<raise>`, the one node that
  cannot fail
- `lib/statifier/machine_state.ex:640-700` - `raise_internal/4`,
  `raise_platform/4`
- `test/support/case.ex:179-197` - `drive_through_session/3`
- `test/passing_tests.json` - no entry for either test

## Architecture Documentation

- ADR-0003 - pure core, effects at the edge; the constraint every shape above
  has to satisfy.
- ADR-0027 - embedder-placed runtime; the registry's home, with its existing
  self-addressing carve-out.
- ADR-0028 - one datamodel context per block; unchanged by any shape here.
- ADR-0036 - a failed `<send>` argument discards the message; the mechanism
  shape A would reuse verbatim.
- ADR-0039 - the write-back door, and the rejected "move target routing into
  the core"; the record shapes C/D/E amend.
- ADR-0044 - deferral of re-entry effects; relevant to why re-ordering the
  session's instruction list is not a route to test496.
- ADR-0030, ADR-0038 - the existing provider/resolver precedents.
- ADR-0012 constraint 1 - the resumable microstep boundary, which shape E
  would have to argue against.
- `docs/architecture.md:105-119` - the block-runner contract ("never a change
  to the runner").
- `docs/testing.md:179-198` - the ratchet, and how these two tests would enter it.

## Historical Context

- `docs/research/260815-st-cmq.5-external-send-targets-and-scxml-event-io-processor.md` -
  the pre-implementation research for external send targets; already documents
  test496's expectation.
- `docs/plans/260815-st-cmq.5-external-send-targets-and-scxml-event-io-processor.md` -
  the plan that placed `Target.parse/1` under `lib/statifier/session/` and put
  the `{:invalid, _}` arm in the planner, for locality with the
  registry-dependent arm. It does not argue that the core was forbidden the
  static check; it simply never put target parsing in the core.
- `docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md`,
  `docs/plans/260816-st-u2h4-start-session-init-deadlock-deferred-invoke.md` -
  both assign test159 and test496 to st-yizi.
- `docs/research/260817-st-r6l9-invoke-effect-order-reentry.md` - the ordering
  research that produced ADR-0044; the nearest prior work on effect ordering
  across the session seam.

## Open Questions

1. **Does `supported_type?/1` stay static?** Today it is a fixed three-way
   string test, so the core could run it. If a future embedder registers extra
   Event I/O Processors (the spec explicitly permits "other types such as
   web-services, SIP or basic HTTP GET"), the supported-type set becomes
   deployment state and the 6.2.5 check joins the registry-dependent side.
   Whether to design for that now is a decision, not a fact.
2. **Where should a core-side target classifier live?** `Target.parse/1`'s
   current home under `lib/statifier/session/` is a namespace statement. Moving
   it, splitting it, or having the core call into it as-is are three different
   answers with different readability costs.
3. **Should `error.communication` abort the block?** 4.9 says an error raised
   while processing an element aborts; 6.2.4's dispatch failure may be
   discovered asynchronously. No corpus document in this repo distinguishes the
   two readings today, and test496 passes either way.
4. **Does a `<send>` whose target is invalid still consume a send id?**
   `generate_send_id/2` runs at `lib/statifier/machine/content/send.ex:120`,
   after the target resolves. Shape A would reject before that line, so
   `machine_state.send_counter` would no longer advance for an invalid-target
   `<send>` - a visible change to ADR-0035's sequence for any document that
   mixes one in. No corpus test is known to observe it, but it is a semantic
   consequence rather than a refactor.
5. **How does a resolver-based shape (D) replay?** ADR-0034 drives the pure
   core, not a live session; a resolver consulted inside the core is a fifth
   input the recording would have to capture, which ADR-0029's four-input tuple
   does not currently account for.
6. **Is there an ordering interaction with `pending_errors`?** The runner's
   existing 5.9.1 drain already queues an error one position later than the
   spec reads (documented at `lib/statifier/interpreter/content.ex:92-110`). A
   new in-block error channel for `<send>` should state explicitly whether it
   uses the fatal arm (halts, correct position) or that drain (does not halt,
   late position) - they are not interchangeable for test496.

No question here was resolvable from the codebase or the record; all six are
decisions for the planning stage.
