# ADR-0008: UXID for generated identifiers

Status: accepted (2026-08-02) - amended 2026-08-15 (invoke id format; invoke platformid is a session counter, not a UXID) - amended 2026-08-15 (st-mvna: the uxid dependency is dropped; the format decisions stand)

## Context

The engine generates identifiers in several places: session IDs (`_sessionid`),
`<send>` IDs (including `idlocation`), invoke IDs, and effect correlation IDs.
v1 used ad hoc generation and regenerated `_sessionid` on every expression
evaluation (a live bug). UUIDs are opaque and unsorted; bare random strings say
nothing about what they name. UXID (`~> 2.9`, same maintainer) produces K-sortable,
prefixed identifiers.

## Decision

Generated identifiers minted **outside the pure core** are UXIDs with a
stable prefix per kind: `sess_` for sessions. Identifiers minted **inside
the pure core** - today only the invoke id, and any future `<send
idlocation>` generation site - are never UXIDs: they are deterministic
values derived from `%MachineState{}` alone, because UXID reads the clock
and a CSPRNG and the core's contract does not admit either. IDs are
generated once at the owning entity's creation and are immutable for its
lifetime - `_sessionid` is set when a session starts and never
regenerated. Document-authored IDs (state IDs, explicit `id` attributes)
are always respected; generated ids fill the spec's "platform-generated
id" holes only.

*(This section originally read "All generated identifiers are UXIDs with a
stable prefix per kind: `sess_` for sessions, `send_` for send IDs, `inv_`
for invocations." The 2026-08-15 amendment replaces that sentence with the
core/non-core split above; the invoke-specific decision follows.)*

**An invoke's generated identifier is
`state.id <> "." <> "inv_" <> counter` - or bare `inv_<counter>` when the
state has no `id` - where `counter` is one session-global auto-increment
carried on `%MachineState{}`, not a UXID.** *(Amended 2026-08-15.)* Two
constraints force the two halves of that shape.

The composite form is 6.4.1's. Spec 6.4.1 does not leave the generated
invoke id a bare platform-prefixed token; it names a composite form:

> The automatically generated identifier MUST have the form
> stateid.platformid, where stateid is the id of the state containing
> this element and platformid is automatically generated. platformid
> MUST be unique within the current session.

W3C mandatory test224 is mechanical evidence for this: it asserts a
`predicator` `starts_with(Var1, Var2)` with `Var2` seeded `'s0.'` against
an `idlocation`-generated invokeid, so a generated id without the state-id
qualifier would leave a mandatory conformance test permanently red.

The counter is ADR-0003's. `generate_invoke_id/2` runs inside
`main_event_loop/1`'s fold - the pure core - and its first landed shape
called `UXID.generate!` there. UXID reads the wall clock and a CSPRNG, so
on that path the core was not `(state, event) -> {state, [effect]}` but
`(state, event, clock, entropy) -> ...`, and ADR-0003's promise
"Deterministic replay: a session is (machine, initial data, event log)"
was broken observably: `<invoke idlocation>` writes the generated id into
the datamodel, so a recorded run and its replay diverge in program state.
Where ADR-0008's identifier aesthetics collide with ADR-0003's core
contract, ADR-0003 wins. A counter read from and written back to
`%MachineState{}` is a pure function of the state, replays identically,
and satisfies ADR-0012 constraint 1 (the counter is an inspectable field,
not hidden generator state).

