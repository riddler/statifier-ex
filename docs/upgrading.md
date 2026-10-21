# Upgrading from 2.5 to 2.16.0: what a host changes

**Read this to:** learn what your host must change to take each release from
2.6.0 to 2.16.0, and what the release lets you start to do.

**Short version:** only 2.14.0 has a Breaking entry in the CHANGELOG. Every
"must change" from 2.6.0 to 2.10.0 is NONE. Later releases reach only the
hosts named in each section.

A host is the application that compiles charts, starts executions and
supplies the services a chart reaches through `<invoke>` and `<send>`. Each
section gives what the host must change (NONE when nothing), what it may
start to do, and what else changed. The [Changelog](../CHANGELOG.md) says
what the library changed.

A dependency requirement of `{:statifier, "~> 2.5"}` already accepts every
version on this page. Raise it only when your host calls a function that a
later release added. Each section names the lowest requirement that its
functions need.

**Who each later release reaches** (2.6.0 to 2.10.0 reach no one):

| Release | Reaches |
|---|---|
| 2.11.0 | a `<send>` `<param>` with both `expr` and `location`; a match on an error shape, or a rescue of a raise, that a named refusal replaces; a receiver that parsed a list or map parameter as text |
| 2.12.0 | a Basic HTTP send whose `<content expr>` is a struct; a compound state with no `id` and a bad `initial`; a document refused for a shared `id`; predicator at 9.0 to 9.3; a `\u` or `\U` escape in a string literal |
| 2.12.1 | nothing (documentation only) |
| 2.13.0 | a `<state>` with no `id` and a bad `initial`; a document refused for a shared `id`; a host that waited for a further halted message after a failed send of a budget-halted session |
| 2.14.0 | a repeated attribute on one element, or exhaustive matching on validator reasons (Breaking); a cancel of a budget-halted session with events queued; a host that waited for a further halted message after a delayed send fired into a budget-halted session |
| 2.15.0 | a call to a function that is not `In`, a predicator builtin or a declared function; exhaustive matching on compiler error reasons |
| 2.16.0 | predicator at 9.4 |

## 2.6.0

**A host must change:** NONE. A session started without `:send_types`
behaves as it did in 2.5: a `<send>` whose `type` is not built in still
raises `error.execution`.

**A host may start:** handing `<send>` types to its own processors.
Requires `{:statifier, "~> 2.6"}`.

1. Write a module per type that implements `Statifier.Send.Processor`.
   - `deliver/3` and `cancel/2` are required and pure.
   - The optional `perform/2` does the delivery. The session can call it
     more than once for the same send, so make it idempotent.
   - The optional `ioprocessors_entry/1` fills the `_ioprocessors` entry of
     the type.
   - A delayed send is the timer of your processor. The session schedules
     nothing for it.
2. Pass the map to `Statifier.Session.start_link/2` as
   `send_types: %{"my-type" => MyProcessor}`.
   - Add `inherit_send_types: true` if the children that a chart starts
     through `<invoke>` must get the same map.
   - A map that names a built-in type (`"scxml"`, the SCXML Event I/O
     Processor URI, or `nil`) makes the session refuse to start with
     `{:error, {:send_types, {:built_in_types, types}}}`.
3. When your processor cannot deliver a send and the sender still exists,
   call `Statifier.Session.failed_send/3`. The chart then sees
   `error.communication` with the send's id.
   - When the sender has finished, that call writes nothing, and you must
     record the miss.
   - A host without a session process makes the same write with
     `Statifier.Interpreter.deliver_internal/5`.
4. At publish time, refuse a chart that names a type you did not register.
   Call `Statifier.Send.Types.unsupported_sends/2` with the compiled chart
   and `Statifier.Send.Types.from_send_types/1` of the map you will start
   it with. It lists each such `<send>` with its location.
5. After a resume, you must route a `<cancel>` for a send handed over
   before the position was saved, and you must re-arm timers. A resumed
   session does not remember which processor holds a delayed send.

Guide: the section "The `<send>` half: host-registered send types" of
[How to extend Statifier: `<invoke>` handlers and `<send>` types](extending.md).

