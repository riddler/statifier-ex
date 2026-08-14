# ADR-0029: Session.interpret/2 stays public; replay records four inputs

Status: accepted (2026-08-14)

## Context

st-cmq.4 shipped `Statifier.Session.interpret/2` public: it hands the
session a list of `Statifier.Effect.t()` values from any driver of the pure
core, planned through `Statifier.Session.Effects.plan/1` and performed on
exactly the code path the session's own drives of the core use, funneled
through the same `handle_cast` serialization as `send_event/2`. That was
Decision 9 of `docs/plans/260814-st-cmq.4-session-genserver-effect-
interpreter.md` - "a public seam, not a test hook" - with st-cmq.11 named
as its revisit trigger. The trigger is this record.

The seam's warrant is ADR-0003, whose Consequences say "Embedders can
supply their own effect interpreter". `interpret/2` is that consequence
read the other way: an embedder that drives the pure core itself can still
lean on a session for timer and routing service. It is also what makes
`:send_delayed` and `:cancel` testable end to end today, before st-cmq.3
gives those effects a document-side producer -
`test/statifier/session_test.exs`'s delayed-send and cancel suites have no
other way to put a timer into a live session.

The tension is with `docs/observability.md` constraint 6. Its replay claim
is a three-input tuple - (machine, initial data, external event log) - and
that tuple reconstructs a run only when every effect the session
interpreted was derived by the core from those inputs. An `interpret/2`
call hands the session effects no core drive produced, so a recording that
captured only the three inputs replays to a different session, and the
failure is silent: replay succeeds and produces a different answer.
`interpret/2`'s `@doc` says this today, and constraint 6 defers to that
`@doc` rather than stating the widened contract itself - a warning, not a
contract.

Two facts bound the options:

- No replay recorder exists, and before this record no bead tracked one.
  Constraint 6 is a constraint on code shape (one capturable input path,
  no side doors) with nothing yet that records.
- v2 is unreleased and `mix.exs` stays `2.0.0-dev`, so removing or moving
  `interpret/2` is free now and a breaking change after release. That is
  the argument for deciding now, not for deferring.

## Decision

**`interpret/2` stays public, as the ADR-0003 embedder seam it was shipped
as. Constraint 6's replay recording widens to four inputs - (machine,
initial data, external event log, `interpret/2` batches) - where the
fourth input is empty for any session never handed an `interpret/2` call.
Calling `interpret/2` does not void the replay guarantee; it obligates the
recording.** Three numbered decisions:

1. **Public, on `Statifier.Session`, under its own name.** The
   alternatives both cost more than they buy. Making it private would
   leave the delayed-send and cancel suites no honest path to a live
   timer until st-cmq.3 lands - a test-only back door (`:sys.replace_state`,
   a `@doc false` escape hatch, or casting `{:interpret, effects}`
   directly) is the same input path with the name filed off, unrecordable
   by construction and undocumented to the embedder ADR-0003 promised it
   to. Moving it behind a separately named embedder module would be
   mechanism with no second caller, the same standing rule ADR-0027
   decision 1 cites for excluding multiple named runtimes; the function
   already sits on the session it services, and a rename adds a module
   without removing the question.

2. **A sound recording has four inputs.** Replay re-derives core effects
   by re-driving the pure core from the event log, and re-injects what the
   core never produced: each `interpret/2` batch (its effect list),
   captured at its position in the session's serialized input order.
   `send_event/2`, `cancel/1`, fired timers, and `interpret/2` all cross
   the one GenServer mailbox, so that total order is well defined and
   observable at the boundary - the widening is a statement about the
   recording's contents, not a leak in the boundary. A session driven only
   through `send_event/2` keeps the three-input tuple unchanged; the
   fourth input prices the seam only for runs that used it.

3. **The contract is stated where an embedder reads it, in both
   directions.** `interpret/2`'s `@doc` carries the four-input contract
   (it already carried the widening; it now names this record), and
   `docs/observability.md` constraint 6 states the four-input form itself
   instead of deferring to the `@doc`. Neither surface is allowed to say
   "see the other one" in place of the claim.

**What this obligates: the recorder cannot be a subscriber.**
`Statifier.Session.Effects.plan/1` plans every effect to a
`{:notify, effect}` instruction on the same path whether the core produced
it or an `interpret/2` caller supplied it, so the subscriber stream is the
union of derived and injected effects with nothing distinguishing them -
and replay must treat the two oppositely (re-derive one, re-inject the
other). A sound recorder therefore attaches on the input side of the
session, not the output side. That recorder is st-dtm, filed as part of
this decision (discovered-from st-cmq.11); whether it is a session option
or a cooperating wrapper is that bead's design work, deliberately not
settled here.

## Consequences

- `docs/observability.md` constraint 6 now states the replay tuple in its
  conditional four-input form and cites this record; the "no side doors"
  clause is unchanged, because `interpret/2` was never a side door - it is
  on the one serialized, capturable input path.
- `Statifier.Session`'s moduledoc section and `interpret/2`'s `@doc` cite
  this record; the `@doc`'s widening paragraph is now the contract, not a
  caveat awaiting a decision.
- Decision 9 of the st-cmq.4 plan is discharged on its own revisit
  trigger, the same way ADR-0027 discharged that plan's Decision 1.
- st-cmq.3 landing does not demote `interpret/2` to test scaffolding. The
  tests that today reach timers only through it may migrate to real
  `<send delay>` documents; the function stays, because its warrant is the
  embedder seam, not the test gap it also happens to fill.
- st-dtm owes the recorder and a round-trip proof (record a run, replay
  it, compare effect stream and terminal snapshot - for one run that used
  `interpret/2` and one that did not). Until it lands, constraint 6
  remains what it was: a binding constraint on code shape, with the
  recording itself an unbuilt consumer.
- What would reopen this record: an embedder-facing reason to route
  injected effects around the serialized mailbox (which would break
  decision 2's ordering claim), or st-dtm discovering the input-side
  recording cannot capture `interpret/2` batches without a session-side
  change this record forbids. Neither is expected; either is argued here,
  not patched around.