Contrast the one other generation site, `MachineState.new/2`
(`lib/statifier/machine_state.ex:322`): the `sess_` UXID is generated
once, at construction, outside any fold, via
`Keyword.get_lazy(opts, :session_id, ...)` - already injectable, already
outside the replay boundary (ADR-0029 records the session id as an input).
It stays a UXID: session ids must be unique **across** sessions - the
ADR-0027 registry and parent/child routing depend on it - which is exactly
what entropy buys and exactly what a per-session counter cannot provide.
Invoke ids need uniqueness only **within** the session (6.4.1's MUST), so
a session-local counter is sufficient there and entropy buys nothing.

The counter is session-global, not per-state or per-element. 6.4.1 hangs
its MUST on the platformid itself - "platformid MUST be unique within the
current session" - not on the composite. Per-state counters would give
`s0.1` and `s1.1` the same platformid `1`, satisfying composite uniqueness
while violating the clause as written. One counter for the whole session
makes every platformid distinct by construction, and also keeps the
anonymous-state fallback unique without any special case.

The platformid keeps the `inv_` prefix: `s0.inv_1`, not `s0.1`. 6.4.1 is
silent on the platformid's content, so both are conformant; the prefix
stays for this record's original self-describing intent - a `.inv_`
substring in a log line, a trace, or a datamodel dump says what the token
is, where a bare `s0.1` reads as a decimal or a version, and grepping
`inv_` still finds every generated invocation id. test224 constrains only
the `s0.` half and is indifferent to the rest.

The anonymous-state fallback is the same platformid with no qualifier:
`inv_<counter>`, no dot. This engine leaves `Machine.State.id` `nil` for
an anonymous state rather than synthesizing one at load time, so there is
no `stateid` for the composite and uniqueness is all that remains of
6.4.1's MUST - carried by the session counter. A bare `1` would be a poor
identifier in every surface the id reaches; `inv_1` is the composite minus
its qualifier rather than a third format. An author-written `id` attribute
is used verbatim and never composed, per this record's own
"document-authored IDs are always respected."

**Scope: this format is `<invoke>`'s only; the no-entropy rule is not.**
Spec 3.14 mandates the composite form for `<invoke>` alone and frees
everything else:

> Finally note that the automatically generated id for `<invoke>` has a
> special format. See 6.4.1 Attribute Details for details. The SCXML
> processor MAY generate all other ids in any format, as long as they
> are unique.

`<send idlocation>` has no generation site in `lib/` today - `send_` ids
are never generated. When that site lands it will sit inside the same pure
core, so the no-entropy rule above already governs it: no UXID, a
deterministic value from `%MachineState{}`. Its concrete format (and
whether it shares this counter or carries its own) is left to the record
that implements it, since 3.14 imposes no shape there.

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
invocations, each with its own generated id (the counter advances per
generation, which is per execution), immutable for that invocation's own
life. "Generated once at creation" still holds - it is the invocation, not
the syntactic `<invoke>` element, whose creation the rule is about.

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

**The uxid dependency is dropped; the format outlives the library.**
*(Amended 2026-08-15, st-mvna.)* After the amendment above, `UXID.generate!`
has exactly one call site in the library: the session id in
`MachineState.new/2` (`lib/statifier/machine_state.ex:423`,
`Keyword.get_lazy(opts, :session_id, fn -> UXID.generate!(prefix: "sess")
end)`). Send ids and invoke ids are `%MachineState{}` counters and are out
of reach permanently - ADR-0003 forbids the core a clock or a CSPRNG, and
ADR-0035 and the invoke amendment above already decided both. One call site
does not justify a dependency every embedder inherits, because everything
this record wanted from the library is a property of the *format*, not the
implementation: a stable `sess_` prefix, lexicographic sort by creation
time, and a hyphen-free body so a double-click selects the whole id.

`MachineState.new/2` therefore mints the session id inline: `"sess_"` plus
a lowercase Crockford base32 encoding of a 48-bit big-endian
`System.os_time(:millisecond)` timestamp followed by at least 80 bits of
`:crypto.strong_rand_bytes/1` output. That is the same
timestamp-then-randomness layout UXID's defaults produce (48-bit time, 10
random bytes), so all three format properties survive, and the entropy
that makes session ids unique **across** sessions - what the ADR-0027
registry and parent/child routing depend on - is kept at full strength.
The generator runs outside the pure core, exactly where the UXID call sat;
nothing about the core/non-core split above moves.