Decision: ADR-0069

## 2.6.1

**A host must change:** NONE. The release adds conformance cases under
`conformance/`, which is not in the Hex package.

**A host may start:** nothing new. A sibling implementation that vendors
the corpus re-vendors it at the `v2.6.1` tag. That is not a host step.

## 2.7.0

**A host must change:** NONE.

**A host may start:** checking a chart's events at publish time. Requires
`{:statifier, "~> 2.7"}`.

- `Statifier.Chart.events/1` gives a compiled chart's event vocabulary:
  every event descriptor on a transition from a state that some path can
  enter, as authored.
- `Statifier.Chart.check_accepts/2` compares a declared list of the event
  names the chart accepts with that vocabulary. It answers
  `%{unreachable: [...], undeclared: [...]}`.
  - `unreachable` holds the declared names that the chart can never select
    on.
  - `undeclared` holds the descriptors that the declaration leaves out.
  - With `nil` for the declaration, both lists are empty.
  - To ask whether one event name reaches the chart, call
    `check_accepts(machine, [name])` and read `unreachable`.

Both functions report and refuse nothing. You decide which list refuses a
publish.

Next: [Publish-time checks: every runtime refusal and its twin](publish-time-checks.md)
lists the runtime refusal that each function checks first.

Decision: ADR-0071

## 2.8.0

**A host must change:** NONE.

**A host may start:** comparing two compiled charts before publishing the
second, and checking whether one execution's position survives the edit.
Requires `{:statifier, "~> 2.8"}`.

- `Statifier.Chart.diff/3` takes the published chart, the candidate and an
  optional `mapping:` of renamed state ids (old id to new id). It answers
  `%{class: class, reasons: reasons}` with a class of `:identical`,
  `:compatible`, `:mapped` or `:breaking`. It raises `ArgumentError` on an
  option other than `mapping:` or an invalid mapping.
- `Statifier.Position.compatible_at?/3` takes the two charts and the
  `Statifier.Position.export/1` map of one execution. It answers `true`
  only when the edit does not touch the position of that execution. Both
  charts must carry their source, which `Statifier.compile/2` keeps. A
  chart built without its source answers `false`.

Neither function moves an execution, and the library calls neither. You
decide whether and when an execution moves to the new chart.

Decision: ADR-0072

## 2.8.1

**A host must change:** NONE.

An `<invoke>` whose type is `http://www.w3.org/TR/scxml`, the SCXML type
URI without its trailing slash, now starts an SCXML child session. Before
2.8.1 it raised `error.execution`.

- A handler that your host registered under `:invoke_handlers` for that
  exact string still receives the invoke. A registered handler takes
  precedence over the built-in one.
- If a chart of yours carries that spelling and your host relied on the
  `error.execution`, that chart now starts a child instead.
- A host that needs the new behaviour requires
  `{:statifier, "~> 2.8 and >= 2.8.1"}`.

**A host may start:** nothing new. The corpus changes follow the rule of
2.6.1: a sibling implementation re-vendors the corpus at the `v2.8.1` tag.
That is not a host step.

## 2.9.0

**A host must change:** NONE. `Statifier.MachineState` gains a
`last_selection` field. A position blob does not carry this field, so a
position saved under 2.8.1 restores as before.

**A host may start:** running every publish-time check in one call.
Requires `{:statifier, "~> 2.9"}`.

- `Statifier.Publish.findings/2` takes a compiled chart and a declaration
  of the host's `send_types:`, `invoke_types:` and `accepts:`. It answers a
  list of findings. Each finding names its row of
  [Publish-time checks: every runtime refusal and its twin](publish-time-checks.md)
  with a `kind`, a location and its data. Like the functions of 2.7.0, it
  refuses nothing. You decide which finding refuses a publish.
- `Statifier.MachineState`'s `last_selection` reads `:selected` when the
  last external event selected a transition, `:none` when it selected none,
  and `nil` before any external event.

## 2.10.0

**A host must change:** NONE. A session that registers no send type sees
nothing new: no request is made, nothing is started, and `_ioprocessors`
holds the SCXML processor's entry alone. A `{:statifier, "~> 2.9"}`
requirement already accepts 2.10.0.

