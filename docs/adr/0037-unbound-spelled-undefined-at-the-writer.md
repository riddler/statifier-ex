# ADR-0037: Unbound is spelled `:undefined` at the writer; `nil` means null

Status: accepted (2026-08-15)

## Context

The engine carries two distinct datamodel states with one spelling. predicator
6.0 (upstream px-o9v) split the value space: `nil` became the `null` literal's
own value and `:undefined` stayed the undefined literal's, and the 5.x
`normalize_value(nil) -> Undefined.value()` clause was dropped, so `nil`
survives `Predicator.Context.new/2` and `bind/3` unchanged. This repo kept the
old collapse alive on its own side: `Statifier.Evaluator.undefine_nils/1`
(`lib/statifier/evaluator.ex`) recursively rewrites `nil` to `:undefined`, and
`Evaluator.bind/3` applies it to every root bound into a
`Predicator.Context` - `_event` included, because `context/1`'s `bind_roots/2`
folds `bind/3` over every top-level datamodel key.

The rewrite exists because five writers spell "declared but no value yet" as a
raw `nil` in `machine_state.datamodel`:

- `Statifier.Evaluator.SystemVariables.initial/2` seeds `"_event" => nil`
  before any event is processed.
- `SystemVariables.event/1` writes `nil` for the `sendid`/`origin`/
  `origintype` fields `Statifier.Event` does not carry yet, and passes
  `event.data` through, where `nil` means "no data".
- `Statifier.Interpreter.Datamodel.seed/2` seeds every declared `<data>` id to
  `nil` (and its failure branches deliberately keep that seed - 5.3.2's "MUST
  create an empty data element").
- `Statifier.Machine.Content.Foreach`'s `declare/2` declares `item`/`index`
  with `Map.put_new(datamodel, item, nil)`.
- `Statifier.EventData.coerce/1`'s empty rungs return `nil` for empty
  `<content>` text and an empty `<param>` list.

The collapse this produces is the bead's finding, verified twice (bead
st-xw7a; `docs/plans/260815-st-cmq.3-send-cancel-content-nodes-and-effects.md`
Decision 3): `EventData.coerce/1` preserves a present-and-null JSON field
faithfully - `coerce({:text, ~s({"foo": null, "bar": 1})})` is
`%{"bar" => 1, "foo" => nil}` - and one layer later
`bind(ctx, "_event", %{"data" => %{"foo" => nil, "bar" => 1}})` rewrites it to
`%{"_event" => %{"data" => %{"bar" => 1, "foo" => :undefined}}}`. At
expression time, a field that arrived present-and-null is indistinguishable
from one that never arrived.

The spec distinguishes exactly the two states the collapse conflates. B.2.8.1
(`_event.data`), quoted from the local cache:

> Otherwise (i.e., if the content does not consist of key-value pairs), if
> the Processor supports JSON and it can interpret the content as JSON, it
> MUST create the corresponding ECMAScript object(s) as the value of
> _event.data.

The corresponding ECMAScript object for `{"foo": null}` has `foo === null`
true and `foo === undefined` false. B.2.1 names undefined as the *unassigned*
default, not null's spelling:

> If no value is assigned, the SCXML Processor MUST assign the variable the
> default value ECMAScript undefined.

And 5.10 is why the "declared, no value yet" state must read as undefined at
all:

> The SCXML Processor MUST NOT bind _event at initialization time until the
> first event is processed. Hence _event is unbound when the state machine
> starts up.

This engine's value space is predicator's, not ECMAScript's (ADR-0004), but
since predicator 6.0 that value space *represents both states*. Probed in this
worktree against the pinned predicator 8.x: with `x` bound to `nil`,
`x === null` is `{:ok, true}` and `x === undefined` is `{:ok, false}`; with
`y` bound to `:undefined`, `y === undefined` is `{:ok, true}` and
`y === null` is `{:ok, false}`; an absent map key reads `=== undefined` true,
`=== null` false - exactly the ECMAScript-corresponding answers. The only
thing standing between the engine and those answers is its own
`undefine_nils/1`.

