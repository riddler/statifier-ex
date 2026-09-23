# Publish-time checks: every runtime refusal and its twin

A runtime refusal for something a literal in the source could have told us is a bug in the publish check.

The packages in this family ship pure functions a host calls. The host's
publish step is the gate: it runs those functions over a chart before the
chart can start an execution, and it refuses the publish on what they
report. An editor runs the same functions at edit time. The runtime checks
described below stay in place as the backstop, and they are never the first
line.

This page lists every refusal the family raises at run time, next to the
publish-time function that finds the same defect first (its **twin**), or the
word NONE when no function does. It covers three packages: `statifier` (this
repo), `statifier_router` and `statifier_blocks`.

## How to read the tables

Each row has five columns:

- **Refusal** - what happens at run time, and the event or return value that
  reports it.
- **Raised by** - the module (and, where it helps, the function) that raises
  it.
- **Record** - the decision record that governs it, by path in its own repo.
  In the `statifier` table the paths are in this repo. In the router and
  blocks tables they are in that package's repo.
- **Literal?** - whether a literal in the source decides the defect. "yes"
  means the defect is visible in the chart or configuration text, so a
  runtime refusal for it is a bug in the publish check. "no" means the
  defect depends on data, on another execution, or on a host's services, so
  the runtime check is the only possible check. "part" means the row splits,
  and the cell says where.
- **Twin** - the publish-time function, its package, and the version that
  ships it, or NONE.

A twin marked "main, next release" is on that package's main branch and not
yet on Hex.

Only a literal can be checked. A `typeexpr`, `targetexpr`, `eventexpr`,
`srcexpr`, or a document id computed by an `expr` is resolved against the
datamodel at run time. Every twin below reports such a value as unchecked
(or leaves it out) rather than guessing at it. The runtime check is the only
check for such values.

## statifier

`error.execution` and `error.communication` are platform events. The engine
puts them on the execution's internal queue, and the chart handles them
like any other event (`docs/architecture.md`, design principle 3, "Errors are events").