**A host may start:** the W3C Basic HTTP Event I/O Processor. Requires
`{:statifier, "~> 2.10"}`.

1. Register `{Statifier.Send.BasicHTTP, base_url: base}` in `:send_types`
   under both of its type strings,
   `"http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"` and
   `"basichttp"`.
   - The `_ioprocessors` entry of each string holds one `"location"`: the
     base URL, `/`, and the `_sessionid` of the session.
   - A registration without `:base_url` refuses the start of the session
     with an `ArgumentError`.
   - The POSTs go through OTP's `:httpc` by default. A `:transport` option
     names your own `Statifier.Send.BasicHTTP.Transport`. The package adds
     no dependency.
2. Answer at the base URL with your own front. The processor receives
   nothing on its own. Hand each request to
   `Statifier.Send.BasicHTTP.decode/1`. It answers the event to enqueue or
   the reason to refuse the request.
3. Deduplicate by key. Every POST carries the deduplication key of the send
   in an `scxml-send-key` header. A front that enqueues a request only when
   it has not already enqueued one with the same value delivers each send
   once. A front that ignores the header sees at-least-once delivery.
4. For a processor of your own, a `:send_types` value can now be
   `{module, opts}`.
   - The options reach `deliver/3` and `cancel/2` under the `:opts` key of
     the plan context.
   - A processor can implement the optional `ioprocessors_entry/2`. It
     receives the type string and a context that carries the session id and
     the options, so its entry can address one session.
   - A bare-module registration behaves as it did in 2.9.0.

Guide: [The Basic HTTP Event I/O Processor](basichttp.md).

**Conformance corpus.** It claims the W3C documents of the processor, and
its case schema gains `host.event_io_processors`. A sibling implementation
re-vendors it at the `v2.10.0` tag. That is not a host step.

Decision: ADR-0075

## 2.11.0

**A host must change:** only where one of these reaches it. A session that
registers no send type sees nothing new, and a `{:statifier, "~> 2.10"}`
requirement already accepts 2.11.0.

- **Param.** A chart whose `<send>` carries a `<param>` with both `expr` and
  `location` no longer compiles. `Statifier.Validator.validate/2`, and so
  `Statifier.compile/2`, refuses it as `{:param_expr_and_location, name}`.
  - Before 2.11.0 it compiled and the parameter took `location`.
  - Drop one of the two attributes. If you keep `location`, the chart sends
    what it sent before.
  - `Statifier.compile/2` raised `FunctionClauseError` for a `<send>`
    `<param>` with neither attribute. It now refuses that `<param>` as
    `{:param_no_value, name}`.
- **Start without `:base_url`.** A fresh `Statifier.Session.start_link/2`
  whose `Statifier.Send.BasicHTTP` registration has no usable string
  `:base_url` answers
  `{:error, {:send_types, {:invalid_registration, type, {:missing_option, :base_url}}}}`.
  - The session refuses before it spawns any session process, so there is
    no crash report. It answered `{:error, {%ArgumentError{}, stacktrace}}`.
    If your host matched the `ArgumentError` shape, match the named refusal
    instead.
  - Every registration from which the processor can build its entry still
    starts.
  - A resume is not refused and does not change: its position carries the
    `_ioprocessors` entries that it started with.
  - `ioprocessors_entry/2` still raises `ArgumentError` for a direct
    caller.
  - Corrected 2026-10-04: the engine decides the named refusal before the
    session process starts. A start that also had another fault now answers
    the named refusal. Before, it answered that other fault. The other
    faults are a `:name` already registered
    (`{:already_started, pid}`), an `:invoke_handlers` value that is not a
    map (`{:function_clause, stacktrace}`), and an `_ioprocessors` entry of
    another processor that is not a map (the `ArgumentError` of that
    processor). Beside another processor whose `check_registration/2`
    breaks its contract (it raises, throws, exits or answers anything other
    than `:ok` or `{:error, reason}`), the engine does not refuse the
    registration by name. The start answers the `ArgumentError` shape as
    before. The Note of 2026-10-04 in ADR-0069 records this.
