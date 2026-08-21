# ADR-0064: The position blob drops the per-drive snapshot fields

Status: accepted (2026-08-21) - amends 0052 in part (decision 3's payload
sentence: `routes` and `invoke_types` join `:machine` as dropped fields,
and `from_binary/2` blanks both on decode); no other 0052 decision moves;
adopts option (a) of bead st-otr0; the format version does not bump

## Context

Two serialization paths on `Statifier.Position` disagree about whether
`routes` and `invoke_types` are durable, and three documentation sites
promise the behaviour the code does not have.

The code, as of this record:

- `to_binary/1` builds its payload as
  `machine_state |> Map.from_struct() |> Map.delete(:machine)`
  (`lib/statifier/position.ex:102`), so `routes` and `invoke_types` are
  written to the blob with their save-time values.
- `from_binary/2` rebuilds via `struct!/2` with no blanking
  (`lib/statifier/position.ex:148`), so both fields come back verbatim.
- Only `import/2` blanks them (`lib/statifier/position.ex:511-512`), and
  the module's own `export/1`/`import/2` section states the rationale:
  both are per-drive/per-session snapshots a driver re-stamps before the
  next drive (ADR-0048, ADR-0051), not durable position state. ADR-0052
  decision 6 records the same reasoning for the export vocabulary.

The documentation, as of this record:

- `Statifier.Interpreter`'s moduledoc ("Rehydrating a position") says the
  two fields "come back `nil`: re-stamp both before the first drive."
  False against `from_binary/2` as it stands.
- `docs/persistence.md` (the pure-core recipe under "Resuming a session")
  calls them "the two fields `Statifier.Position.from_binary/2`
  deliberately returns `nil`, per-driver snapshots rather than durable
  position state." Also false against the code.
- `Statifier.Position`'s `import/2` docs correctly describe `import/2`,
  and by proximity imply the same model for the binary pair.

So the documented contract - in the interpreter moduledoc that ADR-0060's
consequences list commissioned, and in the persistence narrative
commissioned alongside it - is already the blanking behaviour. The code is
the outlier, not the docs. A resumed position today carries a *stale*
per-drive snapshot rather than an absent one, and stale is strictly worse
than `nil` for a consumer: `nil` announces itself at first use (ADR-0048's
`t:routes/0` gives `nil` a defined meaning, "no determination made"),
while a stale `Routes.t()` answers send-reachability against a previous
drive's session set while looking valid. `Routes.t()` holds live session
ids (`sessions: MapSet.t(String.t())`, `lib/statifier/send/routes.ex`),
so the current blob also bakes liveness-adjacent data into a durable
artifact, which sits oddly beside ADR-0060's organizing principle that
resume restores position, not liveness (its decision 7 enumerates exactly
this kind of non-restoration). `InvokeTypes.t()` is a `MapSet` of type
strings, so nothing unsafe is persisted on that side - the defect is
contract coherence, not safety.

`Statifier.Session`'s resume path is indifferent to the choice: its
resumed boot arm re-stamps both fields from the session's own state
(`MachineState.put_routes/2` with freshly built routes, and
`put_invoke_types/2` from the `:invoke_handlers` option's keys - ADR-0051
decision 3's "one constructor"; `lib/statifier/session.ex:1043-1044`).
The blob's copies are never read on that path. Only a host driving
`Statifier.Interpreter` directly can observe the stale values, and the
interpreter moduledoc has always instructed that host to re-stamp.

Downstream, statifier_persistence's storage conformance suite (its sp-5qa
work, their ADR-0003) deliberately pinned the current behaviour with a
test named "facade: routes and invoke_types round trip stale, not
blanked" rather than compensating for it - an explicit tripwire awaiting
this decision. Per the cross-repo contract-ownership rule, the repo whose
files change owns the decision, and `lib/statifier/position.ex` is here.

## Decision

**1. `from_binary/2` blanks `routes` and `invoke_types` on decode,
unconditionally.** The decoded payload has both keys dropped before
`struct!/2` runs, so both fields are `nil` on every decoded position -
regardless of blob vintage, and regardless of what a hand-written or
old-encoder blob carries. Blanking on decode rather than only on encode
is what makes the guarantee independent of who wrote the blob: the
same-revision codec now has exactly `import/2`'s contract for these two
fields, and the loud-`nil` hazard model replaces the silent-stale one.
`struct!/2` fills absent struct keys with their defaults, and both
fields default to `nil` (`lib/statifier/machine_state.ex:382-383`), so
the drop and the blank are the same operation.