| # | Refusal | Raised by | Record | Literal? | Twin |
|---|---|---|---|---|---|
| S1 | `<send>` names a `type` the session never registered: `error.execution`, data `{:unsupported_type, type}`, carrying the send's `sendid` | `Statifier.Machine.Content.Send`, raised through `Statifier.Interpreter.Content`; `Statifier.Session.Effects` for an effect a caller injects through `Statifier.Session.interpret/2` | `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md`, `docs/adr/0069-host-registered-send-types.md` | part: yes for `type`, no for `typeexpr` | `Statifier.Send.Types.unsupported_sends/2` (statifier, since 2.6.0); the router composes it as `StatifierRouter.Routes.unsupported_types/2` (statifier_router 0.2.0) |
| S2 | `<send>` with a built-in type writes a `target` the engine cannot parse: `error.execution`, data `{:invalid_target, target}`, carrying `sendid` | `Statifier.Machine.Content.Send`, through `Statifier.Interpreter.Content`; `Statifier.Session.Effects` for an injected effect | `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md` | part: yes for `target`, no for `targetexpr` | NONE |
| S3 | `<send>` to a route that is missing from the snapshot the driver declared: `error.communication`, data `{:unreachable_target, target}`, carrying `sendid` | `Statifier.Machine.Content.Send`, through `Statifier.Interpreter.Content` | `docs/adr/0048-send-reachability-judged-against-a-route-snapshot.md` | part: yes for a `#_<invokeid>` target that no `<invoke id>` in the chart declares; no for a session id or `#_parent`, which depend on who started the execution | NONE |
| S4 | A send whose target session does not exist or cannot be reached, found at delivery (no snapshot declared, a delayed send when its timer fires, an injected effect): `error.communication` carrying `sendid` | `Statifier.Session` (the `deliver` path and `communication_error`) | `docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`, `docs/adr/0048-send-reachability-judged-against-a-route-snapshot.md` | no | NONE |
| S5 | A host-registered send processor cannot deliver: `error.communication` carrying `sendid`, written by the host | `Statifier.Session.failed_send/3`; `Statifier.Interpreter.deliver_internal/5` when no session process is running | `docs/adr/0069-host-registered-send-types.md` (decision 5) | depends on the processor: RT1 to RT9 are the router's | NONE in statifier, which cannot see a processor's routes; the router's twins are in RT1 to RT9 |
| S6 | `<invoke>` names a `type` the session never registered: `error.execution` with the invocation as its origin and no data; no child starts | `Statifier.Interpreter` (`reject_unregistered_type`); `Statifier.Session.Effects` (`plan_invoke`) | `docs/adr/0051-invoke-handlers-are-registered-per-session.md` | part: yes for `type`, no for `typeexpr` | NONE for a chart; a block document reports it through `StatifierBlocks.Compiled`'s `invoke_types` field and the `:known_invoke_types` lint of `StatifierBlocks.Compiler.compile/3`, a warning only (statifier_blocks 0.32.0) |
| S7 | A registered invoke handler's `start/2` answers `{:error, _}`: `error.execution` with the invocation as its origin | `Statifier.Session.Effects` (`plan_invoke`) | `docs/adr/0051-invoke-handlers-are-registered-per-session.md` | no: the handler decides | NONE |
| S8 | An `<invoke>` argument fails to evaluate: `error.execution` carrying the reason; the invocation is abandoned | `Statifier.Interpreter` (`abort_invocation`) | `docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md` | part: the argument's own failure is one of S12 to S14 | NONE; S12 to S14 say which of those failures a literal decides |
| S9 | A child fails to start (the built-in `scxml` invoke's `src` or `<content>` does not resolve or compile, or `Statifier.start_session/2` fails): `error.communication` with the invocation as its origin | `Statifier.Session` (`start_child`, `invoke_error`); `Statifier.Invoke.Source.resolve/2` | `docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md` | part: yes for an inline `<content>` child that does not compile; no for a `src`, which the host's resolver answers | NONE (for block documents see B1 to B3) |
| S10 | A started invocation fails for good: `error.communication.invoke.<invokeid>` | `Statifier.Invoke.Answer.failed/4`, through `Statifier.Session.failed_invocation/3` | `docs/adr/0068-permanent-invoke-failure-is-a-suffixed-error-communication.md` | no | NONE |
| S11 | A location write whose root the datamodel does not declare (`<assign>`, an `idlocation`, a `<finalize>` namelist write): `error.execution`, data `{:unbound_location, location}`; a root beginning with `_` gives `{:system_variable, root}` instead | `Statifier.Interpreter.Datamodel.write_location/4`, called by `Statifier.Machine.Content.Assign`, `Statifier.Machine.Content.Send` and `Statifier.Interpreter` | `docs/datamodel.md` (the root of a written path must already exist) | yes, when the location's root is a name and the chart's `<data>` ids are in the source | NONE for a chart; for a block document, `StatifierBlocks.Datamodel.findings/4`, reached through `StatifierBlocks.Publish.findings/3`, reports it as an `:info` advisory and does not refuse (statifier_blocks main, next release) |
| S12 | A read of a root the datamodel does not declare: `error.execution` carrying predicator's undefined-variable error, wherever the expression sits (`cond`, executable content, `<data>`, `<donedata>`, a global `<script>`) | the raise site of the expression: `Statifier.Interpreter.Selection`, `Statifier.Interpreter.Content`, `Statifier.Interpreter.Datamodel`, `Statifier.Interpreter.ExitEntry`, `Statifier.Interpreter` | `docs/architecture.md` (design principle 3), `docs/datamodel.md` | yes, when the root is neither declared by a `<data>` nor a system variable | NONE for a chart; for a block document, `StatifierBlocks.Publish.findings/3` reports an undeclared path as an `:info` advisory and does not refuse (statifier_blocks main, next release) |
| S13 | An expression that fails to compile, where the compiler defers the failure to run time (`<data expr>`, `<assign expr>`, `<script>` in content or at the top level, a `namelist` entry): `error.execution` carrying the compile error | `Statifier.Compiler` stores the failure as `{:invalid, error}` on the compiled node; the raise sites are `Statifier.Interpreter.Datamodel`, `Statifier.Interpreter.Content` and `Statifier.Interpreter` | `docs/datamodel.md` (spec 5.9.4 allows either a load-time or a run-time rejection, and the engine takes the run-time one); `docs/adr/0026-script-as-predicator-statement-programs.md` for `<script>` | yes | NONE: the compiled machine carries each failure, but no function lists them. Every other expression that fails to compile fails `Statifier.compile/2` itself, which is its own publish-time check |
| S14 | An expression that compiles and then fails to evaluate on the data it meets (a type error, a `<foreach>` array that is not a list, a `delayexpr` of the wrong shape): `error.execution` carrying the reason | `Statifier.Interpreter.Selection`, `Statifier.Interpreter.Content`, `Statifier.Interpreter.Datamodel`, `Statifier.Interpreter.ExitEntry` or `Statifier.Interpreter`, wherever the expression sits | `docs/architecture.md` (design principle 3); `docs/adr/0021-donedata-content-expr-failure-yields-no-data.md` for `<donedata>`; `docs/adr/0036-send-argument-failure-discards-the-message.md` for `<send>` | no | NONE |
| S15 | An event the chart has no transition for: not refused. The engine discards it, as the SCXML algorithm does | `Statifier.Interpreter.Selection` (no transition is selected) | `docs/adr/0071-chart-event-vocabulary-and-accepts-check.md` | yes, when the sender's event name is a literal | `Statifier.Chart.check_accepts/2` and `Statifier.Chart.events/1` (statifier 2.7.0); the router applies them in RT13 |

## statifier_router

At the executor seam, a refusal on the send side reaches the sending
execution as `error.communication` carrying the send's `sendid`
(`StatifierRouter.SendHandler`). The step that made the send is still
committed. The routing side's outcomes are what `StatifierRouter.route/3`
returns, and they are written to the binding's ledger.

| # | Refusal | Raised by | Record | Literal? | Twin |
|---|---|---|---|---|---|
| RT1 | A send of the router's type names a route the host never registered: `{:error, {:unregistered_route, name}}`, a `send_refused` ledger row with reason `route` | `StatifierRouter.SendHandler` | `docs/adr/0005-routes.md` (section 7); `docs/adr/0006-the-execution-target.md` (the Note of 2026-09-21) | part: yes for `target`, no for `targetexpr` | `StatifierRouter.Routes.unregistered/2` (statifier_router 0.2.0), also composed by `StatifierRouter.Contracts.check/3` (statifier_router main, next release) |
| RT2 | A send to the execution target with no usable `document` param: `{:send_refused, :document}` | `StatifierRouter.SendHandler` | `docs/adr/0006-the-execution-target.md` (section 6) | part: yes when the param is absent or is a literal; no when it is an expression | `StatifierRouter.Contracts.check/3` (statifier_router main, next release) lists the send under `unchecked` with reason `:no_document` or `:document_expr`. It reports and does not refuse |
| RT3 | A binding, or a send to the execution target, names a document the host has no published chart for: the delivery is rolled back and `StatifierRouter.route/3` returns `{:error, {:unresolved_document, document, reason}}`, with no ledger row | `StatifierRouter.Delivery` (`resolve/3`), through the host's `StatifierRouter.Resolver` | `docs/adr/0003-delivery-discipline.md` (the Note of 2026-09-20); `docs/adr/0008-the-receiver-contract-at-publish.md` (decision 4) | yes, for a binding's `document` and for a literal `document` param | `StatifierRouter.Contracts.check/3`, reason `:not_published` (statifier_router main, next release) |
| RT4 | A send to the execution target with no usable `key` param: `{:send_refused, :key}` | `StatifierRouter.SendHandler` | `docs/adr/0006-the-execution-target.md` (section 6) | part: yes when the param is absent; no when it is an expression | NONE |
| RT5 | A send to the execution target whose `create` param is neither `if_absent` nor `never`: `{:send_refused, :create}` | `StatifierRouter.SendHandler` | `docs/adr/0006-the-execution-target.md` (sections 3 and 6) | part: yes when the param is a literal; no when it is an expression | NONE |
| RT6 | A send to the execution target that resolves to the sender's own address: `{:send_refused, :self_address}` | `StatifierRouter.SendHandler` | `docs/adr/0006-the-execution-target.md` (section 6) | no | NONE |
| RT7 | A send to the execution target from an execution with no address row: `{:send_refused, :unaddressed_sender}`, with no ledger row | `StatifierRouter.SendHandler` | `docs/adr/0006-the-execution-target.md` (section 6) | no: it depends on how the sender was created | NONE |
| RT8 | A send to the execution target that finds nothing to deliver to: `{:send_undelivered, :no_execution}` or `{:send_undelivered, :finished}` | `StatifierRouter.SendHandler` | `docs/adr/0006-the-execution-target.md` (section 3) | no | NONE |
| RT9 | A delayed send of the router's type on the send-processor shape: `{:delayed_send_unsupported, send_id}` | `StatifierRouter.SendHandler.perform/2` | `docs/adr/0005-routes.md` (section 5) | yes, given the host's shape: a literal `delay` on a send of the router's type | NONE |
| RT10 | A binding's `match` or `key` program refuses the event: `{:key_refused, binding_id, reason}` | `StatifierRouter.route/3` | `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (section 1) | no: the programs read the event payload | NONE |
| RT11 | A binding whose `create` is `:never` meets an address with no row: `{:dropped, binding_id, :no_execution}` | `StatifierRouter.Delivery` | `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (sections 1 and 2) | no | NONE |
| RT12 | The execution the event was for is terminal: `{:dropped, binding_id, :finished}` | `StatifierRouter.Delivery` | `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (sections 1 and 3) | no | NONE |
| RT13 | An event the receiving chart never listens for: not refused. It is delivered, recorded as delivered, and selects no transition. A `dropped: unmatched_event` outcome is deferred and is not in this release | `StatifierRouter.Delivery`; `Statifier.Interpreter.Selection` in the receiver | `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (section 8); `docs/adr/0008-the-receiver-contract-at-publish.md` (decision 5) | yes, for a binding's `event` and for a send's literal `event` | `StatifierRouter.Contracts.check/3` (statifier_router main, next release), which falls back to `Statifier.Chart.check_accepts/2` (statifier 2.7.0) for a receiver that declares nothing |
| RT14 | A route calls back into routing while it runs: `{:error, {:reentrant_route, execution_id}}` | `StatifierRouter.Delivery.deliver/4` | `docs/adr/0005-routes.md` (decision 5) | no: a host route's code does this, not a chart | NONE |

## statifier_blocks

A `core.subchart` or a `core.map` names its child by a literal document id.
When the child cannot start, the handler raises
`error.communication.invoke.<block id>` with one of three reasons. It never
answers `{:error, _}`, because the engine would turn that into an
`error.execution` with no data and the reason would be lost
(`StatifierBlocks.Runtime.Subchart`).

| # | Refusal | Raised by | Record | Literal? | Twin |
|---|---|---|---|---|---|
| B1 | The child document id resolves to nothing: reason `unknown_document` | `StatifierBlocks.Runtime.Subchart.Resolution.resolve/3` | `docs/adr/0008-durable-subchart-handler.md` | yes | `StatifierBlocks.Graph.check/2`, a `:graph` error anchored on the block's `chart` field (statifier_blocks main, next release) |
| B2 | The child document does not compile for child use: reason `child_compile_findings` | `StatifierBlocks.Runtime.Subchart.Resolution.resolve/3` | `docs/adr/0008-durable-subchart-handler.md` | yes: the child's own document | the child's own publish, `StatifierBlocks.Publish.findings/3` and then `StatifierBlocks.Compiler.compile/3` (statifier_blocks main, next release) |
| B3 | The host's resolver reports a cycle across documents: reason `cycle_refused` | `StatifierBlocks.Runtime.Subchart.Resolution.resolve/3` | `docs/adr/0008-durable-subchart-handler.md` | yes: every id in the cycle is a literal | NONE. A document that names itself is refused by its own compile (`StatifierBlocks.Compiler.SelfReference`); a longer cycle is not checked at publish |
| B4 | A parent routes on an outcome the child does not declare: not refused. The child's answer falls to the parent's unconditioned arm | the generated chart | `docs/adr/0008-durable-subchart-handler.md` (the Amendment of 2026-09-22) | yes | `StatifierBlocks.Graph.check/2` when the parent is published and `StatifierBlocks.Graph.consumers_broken/2` when the child is (statifier_blocks main, next release) |
| B5 | A parent reads a done-data key the child does not declare: not refused | the generated chart | `docs/adr/0008-durable-subchart-handler.md` (the Amendment of 2026-09-22) | yes | `StatifierBlocks.Graph.check/2` and `StatifierBlocks.Graph.consumers_broken/2` (statifier_blocks main, next release) |

A block document is also a chart once it compiles, so rows S1 to S15 apply
to it too. Where `statifier_blocks` has its own check for one of those rows,
that row says so.

## An example: a library loan

A loan chart sends overdue notices through a processor the host registers
under `library:notices`. The loan document's declaration names
`patron.blocked` as an event it accepts, but no transition listens for it.

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
       initial="on_loan" datamodel="predicator">
  <state id="on_loan">
    <transition event="loan.renew" target="on_loan"/>
    <transition event="loan.due" target="overdue">
      <send type="library:notices" target="overdue_notice" event="loan.overdue"/>
    </transition>
    <transition event="copy.returned" target="returned"/>
  </state>
  <state id="overdue">
    <transition event="copy.returned" target="returned"/>
  </state>
  <final id="returned"/>
</scxml>
```

A host whose publish step has not registered the processor, checking the
chart against the names the loan document declares, gets two findings:

```elixir
{:ok, machine} = Statifier.compile(loan_source)

Statifier.Send.Types.unsupported_sends(machine, nil) |> Enum.map(& &1.type)
#=> ["library:notices"]

Statifier.Chart.check_accepts(machine, ["loan.renew", "loan.due", "copy.returned", "patron.blocked"])
#=> %{unreachable: ["patron.blocked"], undeclared: []}
```

The first finding is S1. Without it the send would raise `error.execution`
the first time a loan fell due. The second is S15. Without it a
`patron.blocked` event sent to this execution would be discarded without a
word.

Drop the `type` from the send and the chart still compiles, and
`unsupported_sends/2` returns `[]`. The literal `target="overdue_notice"` is
not a target the built-in processor can parse. The first time a loan falls
due, the engine raises `error.execution` with data `{:invalid_target,
"overdue_notice"}`. That is row S2, and its twin is NONE: a runtime refusal
that a literal could have prevented.

## Keeping this table true

The `statifier` rows come from this search over `lib/`, which finds every
place the engine names `error.execution` or `error.communication`, in code
or in prose:

```sh
grep -rn -E 'error\.(execution|communication)' lib/
```

and this one, which narrows it to the raise sites:

```sh
grep -rn -E 'raise_platform\(|\{:raise, :platform|error_name\(|Event\.(external|platform)\("error|"error\.communication"' lib/
```

A new raise site, a new refusal reason in a sibling package, or a new
publish-time function changes a row here. So does a twin that moves from a
main branch to a release.
