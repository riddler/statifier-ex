# Upgrading from 2.5 to 2.11.0: what a host changes

This page is for a host: the application that compiles charts, starts
executions and supplies the services a chart reaches through `<invoke>` and
`<send>`. For each release from 2.6.0 to 2.11.0 it says what a host must
change to take the release, and then what a host may start doing with it.
Where a host must change nothing, the page says NONE.
[CHANGELOG.md](../CHANGELOG.md) says what the library changed; this page
does not repeat it.

No release in this range has a Breaking entry in the CHANGELOG. Every
"must change" from 2.6.0 to 2.10.0 is NONE. 2.11.0 changes some answers,
and its "must change" names the hosts each one reaches: a host whose
charts carry a `<send>` `<param>` with both `expr` and `location`, a host
that matched an error shape or rescued a raise the release replaces with a
named refusal, and a receiver that parsed a list or map parameter's text.
A dependency requirement of `{:statifier,
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

## 2.9.0

**A host must change:** NONE. `Statifier.MachineState` gains a
`last_selection` field, which a position blob does not carry, so a
position saved under 2.8.1 restores as before.

**A host may start:** running every publish-time check in one call.
Requires `{:statifier, "~> 2.9"}`.

- `Statifier.Publish.findings/2` takes a compiled chart and a declaration
  of the host's `send_types:`, `invoke_types:` and `accepts:`, and answers
  a list of findings, each naming its row of
  [Publish-time checks](publish-time-checks.md) with a `kind`, a location
  and its data. Like 2.7.0's functions, it refuses nothing: which finding
  refuses a publish is your decision.
- `Statifier.MachineState`'s `last_selection` reads `:selected` when the
  last external event selected a transition, `:none` when it selected
  none, and `nil` before any external event.

## 2.10.0

**A host must change:** NONE. A session that registers no send type sees
nothing new: no request is made, nothing is started, and `_ioprocessors`
holds the SCXML processor's entry alone. A `{:statifier, "~> 2.9"}`
requirement already accepts 2.10.0.

**A host may start:** the W3C Basic HTTP Event I/O Processor (ADR-0075).
Requires `{:statifier, "~> 2.10"}`.

- Register `{Statifier.Send.BasicHTTP, base_url: base}` in `:send_types`
  under both of its type strings,
  `"http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"` and
  `"basichttp"`. Each string's `_ioprocessors` entry holds one
  `"location"`: the base URL, `/`, and the session's `_sessionid`. A
  registration without `:base_url` refuses the session's start with an
  `ArgumentError`. The POSTs go through OTP's `:httpc` by default, and a
  `:transport` option names your own `Statifier.Send.BasicHTTP.Transport`;
  the package adds no dependency.
- The processor receives nothing on its own: your front answers at the
  base URL and hands each request to `Statifier.Send.BasicHTTP.decode/1`,
  which answers the event to enqueue or the reason to refuse the request.
- Every POST carries the send's deduplication key in an `scxml-send-key`
  header. A front that enqueues a request only when it has not already
  enqueued one with the same value delivers each send once; one that
  ignores the header sees at-least-once delivery.
- For a processor of your own, a `:send_types` value may now be
  `{module, opts}`: the options reach `deliver/3` and `cancel/2` under the
  plan context's `:opts` key. A processor may implement the optional
  `ioprocessors_entry/2`, which receives the type string and a context
  carrying the session id and the options, so its entry can address one
  session. A bare-module registration behaves as it did in 2.9.0.

The guide is [The Basic HTTP Event I/O Processor](basichttp.md). The
conformance corpus claims the processor's W3C documents and its case
schema gains `host.event_io_processors`; a sibling implementation
re-vendors the corpus at the `v2.10.0` tag, which is not a host step.

## 2.11.0

**A host must change:** only where one of these reaches it. A session that
registers no send type sees nothing new, and a `{:statifier, "~> 2.10"}`
requirement already accepts 2.11.0.

- A chart whose `<send>` carries a `<param>` with both `expr` and
  `location` no longer compiles: `Statifier.Validator.validate/2`, and so
  `Statifier.compile/2`, refuses it as `{:param_expr_and_location, name}`.
  Before 2.11.0 it compiled and the parameter took `location`. Drop one of
  the two attributes; keeping `location` keeps what the chart sent. A
  `<send>` `<param>` with neither attribute is refused as
  `{:param_no_value, name}`, where `Statifier.compile/2` raised
  `FunctionClauseError`.
- A fresh `Statifier.Session.start_link/2` whose `Statifier.Send.BasicHTTP`
  registration has no usable string `:base_url` answers
  `{:error, {:send_types, {:invalid_registration, type, {:missing_option, :base_url}}}}`,
  refused before any session process is spawned and so with no crash
  report. It answered `{:error, {%ArgumentError{}, stacktrace}}`. If your
  host matched the `ArgumentError` shape, match the named refusal instead.
  Every registration the processor can build its entry from still starts.
  A resume is not refused and does not change: its position carries the
  `_ioprocessors` entries it started with. `ioprocessors_entry/2` still
  raises `ArgumentError` for a direct caller.
- `Statifier.Lowering.lower/2`, and so `Statifier.compile/2`, answers
  `{:error, [%Statifier.Lowering.Error{reason: {:unexpected_root, name}}]}`
  for a document whose root is any SCXML element other than `<scxml>` (a
  `<state>`, a `<parallel>`, a `<final>`, a `<history>`, a `<transition>`,
  ...), where it raised `BadMapError`, and `{:unsupported_element, "scxml"}`
  for an `<scxml>` nested below the root, where it raised
  `FunctionClauseError`. If your host rescued either raise, match the error
  tuple instead.
- `Statifier.Validator.validate/2` no longer raises `FunctionClauseError`
  on a `<history>` whose compound parent has no `id`: a default target
  outside the parent is reported as `{:initial_not_descendant, target, nil}`.
  If your host matches that reason's parent id as a binary, handle `nil`
  too.
- `Statifier.Send.BasicHTTP` writes a parameter value that is a list or a
  map, and a `<content>` body that is a list, as JSON text
  (`["Dune",2]`, `{"title":"Dune"}`), where it wrote the value's
  `inspect/1` text; an undefined value inside such a list or map is
  written as JSON `null`. A list or map holding anything with no JSON form
  (a key that is not a string, a struct such as a `Date`, a tuple, a
  string that is not UTF-8) keeps its whole `inspect/1` text, and every
  scalar keeps its text. A `<content>` body that is a list is still sent as
  `text/plain`. If a receiver of your POSTs parsed the `inspect/1` text,
  read JSON instead. The inbound decoder is unchanged.

Three changes to a `Statifier.Send.BasicHTTP` delayed send ask nothing of a
host, but a chart sees them. A delayed send whose transport raises now
reaches the sender as `error.communication`, through
`Statifier.Session.failed_send/3` with the reason `{:raised, exception}`;
before, nothing reached the chart. A delayed send of a live session that is
busy when the delay passes is now POSTed; before, it was dropped. A cancel
the send's timer has received before its POST now always wins. An
immediate send whose transport raises is unchanged.

**A host may start:** refreshing a session's registered `_ioprocessors`
entries, refusing a registration in its own processor, and telling a
processor's own process that its session halted. Requires
`{:statifier, "~> 2.11"}`.

- `Statifier.MachineState.refresh_ioprocessors/1` recomputes a position's
  registered `_ioprocessors` entries from the registration it is stamped
  with, and answers `{:ok, machine_state}` or a registration's
  `{:error, reason}` with nothing changed; an entry that raises raises
  here. A host whose Basic HTTP base URL moved across a resume re-stamps
  the position with `Statifier.MachineState.put_send_types/2`, refreshes
  it, and then passes it as `:resume`. `Statifier.Session.refresh_ioprocessors/1`
  refreshes a live session and answers `:ok`, or, changing nothing,
  `{:error, reason}` for a registration its processor rejects
  (`{:error, {:missing_option, :base_url}}` for Basic HTTP without
  `:base_url`), `{:error, :not_running}` once the session has halted,
  `{:error, :recorded_session}` for a session started with `record: true`,
  or `{:error, {:ioprocessors_entry, type, exception}}` when an entry
  raises, the session running on at the position it held. The SCXML entry
  and an entry from a processor exporting only `ioprocessors_entry/1` are
  untouched, and a resume still reads the entries its position carries. A
  session that registers nothing answers success and sees nothing change.
  ADR-0075's Amendments of 2026-10-02 record both calls.
- A processor of yours may implement the optional
  `Statifier.Send.Processor` callback `check_registration/2`, which answers
  `:ok` or `{:error, reason}` for a registration's type string and options.
  A fresh start asks it for every registration whose module exports it and
  refuses the first one rejected with
  `{:error, {:send_types, {:invalid_registration, type, reason}}}`, before
  any session process is spawned; a resume does not ask it. A processor
  that does not implement it is not asked. ADR-0069's Amendment of
  2026-10-02 records the callback.
- A processor that holds a delay in a process it starts from `perform/2`
  can hand that process to `Statifier.Session.HaltNotice.watch/2`; the
  session sends it `{:statifier_halted, session, reason}` when it halts
  (`:done`, `:cancelled` or `:budget_exhausted`), at once when it already
  has. `HaltNotice.take/1` removes and returns the processes watched under
  a key. Outside a session `watch/2` keeps nothing and answers
  `:not_a_session`. The delay stays the processor's (ADR-0069 decision 4).

The conformance corpus changes too. The W3C Basic HTTP documents test518,
test519, test520 and test534 now check the decoded event their transition
takes, not its name alone, and a `statifier` case's step may carry an
optional `expect_position`, the position the chart holds after that step
(ADR-0076), with three new library cases. The corpus hash in
`conformance/manifest.json` moves, so a sibling implementation that
vendors the corpus re-vendors it at the `v2.11.0` tag, which is not a host
step.

## 2.12.0

**A host must change:** only where one of these reaches it.

- `Statifier.Send.BasicHTTP` sends a `<content expr>` that evaluates to a
  struct as the body, its `inspect/1` text as `text/plain`. Before
  2.12.0 such a content took the form arm. A struct that does not
  enumerate as parameter pairs (a `Date`, for example) made planning the
  send raise (`Protocol.UndefinedError` for a `Date`), the session
  performing it exited, and no request was made. A struct that does
  enumerate as pairs (a `MapSet` of two-element tuples, for example) was
  sent as an `application/x-www-form-urlencoded` body of those pairs; a
  receiver of such a send now gets the struct's `inspect/1` text as
  `text/plain` instead, the text it already reads for a struct inside a
  list or a map. A session that registers no send type sees nothing new.

**A host may start:** nothing new.
