# ADR-0075: The Basic HTTP Event I/O Processor is a registered send type in statifier-ex, with a pure inbound decoder, an injected transport and a corpus host declaration

Status: proposed (2026-09-30) - builds on ADR-0069 (the processor is a
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

Status: proposed (2026-09-30) - amends decision 4 (the outbound mapping)
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

Status: proposed (2026-09-30) - amends decision 8 point b in part (which
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