**2. `to_binary/1` drops both fields from the payload, alongside
`:machine`.** ADR-0052 decision 3's payload sentence becomes "a plain map
with `:machine`, `:routes`, and `:invoke_types` deleted." Decision 1
already makes the written values unreadable, but writing them anyway
would keep live session ids sitting in durable blobs at rest - data no
reader can use and an operator can still see. Dropping them keeps the
blob's content equal to what the position contract actually promises to
restore, the same reasoning ADR-0052 decision 3 gives for `:machine`
(never write what the decoder will not use).

**3. The format version stays 2; this is not a shape change a reader must
be told about.** ADR-0059 decision 4 bumped `1 -> 2` because a key was
*added* whose absence in old blobs needed a blessed default and an
explicit upgrade clause. This change *removes* keys, and both directions
are compatible without signalling: a current-build reader of an
old-encoder blob drops the keys in decode (decision 1); an old-build
reader of a new-encoder blob rebuilds via `struct!/2`, which fills the
absent keys with their `nil` defaults - producing on the old build
exactly the state its own documentation told hosts to expect. A bump
would buy nothing and cost something real: every existing build would
refuse newly written blobs with `{:unsupported_format_version, 3}` for a
change it already handles correctly. The version-1 upgrade clause
(`timer_counter: 0`, ADR-0059) is untouched and composes with decision 1
in either order.

**4. The interpreter moduledoc and `docs/persistence.md` stand as
written; the false claims become true rather than corrected.** No prose
change is needed at either site - that is the point of choosing option
(a). What does change: `Statifier.Position`'s `to_binary/1` and
`from_binary/2` docs name the two dropped/blanked fields and point at the
existing `export/1`/`import/2` section for the rationale, and the
moduledoc's "the exported map deliberately omits" framing widens to cover
the binary pair, since the omission is now common to both vocabularies.

Rejected alternative, recorded rather than left silent: option (b),
declaring the faithful-stale round trip intended and correcting the two
doc sites to say "restored stale - re-stamping is mandatory on every
resume." It keeps blob bytes identical across the change, but it corrects
two documents to describe a hazard instead of removing the hazard, leaves
the codec pair and the export pair with opposite contracts for the same
two fields, and leaves session ids in durable blobs. Nothing depends on
the stale values: the only known reader is the downstream pin test that
exists precisely to be deleted when this decision lands.

## Consequences

- A pure-core host that (against the documented contract) read the stale
  `routes`/`invoke_types` off a decoded position loses them. The
  interpreter moduledoc has instructed re-stamping since the rehydration
  section existed (ADR-0060's consequences list), so this breaks only
  undocumented reliance. Session-based resume is byte-for-byte unaffected.
- statifier_persistence's "facade: routes and invoke_types round trip
  stale, not blanked" pin goes red by design when its statifier pin moves
  past this change (the ADR-0061 SHA-pinning contract's fragment rule
  covers the break). Their fix is deleting the pin test and reverting the
  doc paragraph that described the stale behaviour; no compensation code
  exists to unwind. The implementation session for this record should
  leave a dated note on the downstream tracker's pinning bead when the
  change lands, since st-otr0 itself carries `mirrors: none`.
- Blob bytes shrink slightly and, more to the point, durable position
  blobs no longer contain any live session id - `Routes.t().sessions` was
  the one liveness-adjacent value that had been crossing the persistence
  boundary. ADR-0060 decision 7's non-restoration list gains no new
  entry; rather, the codec stops restoring something that list's
  principle already excluded.
- Implementation, sized on st-otr0's remaining work (this record changes
  no code): the two-line `Map.drop/2` additions in `to_binary/1` and
  `from_binary/2`'s decode path, the `Statifier.Position` doc adjustments
  from decision 4, and round-trip tests asserting both fields decode to
  `nil` - including from a payload carrying stale non-`nil` values, to
  pin decision 1's "regardless of what the blob carries" clause against
  old-encoder blobs. A user-facing changelog fragment is warranted
  (`changelog.d/st-otr0.md`): the round-trip behaviour of a public codec
  changes.
- What would reopen this record: either field becoming genuinely durable
  state - `invoke_types` is ADR-0051's territory to reopen first, and
  `routes` ADR-0048's - or a demonstrated host need to inspect a saved
  position's snapshot values, which would arrive as a new read-only
  accessor decision, not as a revert of the blanking.

## Related

- ADR-0052 (the position codec; decision 3's payload sentence is amended,
  decision 6's per-drive rationale is extended to the binary pair)
- ADR-0060 (resume restores position, not liveness; its rehydration
  narrative and re-stamp instruction become literally true)
- ADR-0048 (`routes` as a per-drive, caller-declared snapshot; `nil` as
  "no determination made")
- ADR-0051 (`invoke_types` stamped once per session from the handler map;
  the "one constructor" the session resume path already uses)
- ADR-0059 (the format-version-bump precedent decision 3 distinguishes)
- ADR-0061 (the SHA-pinning contract under which the downstream break is
  a documented, fragment-covered event)
