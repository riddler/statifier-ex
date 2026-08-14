# ADR-0024: `<data src>` is never fetched

Status: accepted (2026-08-14)

## Context

`<data>` has three mutually exclusive value sources - `expr`, `src`, and
child content - and spec 5.3.2 gives all three the same timing rule:

> If the 'src' attribute is present, the Platform MUST fetch the
> specified object at the time specified by the 'binding' attribute of
> `<scxml>` and MUST assign it as the value of the data element.

"The time specified by the 'binding' attribute" means fetch timing is
binding-controlled: at initialization under `binding="early"`, and at
first entry of the containing state under `binding="late"` (5.3.3, and
B.2.2's "the processor MUST assign the specified initial values to data
elements only when the state containing them is first entered"). A
conforming `<data src>` is therefore a network or filesystem fetch that
can occur mid-`enter_states`, deep inside the interpreter.

That collides with ADR-0003. The core is
`(machine_state, event) -> {machine_state, [effect]}`, and every effect
this engine emits - `{:send, ...}`, `{:invoke, ...}`, `{:log, ...}` - is
fire-and-forget output, interpreted after the step returns. None feeds a
result back into the middle of an Appendix D procedure. A binding-time
fetch is different in kind: 5.3.2 requires the fetched value assigned
*as the value of the data element* at binding time, and a `cond`
evaluated later in the same microstep may read it. An effect-shaped
fetch would require `enter_states` to suspend mid-body, hand control to
the effect interpreter, and resume with the response - a coroutine core,
not the ADR-0003 core with one more effect variant. "Like `<send>`" is
the wrong analogy: `<send>`'s results, when any exist, arrive later as
ordinary external events; a fetch's result is consumed synchronously by
the very procedure that requested it.

What ships today (built by st-af3.3, traced end to end in
`docs/research/260814-st-bnr-data-src-never-fetched-test552.md`): `src`
is lowered, validated, and compiled to `{:src, uri}` on
`Statifier.Machine.Data`, and `bind_value/4` in
`lib/statifier/interpreter/datamodel.ex` matches that shape and raises
`error.execution`, leaving the id seeded to `nil`. That is exactly the
shape of 5.3.2's failure clause:

> If the value specified for a `<data>` element (by 'src', children, or
> the environment) is not a legal data value, the SCXML Processor MUST
> raise place error.execution in the internal event queue and MUST
> create an empty data element in the data model with the specified id.

applied unconditionally, without attempting the fetch. Whether that
unconditional application becomes the recorded semantics or a
session-layer fetch replaces it is the fork st-322 was filed to decide.
`docs/datamodel.md` has carried the contradiction as "named here, not
resolved" since st-af3.3 declined to decide it.

Demand, with st-bnr's corrected fact: exactly one file in the generated
corpus uses `<data src>` - `test/scxml_tests/mandatory/data/test552_test.exs`,
which fails on full conformance runs for exactly this reason - and there
are zero known embedders asking for the feature.

Two more inputs weigh in:

- **Security posture.** ADR-0004 stakes out an engine that is safe for
  end-user-authored documents: no eval, no side channels. A processor
  that dereferences whatever URI a document names is a server-side
  request forgery and local-file-read surface, handed to the document
  author. The v1 engine's refusal to fetch was part of why an Elixir
  SCXML engine is worth having; conforming here would spend that.
- **The spec's own escape hatch already exists in this engine.** 5.3.2:

  > The SCXML Processor MUST use any values provided by the environment
  > at instantiation time in place of those contained in the top-level
  > `<data>` elements. ... The manner in which the environment specifies
  > these overriding values is platform-dependent.

  Statifier implements this: `Statifier.Interpreter.Datamodel` skips
  binding any top-level `<data>` whose id the environment supplied. An
  embedder that wants `src` semantics fetches the URI itself - with its
  own HTTP client, allowlist, timeout, and supervision - and passes the
  value in as initial data. The I/O happens where ADR-0003 says I/O
  belongs, under the embedder's security policy rather than the
  document's.

## Decision

**`<data src>` is never fetched, at any binding time. This is a
deliberate, permanent deviation from 5.3.2's fetch MUST, recorded here
with ADR-0003's I/O boundary as the reason.** The shipped behavior is
the decided behavior: `src` compiles to `{:src, uri}`, binding raises
`error.execution` and leaves the id as an empty (nil) data element -
the failure clause's shape, applied unconditionally.

Three reasons, in order of weight:

1. **A binding-time fetch is not expressible in the ADR-0003 core.**
   Binding runs during machine initialization and, under
   `binding="late"`, mid-`enter_states`; the fetched value must be
   readable by the next expression in the same step. Effects are
   post-step outputs, not mid-procedure request-response. Honoring the
   fetch MUST means either blocking I/O inside the pure core (the exact
   v1 disease ADR-0003 exists to cure) or rebuilding the interpreter as
   a suspendable coroutine, which is a different architecture, not a
   feature.
2. **Fetching document-named URIs contradicts ADR-0004's security
   posture.** An engine that is safe for end-user-authored documents
   cannot let those documents direct the platform to dereference
   arbitrary URIs. The embedder-supplied-values path keeps the fetch
   under the embedder's policy, which is where ADR-0003 already puts
   every other interaction with the outside world.
3. **The demand is one corpus file and zero embedders.** test552 is the
   only `<data src>` user in the corpus, and the environment-override
   hatch covers the realistic embedder need (top-level configuration
   data) without any new code.

The rejected alternative - fetch as a session-layer effect - was not
rejected for cost alone. Even fully built, it would either violate the
timing MUST anyway (a pre-fetch at document-load time is not "at the
time specified by the 'binding' attribute" for late binding) or violate
ADR-0003 (a synchronous fetch inside binding). There is no design in
which this engine both keeps its core pure and conforms to 5.3.2's
letter; given that, the honest posture is a recorded deviation rather
than a half-conforming fetch with its own new deviation footnote.

**Scope limit.** This decision covers `<data src>` only. `<assign>` has
no `src` in this engine's surface today, and `<content>` fetching for
`<send>`/`<invoke>` payloads, if ever implemented, must argue its own
case - those sit at the effect boundary where a fetch may genuinely be
expressible, so they do not inherit this answer.

## Consequences

- test552 is this repo's one permanently red `<data src>` conformance
  file: in the corpus, failing visibly on full runs, absent from
  `test/passing_tests.json`, and gated by no `FeatureDetector` atom -
  the standing decided by st-bnr
  (`docs/research/260814-st-bnr-data-src-never-fetched-test552.md`),
  which this record ratifies. It is the same accepted-and-documented
  standing the ECMAScript-only tests have.
- The engine knowingly violates one MUST in 5.3.2 (fetch and assign)
  while keeping the failure clause's observable shape
  (`error.execution` plus an empty data element under the id), so a
  document using `src` gets defined, diagnosable behavior rather than
  silence. A conformance reader diffing this interpreter against 5.3.2
  finds the answer here instead of re-deriving it from a code comment.
- `docs/datamodel.md`'s open-contradiction paragraph is rewritten to
  state this decision and cite this record.
- Embedders who need remote data fetch it themselves and supply it via
  the environment-values path for top-level `<data>` ids. That path
  covers early-bound top-level data only; extending an override hatch
  to state-scoped late-bound ids is possible but waits for a real
  embedder to ask, and would amend this record's Consequences, not its
  Decision.
- `Statifier.Machine.Data`'s moduledoc and the `bind_value/4` clause
  already state the non-fetch and cite ADR-0003; a future touch of
  either file should add a citation of this record (ADR-0018's rule
  that ADR numbers are the durable citation form). Not worth a
  code-touching commit by itself.
- Reversing this decision means amending this record and ADR-0003
  together, and accepting one of the two violations named in the
  Decision. test552 is the acceptance test for any such future work.