- **Root element.** `Statifier.Lowering.lower/2`, and so
  `Statifier.compile/2`, answers
  `{:error, [%Statifier.Lowering.Error{reason: {:unexpected_root, name}}]}`
  for a document whose root is any SCXML element other than `<scxml>` (a
  `<state>`, a `<parallel>`, a `<final>`, a `<history>`, a `<transition>`,
  ...). It raised `BadMapError` for such a document. It answers
  `{:unsupported_element, "scxml"}` for an `<scxml>` nested below the root.
  It raised `FunctionClauseError` for such a document. If your host rescued
  either raise, match the error tuple instead.
- **History parent.** `Statifier.Validator.validate/2` no longer raises
  `FunctionClauseError` on a `<history>` whose compound parent has no `id`.
  It reports a default target outside the parent as
  `{:initial_not_descendant, target, nil}`. If your host matches the parent
  id of that reason as a binary, handle `nil` too.
- **JSON body.** `Statifier.Send.BasicHTTP` writes a parameter value that is
  a list or a map, and a `<content>` body that is a list, as JSON text
  (`["Dune",2]`, `{"title":"Dune"}`). Before, it wrote the `inspect/1` text
  of the value.
  - It writes an undefined value inside such a list or map as JSON `null`.
  - A list or map that holds anything with no JSON form (a key that is not a
    string, a struct such as a `Date`, a tuple, a string that is not UTF-8)
    keeps its whole `inspect/1` text.
  - Every scalar keeps its text.
  - A `<content>` body that is a list is still sent as `text/plain`.
  - If a receiver of your POSTs parsed the `inspect/1` text, read JSON
    instead. The inbound decoder is unchanged.

Three changes to a `Statifier.Send.BasicHTTP` delayed send ask nothing of a
host, but a chart sees them:

- A delayed send whose transport raises now reaches the sender as
  `error.communication`, through `Statifier.Session.failed_send/3` with the
  reason `{:raised, exception}`. Before, nothing reached the chart.
- A delayed send of a live session that is busy when the delay passes is now
  POSTed. Before, the engine dropped it.
- A `<cancel>` that has reached the send's timer before the timer POSTs now
  always stops the POST.

An immediate send whose transport raises is unchanged.

**A host may start:** refreshing a session's registered `_ioprocessors`
entries, refusing a registration in its own processor, and telling a
processor's own process that its session halted. Requires
`{:statifier, "~> 2.11"}`.

- **Refresh entries.** `Statifier.MachineState.refresh_ioprocessors/1`
  recomputes the registered `_ioprocessors` entries of a position from the
  registration that stamps the position. It answers `{:ok, machine_state}`,
  or the `{:error, reason}` of a registration with nothing changed. An
  entry that raises raises here.
  - A host whose Basic HTTP base URL moved across a resume re-stamps the
    position with `Statifier.MachineState.put_send_types/2`, refreshes it,
    and then passes it as `:resume`.
  - `Statifier.Session.refresh_ioprocessors/1` refreshes a live session and
    answers `:ok`. It changes nothing and answers an error in these cases:
    - `{:error, reason}` for a registration that its processor rejects
      (`{:error, {:missing_option, :base_url}}` for Basic HTTP without
      `:base_url`);
    - `{:error, :not_running}` once the session has halted;
    - `{:error, :recorded_session}` for a session started with
      `record: true`;
    - `{:error, {:ioprocessors_entry, type, exception}}` when an entry
      raises. The session runs on at the position it held.
  - The call does not touch the SCXML entry or an entry from a processor
    that exports only `ioprocessors_entry/1`. A resume still reads the
    entries that its position carries.
  - A session that registers nothing answers success and sees nothing
    change.
  - Decision: the Amendments of 2026-10-02 in ADR-0075.