The corpus does not depend on the collapse. Zero files under
`test/scxml_tests/` or `test/scion_tests/` contain the token `null`
(re-grepped for this record; `docs/research/260812-st-unt-*` open question 4
recorded the same fact). The 25 `undefined`-comparing conds across 24 W3C
files (inventoried in that research document) all compare against
`undefined`, never against `null`, and every one keeps its answer provided
the *writers* above respell - test319's seeded `_event`, test333/335/337/339's
event fields, test343/488/528's empty event data, the `Var<n>` `<data>` seeds,
and test150/151's `<foreach>` declarations. 40 corpus files use `<content>`;
none asserts a null-versus-undefined distinction.

## Decision

**The convention flips: "declared but no value" is spelled `:undefined` at
every site that writes it, and `nil` means exactly one thing - predicator's
null. `undefine_nils/1` is retired.**

Concretely:

1. **Writers spell unbound directly.** `SystemVariables.initial/2` seeds
   `"_event" => :undefined`; `SystemVariables.event/1` writes `:undefined`
   for the fields `Statifier.Event` does not carry; `Interpreter.Datamodel`'s
   `seed/2` seeds declared `<data>` ids to `:undefined` (its keep-the-seed
   failure branches unchanged in shape); `Foreach`'s `declare/2` declares
   `item`/`index` as `:undefined`; `EventData.coerce/1`'s empty rungs return
   `:undefined` instead of `nil`.
2. **Bind-time normalization stops.** `Evaluator.bind/3` and `bind_roots/2`
   hand values to `Predicator.Context.bind/3` verbatim; the only remaining
   normalization is predicator's own. A bound `nil` stays `nil` and reads
   `=== null`.
3. **`_event` is not special-cased.** The bead's question - should
   `undefine_nils/1` apply to `_event` at all - dissolves rather than getting
   a carve-out: it applies to nothing, and `bind/3` stays a generic function
   with no root-name knowledge.

Alternatives weighed:

- **Status quo** (keep the global rewrite): keeps a latent deviation from
  B.2.8.1's corresponding-object MUST, keeps `nil`'s double meaning, and
  keeps the comment burden that meaning demands - `run_program/2`'s
  "never write back wholesale" caveat and
  `Interpreter.Datamodel.write_location/4`'s raw-versus-normalized round-trip
  prose exist only to police the `nil`/`:undefined` seam.
