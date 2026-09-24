# Upgrading from 2.5 to 2.8.1: what a host changes

This page is for a host: the application that compiles charts, starts
executions and supplies the services a chart reaches through `<invoke>` and
`<send>`. For each release from 2.6.0 to 2.8.1 it says what a host must
change to take the release, and then what a host may start doing with it.
Where a host must change nothing, the page says NONE.
[CHANGELOG.md](../CHANGELOG.md) says what the library changed; this page
does not repeat it.

No release in this range has a Breaking entry in the CHANGELOG, so every
"must change" below is NONE. A dependency requirement of `{:statifier,
"~> 2.5"}` already accepts every version on this page. Raise it only when
your host calls a function a later release added: each section names the
lowest requirement its functions need.

## 2.6.0

**A host must change:** NONE. A session started without `:send_types`
behaves as it did in 2.5: a `<send>` whose `type` is not built in still
raises `error.execution`.

**A host may start:** handing `<send>` types to its own processors
(ADR-0069). Requires `{:statifier, "~> 2.6"}`.

1. Write a module per type that implements `Statifier.Send.Processor`:
   `deliver/3` and `cancel/2` are required and pure; the optional
   `perform/2` does the delivery, and the optional `ioprocessors_entry/1`
   fills the type's `_ioprocessors` entry. `perform/2` may be called more than once for the same send, so
   make it idempotent. A delayed send is your processor's timer: the
   session schedules nothing for it.
2. Pass the map to `Statifier.Session.start_link/2` as
   `send_types: %{"my-type" => MyProcessor}`, and add
   `inherit_send_types: true` if the children a chart starts through
   `<invoke>` should get the same map. A map that names a built-in type
   (`"scxml"`, the SCXML Event I/O Processor URI, or `nil`) makes the
   session refuse to start with
   `{:error, {:send_types, {:built_in_types, types}}}`.
3. When your processor cannot deliver a send and the sender still exists,
   call `Statifier.Session.failed_send/3`; the chart then sees
   `error.communication` with the send's id. When the sender has finished,
   that call writes nothing and recording the miss is yours. A host
   without a session process makes the same write with
   `Statifier.Interpreter.deliver_internal/5`.
4. At publish time, refuse a chart that names a type you never registered:
   `Statifier.Send.Types.unsupported_sends/2`, called with the compiled
   chart and `Statifier.Send.Types.from_send_types/1` of the map you will
   start it with, lists each such `<send>` with its location.
5. A resumed session does not remember which processor holds a delayed
   send. Routing a `<cancel>` for a send handed over before the position
   was saved is yours, as re-arming timers after a resume already is.

The guide is the "`<send>` half" of [Extending](extending.md).

## 2.6.1

**A host must change:** NONE. The release adds conformance cases under
`conformance/`, which is not in the Hex package.

**A host may start:** nothing new. A sibling implementation that vendors
the corpus re-vendors it at the `v2.6.1` tag; that is not a host step.

## 2.7.0

**A host must change:** NONE.

**A host may start:** checking a chart's events at publish time
(ADR-0071). Requires `{:statifier, "~> 2.7"}`.

- `Statifier.Chart.events/1` gives a compiled chart's event vocabulary:
  every event descriptor on a transition from a state some path can enter,
  as authored.
- `Statifier.Chart.check_accepts/2` compares a declared list of the event
  names the chart accepts with that vocabulary and answers
  `%{unreachable: [...], undeclared: [...]}`. `unreachable` holds the
  declared names the chart can never select on; `undeclared` holds the
  descriptors the declaration leaves out. With `nil` for the declaration
  both lists are empty. To ask whether one event name reaches the chart,
  call `check_accepts(machine, [name])` and read `unreachable`.

Both functions report and refuse nothing: which list refuses a publish is
your decision. [Publish-time checks](publish-time-checks.md) lists the
runtime refusal each one stands in front of.

## 2.8.0

**A host must change:** NONE.

**A host may start:** comparing two compiled charts before publishing the
second, and checking whether one execution's position survives the edit
(ADR-0072). Requires `{:statifier, "~> 2.8"}`.

- `Statifier.Chart.diff/3` takes the published chart, the candidate and
  an optional `mapping:` of renamed state ids (old id to new id), and
  answers `%{class: class, reasons: reasons}` with a class of
  `:identical`, `:compatible`, `:mapped` or `:breaking`. It raises
  `ArgumentError` on an option other than `mapping:` or an invalid
  mapping.
- `Statifier.Position.compatible_at?/3` takes the two charts and one
  execution's `Statifier.Position.export/1` map and answers `true` only
  when that execution's position is untouched by the edit. Both charts
  must carry their source, which `Statifier.compile/2` keeps; a chart
  built without it answers `false`.

Neither function moves an execution, and the library calls neither.
Whether an execution moves to the new chart, and when, stays your
decision.

## 2.8.1

**A host must change:** NONE.

An `<invoke>` whose type is `http://www.w3.org/TR/scxml`, the SCXML type
URI without its trailing slash, now starts an SCXML child session; before
2.8.1 it raised `error.execution`. A handler your host registered under
`:invoke_handlers` for that exact string still receives it, since a
registered handler takes precedence over the built-in one. If a chart of
yours carries that spelling and your host relied on the
`error.execution`, that chart now starts a child instead. A host that
needs the new behaviour requires `{:statifier, "~> 2.8 and >= 2.8.1"}`.

**A host may start:** nothing new. The corpus changes follow 2.6.1's
rule: a sibling implementation re-vendors at the `v2.8.1` tag.