- **Check a registration.** A processor of yours can implement the optional
  `Statifier.Send.Processor` callback `check_registration/2`. It answers
  `:ok` or `{:error, reason}` for the type string and options of a
  registration.
  - A fresh start asks it for every registration whose module exports it.
    The start refuses the first rejected registration with
    `{:error, {:send_types, {:invalid_registration, type, reason}}}`, before
    it spawns any session process.
  - A resume does not ask it. A processor that does not implement it is not
    asked.
  - Corrected 2026-10-04: `Statifier.Send.BasicHTTP` implements the
    callback, so 2.11.0 also adds the public function
    `Statifier.Send.BasicHTTP.check_registration/2`. A host can call it to
    check the options of a Basic HTTP registration before a start. It
    answers `:ok` exactly when `ioprocessors_entry/2` would build an entry
    from the options (a string `:base_url`). It answers
    `{:error, {:missing_option, :base_url}}` for any other registration,
    including a `:base_url` that is present but not a string.
  - Decision: the Amendment of 2026-10-02 in ADR-0069.
- **Watch a halt.** A processor can hold a delay in a process that it starts
  from `perform/2`. It can hand that process to
  `Statifier.Session.HaltNotice.watch/2`.
  - The session sends the process `{:statifier_halted, session, reason}`
    when the session halts (`:done`, `:cancelled` or `:budget_exhausted`),
    at once when it already has.
  - `HaltNotice.take/1` removes and returns the processes watched under a
    key.
  - Outside a session, `watch/2` keeps nothing and answers
    `:not_a_session`.
  - The delay stays with the processor (ADR-0069, decision 4).

**Conformance corpus.** The W3C Basic HTTP documents test518, test519,
test520 and test534 now check the decoded event that their transition
takes, not its name alone. The step of a `statifier` case can carry an
optional `expect_position`, the position that the chart holds after that
step (ADR-0076). The release adds three library cases. The corpus hash in
`conformance/manifest.json` moves, so a sibling implementation re-vendors
it at the `v2.11.0` tag. That is not a host step.

## 2.12.0

**A host must change:** only where one of these reaches it.

- **Struct body.** `Statifier.Send.BasicHTTP` sends a `<content expr>` that
  evaluates to a struct as the body, with the `inspect/1` text of the struct
  as `text/plain`. Before 2.12.0 such a content took the form arm.
  - A struct that does not enumerate as parameter pairs (a `Date`, for
    example) made the planning of the send raise (`Protocol.UndefinedError`
    for a `Date`). The session that performed the send exited, and no
    request was made.
  - A struct that does enumerate as pairs (a `MapSet` of two-element
    tuples, for example) was sent as an `application/x-www-form-urlencoded`
    body of those pairs.
  - A receiver of such a send now gets the `inspect/1` text of the struct as
    `text/plain` instead. The receiver already reads that text for a struct
    inside a list or a map.
  - A session that registers no send type sees nothing new.
- **Unnamed compound state.** `Statifier.Validator.validate/2`, and so
  `Statifier.compile/2`, refuses a chart whose compound `<state>` has no
  `id` and carries an `initial` attribute or an `<initial>` element that
  names a target outside that state. It reports
  `{:initial_not_descendant, target, nil}`.
  - Before 2.12.0 such a chart validated, and `Statifier.compile/2` raised
    `KeyError`. If your host rescued the raise, match the refusal instead.
  - The validator accepts a target inside the state as before.
  - If your host matches the parent id of that reason as a binary, handle
    `nil` too, as 2.11.0 asked for a `<history>` parent.
- **History target.** `Statifier.Validator.validate/2`, and so
  `Statifier.compile/2`, now decides by the structure of the document, for
  every parent, whether the default target of a `<history>` sits under the
  parent of the history. It already did so for a parent with no `id`.
  - Take a document where two states share an `id`, and a history under one
    of them names a target under the other. The validator already refused
    that document for the `id` (`{:duplicate_id, id}`, or `{:empty_id}` for
    an empty one). It now also reports
    `{:initial_not_descendant, target, parent_id}`.
  - The validator refuses no document that validated before, and it accepts
    no document that it refused.
