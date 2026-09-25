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
repo), `statifier_router` and `statifier_blocks`. Each package's section
names the kinds of refusal it leaves out, and why. Every other refusal in
the package is a row.

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

Five kinds of refusal in this package have no row, because none is a
refusal of a chart at run time:

- The compile pipeline's own refusals: `Statifier.compile/2` and what it
  runs (the parser, the lowering and `Statifier.Validator`). They are
  publish-time checks themselves.
- The stored-form codecs and the replay tool: `to_binary` and
  `from_binary` on `Statifier.Chart`, `Statifier.Position`,
  `Statifier.Machine.Identity` and `Statifier.Session.Recording`,
  `Statifier.Position.export/1` and `Statifier.Position.import/2`, and
  `Statifier.Replay.run/1`. They refuse a blob or a recording a host
  stored, not a chart.
- Answers to a host's own call: `Statifier.send_event/2` on a machine
  that is no longer running (`{:error, :not_running}`),
  `Statifier.Session.recording/1` and `subscribe/3` on a session that
  does not record, and the start options that `Statifier.start_session/2`
  and `Statifier.Session.start_link/2` refuse before an execution begins.
- A host handler's own `perform/2` answer. `Statifier.Session` does not
  read what an invoke handler's `perform/2` returns, and
  `Statifier.Invoke.SyncHandler.Adapter.perform/3`'s
  `{:session_not_registered, id}` is that kind of answer. A sync handler's
  `{:error, reason}`, and the adapter's `{:unknown_invoke_type, type}`,
  do reach the chart: they are reported as S10.
- Each `ArgumentError` raised when a host breaks a contract: a send
  processor's `ioprocessors_entry/1` that answers something other than a
  string-keyed map, a sync handler module that does not export
  `invoke_types/0`, or a `:datamodel` start option with a key the engine
  refuses. That is a host programming fault.

The build tasks under `lib/mix/` are tooling and are not part of the
runtime.

The one function a host calls for this table is
`Statifier.Publish.findings/2` (statifier main, next release): it runs
every check this package holds over a compiled chart and the host's
declaration, and returns findings that each name their row here
(`docs/adr/0073-one-publish-findings-function-holds-every-publish-time-check.md`).
Today it composes the twins of S1 and S15; each NONE row that a literal
decides lands inside it as one check, and its cell changes when it does.

