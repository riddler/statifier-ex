# ADR-0075: The Basic HTTP Event I/O Processor is a registered send type in statifier-ex, with a pure inbound decoder, an injected transport and a corpus host declaration

Status: accepted (2026-09-30) - builds on ADR-0069 (the processor is a
registered send type in that record's sense); amends ADR-0069 decision 2
in part (a registration value may carry options) and adds an optional
callback to its processor behaviour; amends ADR-0070 decision 5 in part
(one `host` key is allowed on a W3C case); answers ADR-0062 fact 2 for
this processor by adding no optional dependency; answers ADR-0069's reopen
trigger "a corpus document naming a non-built-in send type"

## Context

SCXML appendix C.2 defines the Basic HTTP Event I/O Processor. Quoted
from the local spec cache
(`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`):

- C.2.1: "An SCXML Processor that supports the Basic HTTP Event I/O
  Processor MUST accept messages at the access URI as HTTP POST requests
  [...] If a single instance of the parameter '_scxmleventname' is
  present, the SCXML Processor MUST use its value as the name of the SCXML
  event that it raises. If multiple instances of the parameter are
  present, the behavior is platform-specific. If the parameter
  '_scxmleventname' is not present, the SCXML Processor MUST use the name
  of the HTTP method that was used to deliver the message as the name of
  the event that it raises. The processor MUST use any message content
  other than '_scxmleventname' to populate _event.data. [...] After it
  adds the received message to the appropriate event queue, the SCXML
  Processor MUST then indicate the result to the external component via a
  success response code 2XX. [...] In the cases where the message cannot
  be formed into an SCXML event, the Processor MUST return an HTTP error
  code as defined in [RFC 2616]."
- C.2.2: "If neither the 'target' nor the 'targetexpr' attribute is
  specified, the SCXML Processor MUST add the event error.communication to
  the internal event queue of the sending session. The SCXML Processor
  MUST attempt to deliver the message using HTTP method "POST" and with
  parameter values encoded by default in an
  application/x-www-form-urlencoded body [...] If the 'event' parameter of
  <send> is defined, the SCXML Processor MUST use its value as the value
  of the HTTP POST parameter _scxmleventname. If the namelist attribute is
  defined, the SCXML Processor MUST map its variable names and values to
  HTTP POST parameters. If one or more <param> children are present, the
  SCXML Processor MUST map their names (i.e. name attributes) and values
  to HTTP POST parameters. If a <content> child is present, the SCXML
  Processor MUST use its value as the body of the message."
- C.2.3: "SCXML Processors that support the BasicHTTP Event I/O Processor
  MUST maintain a 'http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor'
  entry in the _ioprocessors system variable. The Processor MUST maintain
  a 'location' field inside this entry whose value holds an address that
  external entities can use to communicate with this SCXML session using
  the Basic HTTP Event I/O Processor."

Twelve W3C IRP documents need the processor, and each is excluded today
with the reason `:needs_basichttp` in `tools/corpus/scxml_w3/exclusions.exs`
and in `conformance/exclusions.json`: test201, test509, test510, test518,
test519, test520, test522, test531, test532, test534, test567 and
test577. None of them is in the corpus (`conformance/corpus/w3c.json`) or
in `test/passing_tests.json`.

[ADR-0069](0069-host-registered-send-types.md) opened the slot a
processor like this fills: a host registers a send type per session
(`:send_types` on `Statifier.Session.start_link/2`), a registered type's
`target` is the processor's own opaque string, and the processor
implements `Statifier.Send.Processor`. The spike on st-lhwd built the
processor on a branch that was never merged and ran the twelve documents
through a loopback HTTP front in this repository's own suite; its
findings note on that bead is what this record decides from. What it
found, and what the code on `main` says:

- **Eleven of the twelve pass end to end.** Every pass was a real POST
  answered 2xx, and with nothing listening at the location the same
  eleven fail, so the passes depend on the delivery. test201 fails under
  every transport the spike tried (decision 7 says why).
- **The transport needs no dependency.** OTP's `:httpc` passed the same
  eleven documents as a `req` adapter did. A cold production compile of
  this package roughly doubled with `req` as an optional dependency, and
  `req`'s own dependencies joined the lock with it.
- **A `_ioprocessors` entry cannot name the session today.** The
  `Statifier.Send.Processor` callback `ioprocessors_entry/1` receives the
  type string only, and `Statifier.Send.Types.from_send_types/1`, the one
  constructor, calls it once per registered set with nothing else.
  `Statifier.Evaluator.SystemVariables.initial/3` writes the entries it is
  handed. C.2.3's location must address one session.
- **A registration has no configuration channel.** A `:send_types` value
  is a bare module (`Statifier.Send.Types.from_send_types/1`'s spec), and
  no `Application` environment is read anywhere under `lib/`.
- **`params` and `<content>` are folded before a processor sees them.**
  `%Statifier.Effect.Send{}`'s `data` is `EventData.coerce({:params, ...})`
  when the `<send>` has no `<content>` child and the content value
  otherwise (`Statifier.Machine.Content.Send`'s private `data/3`).
- **A failed delivery is dropped unless someone reports it.** The session
  performs a `{:handler, module, payload}` instruction inline and ignores
  what `perform/2` returns (`Statifier.Session`'s private
  `perform_instruction/3`, ADR-0051 decision 4).
  `Statifier.Session.failed_send/3` is the door that turns a miss into
  C.1's `error.communication`, and it is a cast.
- **The corpus cannot declare a delivering host.** In
  `conformance/schema/case.json` a `w3c` case may not carry `host` at all
  (the `allOf` branch for `"suite": "w3c"` has
  `"not": {"required": ["host"]}`), and the one host key that registers a
  processor, `host.send_types`, registers one that records every send and
  delivers none.
- **The transform leaves the location unwritten.** Every BasicHTTP
  template in `tools/corpus/scxml_w3/conf_predicator.xsl` is a stub that
  emits nothing, so the committed transform left the twelve documents'
  sends without a target. The IRP's own stylesheet spells the access URI
  as `_ioprocessors['basichttp']['location']`: the documents read the
  short key.

Every `lib/`, `tools/` and `conformance/` cite in this record was read at
`dc1900d0`.

## Decision

**1. statifier-ex owns the processor and the pure inbound decoder;
statifier_router owns the durable-execution inbound front.** The
processor is `Statifier.Send.BasicHTTP`, a `Statifier.Send.Processor`
shipped in this package and registered by a host like any other send
type. The reference implementation's registry is derived from its own
ratchet ([ADR-0070](0070-statifier-emits-a-language-neutral-conformance-corpus.md)),
so whatever claims the twelve documents must run them in this
repository's suite; a sibling port claims the same cases from the same
corpus. The router cannot host the processor: it depends on this package,
and its route `target` is a route name, never a URL. A separate package
(ADR-0062's shape) is not needed because the transport costs nothing
(decision 6). What this package cannot do is resolve a location to an
execution that is persisted and not running: it resolves a location only
to a live registered session. The durable front, which gets or creates the
execution and delivers through its own address table, is
statifier_router's, and it calls this record's decoder (decision 5). The
placement was ruled by the operator, 2026-09-29, and the spike confirmed
it.

**2. Two type strings, neither redirectable.** The registered type is the
spec's processor URI, `http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor`,
and the short form `basichttp` is an accepted alias (ADR-0069 decision 1
permits a short form beside the URI). A host registers the processor
under both. Neither string is a built-in spelling, so registering them
redirects no built-in send, and a registration naming a built-in spelling
stays refused when the session starts (ADR-0069 decision 1). Ruled by the
operator, 2026-09-29.

**3. Two `_ioprocessors` keys, one location, written through a new
optional callback.** C.2.3 requires the URI key and the documents read
the short key, so the session's `_ioprocessors` carries an entry under
each registered string, and both entries hold the same `"location"`: the
host's base URL followed by `/` and the session's `_sessionid`. Ruled by
the operator, 2026-09-29 (both keys, one location); the shape is this
record's. Whether a durable execution's location carries more than its
id, and whether a front authenticates the POST, is statifier_router's
front's to decide in its own record.

The location is written through an OPTIONAL
`ioprocessors_entry/2` callback on `Statifier.Send.Processor`, taking the
type string and a context map carrying the session id and the
registration's options (decision 8, point b). The one constructor,
`Statifier.Send.Types.from_send_types/1`, keeps each type's module and
options on the registered set, and
`Statifier.Evaluator.SystemVariables.initial/3`, which already knows the
session id, asks a module that exports `/2` for its entry; a module that
exports only `/1` gets its `/1` entry exactly as today. The spike named
an alternative, calling `/2` from `Statifier.MachineState.new/2` with the
`:send_types` map; it is not taken, because `MachineState.new/2` receives
the derived set, not the map, and the set is the one stamp every entry
already comes from. The entries are still written once, when the session
starts, and a persisted position carries them in the datamodel, so a
resumed session reads the location it started with.

**4. The outbound mapping (C.2.2).**

- `event` becomes the form parameter `_scxmleventname`; each `namelist`
  entry and `<param>` becomes a form parameter; the default body is
  `application/x-www-form-urlencoded`; the method is POST.
- A `<content>` child is the body. When the send also names an `event`,
  `_scxmleventname` travels as a query parameter of the target URL, which
  the decoder reads (decision 5); C.2.2 does not say where the name goes
  when the body is content.
- The processor tells a body from form parameters by `data`'s shape: a
  map is form-encoded, `:undefined` (no parameters and no content) sends
  `_scxmleventname` alone as a form body, and any other value is the body
  (a string is sent as `text/plain`). A `<content expr>` that evaluates
  to a map is therefore form-encoded, and duplicate parameter names
  keep the last value, as they already do for every send (`EventData.coerce/1`'s `{:params, _}`
  rung). No effect field is added to carry which of the two produced
  `data`: the field would change what `Statifier.Machine.Content.Send`
  answers for every registered type, not only this one.
- A send with neither `target` nor `targetexpr` plans C.2.2's
  `error.communication` in `deliver/3`, as a `{:raise, :platform,
  "error.communication", ...}` instruction carrying the send id
  (`t:Statifier.Session.Effects.instruction/0`), and no request is made.
  The core has already built the send effect by then: ADR-0069 decision 1
  keeps the core from reading a registered type's `target`, and this
  record does not change that.
- A delivery that fails (the transport answers an error, or a status
  outside 2xx) reaches the sender as C.1's `error.communication` through
  the existing miss door (decision 8, point d).

**5. The inbound half is a pure decoder, called by any front.**
`Statifier.Send.BasicHTTP.decode/1` takes the request's method, content
type, body and query string and returns `{:ok, %Statifier.Event{}}` or
`{:error, reason}`. It performs nothing and knows no session: a front
resolves the location to a session (or, for statifier_router, an
execution), calls the decoder, and enqueues the event as an external
event. The rules:

- The event name is the first `_scxmleventname` found, query string
  before body (C.2.1 makes several instances platform-specific), else
  `HTTP.` followed by the method in upper case, the spelling test532
  expects (`HTTP.POST`).
- A form body's other parameters become `_event.data` (decision 8, point
  f). A body of any other content type becomes `_event.data` through
  `Statifier.EventData`'s text rung.
- `origintype` is the processor URI.
- The status rule a front applies: `{:ok, event}` is answered 204 once
  the event is enqueued and before it is processed (C.2.1); a method
  other than POST is `{:error, {:method_not_allowed, method}}`, answered
  405 with `Allow: POST`; any other `{:error, _}` is answered 400; a
  location that names no session the front can reach is the front's 404.

**6. The transport is a behaviour with an always-compiled default on OTP
`:httpc`, and no new dependency.** `Statifier.Send.BasicHTTP.Transport`
has one callback that POSTs a body with headers to a URL and answers the
status code or an error. Its default adapter is on OTP `:httpc`, always
compiled and always gated; a host injects any other adapter. The default
adapter sets TLS verification itself (`verify: :verify_peer`, the system
CA store through `:public_key.cacerts_get/0`, and hostname checking), and
starts `:inets` and `:ssl` itself on first use: this package's
application list gains nothing, so a session that registers nothing
starts nothing. A host that uses `req` writes a small adapter of its own;
the docs page for the processor carries the recipe as text, not as
compiled code.

This overturns the earlier plan of an optional `req` dependency with a
`req` adapter as the default when loaded. The overturn is the spike's
finding (st-lhwd), recorded here, and its reason is
[ADR-0062](0062-opentelemetry-bridge-is-a-separate-package.md) fact 2:
an adapter compiled only when `req` is loaded is code the gate compiles
on one side only, since this repository's lock always carries `req` once
it is listed, and the no-`req` side is the one no gate run would compile.
With no optional dependency there is no unchecked side, and because a
default always exists, no refusal at session start is needed for a host
without `req`.

**7. The corpus: a host key that delivers, allowed on W3C cases.**

- `conformance/schema/case.json` gains `host.event_io_processors`: an
  array of Event I/O Processor URIs the host runs with a location that
  reaches the running session through a loopback front, and delivers
  every send through. Its item set is closed, and its one member today is
  the BasicHTTP URI; the host registers the processor under that URI and
  its short form (decision 2). It is a closed-set growth, a minor
  version.
- The W3C branch's ban on `host` is lifted for this key only: a `w3c`
  case may carry a `host` object whose only key is
  `event_io_processors`. Every other `host` key stays banned on `w3c`
  cases, and `scion` cases carry no `host` at all, as today. This amends
  ADR-0070 decision 5 in part ("No W3C or SCION case carries it: upstream
  cases run with no registration"): the BasicHTTP documents are upstream
  cases that run with a registration, because they cannot run without
  one. Ruled by the operator, 2026-09-29 (a host declaration in the case
  schema, a closed-set growth); the key's name and the per-key lift are
  this record's.
- The twelve documents leave the exclusions once the reference
  implementation passes them. test509, test510, test518, test519, test520,
  test522, test531, test532, test534, test567 and test577 join
  `test/passing_tests.json` and are claimed. test201 leaves the
  exclusions and enters the corpus unclaimed: it sends `event1` through
  the processor and then a `<send event="timeout"/>` through the SCXML
  processor, and expects `event1` first. The processor's delivery reaches
  the session from outside, after the step that sent it, while the SCXML
  send is appended to the session's own external queue inside that step,
  so the timeout is always ahead. Every transport gives the same order;
  only a short-circuit that enqueues a send to the session's own location
  without HTTP would pass it, and that is not the processor the document
  describes. A case can be in the corpus and out of the ratchet, as
  test552 and test330 are today.
- A sibling port that does not implement the processor leaves these
  cases unclaimed, which is what an optional processor means in the
  registry.
- `conf:basicHTTPAccessURITarget` in `conf_predicator.xsl` emits
  `targetexpr="_ioprocessors['basichttp']['location']"`, the IRP's
  spelling.

**8. The contract gaps the spike found, each decided.** For each, whether
any existing function answers differently for a session that registers
nothing:

| Gap | Decision | Reason | A session registering nothing |
|---|---|---|---|
| a. A location cannot address the session | Decision 3's optional `ioprocessors_entry/2`, with the module and options kept on the registered set | The session id exists only once the session starts; the set is the one stamp entries come from | Unchanged: `send_types` is `nil`, so `_ioprocessors` holds the SCXML entry alone, and `Statifier.Position` drops `send_types`, so the persisted shape does not change |
| b. Deployment configuration (base URL, transport) has no channel | A `:send_types` value may be `{module, opts}` as well as a bare module. The options reach `ioprocessors_entry/2`'s context and, for a `{module, opts}` registration only, the plan context a processor's callbacks receive, under an added `:opts` key. `Statifier.Send.BasicHTTP` reads `:base_url` (required: C.2.3's location cannot be built without it, so a registration of the processor without it is refused when the session starts) and `:transport` (default the `:httpc` adapter). `Statifier.Session.Recording` writes the options as strings, the rule ADR-0057 decision 5 sets for `:invoke_handlers` and the recording already applies to `:send_types` | Registration is per session (ADR-0069 decision 2), every other host setting of this library is a `start_link/2` option, and no `Application` environment is read under `lib/`; a test suite can run two fronts in one node | Unchanged; a bare-module registration's plan context is also unchanged, since the `:opts` key is added only for a `{module, opts}` registration (the `Statifier.Send.Processor` moduledoc already makes a new plan-context key additive) |
| c. `params` and `<content>` are folded into `data` | No new effect field; decision 4's shape rule | The only ambiguous case is a `<content expr>` that evaluates to a map, and form-encoding is C.2.2's default encoding for a body; a field would change what the core answers for every registered type | Unchanged: nothing in the core or the effects changes |
| d. A failed delivery never reaches the sender | The processor makes one attempt. On an error or a non-2xx status, its `perform/2` reports the miss through `Statifier.Session.failed_send/3`, addressed by the sender's session id through `Statifier.Registry`, and returns `{:error, reason}`. When no live session is registered under that id, it returns `{:error, reason}` only, and the dead-letter rule of `failed_send/3`'s documentation is the host's | `failed_send/3` is a cast, so a call from inside the sending session's own process does not block it; the processor is the layer that owns its one-attempt policy, which is who `failed_send/3`'s documentation says reports a miss. The alternative, the session routing every registered processor's `{:error, _}` to `failed_send/3`, would change what an existing path does for every registered type | Unchanged: `Statifier.Session`'s handling of `perform/2`'s return is not touched |
| e. test201 fails on ordering | Leaves the exclusions, enters the corpus unclaimed (decision 7) | No processor can deliver ahead of an in-step send without bypassing HTTP | Unchanged |
| f. Inbound form values are strings | Each value goes through `Statifier.EventData`'s text rung (a predicator literal, else the string), the rule a `<content>` body already gets | C.2.1 defers `_event.data` to appendix B, whose key and value rule says nothing about value types; with strings, `Var1 == 2` against `"2"` reads undefined in predicator and test567 fails | Unchanged: the decoder is new |
| g. The corpus host key that delivers | `host.event_io_processors`, the W3C ban lifted for that key only (decision 7); a closed-set growth, a minor | The narrower of the two options the spike named; lifting the ban wholesale would let W3C cases carry recording processors that never deliver | Unchanged: a case without the key runs as today |

**9. The edge cases the twelve documents do not cover.**

| Case | Disposition |
|---|---|
| Several `_scxmleventname` instances inbound | Decided here (decision 5: the first, query before body); st-gje8 tests it |
| A non-2xx answer | Decided here (gap d); st-gje8 implements and tests it |
| An unreachable location | Decided here (gap d); st-gje8 implements and tests it |
| A non-form content type inbound | Decided here (decision 5: the text rung); st-gje8 implements it. JSON bodies and charset handling are residue |
| A method other than POST inbound | Decided here (decision 5: 405 with `Allow: POST`); st-gje8 |
| An unknown session at the location | st-gje8, for this repository's loopback front (404); the durable case is statifier_router's front |
| `<content>` and `event` on one send | Decided here (decision 4: the name in the query string); st-gje8 |
| A delayed send and its cancel | st-gje8. The processor owns the delay (ADR-0069 decision 4) and `cancel/2` must cancel a send not yet fired; how the timer is held is st-gje8's choice, which must pass `mix adr.check`'s effects rule (the spike's timer tripped it) |
| Non-scalar values in `params` (a map, a list, `:undefined`) | Residue: the encoding is the processor's own (`Statifier.Effect.Send`'s moduledoc already leaves `:undefined` to such a processor) |
| `_event.origin` on an inbound event | Residue: 5.10.1 asks for an address a reply can be sent to, and the decoder has none |
| A location read after a resume on a host whose base URL moved | Residue: the persisted `_ioprocessors` keeps the location written at start, as the SCXML location does |
| Authentication of inbound POSTs | Out of this record: C.2 has none, and the durable front's location shape and authentication are decided by statifier_router's front in its own record |

## Consequences

- What moves in `lib/` when this is implemented (st-gje8):
  `Statifier.Send.BasicHTTP`, its transport behaviour and the `:httpc`
  adapter; the optional `ioprocessors_entry/2` callback on
  `Statifier.Send.Processor`; the module and options kept on
  `Statifier.Send.Types`'s registered set; `SystemVariables.initial/3`
  asking `/2`; the `{module, opts}` registration value through
  `Statifier.Session.start_link/2`, the planner's lookup, the plan
  context and `Statifier.Session.Recording`; a way for
  `Statifier.Testing.Case.test_scxml/5` to start its session with a
  registration, as an added option a call without it does not notice;
  and a loopback front on OTP `:inets` httpd for this repository's own
  runs, with no dependency.
- What moves with the corpus (st-8kn8): the schema key and the per-key
  lift of decision 7, `Mix.Statifier.Corpus.HostCase` starting the
  loopback front for a case that declares the key, the XSL template, the
  twelve entries leaving both exclusion files, the eleven claims, and the
  processor's docs page with the `req` recipe.
- Sentences on `main` this record makes stale, for those two changes to
  update, none edited here: `Statifier.Send.Target.supported_type?/1`'s
  documentation ("this engine implements only the SCXML Event I/O
  Processor"); the `:needs_basichttp` reason line at the head of
  `tools/corpus/scxml_w3/exclusions.exs` ("out of scope");
  `conf_predicator.xsl`'s "BasicHTTP Event I/O Processor support is out
  of scope" comment; `tools/corpus/README.md`'s exclusions bullet and
  `docs/testing.md`'s list of excluded trees, which both name the
  BasicHTTP tree; `Statifier.Effect.Send`'s "a future external-wire
  processor (BasicHTTP or otherwise)". ADR-0070 decision 5 names
  `test/scxml_tests/optional/send/test201_test.exs` as generated at
  `abf713c`; it is not generated at `dc1900d0`, and this record leaves
  that record's text alone.
- `perform/2` runs inside the sending session's process, so a slow
  location holds that session for the length of the request. The default
  adapter bounds each request with a timeout.
- The four documents test518, test519, test520 and test534 carry IRP
  checks on `_event.raw` that the transform stubs out, so they assert less
  than the upstream documents do; test567 keeps a real check on
  `_event.data`.
- Code builds against this record at proposed. It stays proposed until
  the code that implements it ships in a published version.

## Related

- [ADR-0069](0069-host-registered-send-types.md) (the registered send type, its processor behaviour, `failed_send/3`; decision 2 amended in part; its reopen trigger answered)
- [ADR-0070](0070-statifier-emits-a-language-neutral-conformance-corpus.md) (the corpus, the registry, the `host` object; decision 5 amended in part)
- [ADR-0062](0062-opentelemetry-bridge-is-a-separate-package.md) (fact 2, the optional-dependency objection, answered)
- [ADR-0051](0051-invoke-handlers-are-registered-per-session.md) (decision 4, the planning and performing split)
- [ADR-0057](0057-recording-identity-and-serialization.md) (decision 5, registrations recorded as strings)
- [ADR-0054](0054-durable-timers-consume-the-effect-vocabulary.md) (the processor-owned timer and its cancellation key)

### Amendment 2026-09-30: every POST carries the send's dedup key, and the receiver deduplicates

Status: accepted (2026-09-30) - amends decision 4 (the outbound mapping)
and decision 5 (the inbound decoder) by addition; every other decision,
and the record's own Status above, are unchanged. The header,
at-least-once delivery and deduplication by the receiver were ruled by
the operator, 2026-09-30; what the decoder does with the header is this
record's.

[ADR-0069](0069-host-registered-send-types.md) decision 4 binds every
registered processor: "A processor MUST be idempotent on the ADR-0054
decision 3 dedup key's components read off the effect", because "after a
crash and retry, a host may perform the same effect more than once."
Decision 8 point d above has the processor make one attempt per
`perform/2` and keep no memory between calls, so a host that performs the
same instruction twice POSTs twice. Neither decision 4 nor decision 5 said
how the MUST is met. This Amendment says it.

**The processor is at-least-once, and the receiver deduplicates.** Every
POST the processor makes, immediate or delayed, whatever its body,
carries the send's dedup key in one request header:

- **Name:** `scxml-send-key`.
- **Value:** the eight components of
  [ADR-0054](0054-durable-timers-consume-the-effect-vocabulary.md)
  decision 3's deduplication key, as that record and ADR-0059 order them,
  joined by `/`: the session scope, `send_id`, `macrostep`, `microstep`,
  `round`, `c_index`, `owner`, `ordinal`.
  - The session scope is the plan context's `session_id` (spec 5.10's
    `_sessionid` for a live session, a host's own scope for a
    process-less host), percent-encoded.
  - `send_id` is percent-encoded. Percent-encoding here escapes every
    byte outside RFC 3986's unreserved set (`A-Z a-z 0-9 - . _ ~`), so
    neither field can carry a `/`.
  - `macrostep`, `microstep`, `round`, `c_index` and `ordinal` are
    decimal integers.
  - `owner` is spelled `onentry.S.B`, `onexit.S.B` or `finalize.S.B` with
    its state and block indexes, or `transition.T` with its transition
    index.
  - A component the effect does not carry is the empty string.

Every component is a deterministic counter or a static position, so a
re-performed instruction sends a byte-identical value. A receiver that
enqueues a request only when it has not already enqueued one with the same
`scxml-send-key` delivers each send once: for such a receiver ADR-0069's
MUST holds end to end. A receiver that ignores the header sees
at-least-once delivery. The processor itself still keeps no memory across
`perform/2` calls.

**What the decoder does with it.** `decode/1`'s request map takes the
header's value under an optional `:send_key` key, and sets no event field
from it: an inbound event's `sendid` stays unset, as it is for a request
without the header. A value that is not eight `/`-separated fields whose
second field percent-decodes to UTF-8 is
`{:error, {:malformed_send_key, value}}`, answered 400 by decision 5's
status rule; an absent one changes nothing. The decoder does no
deduplicating: it is pure and remembers nothing. A front deduplicates on
the `scxml-send-key` header's value itself, and a request it has already
enqueued is answered 204 again with nothing enqueued. This repository's
loopback front, which lives only as long as one test run, does not
deduplicate; statifier_router's durable front, which must survive a
restart, is the one that will.

### Amendment 2026-09-30: a registration's options reach the planning callbacks, and `perform/2` gets its configuration through the payload

Status: accepted (2026-09-30) - amends decision 8 point b in part (which
callbacks receive `:opts`); every other decision, the Amendment above,
and the record's own Status are unchanged.

Decision 8 point b says a `{module, opts}` registration's options reach
"the plan context a processor's callbacks receive, under an added `:opts`
key". `Statifier.Send.Processor` has three callbacks that take its
`ctx()`: `deliver/3`, `cancel/2` and `perform/2`. The code that
statifier 2.10.0 ships gives `:opts` to two of them. This Amendment
states that rule as the decision:

- A `{module, opts}` registration's options reach the context
  `deliver/3` and `cancel/2` receive, under `:opts`
  (`Statifier.Session.Effects`'s private `processor_for/2`, at
  `c8894aea`).
- `perform/2` receives the session's plan context without `:opts`
  (`Statifier.Session`'s private `perform_instruction/3`, at
  `c8894aea`), because a `{:handler, module, payload}` instruction names
  its module and not the registration it came from, so the session has
  no one registration's options to add.
- A processor that needs its configuration when it performs carries it
  in the instruction payload `deliver/3` plans. `Statifier.Send.BasicHTTP`
  carries its transport this way.

The `Statifier.Send.Processor` moduledoc, section "Registration options",
names `deliver/3` and `cancel/2` as the callbacks whose context carries
`:opts`, at `c8894aea`. A bare-module registration is
unchanged: none of its callbacks receives an `:opts` key. This Amendment
decides nothing beyond which callbacks receive `:opts`.

## Note (2026-09-30): accepted

This record and its two Amendments of 2026-09-30 are accepted on
2026-09-30. Their three Status lines are the only lines of the record
that change; no decision, consequence, Related entry or Amendment
paragraph changes here, and this Note decides nothing.

Their code shipped in statifier 2.10.0: `Statifier.Send.BasicHTTP`, its
transport behaviour, the `:httpc` adapter, the optional
`ioprocessors_entry/2` callback and the `{module, opts}` registration came
in `15044527`; the `scxml-send-key` header in `b4e4a459`, and the
decoder's rule that sets no event field from it in `3ffcf9df`; the schema
key, the loopback front in the corpus host, the transform template and
the eleven claims in `b6f7fcab`. All four are in the `v2.10.0` tag
(`c8894aea`), and statifier 2.10.0 is published. Every claim above was
verified against `main` at `39942820`, which differs from that tag only
by the second Amendment above; nothing under `lib/`, `test/`, `tools/`
or `conformance/` differs.

Decision 8 point b's sentence on "the plan context a processor's
callbacks receive" is read with the Amendment of 2026-09-30 on which
callbacks receive `:opts`: the options reach `deliver/3` and `cancel/2`,
and `perform/2` gets its configuration through the instruction payload.

The Context describes the package at `dc1900d0`, as it says, and was
checked there: the twelve documents excluded as `:needs_basichttp` in
both exclusion files and absent from the corpus and the ratchet;
`ioprocessors_entry/1` taking the type string alone; a `:send_types`
value typed as a bare module; `Statifier.Machine.Content.Send`'s private
`data/3`; the handler clause of `Statifier.Session`'s private
`perform_instruction/3`; `failed_send/3` as a cast; and the `w3c` and
`scion` branches of `conformance/schema/case.json` each refusing `host`.
On `main` each of those is as the Decision directs: both exclusion files
carry none of the twelve, all twelve are in `conformance/corpus/w3c.json`
with `host.event_io_processors`, the eleven are in
`test/passing_tests.json` and `conformance/registry.json`, and test201 is
in neither. The sentences the Consequences name as made stale have each
been rewritten by that code.

Decision 1's durable-execution front, and the front decisions 3 and 9
leave to it, belong to statifier_router and are not built yet; nothing
on `main` here contradicts them. The Consequences bullet "Code builds
against this record at proposed. It stays proposed until the code that
implements it ships in a published version." is met here: the code
shipped in 2.10.0 and the record is accepted. Each Amendment's own
Status line, which says the record's Status is unchanged, speaks of what
that Amendment changes and still holds as written.

### Amendment 2026-10-02: a host refreshes the registered `_ioprocessors` entries by an explicit call

Status: accepted (2026-10-02) - amends decision 3 (when the entries are written) and
answers decision 9's row "A location read after a resume on a host whose
base URL moved"; every other decision, the two Amendments above, and the
record's own Status are unchanged.

Decision 3 says the entries "are still written once, when the session
starts", so a resumed session reads the location it started with. A host
whose base URL moved across a resume, or whose front rotated a location,
had no way to tell the chart. This Amendment adds that way as an
explicit, additive host call, and leaves the resume itself as it was
(ruled by the operator, 2026-10-01).

**The two calls.**

- `Statifier.MachineState.refresh_ioprocessors/1` takes a position and
  answers `{:ok, machine_state}` or `{:error, reason}`. It is pure.
- `Statifier.Session.refresh_ioprocessors/1` takes a live session and
  answers `:ok` or `{:error, reason}`. It is a `GenServer.call`, so the
  host learns the answer; it is the only one of `Statifier.Session`'s
  calls that changes a session's position.

**What a refresh recomputes and what it leaves.** Each registration
reads as follows, against the registration the position is stamped with
(`Statifier.Evaluator.SystemVariables`'s `refreshed_ioprocessors/3`):

| `_ioprocessors` key | After a refresh |
|---|---|
| A registered type whose processor exports `ioprocessors_entry/2` | Asked again with the type, `_sessionid` and the stamped registration's options, as at session start |
| A registered type whose processor exports only `ioprocessors_entry/1` | Unchanged; the re-stamped set's own `/1` entry is not used |
| The SCXML Event I/O Processor's URI | Unchanged |
| A type the stamp does not name | Unchanged |
| A type the stamp names that the datamodel has no key for | Not added |

The set of keys never changes, so the registered type set stays fixed
for the session's lifetime, as ADR-0069 decision 2 has it: a refresh
changes entry values, never what is registered.

**When it refuses.** Before any entry is recomputed, every processor in
the first row of the table that exports `check_registration/2` is asked,
in type order, through the asker `Statifier.Send.Types` already holds for
the fresh-start refusal (ADR-0069's Amendment of 2026-10-02). The first
`{:error, reason}` is the answer and nothing changes: for the Basic HTTP
processor without `:base_url`, `{:error, {:missing_option, :base_url}}`.
A check that raises or answers outside its contract does not stop the
refresh. A processor that exports `ioprocessors_entry/2` and no check is
asked for its entry as it is, and an entry that raises, or is not a
string-keyed map, raises out of the pure call as it does at session
start; inside a live session that raise exits the session.

For a session that registers something, the live call answers two more
errors, each changing nothing:

- `{:error, :not_running}` once the session has halted (`:done`,
  `:cancelled` or `:budget_exhausted`): no chart is left to read the
  entries.
- `{:error, :recorded_session}` for a session started with
  `record: true`. A recording is a persisted, versioned format
  (ADR-0057 decision 4; `Statifier.Session.Recording`'s
  `@format_version` is 5 at `f250ce2f`), and its entries hold delivered
  inputs only, with no entry for a datamodel refresh
  (`Statifier.Replay`'s private `apply_entry/2` has one clause per entry
  kind, at `f250ce2f`). Recording a live refresh would need a new entry
  kind and so a format version bump, which moves every recording's
  envelope, a session's that registers nothing included. A recorded
  session refreshes before it starts instead (next paragraph).

**The resume stays as it was; the host's step is re-stamp, then refresh.**
A resume still reads the entries its position carries, and nothing
recomputes them on its own: recomputing on every resume would change
what every resumed session reads. A host whose base URL moved re-stamps
the position with `Statifier.MachineState.put_send_types/2`, calls the
pure refresh, and passes the result to `Statifier.Session.start_link/2`'s
`:resume`. This answers decision 9's row: the moved base URL is the
host's to carry, through this call.

**Replay.** A session resumed this way and started with `record: true`
takes its recording's anchor from the position it boots with
(`Statifier.Session`'s private `boot/7`, at `f250ce2f`), which already
holds the refreshed entries, so a replay reads the same location the
live session read. The live call is never recorded, because a recorded
session refuses it.

**A sibling's rotation.** statifier_router documents, in the moduledoc
of `StatifierRouter.BasicHTTP` (read at `1bc8a8f`), that a rotated
location "does not reach the execution's own `_ioprocessors`" and that
the router hands its token to `ioprocessors_entry/2` through the
registration. With these calls a front can re-stamp the registration
with the current token and refresh, so the chart reads the rotated
location. Whether and how the router does so is its own record's to
decide.

Nothing changes for a session that registers nothing: its stamp is
`nil`, and both calls answer success with the position byte-identical.
The live call answers `:ok` for it before it looks at anything else, so
a session that registers nothing answers `:ok` when it has halted or
was started with `record: true` too: there is nothing to recompute, so
the refresh neither needs a running chart nor escapes a recording.

### Amendment 2026-10-02: a live refresh answers an entry that raises, and the session keeps running

Status: accepted (2026-10-02) - amends the Amendment above ("a host refreshes the
registered `_ioprocessors` entries by an explicit call") in one sentence;
every decision, every other Amendment, and the record's own Status are
unchanged.

The Amendment above ends its paragraph "When it refuses." with "inside a
live session that raise exits the session." That sentence is replaced by
this Amendment (ruled by the operator, 2026-10-02). A refresh is a host's
call into a running execution; a processor whose entry raises must not
end that execution, where at session start the same raise only fails the
start.

**The answer.** When a registered processor's `ioprocessors_entry/2`
raises during `Statifier.Session.refresh_ioprocessors/1`, the call
answers `{:error, {:ioprocessors_entry, type, exception}}`, where `type`
is the registered type string whose entry raised and `exception` is the
raised exception struct. An entry that is not a string-keyed map is
answered the same way, with the `ArgumentError` the entry check raises
(`Statifier.Send.Types`'s `session_entry!/3`). The session keeps running.

**All or nothing.** Every entry is computed before any is stored
(`Statifier.Evaluator.SystemVariables`'s `refreshed_ioprocessors/4`), so
after the error the session holds the position it held before the call:
an entry computed ahead of the one that raised is not stored either.

**What is answered.** Only an exception raised while an entry is
computed. A throw or an exit out of `ioprocessors_entry/2` is outside the
callback's contract, which returns a map or raises, and still exits the
session.

**The pure call is unchanged.** `Statifier.MachineState.refresh_ioprocessors/1`
still raises the entry's exception, with nothing returned, as session
start does: a host refreshing a position before a resume holds no running
execution and sees the processor's own exception.

The other answers of the live call (`:ok`, a refused registration,
`{:error, :not_running}`, `{:error, :recorded_session}`, and `:ok` for a
session that registers nothing) are unchanged.

### Amendment 2026-10-02: a list or a map value is written as JSON text, and a body is read as UTF-8 text whatever its type

Status: accepted (2026-10-02) - amends decision 4 (the outbound mapping) and decision 5
(the inbound decoder) by addition, and answers decision 9's row
"Non-scalar values in `params` (a map, a list, `:undefined`)" and the
residue sentence "JSON bodies and charset handling are residue" in its row
"A non-form content type inbound"; every other decision, the Amendments
above, and the record's own Status are unchanged.

Decision 9 left two encodings open. Outbound, statifier 2.10.0 writes a
parameter value that is a list or a map with `inspect/1`, an Elixir
rendering no receiver in another language reads. Inbound, it said nothing
about a JSON body or a charset. The rule below was ruled by the operator,
2026-10-01.

**Outbound: a list or a map is JSON text.** A parameter value (a `<param>`
or a `namelist` entry inside the form body), and a `<content>` body that is
a list, is written as follows:

| The value | Written as |
|---|---|
| A string | As it is (unchanged) |
| A number or a boolean | Its literal (unchanged) |
| `nil` | `null` (unchanged) |
| `:undefined` | The empty string (unchanged) |
| A list or a map every value inside which has a JSON form | JSON text, through Elixir's own `JSON` module (no dependency; the package requires Elixir `~> 1.18`, which ships it) |
| `:undefined` inside such a list or map | JSON `null` |
| A list or a map holding anything with no JSON form | The whole value's `inspect/1` text (unchanged) |
| Any other value (a tuple, an atom, a struct such as a `Date`) | Its `inspect/1` text (unchanged) |

A value has a JSON form when it is a UTF-8 string, a number, a boolean,
`nil`, `:undefined`, a proper list of such values, or a map whose every key
is a UTF-8 string and whose every value is such a value. The check is the
private `json/1` of `Statifier.Send.BasicHTTP`, and the writing its
private `encode/1`.

- **Map keys are strings.** JSON object keys are strings, and the
  datamodel's maps are string-keyed: predicator turns a value's atom keys
  into string keys, except `true` and `false`, when the value is bound into
  a context (`Predicator.Context.bind/3`'s documentation, predicator 9.0.0),
  and `Statifier.Evaluator`'s `context/1` binds every datamodel root that
  way. A map
  with any key that is not a string (an atom, `true`, a number) has no JSON
  form here. Writing an atom key as its name is not taken: `%{:a => 1, "a"
  => 2}` would become an object with two members named `a`.
- **No `inspect/1` inside JSON.** A list or a map that holds a value with
  no JSON form keeps its whole `inspect/1` text, the text 2.10.0 writes for
  it, rather than a JSON text with an Elixir rendering inside it or a
  failed send. Either of those would change what such a send POSTs or
  answers; the whole-value text changes nothing for it.
- **The body's content type does not change.** A `<content>` body that is a
  list is JSON text sent as `text/plain`, as every non-map content body is
  (decision 4). A `<content expr>` that evaluates to a map is still
  form-encoded (decision 4), so its top-level keys stay form parameters and
  only the lists and maps inside it are JSON text.

A receiver that uses this record's decoder reads such a form value through
the text rung (decision 5). This record does not promise that the value
reads back as the list or the map that was sent: the text rung reads
predicator literals, not JSON.

**Inbound: unchanged, and now recorded.** A JSON body
(`application/json`) is a body of another content type (decision 5): it
goes through `Statifier.EventData`'s text rung, so a JSON object or array
that is also a predicator literal becomes a map or a list in
`_event.data`, and any other text stays a string. The decoder reads no
charset: a body that is not UTF-8 is `{:error, {:not_utf8, :body}}`,
answered 400 by decision 5's status rule, whatever charset its content
type names, and a form body's values are held to the same test
(`Statifier.Send.BasicHTTP`'s private `body/1`, at `1d1361db`). A
datamodel string is UTF-8, so a front whose senders use another charset
transcodes the body before it calls `decode/1`.

**The one changed answer.** A list or a map parameter value, and a list
`<content>` body, that 2.10.0 wrote as `inspect/1` text is now JSON text,
with `:undefined` inside it as `null`. Nothing else changes: every scalar
keeps its text, a value with no JSON form keeps its `inspect/1` text, and
the inbound decoder answers as before. The encoding runs only inside this
processor, so a session that registers nothing sees nothing new: a list
or a map sent through a built-in type reaches its event as the value
itself, as before (`Statifier.Send.BasicHTTPSessionTest`).

### Amendment 2026-10-02: an inbound event's `sendid` and `origin` stay unset

Status: accepted (2026-10-02) - amends decision 5 (the inbound decoder) by addition, and
answers decision 9's row "`_event.origin` on an inbound event"; every other
decision, the Amendments above, and the record's own Status are unchanged.

Spec 5.10.1 asks for two event fields this decoder leaves unset: `sendid`,
when the sending `<send>` named an id, and `origin`, an address a reply can
be sent to. The first Amendment of 2026-09-30 says the decoder sets no
event field from the `scxml-send-key` header, without weighing an
author-named id, and decision 9 leaves `origin` as residue. This Amendment
decides both as statifier 2.10.0 already answers them, and says why (ruled
by the operator, 2026-10-01). No answer changes.

**`sendid` stays unset, for a named send as for a generated one.** The one
send id a POST carries is the second field of its `scxml-send-key` header
(the first Amendment of 2026-09-30). That field holds the send's id
whichever way it was made: the author's `id` attribute as written, or
`send_` and a counter when the author wrote none
(`Statifier.Machine.Content.Send`'s private `generate_send_id/2`, at
`b794f906`), and both travel in the header the same way
(`Statifier.Send.BasicHTTPTest`'s test "an author-named send id and a
generated one travel in the same key field"). From the header alone the
decoder cannot tell the two apart,
and 5.10.1 asks for `sendid` only when the author named one, so setting it
from every header would hand a chart an id its author never wrote. The
trade-off is accepted: an author-named send also arrives with
`_event.sendid` unset. Carrying an author-named id separately, in a
parameter or a header of its own, is not taken: it is a wire shape every
sibling processor and every front would have to match. A chart that needs
the id on the receiving side sends it in a `<param>`. The round trip
through the loopback front is
`Mix.Statifier.BasicHTTPFrontTest`'s test "an author-named send and a
generated one both arrive with no sendid".

**`origin` stays unset; a sender that wants a reply sends its location.**
The request `decode/1` is handed carries the method, the content type, the
body, the query string and the `scxml-send-key` value
(`Statifier.Send.BasicHTTP`'s `t:request/0`, at `b794f906`). None of them
is an address the receiver can POST back to, so `_event.origin` stays
unset, and `origintype` is the processor URI as decision 5 says. A sender
that wants a reply puts its own location in a parameter, for example
`<param name="replyto" expr="_ioprocessors['basichttp']['location']"/>`,
and the receiver replies with `targetexpr="_event.data.replyto"`. A
location is not a predicator literal, so the text rung (decision 8 point
f) keeps it a string. The decoder's answer is
`Statifier.Send.BasicHTTPTest`'s test "an inbound event's origin stays
unset, and its origintype is the processor URI", and the reply recipe end
to end is `Mix.Statifier.BasicHTTPFrontTest`'s test "an inbound event has
no origin, and a reply goes to a location the sender put in a param".

Nothing changes for a session that registers nothing: the decoder runs
only for this processor's inbound requests.

## Note (2026-10-02): query parameters beside each kind of body, and which callbacks receive `:opts`

This Note decides nothing. It states what decision 5 leaves implicit about
the query string, as the decoder reads it at `b794f906`, and points a
reader of decision 8 point b at the Amendment that settled it.

**Query parameters.** Decision 5 names the query string only as a place
the event name is read from, before the body. Its other parameters are
read by the body's kind (`Statifier.Send.BasicHTTP.decode/1` and its
private `data/2`, at `b794f906`):

| The body | The query string's other parameters |
|---|---|
| A form body (`application/x-www-form-urlencoded`) | Join `_event.data` beside the body's parameters, each through the text rung. The query string's pairs come first, so a name both carry takes the body's value: `Statifier.EventData.coerce/1`'s `{:params, _}` rung keeps the last duplicate |
| A body of any other content type, or a request with no content type | Dropped: `_event.data` is the body through the text rung, and the query string gives the event name only |

Beside either kind, a query string that is not UTF-8 once decoded is
`{:error, {:not_utf8, :query}}` (`Statifier.Send.BasicHTTP`'s private
`pairs/2`). The two rows are `Statifier.Send.BasicHTTPTest`'s tests
"beside a form body the query string's other parameters join the data, a
body parameter winning a name both carry" and "beside a body of another
content type the query string gives the event name only".

**Which callbacks receive `:opts`.** Settled by the Amendment of
2026-09-30 "a registration's options reach the planning callbacks, and
`perform/2` gets its configuration through the payload": a
`{module, opts}` registration's options reach `deliver/3` and `cancel/2`
under `:opts` (`Statifier.Session.Effects`'s private `processor_for/2`, at
`b794f906`), and `perform/2` receives the plan context without them
(`Statifier.Session`'s private `perform_instruction/3`, at `b794f906`), so
`Statifier.Send.BasicHTTP` carries its transport in the instruction
payload `deliver/3` plans.

## Note (2026-10-02): the four Amendments of 2026-10-02 are accepted

These four Amendments of 2026-10-02 are accepted on 2026-10-02:

- "a host refreshes the registered `_ioprocessors` entries by an explicit
  call";
- "a live refresh answers an entry that raises, and the session keeps
  running";
- "a list or a map value is written as JSON text, and a body is read as
  UTF-8 text whatever its type";
- "an inbound event's `sendid` and `origin` stay unset".

Their four Status lines are the only lines of the record that change; no
decision, consequence, Related entry, Note or Amendment paragraph changes
here, and this Note decides nothing. The Note of 2026-10-02 on query
parameters decides nothing and has no status to change. The two
Amendments of 2026-09-30 were accepted on 2026-09-30 and are untouched.

Their code shipped in statifier 2.11.0: the tag `v2.11.0` names
`bbc4c0ee`, and statifier 2.11.0 is published. Every claim the four make
was verified against `main` at `bbc4c0ee`, with the first Amendment's
paragraph "When it refuses." read as follows.

- **A superseded sentence.** The first Amendment's sentence "inside a live
  session that raise exits the session." no longer holds:
  `Statifier.Session.refresh_ioprocessors/1` answers
  `{:error, {:ioprocessors_entry, type, exception}}` and the session keeps
  running. The second Amendment, "a live refresh answers an entry that
  raises, and the session keeps running", names that change and replaces
  the sentence; its code is `f6910b18`.
- **A moved anchor.** The first Amendment cites
  `Statifier.Evaluator.SystemVariables`'s `refreshed_ioprocessors/3`. The
  same change, `f6910b18`, gave it a fourth argument that says whether an
  entry's raise is raised (the pure call) or answered (the live call), and
  the second Amendment cites it as `refreshed_ioprocessors/4`. The table
  the first Amendment cites it for holds at `/4`.
- **The order of the checks.** The first Amendment's "every processor in
  the first row of the table that exports `check_registration/2` is asked,
  in type order" is the order of asking: `refreshed_ioprocessors/4` asks
  them in type order and the first `{:error, reason}` is the answer, so a
  check after a refusing one is not asked. A fresh start asks every check
  before it uses any answer (`Statifier.Send.Types.rejected_registration/1`,
  ADR-0069's Amendment of 2026-10-02); a refresh does not.

The first Amendment's cites to `f250ce2f` (the recording's format version,
`Statifier.Replay`'s private `apply_entry/2`, `Statifier.Session`'s private
`boot/7`) hold at `bbc4c0ee`, and its sentence on statifier_router quotes
that package's moduledoc at `1bc8a8f`, as it says. The third and fourth
Amendments' cites to `1d1361db` and `b794f906` hold at `bbc4c0ee`.

## Note (2026-10-04): a `<content expr>` that evaluates to a struct is sent as its `inspect/1` text, as `text/plain`

Decision 4 tells a body from form parameters by `data`'s shape, and says
"a map is form-encoded". A struct is a map, so through statifier 2.11.0 a
`<content expr>` that evaluates to a struct (a `Date`, for example) took
the form arm: planning the send raised `Protocol.UndefinedError`, because
a struct cannot be read as parameters, the session performing it exited,
and no request was made.

A top-level struct is now never form-encoded. It is the body, written as
its `inspect/1` text and sent as `text/plain`: the text the Amendment of
2026-10-02 on JSON text already gives "Any other value (a tuple, an atom,
a struct such as a `Date`)". Decision 4's "a map is form-encoded", and
that Amendment's "A `<content expr>` that evaluates to a map is still
form-encoded", read as a map that is not a struct. No miss is reported,
because no transport failed. The arm is `Statifier.Send.BasicHTTP`'s
private `post/2`; the writing is its private `encode/1`, unchanged. The
encoding runs only inside this processor, so a session that registers
nothing sees nothing new.

This was ruled by the operator, 2026-10-03.
`Statifier.Send.BasicHTTPTest` and `Statifier.Send.BasicHTTPSessionTest`
pin it with a `Date`.