- **Predicator 9.4.** `statifier` requires `{:predicator, "~> 9.4"}`, where
  it required `~> 9.0`. A host that holds predicator at 9.0 to 9.3, in its
  own `mix.exs` or in its `mix.lock`, moves to 9.4 with it
  (`mix deps.update predicator`).
  - With 9.4, a string literal that holds a non-ASCII character in an
    expression reaches `_event.data` and a `Statifier.Send.BasicHTTP` text
    body as the UTF-8 string that the chart writes.
  - Before 2.12.0 each such character became one byte, the low eight bits
    of its code point. A text body that carried one was not the literal and
    was usually not valid UTF-8.
- **Escapes.** With the same move, a string literal that holds a `\u` or
  `\U` escape no longer reads as its letters with the backslash dropped.
  Before 2.12.0 `'caf\u00e9'` read as `cafu00e9`. Write the character
  itself instead. What a chart sees depends on where the literal sits:
  - In an expression that the compiler checks at load (a transition's
    `cond`, a `<log expr>` or a `<send>` `<content expr>`, for example),
    `Statifier.compile/2` refuses the document with an
    `:expression_compile_error`.
  - In a `<data expr>`, an `<assign expr>`, a `<script>` or a `namelist`
    entry, the compiler defers the failure. It raises `error.execution`
    when the expression runs, and `Statifier.Publish.findings/2` reports it
    under row S13.
  - Wherever the engine reads text as a value, through
    `Statifier.Compiler.Expressions.inline_value/1` or
    `Statifier.EventData.coerce/1`, the text no longer folds to a string.
    The engine keeps it as its text, with the quotes and the backslash.
    This applies to the text of a `<data>` or an `<assign>` element, the
    text of a `<content>` element under `<send>`, `<invoke>` or
    `<donedata>`, and the text body or form parameter values of an inbound
    Basic HTTP request.

**A host may start:** nothing new.

**Conformance corpus.** `conformance/schema/case.json` now refuses an
`expect_position` of a step whose `history_values` gives a history state
anything but an array of unique, non-empty state ids. The library case
`loan_lost_after_timer` states the position after the step that stops its
chart: `running` false, an empty configuration and `lost` still in
`states_to_invoke`. The corpus hash in `conformance/manifest.json` moves,
so a sibling implementation re-vendors it at the `v2.12.0` tag. That is not
a host step.

The conformance runner compares the numbers of a position by JSON value. A
float that the chart holds agrees with an expected integer of the same
value (`2.0` with `2`). Before, they disagreed, and the message named no
member. A number that differs in value still disagrees, and the message
names the member. A sibling runner compares the same way. That is not a
host step either.

## 2.12.1

**A host must change:** NONE. The release changes documentation only: no
file under `lib/` differs from 2.12.0.

**A host may start:** nothing new. The conformance corpus does not change,
so a sibling implementation that vendored it at the `v2.12.0` tag has
nothing to re-vendor.

## 2.13.0

**A host must change:** only where one of these reaches it. A
`{:statifier, "~> 2.12"}` requirement already accepts 2.13.0.

- **Unnamed state.** `Statifier.Validator.validate/2`, and so
  `Statifier.compile/2`, refuses two documents whose `<state>` has no `id`.
  - One has an `initial` that names a missing state, reported as
    `{:unresolved_initial, missing_id}`.
  - The other has no child states and carries an `initial`, reported as
    `{:initial_on_atomic_state, nil}`.
  - Before 2.13.0 both validated, and `Statifier.compile/2` raised
    `KeyError`. If your host rescued the raise, match the refusal instead.
  - If it matches the id of `initial_on_atomic_state` as a binary, handle
    `nil` too, as 2.12.0 asked for the parent id of
    `initial_not_descendant`.
- **Initial target.** `Statifier.Validator.validate/2`, and so
  `Statifier.compile/2`, now decides by the structure of the document, for
  every state, whether the `initial` target of a `<state>` is its
  descendant. 2.12.0 began doing so for the default target of a `<history>`.
  - Take a document where two states share an `id` and the `initial` of one
    names a state under the other. The validator already refused that
    document for the `id` (`{:duplicate_id, id}`). It now also reports
    `{:initial_not_descendant, target, id}`.
  - The validator refuses no document that validated before, and it accepts
    no document that it refused.