The monotonicity question, answered before the dependency call was made:
dropping the library loses no within-millisecond monotonicity, because the
engine never had it. UXID's monotonic mode is opt-in - a per-call
`monotonic:` option or the `:uxid` application env, and `UXID.monotonic/0`
defaults to `false` - and this library passes no such option and sets no
such env, so two `sess_` ids minted in the same millisecond already sorted
in random relative order. Nothing observes that order anyway: session ids
are compared for equality and embedded in routing strings (registry keys
per ADR-0027, `#_scxml_` + sessionid targets per C.1, `_sessionid` and
`_ioprocessors` values, ADR-0029's recorded input) and are never sorted -
no `Enum.sort` in `lib/` touches a session id. Sortability by creation
*millisecond* survives in the new layout; ties within one millisecond stay
unordered, exactly as before.

Everything else in this record stands: the `sess_` prefix, the core/non-core
split, "generated once at the owning entity's creation", and both counter
decisions. This amendment reverses only the "use this library" half of the
original decision - the record is amended, not superseded.

## Consequences

- Log lines, effects, and error events are self-describing. Time-sortability
  now holds for `sess_` ids only; invoke ids sort by generation order within
  their session instead, which is the order that matters in a trace.
- Parent/child session trees are easy to follow in traces.
- Spec compliance note: SCXML only requires generated IDs be unique; prefixes are
  an implementation nicety and tests must not depend on their shape beyond the
  documented prefix.
- *(2026-08-15)* Deterministic replay holds for `<invoke idlocation>` by
  construction: the id is a pure function of `%MachineState{}`, so a
  recorded run and its replay produce identical datamodels and effect
  streams with no injection seam. This supersedes `st-futl` ("Injectable
  invokeid generator for deterministic replay"), whose seam existed only to
  restore the determinism the counter now provides directly; the bead
  should be closed as superseded by this amendment.
- *(2026-08-15)* `generate_invoke_id/2`
  (`lib/statifier/interpreter.ex`) changes signature to take and return the
  counter's carrier, `UXID` disappears from the invoke pass, and
  `%MachineState{}` grows the counter field - the sole remaining UXID call
  site in `lib/` is `MachineState.new/2`'s session id.
- *(2026-08-15)* An id-shape change before any child-session mechanics
  exist (st-cmq.7) breaks no compatibility: no persisted run, external
  service, or sibling session has ever seen a UXID-form invoke id.
- *(2026-08-15, st-mvna)* `{:uxid, "~> 2.9"}` leaves `mix.exs` and
  `mix.lock`; embedders inherit one fewer transitive dependency. No
  compatibility break: a `sess_` id is opaque to every consumer - compared,
  registered under, and embedded in routing strings, never parsed or
  decoded - and the inline layout keeps the same prefix-underscore-base32
  shape.
- *(2026-08-15, st-mvna)* The ADR guard's `@uxid_adhoc_pattern`
  (`lib/mix/statifier/adr_guard.ex`) flags `:crypto.strong_rand_bytes(` as
  ad-hoc id generation. The inline generator's site must carry an
  `ADR-0008` citation comment (the guard's escape pattern), and the finding
  message "ADR-0008 makes generated IDs UXIDs" should be reworded by the
  implementing bead - the check's substance, no ad-hoc id minting outside
  this record's formats, is unchanged and stays enforced.
- *(2026-08-15, st-mvna)* Prose that reads "`sess_` UXID" (moduledocs in
  `session.ex`, `supervisor.ex`, `session/recording.ex`,
  `evaluator/system_variables.ex`, `machine_state.ex`;
  `docs/architecture.md`, `docs/datamodel.md`) becomes "`sess_` id" as the
  implementing bead touches it - the format is this record's, not the
  library's. Implementation is that separate bead's whole scope: `mix.exs`
  (area:build) and `machine_state.ex` (area:interpreter); this record
  changes no code.