| # | Refusal | Raised by | Record | Literal? | Twin |
|---|---|---|---|---|---|
| S1 | `<send>` names a `type` the session never registered: `error.execution`, data `{:unsupported_type, type}`, carrying the send's `sendid` | `Statifier.Machine.Content.Send`, raised through `Statifier.Interpreter.Content`; `Statifier.Session.Effects` for an effect a caller injects through `Statifier.Session.interpret/2` | `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md`, `docs/adr/0069-host-registered-send-types.md` | part: yes for `type`, no for `typeexpr` | `Statifier.Send.Types.unsupported_sends/2` (statifier, since 2.6.0); the router composes it as `StatifierRouter.Routes.unsupported_types/2` (statifier_router 0.2.0) |
| S2 | `<send>` with a built-in type writes a `target` the engine cannot parse: `error.execution`, data `{:invalid_target, target}`, carrying `sendid` | `Statifier.Machine.Content.Send`, through `Statifier.Interpreter.Content`; `Statifier.Session.Effects` for an injected effect | `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md` | part: yes for `target`, no for `targetexpr` | NONE |
| S3 | `<send>` to a route that is missing from the snapshot the driver declared: `error.communication`, data `{:unreachable_target, target}`, carrying `sendid` | `Statifier.Machine.Content.Send`, through `Statifier.Interpreter.Content` | `docs/adr/0048-send-reachability-judged-against-a-route-snapshot.md` | part: yes for a `#_<invokeid>` target that no `<invoke id>` in the chart declares; no for a session id or `#_parent`, which depend on who started the execution | NONE |
| S4 | A send whose target session does not exist or cannot be reached, found at delivery (no snapshot declared, a delayed send when its timer fires, an injected effect): `error.communication` carrying `sendid` | `Statifier.Session` (the `deliver` path and `communication_error`) | `docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`, `docs/adr/0048-send-reachability-judged-against-a-route-snapshot.md` | no | NONE |
| S5 | A host-registered send processor cannot deliver: `error.communication` carrying `sendid`, written by the host | `Statifier.Session.failed_send/3`; `Statifier.Interpreter.deliver_internal/5` when no session process is running | `docs/adr/0069-host-registered-send-types.md` (decision 5) | depends on the processor: the router's are RT1 to RT9, RT18 to RT22, RT24 and RT25 | NONE in statifier, which cannot see a processor's routes; the router's twins are in those rows |
| S6 | `<invoke>` names a `type` the session never registered: `error.execution` with the invocation as its origin and no data; no child starts | `Statifier.Interpreter` (`reject_unregistered_type`); `Statifier.Session.Effects` (`plan_invoke`) | `docs/adr/0051-invoke-handlers-are-registered-per-session.md` | part: yes for `type`, no for `typeexpr` | NONE for a chart; a block document reports it through `StatifierBlocks.Compiled`'s `invoke_types` field and the `:known_invoke_types` lint of `StatifierBlocks.Compiler.compile/3`, a warning only (statifier_blocks 0.32.0) |
| S7 | A registered invoke handler's `start/2` answers `{:error, _}`: `error.execution` with the invocation as its origin | `Statifier.Session.Effects` (`plan_invoke`) | `docs/adr/0051-invoke-handlers-are-registered-per-session.md` | no: the handler decides | NONE |
| S8 | An `<invoke>` argument fails to evaluate: `error.execution` carrying the reason; the invocation is abandoned | `Statifier.Interpreter` (`abort_invocation`) | `docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md` | part: the argument's own failure is one of S12 to S14 | NONE; S12 to S14 say which of those failures a literal decides |
| S9 | A child fails to start (the built-in `scxml` invoke's `src` or `<content>` does not resolve or compile, or `Statifier.start_session/2` fails): `error.communication` with the invocation as its origin | `Statifier.Session` (`start_child`, `invoke_error`); `Statifier.Invoke.Source.resolve/2` | `docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md` | part: yes for an inline `<content>` child that does not compile; no for a `src`, which the host's resolver answers | NONE (for block documents see B1 to B3) |
| S10 | A started invocation fails for good: `error.communication.invoke.<invokeid>` | `Statifier.Invoke.Answer.failed/4`, through `Statifier.Session.failed_invocation/3` | `docs/adr/0068-permanent-invoke-failure-is-a-suffixed-error-communication.md` | no | NONE |
| S11 | A location write whose root the datamodel does not declare (`<assign>`, an `idlocation`, a `<finalize>` namelist write): `error.execution`, data `{:unbound_location, location}`; a root beginning with `_` gives `{:system_variable, root}` instead | `Statifier.Interpreter.Datamodel.write_location/4`, called by `Statifier.Machine.Content.Assign`, `Statifier.Machine.Content.Send` and `Statifier.Interpreter` | `docs/datamodel.md` (the root of a written path must already exist) | yes, when the location's root is a name and the chart's `<data>` ids are in the source | NONE for a chart; for a block document, `StatifierBlocks.Datamodel.findings/4`, reached through `StatifierBlocks.Publish.findings/3`, reports it as an `:info` advisory and does not refuse (statifier_blocks main, next release) |
| S12 | A read of a root the datamodel does not declare: `error.execution` carrying predicator's undefined-variable error, wherever the expression sits (`cond`, executable content, `<data>`, `<donedata>`, a global `<script>`) | the raise site of the expression: `Statifier.Interpreter.Selection`, `Statifier.Interpreter.Content`, `Statifier.Interpreter.Datamodel`, `Statifier.Interpreter.ExitEntry`, `Statifier.Interpreter` | `docs/architecture.md` (design principle 3), `docs/datamodel.md` | yes, when the root is neither declared by a `<data>` nor a system variable | NONE for a chart; for a block document, `StatifierBlocks.Publish.findings/3` reports an undeclared path as an `:info` advisory and does not refuse (statifier_blocks main, next release) |
| S13 | An expression that fails to compile, where the compiler defers the failure to run time (`<data expr>`, `<assign expr>`, `<script>` in content or at the top level, a `namelist` entry): `error.execution` carrying the compile error | `Statifier.Compiler` stores the failure as `{:invalid, error}` on the compiled node; the raise sites are `Statifier.Interpreter.Datamodel`, `Statifier.Interpreter.Content` and `Statifier.Interpreter` | `docs/datamodel.md` (spec 5.9.4 allows either a load-time or a run-time rejection, and the engine takes the run-time one); `docs/adr/0026-script-as-predicator-statement-programs.md` for `<script>` | yes | NONE: the compiled machine carries each failure, but no function lists them. Every other expression that fails to compile fails `Statifier.compile/2` itself, which is its own publish-time check |
| S14 | An expression that compiles and then fails to evaluate on the data it meets (a type error, a `<foreach>` array that is not a list, a `delayexpr` of the wrong shape), or a `<send>` whose literal `delay` is not a duration: `error.execution` carrying the reason | `Statifier.Interpreter.Selection`, `Statifier.Interpreter.Content`, `Statifier.Interpreter.Datamodel`, `Statifier.Interpreter.ExitEntry` or `Statifier.Interpreter`, wherever the expression sits | `docs/architecture.md` (design principle 3); `docs/adr/0021-donedata-content-expr-failure-yields-no-data.md` for `<donedata>`; `docs/adr/0036-send-argument-failure-discards-the-message.md` for `<send>` | part: yes for a literal `delay` that is not a duration, which compiles and is refused only when the send runs, with data `{:invalid_delay, delay}`; no for the rest, which depends on the data | NONE |
| S15 | An event the chart has no transition for: not refused. The engine discards it, as the SCXML algorithm does | `Statifier.Interpreter.Selection` (no transition is selected) | `docs/adr/0071-chart-event-vocabulary-and-accepts-check.md` | yes, when the sender's event name is a literal | `Statifier.Chart.check_accepts/2` and `Statifier.Chart.events/1` (statifier 2.7.0); the router applies them in RT13 |
| S16 | A macrostep that does not reach quiescence within the round budget (`max_macrostep_rounds`, default 10,000): the fold stops and appends a `{:budget_exhausted, %Statifier.Effect.BudgetExhausted{}}` effect, and a session halts with `:budget_exhausted` | `Statifier.Interpreter` (the macrostep fold); `Statifier.Session` | `docs/adr/0019-macrostep-round-budget.md` | part: yes for a cycle of eventless transitions none of which carries a `cond`; no in general, where the data a `cond` reads decides whether the cycle ends | NONE |
| S17 | A `<foreach>` whose `item` or `index` is not a legal variable name, or begins with `_`: `error.execution`, data `{:illegal_item_name, name}`, `{:illegal_index_name, name}` or `{:system_variable, name}`; the loop does not run | `Statifier.Machine.Content.Foreach` (`check_name`, `check_index`), through `Statifier.Interpreter.Content` | no record names it; `docs/datamodel.md` and the module's own documentation (spec 4.6.3) | yes: both names are literal attributes, and neither the compile pipeline nor `Statifier.Validator` checks them | `Statifier.Publish.findings/2` (statifier main, next release) |
| S18 | A `<script>`, in executable content or at the top level, that writes a root beginning with `_`: `error.execution`, data `{:system_variable, root}` | `Statifier.Evaluator.run_program/2`, raised through `Statifier.Interpreter.Content` or `Statifier.Interpreter` | `docs/adr/0026-script-as-predicator-statement-programs.md`; `docs/datamodel.md` ("Upstreaming to predicator", item 4) | yes: the script's assignment targets are names in its source | `Statifier.Publish.findings/2` (statifier main, next release) |
| S19 | A literal write location (`<assign location>`, an `idlocation`, a `<finalize>` namelist write) that is not an assignable location: it does not parse; or it names something that cannot be assigned: a literal, a string, a list, a function call, or an arithmetic, comparison, logical or unary expression (predicator's `LocationError` type `:not_assignable`), or a membership test, an object literal, a cast, a duration or a relative date (`:invalid_node`, for example `copies in copies`, `{}`, `copies::integer`, `3d`, `3d ago`); or a bracket key is neither a string, an integer nor a variable (`:computed_key`, `copies[1 + 1]` or `copies[true]`). It compiles, and the write fails with `error.execution` carrying the error | `Statifier.Interpreter.Datamodel` (`resolve_location`, through `write_location/4`) | no record names it; `docs/datamodel.md` | yes: the location is a literal attribute, and none of these depends on the data | NONE |

## statifier_router

At the executor seam, a refusal on the send side reaches the sending
execution as `error.communication` carrying the send's `sendid`
(`StatifierRouter.SendHandler`). The step that made the send is still
committed. The routing side's outcomes are what `StatifierRouter.route/3`
returns, and they are written to the binding's ledger.

A source invoke's refusals (RT15 to RT17) go back to the host's invoke
handler, which decides how the chart hears of them.

A delivery's own errors (RT3, RT20, RT21 and RT24) are met on both sides.
`StatifierRouter.route/3` returns them, and a send to the execution target
hears them as `error.communication`. That send's delivery rolls back to a
savepoint of its own, and the sending step stands
(`StatifierRouter.Delivery.deliver_event/4`).

Four kinds of router refusal have no row:

- Configuration-time checks, made before any event is routed: the
  constructors `StatifierRouter.Config.new/1`,
  `StatifierRouter.Binding.new/1` and
  `StatifierRouter.Resolver.Static.new/1`; the `ArgumentError`s
  `StatifierRouter.Broadway.start_link/1` raises for its options, and
  whatever `Broadway.start_link/2` itself answers; and the
  `ArgumentError`s `StatifierRouter.Migrations.up/1` and `down/1` raise for
  their options.
- Each `ArgumentError` the router raises for a host callback that answers
  outside its contract (a resolver, a chart resolver, a delivery module, a
  `StatifierRouter.Contracts.check/3` lookup), or for a schema handed to
  `StatifierRouter.Config.queryable/2` or `put_meta/2` that is not one of
  the package's. That is a host programming fault.
- The maintenance sweeps. `StatifierRouter.Addresses.reap/3` refuses bad
  options and passes on an error from
  `StatifierPersistence.Storage.fetch_execution/2`, and a
  `StatifierRouter.PinSource` raises when it cannot count. Neither is a
  chart or a message defect.
- The publish-time functions themselves: `StatifierRouter.Contracts` and
  `StatifierRouter.Routes`.

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
| RT15 | A source invoke carries no `binding` param: `{:error, {:missing_binding_param, params}}`, returned to the host's invoke handler | `StatifierRouter.SourceInvoke.start/3` | `docs/adr/0007-the-source-invoke.md` (section 1) | yes, when the `<invoke>` writes no `binding` param | NONE |
| RT16 | A source invoke names a binding the configuration does not hold: `{:error, {:unknown_binding, binding_id}}`, returned to the host's invoke handler | `StatifierRouter.subscribe/3`, reached through `StatifierRouter.SourceInvoke.start/3` | `docs/adr/0007-the-source-invoke.md` | part: yes when the `binding` param is a literal, given the host's configuration; no when it is an expression | NONE |
| RT17 | A source invoke from an execution with no address row: `{:error, {:unaddressed_execution, execution_id}}`, returned to the host's invoke handler | `StatifierRouter.subscribe/3`, reached through `StatifierRouter.SourceInvoke.start/3` | `docs/adr/0007-the-source-invoke.md` (section 6) | no: it depends on how the execution was created | NONE |
| RT18 | A delayed send of the router's type when the configuration has no timer queue: `{:error, {:no_timer_queue, send_id}}` | `StatifierRouter.SendHandler` (`schedule`) | `docs/adr/0005-routes.md` (section 5) | yes, given the host's configuration: a literal `delay` on a send of the router's type | NONE |
| RT19 | A registered route's adapter answers `{:error, reason}`: the handler returns it, and at the executor seam it reaches the sender as `error.communication` carrying `sendid` | `StatifierRouter.SendHandler` (`hand_off`) | `docs/adr/0005-routes.md` (sections 3 and 7) | no: the adapter's service decides | NONE |
| RT20 | The configuration's `:on_complete` route fails for an execution that has just finished: `{:error, {:on_complete, route_name, reason}}`; the delivery rolls back so it can be redriven | `StatifierRouter.Delivery` (`complete`) | no record names it; `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (section 7) governs an error that is not an outcome, and `StatifierRouter.Config` documents the option | no | NONE |
| RT21 | The host's chart resolver has no chart for the content hash an existing execution started on: `{:error, {:chart_not_resolved, content_hash}}`; the delivery rolls back | `StatifierRouter.Delivery` (`chart`) | `docs/adr/0002-addressing.md` ("A chart the host cannot resolve is an error, not an outcome"); `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (section 7) | no: it depends on the host's store | NONE |
| RT22 | The send handler runs with no configuration installed in the process: `{:error, {:no_config, StatifierRouter.SendHandler}}` | `StatifierRouter.SendHandler.fetch_config/0` | no record names it; `StatifierRouter.SendHandler.fetch_config/0` documents it | no: a host's code does this, not a chart | NONE |
| RT23 | `route/3` is handed a malformed message or options: `{:error, :no_message_id}`, `{:error, {:invalid_event, event}}`, `{:error, {:invalid_opts, opts}}`, `{:error, {:unknown_key, name}}` or `{:error, {:invalid_value, :now, value}}`; `StatifierRouter.Webhook.handle/3` adds `{:error, {:invalid_request, request}}` | `StatifierRouter.route/3`; `StatifierRouter.Webhook` | `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (section 7) | no: the message and the host's call decide | NONE |
| RT24 | The delivery's persistence step answers `{:error, reason}`: `StatifierPersistence.Executions.create/4`, `StatifierPersistence.Executions.step/5` or `StatifierPersistence.Storage.fetch_execution/2` refuses, and the delivery rolls back and returns `reason` unchanged, whatever statifier_persistence answered. A host that configures its own delivery module in place of `StatifierRouter.Delivery` answers for that module's errors, which `StatifierRouter.route/3` returns the same way | `StatifierRouter.Delivery` (`create`, `existing`, `step`); `StatifierRouter.route/3` for a host's delivery module | `docs/adr/0004-the-refusal-and-drop-vocabulary.md` (section 7) | no: the host's store decides | NONE |
| RT25 | The configured timer queue refuses: its `schedule/2` or `cancel/3` answers `{:error, reason}`, and the handler returns it unchanged, whatever the queue answered. At the executor seam the sender hears `error.communication`, carrying `sendid` for a delayed send and none for a `<cancel>` | `StatifierRouter.SendHandler` (`schedule`, `dequeue`), through the host's `StatifierRouter.TimerQueue` | `docs/adr/0005-routes.md` (section 5) | no: the host's queue decides | NONE |

## statifier_blocks

A `core.subchart` names its child by a literal document id. When the child
cannot start, the chart hears `error.communication.invoke.<block id>`
carrying a reason. The in-memory handler,
`StatifierBlocks.Runtime.Subchart`, raises that event itself with one of
three reasons, and never answers `{:error, _}`, because the engine would
turn that into an `error.execution` with no data and the reason would be
lost. The durable handler, `StatifierBlocks.Runtime.DurableSubchart`,
answers its dispatch with the same three reasons as a failure list, which
statifier_persistence's driver turns into the same event; the driver adds a
fourth reason of its own (B6).

Three kinds of refusal have no row. A `core.map` compiles to one
`<invoke>`, and the fan-out handler that starts its children is not in this
package (`docs/adr/0009-fan-out-block-type.md`): its refusals belong to the
package that ships it. Every refusal outside
`lib/statifier_blocks/runtime/` belongs to authoring or to publishing:
decoding, editing, compiling and the publish-time functions, which are the
checks themselves, and `StatifierBlocks.Runtime.FixtureRuns`, which runs an
author's fixtures. And each `ArgumentError` the two handlers raise for a
host callback or a dispatch context outside its contract is a host
programming fault.

| # | Refusal | Raised by | Record | Literal? | Twin |
|---|---|---|---|---|---|
| B1 | The child document id resolves to nothing: reason `unknown_document` | `StatifierBlocks.Runtime.Subchart.Resolution.resolve/3` | `docs/adr/0008-durable-subchart-handler.md` | yes | `StatifierBlocks.Graph.check/2`, a `:graph` error anchored on the block's `chart` field (statifier_blocks main, next release) |
| B2 | The child document does not compile for child use: reason `child_compile_findings` | `StatifierBlocks.Runtime.Subchart.Resolution.resolve/3` | `docs/adr/0008-durable-subchart-handler.md` | yes: the child's own document | the child's own publish, `StatifierBlocks.Publish.findings/3` and then `StatifierBlocks.Compiler.compile/3` (statifier_blocks main, next release) |
| B3 | The host's resolver reports a cycle across documents: reason `cycle_refused` | `StatifierBlocks.Runtime.Subchart.Resolution.resolve/3` | `docs/adr/0008-durable-subchart-handler.md` | yes: every id in the cycle is a literal | NONE. A document that names itself is refused by its own compile (`StatifierBlocks.Compiler.SelfReference`); a longer cycle is not checked at publish |
| B4 | A parent routes on an outcome the child does not declare: not refused. The child's answer falls to the parent's unconditioned arm | the generated chart | `docs/adr/0008-durable-subchart-handler.md` (the Amendment of 2026-09-22) | yes | `StatifierBlocks.Graph.check/2` when the parent is published and `StatifierBlocks.Graph.consumers_broken/2` when the child is (statifier_blocks main, next release) |
| B5 | A parent reads a done-data key the child does not declare: not refused | the generated chart | `docs/adr/0008-durable-subchart-handler.md` (the Amendment of 2026-09-22) | yes | `StatifierBlocks.Graph.check/2` and `StatifierBlocks.Graph.consumers_broken/2`, an `:error` (statifier_blocks main, next release). When the parent's `collect_type` names a type and the parent was compiled without `:datamodel`, the keys are not known, and both report the read as unchecked with a `:warning` |
| B6 | The durable path cannot create the child's execution: reason `child_execution_creation_failed` | `StatifierPersistence.Driver` in statifier_persistence, from its own `start_child` refusals | `docs/adr/0008-durable-subchart-handler.md` (decision 5, which records this reason under an older spelling) | no: the host's store decides | NONE |

A block document is also a chart once it compiles, so rows S1 to S19 apply
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

Those two searches find the platform events. The census behind every table
also ran this search over `lib/` in each of the three packages, which
matches every `{:error` in any form (a literal reason, a variable passed
on, a callback's spec), every `raise`, every `else` clause of a `with`, and
the router's and the blocks handlers' own outcome tags:

```sh
grep -rn -E '\{:error\b|\braise\b|^[[:space:]]*else\b|\{:(dropped|key_refused|send_refused|send_undelivered|refuse|failed)\b' lib/
```

A function that returns a callback's answer as its last expression carries
no `{:error` of its own, so each callback whose spec the search matched
was followed to the function that calls it. Every refusal the search led
to is a row or falls in one of the kinds of refusal a section names as left
out, except four that are open for a later revision of this page: a `cond`
that evaluates to something other than a boolean; the refusals of the
`Statifier.Testing` helpers; the write step's refusals from
`Predicator.ContextLocation.put/3` (predicator 9.0.0), `:not_a_container`
and `:invalid_index`, which depend on the data because a negative index
writes to a map and is refused only for a list; and a variable bracket key
that is unbound or is neither a string nor an integer (`:undefined_variable`,
`:invalid_key`).

A new raise site, a new refusal reason in a sibling package, or a new
publish-time function changes a row here. So does a twin that moves from a
main branch to a release.