- **Budget-halted miss.** A session halted `:budget_exhausted` that is
  handed a miss through `Statifier.Session.failed_send/3` drops the miss
  without stepping, as a session halted `:done` or `:cancelled` does.
  - Before 2.13.0 it stepped the halted chart again and sent its subscribers
    another `{:halted, :budget_exhausted}` for every miss. A host that
    waited for that further message after it reported a miss no longer
    receives it.
  - The miss is the dead letter of the host.
  - A session halted `:done` or `:cancelled` is unchanged.

The check of `Statifier.Testing.HandlerCase` that a handler exception
propagates now waits up to ten seconds for the exit of the session instead
of one second. A generated handler test of a host no longer fails on a
loaded machine. A passing run returns as soon as the exit arrives. This is
not a host step.

**A host may start:** replacing the registration of one send type in a
running session. Requires `{:statifier, "~> 2.13"}`.

`Statifier.Session.replace_send_type/3` takes a session, a send type that
the session already registers and a new registration (a module or
`{module, opts}`, as a `:send_types` value of `start_link/2` is). In the
same call, it recomputes the `_ioprocessors` entry of that type.

1. Move the options of a registration while the session runs (a new
   `:base_url` for `Statifier.Send.BasicHTTP`, or a rotated location).
2. Hand the session the new registration. The chart reads the new entry
   from its next event, and later sends of the type go through the new
   registration.

The call answers `:ok`. It changes nothing and answers an error in these
cases:

- `{:error, :not_running}` for a halted session;
- `{:error, :recorded_session}` for a session started with `record: true`;
- `{:error, {:unknown_send_type, type}}` for a type that the session does
  not register;
- `{:error, {:send_types, {:invalid_registration, type, reason}}}` when the
  `check_registration/2` of the processor refuses the registration
  (`start_link/2` spells that refusal the same way);
- `{:error, {:ioprocessors_entry, type, exception}}` when the entry raises.
  The session keeps its position.

Decision: the Amendment of 2026-10-09 in ADR-0069.

**Conformance corpus.** The hash does not move, because no case changes.
The descriptions of the case schema and the corpus README now say two
things. A step's expected datamodel keeps `_name` for a document whose
`<scxml>` carries a `name` attribute. The corpus writes each array of state
ids sorted, while the schema does not check the order. No verdict changes.

## 2.14.0

**A host must change:** only where one of these reaches it. A
`{:statifier, "~> 2.13"}` requirement already accepts 2.14.0.

- **Breaking: duplicate attribute.** `Statifier.Validator.validate/3`, and
  so `Statifier.compile/2`, refuses a document that writes one attribute
  twice on one element, with the error reason
  `{:duplicate_attribute, element, attribute}` (code
  `:duplicate_attribute`), located at the repeated occurrence.
  - Before 2.14.0 such a document compiled with the value of the first
    occurrence.
  - XML does not allow the repeat, so remove it from the document.
  - If your host matches the reasons of `Statifier.Validator.Error`
    exhaustively, add a clause for the new reason.
- **Cancel after budget halt.** `Statifier.Session.cancel/1` sent to a
  session halted `:budget_exhausted` with events queued (by
  `Statifier.Session.send_event/2`, or by a delayed send to the session
  itself that fired after the halt) reaches the session and halts it
  `:cancelled`. It discards the queued events, so `{:halted, :cancelled}`
  follows the budget halt, as the documentation of the session promises.
  Before 2.14.0 the cancel stayed queued behind those events, and the
  session stayed `:budget_exhausted`.
- **Delayed send after budget halt.** A delayed send that fires while a
  session is halted `:budget_exhausted` is dropped without stepping. This
  applies to a send to an internal target (a `targetexpr` that evaluates to
  `#_internal`) and to a send to a route that is unreachable at fire time.
  - The core is not driven, nothing is recorded, and no further message
    reaches a subscriber.
  - Since 2.13.0 the engine drops the miss of a budget-halted sender,
    reported through `Statifier.Session.failed_send/3`, the same way.
  - Before 2.14.0 the delayed send drove the halted core again and sent
    another `{:halted, :budget_exhausted}`. A host that waited for that
    further message no longer receives it.
  - A fired send to the session itself is still enqueued on its inbox, and a
    fired send to another live session is still delivered to it.

