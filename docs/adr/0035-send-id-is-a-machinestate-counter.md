# ADR-0035: The send id is `send_<n>` off a new `machine_state.send_counter`

Status: accepted (2026-08-15)

## Context

st-cmq.3's bead description asks for "a `send_` UXID generated at execute
time." That wording predates ADR-0008's 2026-08-15 amendment and loses to it.
The amended record forbids a UXID for any id minted inside the pure core,
because UXID reads the wall clock and a CSPRNG, which would make `execute/2`
a function of `(state, event, clock, entropy)` instead of ADR-0003's
`(state, event) -> {state, [effect]}` - and observably so, since `<send
idlocation>` writes the generated id into the datamodel, where a replayed run
would then diverge from the recorded one. ADR-0008 names `<send idlocation>`
by this exact concern:

> `<send idlocation>` has no generation site in `lib/` today - `send_` ids
> are never generated. When that site lands it will sit inside the same pure
> core, so the no-entropy rule above already governs it: no UXID, a
> deterministic value from `%MachineState{}`. Its concrete format (and
> whether it shares this counter or carries its own) is left to the record
> that implements it, since 3.14 imposes no shape there.

This record is that record. Two questions remain open where ADR-0008 left
them: the concrete format, and whether the counter is shared with
`invoke_counter` or a sibling of its own.

Spec 3.14 settles the format question by leaving it unsettled. Unlike
`<invoke>`, which 6.4.1 pins to the composite `stateid.platformid` form,
`<send>` gets no format requirement at all:

> The SCXML processor MAY generate all other ids in any format, as long as
> they are unique.

3.14 also fixes when a generated id is minted, for both elements alike:

> The ids for `<send>` and `<invoke>` are subtly different. In a conformant
> SCXML document, they MUST be unique within the session, but in the case
> where the author does not provide them, the processor MUST generate a new
> unique ID not at load time but each time the element is executed.

## Decision

**The send id is `"send_" <> Integer.to_string(counter + 1)`, generated from a
sibling `machine_state.send_counter` field, not from `invoke_counter`.** The
first generated id is `send_1`. There is no state-id prefix: 6.4.1's
`stateid.platformid` requirement is `<invoke>`'s alone, and 3.14 frees every
other id, `<send>`'s included, to any unique format.

An author-written `id` is used verbatim and never advances the counter,
exactly as `generate_invoke_id/3` treats an author-written `id`. A fresh id is
generated on every execution of the `<send>` element, never memoized on it -
3.14's "not at load time but each time the element is executed" governs
`<send>` exactly as it governs `<invoke>`, and ADR-0008 already worked out
what that means for the owning entity: it is the execution (the individual
send), not the syntactic element, whose creation the "generated once,
immutable for its lifetime" rule is about. A state that sends twice produces
two ids.

**A sibling `send_counter`, not `invoke_counter` shared across both kinds of
id.** Two reasons:

- The two sequences answer to different governing clauses. `<invoke>`'s
  format is pinned by 6.4.1; `<send>`'s is free per the 3.14 sentence quoted
  above. Coupling a free-format sequence to a pinned one buys nothing - it
  only makes `<send>`'s numbering depend on an unrelated element's format
  rule for no reason.
- Sharing would let an `<invoke>` advance the send-id sequence, so a
  document's `send_` ids would depend on how many invocations happened
  first. Still deterministic and still replayable either way, but the ids
  stop being locally readable, and readable ids are exactly what
  `idlocation` is for.

The cost of a sibling field is the pattern ADR-0008's `invoke_counter` already
established: one struct field, one typespec line, one key in
`MachineState.new/2`, and one moduledoc section on `%MachineState{}`.

**The bead's "`send_` UXID" wording is superseded.** The `send_` prefix
survives; "UXID" does not. `st-cmq.3`'s description should be read with this
substitution in mind rather than edited to match, since the bead's wording is
historical context for the decision, not the decision itself.

## Consequences

- `%MachineState{}` gains a `send_counter` field alongside `invoke_counter`,
  both non-negative integers starting at `0`, both advanced only when the
  processor - not the author - supplies the id.
- Deterministic replay holds for `<send idlocation>` by the same construction
  ADR-0008 already proved for `<invoke idlocation>`: the id is a pure
  function of `%MachineState{}`, so a recorded run and its replay produce
  identical datamodels with no injection seam and no clock read.
- A document mixing `<invoke>` and `<send>` gets two independently-numbered
  sequences: `inv_1`, `inv_2`, ... and `send_1`, `send_2`, ..., each counting
  only its own kind. Neither format observes the other's count.
- No compatibility is broken: no prior release of this engine has generated a
  `<send>` id in any format, UXID or otherwise, since `<send>` has had no
  producer until this bead.
- An author who writes `id="send_1"` on one `<send>` while another `<send>`
  generates its id can produce two live sends sharing a sendid, which strains
  3.14's "they MUST be unique within the session". The collision is accepted
  rather than defended against: it is inherent to every counter-based format,
  the colliding document is already nonconformant under that same MUST, and
  6.3.1 tolerates the outcome anyway - "If multiple delayed events have this
  sendid, the Processor will cancel them all." Widening the counter's format
  to dodge an author id would trade a spec-conformant collision the author
  caused for less readable ids on every document.
