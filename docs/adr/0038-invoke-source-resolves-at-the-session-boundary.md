# ADR-0038: `<invoke>`'s source resolves at the session boundary, never inside the library

Status: accepted (2026-08-15)

## Context

ADR-0031 closed the argument-evaluation half of `<invoke>` and routed the
remaining question here by name: "whether anything downstream fetches the
resolved URI, and under what security posture, is st-cmq.7's call." ADR-0024
answered the sibling question for `<data src>` - "never fetched, at any
binding time" - on ADR-0004's security posture and ADR-0003's I/O boundary,
and drew its own scope limit around the answer:

> `<content>` fetching for `<send>`/`<invoke>` payloads, if ever implemented,
> must argue its own case - those sit at the effect boundary where a fetch may
> genuinely be expressible, so they do not inherit this answer.

`<invoke>` is exactly that effect boundary. Unlike `<data src>`'s binding-time
fetch, which would have to complete synchronously inside a pure-core
procedure to satisfy 5.3.2's timing MUST, an invocation's source is only
needed once the session-side effect performer decides to start a child - a
point after the core has already returned control, where an embedder-supplied
function is an ordinary call rather than a coroutine.

Spec 6.4.2 requires SCXML-typed services to treat `src` and `<content>` as
data of the same kind:

> these services MUST treat values specified by 'src' and `<content>`
> identically... they must interpret values specified by the `<content>`
> element or 'src' attribute as markup to be executed.

`Statifier.Effect.Invoke` already keeps `src` (a URI string, never
dereferenced by the core) and `content` (an already-resolved value or markup
text) as two fields for the reason its own moduledoc gives - one field cannot
hold both a reference and a resolved value. Something has to turn either one
into a `Statifier.Machine.t()` before a child session can start, and that
something did not exist before this record: `content` reaching the effect as
markup-in-a-binary is exactly 6.4.2's "markup to be executed", and compiling
it is `Statifier.compile/1`, already a plain function callable from inside a
session process. `src` names a resource with no such library-owned
resolution: dereferencing it is a network or filesystem read the library does
not perform, for the same reason ADR-0024 gives for `<data src>`.

## Decision

**The library never dereferences `src`.** `Statifier.Invoke.Source.resolve/2`
is the sole seam between an `%Effect.Invoke{}` and a `Statifier.Machine.t()`
ready to start as a child session:

- `content` present and a binary is compiled with `Statifier.compile/1`;
  compile errors fold to `{:error, {:compile, errors}}`.
- `content` absent, `src` present and an `invoke_source` resolver function
  supplied in `opts` is handed to that function, unchanged.
- `content` absent, `src` present, no resolver configured is
  `{:error, :src_not_resolved}` - the same posture ADR-0024 already commits
  to: an embedder that wants `file:`, `http:`, or an application-specific
  scheme supplies the fetch itself, under its own security policy, rather
  than the document directing the engine to dereference an arbitrary URI.
- `content` present but not a binary is `{:error, {:content_not_markup,
  content}}` - a value-shaped `<content>` (5.6's other case) names nothing an
  SCXML-typed service can start.
- Neither `src` nor `content` is `{:error, :no_source}`.

`content` is checked before `src` when a document specifies both, since 6.4
treats them identically and a document naming both is already
non-conformant; there is no ordering rule to violate by picking one.

Every `{:error, _}` this function returns becomes `error.communication` on
the parent session (3.12.2, "errors... such as those arising from `<send>`
and `<invoke>`"), through the same door a runtime-placement failure uses -
the session-side detail a later phase implements, not this record's concern.

## Consequences

- **Inline `<content><scxml>...</scxml></content>` still does not compile.**
  `Statifier.Lowering.Builders.build_content/2` rejects every element child of
  `<content>` today, so the twenty-five corpus files writing that shape reach
  `resolve/2` as an already-failed `Statifier.compile/1` call regardless of
  this record. Closing that gap is `area:parser` work - deciding how
  `<content>`'s element children survive lowering (a preserved DOM subtree, a
  kept source span re-parsed later, or a re-serialized-to-XML value) - and is
  filed as its own follow-up bead rather than decided here, on the same
  layer-boundary reasoning ADR-0024's own scope limit already applies. A
  `<content>` holding XML as static text compiles today and is unaffected;
  only element children are blocked.
- **`Statifier.Invoke.Source` is the seam a future `src`-fetching bead
  extends, not redesigns.** Shipping a default fetcher later means adding an
  `invoke_source` implementation and, if the library ever ships one itself,
  arguing that specific security posture on its own terms - it does not move
  where resolution happens or touch this module's contract.
- No corpus movement: `Statifier.Case` never starts a `Session`
  (test/support/case.ex), so `resolve/2` has no corpus caller yet regardless
  of what it returns. `invoke_elements` and `finalize_elements` stay
  `:unsupported` (Decision 7 of the st-cmq.7 plan).
- A future embedder-facing doc (README, `docs/`) that describes
  `Statifier.start_session/2`'s options should name `invoke_source` and cite
  this record rather than re-explain the posture inline.