- **Narrow `bind/3` for the `_event` root only** (rewrite the event
  structure's own fields, leave the interior of `data` untouched): fixes the
  processor-supplied payload but keeps both spellings alive, teaches a
  generic function a root name, and leaves the same collapse standing for
  author data - `<assign>` or `<data expr>` evaluating predicator's `null`
  still reads back `undefined`.
- **Treat it as upstream work**: nothing to send upstream. predicator did its
  half in 6.0; the collapse is this repo's own 5.x-compatibility shim, kept
  deliberately (the comment above `undefine_nils/1` says so) until this
  decision revisited it.

## Consequences

- **Follow-on implementation is implied and is one bead's worth of work**,
  touching: `lib/statifier/evaluator.ex` (drop `undefine_nils/1`, simplify
  `bind/3`/`bind_roots/2` and their docs),
  `lib/statifier/evaluator/system_variables.ex`,
  `lib/statifier/interpreter/datamodel.ex` (seed plus the step-4 and
  moduledoc prose about the `nil` round trip),
  `lib/statifier/machine/content/foreach.ex`, `lib/statifier/event_data.ex`,
  and the tests that pin the current mechanism
  (`test/statifier/evaluator_test.exs`,
  `test/statifier/evaluator/system_variables_test.exs` keep their observable
  answers; their sabotage lines change). The observable corpus answers are
  unchanged by design; the implementing branch proves it with a full
  conformance run (`mix test --include scion --include scxml_w3`), and
  re-checks once the Phase 4 send/cancel corpus atoms flip, per the bead.
- **The resumable truth changes spelling.** `MachineState.datamodel`
  (ADR-0012's inspectable position) carries `:undefined` for unbound entries
  instead of `nil`. `:undefined` is a plain, serializable atom - predicator's
  public undefined value, the same one `docs/datamodel.md` seam 3 adopted -
  so no ADR-0012 constraint is disturbed.
- **Embedder-visible, pre-2.0:** an environment-supplied `:datamodel` value
  of `nil` now means null rather than unbound; an embedder that wants
  "declared, no value" passes `:undefined`. Documented where the
  `:datamodel` option is documented.
- **Two comment complexes dissolve.** `run_program/2`'s reason for never
  writing the post-context back wholesale (it would rewrite untouched `nil`
  roots) and `write_location/4`'s reason for writing through the raw map (to
  keep unrelated seeds reading `nil`) both rested on raw-map-`nil` versus
  normalized-`:undefined` disagreeing; after the respell the raw map and the
  bound context agree on the unbound spelling. The top-level diff-merge
  itself stays - it still carries the system-variable write check.
- **A genuinely null payload becomes representable end to end.** With
  `coerce/1`'s empty rungs returning `:undefined`, a `<content>null</content>`
  or a null-valued `expr` yields `_event.data === null` rather than being
  conflated with absent data.
- **ADR-0024's wording gets a pointer, not an edit.** Its "leaves the id as
  an empty (nil) data element" phrase describes the seed this record
  respells; the implementing branch adds a one-sentence pointer there naming
  this record, the way ADR-0036 annotated ADR-0021, rather than silently
  rewording an accepted record.

### Open questions deferred to the implementing bead

1. **The outbound payload boundary.** When a `namelist` or `<param
   location>` under `<send>`/`<invoke>`/`<donedata>` references an unbound
   root, the respelled value is `:undefined`, and nothing yet decides whether
   that atom should escape into `Effect.Send.data` and sibling payloads or be
   translated at the effect boundary (ECMAScript's `JSON.stringify` drops
   undefined-valued members; B.2.8.1 is silent for a non-JSON wire). No
   corpus file observes the difference today.
2. **Where `Statifier.Event.data`'s absent spelling lives.** Whether the
   `Event` struct itself carries `:undefined` for "no data" (coerce's new
   return flowing through untouched) or keeps `nil` in the struct with
   `SystemVariables.event/1` translating at the datamodel boundary is a
   struct-typing call the implementation makes; either satisfies this
   record's observable contract.

### Both open questions, answered (st-1bjz, 2026-08-16)

1. **`:undefined` escapes untranslated**, into `Effect.Send.data` and its
   siblings. It is already the shipped behavior rather than a new choice: a
   `namelist` entry and a `<param location>` compile to ordinary predicator
   expressions evaluated against the normalized context, so the atom lands in
   `data` verbatim and this record changes nothing there. Translating would
   recreate, one layer out, the collapse this record retires. An *undeclared*
   root is a different case - ADR-0036's argument failure, which discards the
   whole message and never reaches `data`. A future external-wire processor
   owns its own encoding at its own boundary. Pinned at
   `test/statifier/machine/content/send_test.exs` and end to end in
   `test/statifier/session_test.exs`; recorded in `Statifier.Effect.Send`'s
   moduledoc.
2. **`Statifier.Event.data` carries `:undefined`**, while `sendid`,
   `origin`, `origintype`, and `invokeid` stay `nil` on the struct and are
   translated by `SystemVariables.event/1` at the datamodel boundary. `data`
   can hold a genuine null payload, so its two states collide and the writer
   must spell them apart; the four string fields cannot, so `nil` is
   unambiguous there.

**Question 2 was not the judgment call this record assumed it was.** B.2.8 is
normative and decides it outright, quoted verbatim from the REC:

> `name`, `type`, `sendid`, `origin`, `origintype`, and `invokeid` are String
> values, while `data` can be of any type. In cases where this specification
> does not specify a value for one of these fields or states that the field is
> empty or has no value, the Processor MUST set the value to ECMAScript
> undefined.

Both spellings this record called equally acceptable are therefore not equal:
whatever the struct holds internally, every one of those six fields MUST read
`undefined` from the datamodel when it has no value, which is what
`SystemVariables.event/1` now guarantees. The clause reaches only `_event`'s
own fields, so it does not settle question 1 - B.2.8.1 remains silent for a
non-JSON wire, and question 1's answer rests on the reasoning above rather
than on a MUST.

One writer outside `_event` is worth naming, because it is the same class of
mistake and the corpus does not cover it: `_name` is `String.t() | nil`
whenever `<scxml>` omits the optional `name` attribute, and 5.10 says only
that the Processor "MUST bind the variable `_name` ... to the value of the
'name' attribute", silent on absence. B.2.8's MUST does not reach it, so
`_name => :undefined` is this record's convention applied by inference, not a
clause citation - sound, and matching the behavior both v1 and the released
engine already had, but held on weaker ground than the six fields above.