A session halted `:done` or `:cancelled` is unchanged by either session
change.

**A host may start:** nothing new.

**Conformance corpus.** The statifier suite gains two library cases,
`loan_renew_refused_by_standing` and `loan_dispute_restores_late_shallowly`,
and `conformance/registry.json` claims both. The corpus hash in
`conformance/manifest.json` moves, so a sibling implementation re-vendors
it at the `v2.14.0` tag. That is not a host step. No case repeats an
attribute on one element, so the new refusal moves no case.
The descriptions of the case schema now say two things. The runner compares
the `expect_position` members of a step as JSON values. The corpus writes
`active_invocations` sorted, while the schema does not check the order. No
verdict changes.

## 2.15.0

**A host must change:** only where this reaches it. A
`{:statifier, "~> 2.14"}` requirement already accepts 2.15.0.

- **Unknown function.** `Statifier.compile/2` refuses a chart whose
  expressions call a function that is not `In`, a predicator builtin or a
  function the host declares, with a `Statifier.Compiler.Error` whose reason
  is `{:unknown_function, name, source}`, located at the element that holds
  the call.
  - Before 2.15.0 such a chart compiled, and every evaluation of the call
    raised `error.execution`. The CHANGELOG of 2.15.0 lists the refusal
    under Changed, not as a Breaking entry. The release refuses only a chart
    that calls a function that no evaluation context holds.
  - Register the function with `:function_providers`, or declare its name
    with `:function_names`.
  - If your host matches the reasons of `Statifier.Compiler.Error`
    exhaustively, add a clause for the new reason.
  - This includes a chart that a host stored before 2.15.0 and recompiles
    under it, from its source or from a `Statifier.Chart` blob.

**A host may start:** registering named functions that a chart can call
from `cond` and `expr`. Requires `{:statifier, "~> 2.15"}`.

1. Write a `Predicator.FunctionProvider` module per family of functions. A
   function reads only its arguments and the host term. It does no I/O,
   reads no clock and no random source, and keeps no state, so a replay or
   a resume evaluates it the same way.
2. Pass the list as `:function_providers` to `Statifier.compile/2`,
   `Statifier.MachineState.new/2` and `Statifier.Session.start_link/2`.
   - A provider must not replace `In` or a predicator builtin.
   - A list that does not resolve makes `Statifier.Session.start_link/2`
     refuse with `{:error, {:function_providers, reason}}` before it starts
     anything.
   - It makes `Statifier.compile/2` and `Statifier.MachineState.new/2` raise
     `ArgumentError`.
3. A tool that checks a chart without loading the modules passes
   `:function_names`, the names alone, to `Statifier.compile/2`.
4. A session started with `:resume` stamps the list that it is given, and a
   recording keeps the list for `Statifier.Replay`. A host that resumes a
   position itself re-stamps the list with
   `Statifier.MachineState.put_function_providers/2`.
5. A child session started for an `<invoke>` does not inherit the list, and
   a chart given as `<invoke>` content cannot call a host function.

Guide: the section "Host functions for `cond` and `expr`" of
[How to extend Statifier: `<invoke>` handlers, `<send>` types and host functions](extending.md).

**Conformance corpus.** No change in 2.15.0.

Decision: ADR-0078

## 2.16.0

**A host must change:** only where this reaches it. A
`{:statifier, "~> 2.15"}` requirement already accepts 2.16.0.

- **Predicator 9.5.** `statifier` requires `{:predicator, "~> 9.5"}`, where
  it required `~> 9.4`. A host that holds predicator at 9.4, in its own
  `mix.exs` or in its `mix.lock`, moves to 9.5 with it
  (`mix deps.update predicator`).
  - A host that also depends on `statifier_blocks` takes `statifier_blocks`
    0.43.1 or later: 0.43.0 caps predicator below 9.5, so it cannot resolve
    beside this release.
  - Every answer `Statifier.compile/2` gives is unchanged.

**A host may start:** nothing new.

**Conformance corpus.** No change in 2.16.0.
