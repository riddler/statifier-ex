# ADR-0008: UXID for generated identifiers

Status: accepted (2026-08-02) - amended 2026-08-15 (invoke id format)

## Context

The engine generates identifiers in several places: session IDs (`_sessionid`),
`<send>` IDs (including `idlocation`), invoke IDs, and effect correlation IDs.
v1 used ad hoc generation and regenerated `_sessionid` on every expression
evaluation (a live bug). UUIDs are opaque and unsorted; bare random strings say
nothing about what they name. UXID (`~> 2.9`, same maintainer) produces K-sortable,
prefixed identifiers.

## Decision

All generated identifiers are UXIDs with a stable prefix per kind: `sess_` for
sessions, `send_` for send IDs, `inv_` for invocations. IDs are generated once at
the owning entity's creation and are immutable for its lifetime - `_sessionid` is
set when a session starts and never regenerated. Document-authored IDs (state IDs,
explicit `id` attributes) are always respected; UXIDs fill the spec's
"platform-generated id" holes only.

**An invoke's generated identifier is `"<stateid>." <> UXID(inv)`.**
*(Amended 2026-08-15: invoke id format.)* Spec 6.4.1 does not leave the
generated invoke id a bare platform-prefixed token; it names a composite
form:

> The automatically generated identifier MUST have the form
> stateid.platformid, where stateid is the id of the state containing
> this element and platformid is automatically generated. platformid
> MUST be unique within the current session.

W3C mandatory test224 is mechanical evidence for this: it asserts a
`predicator` `starts_with(Var1, 's0.')` against an `idlocation`-generated
invokeid, so a bare `inv_01J...` UXID with no state-id qualifier would
leave a mandatory conformance test permanently red. The generated
identifier is therefore `state.id <> "." <> UXID.generate!(prefix: "inv")`,
and the bare `inv_` UXID (no qualifier, no trailing dot) when the state has
no `id` - this engine leaves `Machine.State.id` `nil` for an anonymous
state rather than synthesizing one at load time, so there is no `stateid`
for the composite and uniqueness is all that remains of 6.4.1's MUST. An
author-written `id` attribute is used verbatim and never composed, per
this record's own "document-authored IDs are always respected."

This also settles a reading of "generated once at the owning entity's
creation and immutable for its lifetime" against spec 3.14, which draws
`<invoke>` and `<send>` out from every other optional id as the two
elements whose generated id is assigned "not at load time but each time
the element is executed":

> The ids for `<send>` and `<invoke>` are subtly different. In a
> conformant SCXML document, they MUST be unique within the session, but
> in the case where the author does not provide them, the processor MUST
> generate a new unique ID not at load time but each time the element is
> executed.

Read against this record's original "generated once ... immutable for its
lifetime," a state entered twice - invoking twice - looks at first like it
should keep one id across both entries. It does not, and there is no
conflict: the owning entity of an invokeid is the **invocation**, not the
`<invoke>` element. A state entered twice invokes twice and produces two
invocations, each with its own generated id, immutable for that
invocation's own life. "Generated once at creation" still holds - it is
the invocation, not the syntactic `<invoke>` element, whose creation the
rule is about.

## Consequences

- Log lines, effects, and error events are self-describing and time-sortable.
- Parent/child session trees are easy to follow in traces.
- Spec compliance note: SCXML only requires generated IDs be unique; prefixes are
  an implementation nicety and tests must not depend on their shape beyond the
  documented prefix.
