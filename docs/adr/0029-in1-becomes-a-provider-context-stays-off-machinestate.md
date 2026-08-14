# ADR-0029: `In/1` becomes a provider; the built context still is not a `MachineState` field

Status: accepted (2026-08-14)

## Context

`Statifier.Evaluator.context/1` is the sole constructor of a
`%Predicator.Context{}` over live machine data. Before this record, `In/1`
was an inline `functions:` closure over `machine_state.machine` and
`machine_state.configuration` (`lib/statifier/evaluator.ex`, pre-`st-l0t`
shape): because the configuration was captured, the whole context - the
functions map included - had to be rebuilt whenever the configuration moved.

ADR-0028 threaded one context within an executable-content block and
deliberately left the across-blocks context untaken, gating that decision on
two grounds its own text stated under "Why the built context is not a
`MachineState` field": a non-resumability ground it called contingent on the
closure ("dissolvable by the `px-8ii` provider seam, already landed upstream
but not taken here"), and a staleness ground it called structural and said
"survives the px-8ii seam entirely". `st-l0t` (this record's bead, mirrors
`px-10u`) took the `px-8ii` seam - `Predicator.FunctionProvider` plus
`Context.new/2`'s `providers:`/`host:` options and `Context.put_host/2`,
landed in predicator 5.0.0 specifically for this profile - and this record is
the re-answer ADR-0028 deferred.

Three measured facts bound the decision, all from
`bench/results/260814-st-l0t-provider-host-seam.md`:

- `Context.put_host/2` costs 0.0330 us / 0.0859 KB against `T_full`'s 2.30 us
  / 10.92 KB at `:corpus` before this change - roughly 70x faster and 127x
  lighter than a whole-context build.
- `Context.resolve_functions/1` costs the same whether `In/1` is a provider
  entry or an inline closure - 1.36 us / 5.80 KB versus 1.40 us / 5.41 KB at
  `:corpus`, both within the run's own deviation band. **A provider swap by
  itself moves no benchmark number**; Phase 1's before/after `T_full` rows
  confirm this directly.
- That fixed resolution term is 56.6% of one context build at `:corpus`
  (`T_fixed / T_full`, ADR-0028's own Modifier C finding). Hoisting it to a
  compile-time constant - possible only once the functions map holds no
  captured configuration - drops `T_full` at `:corpus` from 2.30 us / 10.92 KB
  to 1.13 us / 4.77 KB, a 50.9%/56.3% reduction, and drops `measured
  macrostep` on the corpus-representative `realistic` document family from
  17.39 us / 74.19 KB to 13.58 us / 43.18 KB, a 21.9%/41.8% reduction. The
  three synthetic `:stress_*` size points show this win vanishing as the
  datamodel grows past corpus scale, exactly as the fixed term's shrinking
  share predicts - reported in the results document as noise or flat rather
  than as wins.

So the seam's value was never that a provider resolves faster than a closure.
It is that a provider-built functions map contains no captured configuration,
which makes that map static - identical for every context this library ever
builds - and makes the configuration a value set separately, per site, with
`put_host/2`.

## Decision

`In/1` is a `Predicator.FunctionProvider` (`Statifier.Evaluator.Functions`)
reading `context.host` rather than a closure. The functions map is resolved
once, at compile time, into a module attribute
(`Statifier.Evaluator.Functions.base_context/0`). The configuration arrives
per site through `Predicator.Context.put_host/2`
(`Statifier.Evaluator.put_configuration/2` is the public wrapper), and
`context/1` binds each datamodel root into the base context with the
existing `bind/3` rather than calling `Predicator.Context.new/2`.

**No context is stored on `%MachineState{}`, and the threaded interval is not
widened across blocks or microsteps.** A context still lives on the stack of
whatever called `context/1`, for the duration of the evaluation site that
built it, same as before this record.

### Grounds, restated

- **Ground 1 (non-resumability) dissolves.** Its own text made itself
  contingent on the closure (`lib/statifier/evaluator.ex`, the pre-`st-l0t`
  "This ground is contingent on the closure" sentence): a local fun in
  `functions` could not survive a node boundary, a code reload, or a
  round-trip through storage, so a struct carrying one could not be a
  resumable position under ADR-0012 constraint 1. The contingency is met -
  every resolved `functions` entry is now a `{module, atom}` pair, which is
  exactly what a `%Predicator.Context{}` must hold to escape into a compile-time
  module attribute at all, since a `function()` value fails that escape at
  compile time. `test/statifier/evaluator/functions_test.exs` and
  `test/statifier/evaluator_test.exs` (landed in Phases 1-2) assert this
  mechanically: every entry in a built context's `functions` map matches
  `{_arity, {module, atom}}`, so the property is enforced by the compiler and
  the test suite together, not by review.
- **Ground 2 (staleness) does not dissolve, and changes species.** ADR-0028
  called it structural and said it "survives the px-8ii seam entirely" - that
  claim is too strong as written, and this record says so plainly. What
  actually survives is a narrower obligation: `host` no longer needs a whole
  context rebuild to refresh - one `put_host/2` moves it in O(1) - but `data`
  still needs a `bind/3` at each site the datamodel changes, and this plan
  did not add refresh where none existed. It stops being "stale by
  construction" (true of every stored context, unconditionally) and becomes
  an exhaustiveness obligation over the seven datamodel write sites this
  plan's Phase 2 enumerated, two of which -
  `MachineState.put_event/2`'s `"_event"` write and the `Map.put_new(id, nil)`
  `<data>` seed in `lib/statifier/interpreter/datamodel.ex` - bind into no
  context today, because nothing holds a context across either write. A
  stored context would need every one of the seven covered, correctly,
  forever; a missed site would answer stale silently rather than raising.
  That is a different, and in this codebase's history a worse, failure shape
  than the closure's outright non-resumability, which is exactly why this
  ground still blocks storage even though the seam that dissolved ground 1
  narrows it.
- **Ground 3, new: a stored context would duplicate state `%MachineState{}`
  already holds.** Its `data` would restate `machine_state.datamodel`; its
  `host` would restate `machine_state.machine` and `machine_state.configuration`.
  Two representations of the same fact that must agree and can silently
  disagree is a different constraint-1 failure mode from a closure's outright
  non-resumability - not "cannot be inspected or resumed" but "can be
  inspected, resumed, and wrong" - and it is a species of sharp edge this
  codebase already documents elsewhere:
  `lib/statifier/machine_state.ex`'s note on `internal_queue` (`:queue.queue/0`
  values that hold the same events in the same order can still differ
  structurally, so `==` is not a reliable same-position test) is a different
  instance of the same shape, two fields that can drift out of the agreement
  a reader assumes. A field that must be kept synchronized with two others by
  discipline rather than by construction is exactly the kind of thing
  constraint 1 exists to rule out, even when each field taken alone would
  satisfy it.
- **Host width: `{machine, configuration}`, unchanged from the Phase 1
  shape.** The narrower `{id_to_index, configuration}` - reaching directly
  into the ADR-0005 interning seam's private field instead of through
  `Machine.index/2` - exists to reduce duplication in a *stored* context, and
  this decision stores nothing: a stack-local context holding a second
  reference to an immutable `%Statifier.Machine{}` costs one word on the
  BEAM, and keeping the whole machine keeps the provider reading through the
  public `Machine.index/2` seam rather than a private field. Narrowing stays
  available as a one-line change if a stored context is ever decided; nothing
  here forecloses it.

## Consequences

- ADR-0012 constraint 1 (`docs/observability.md`) is untouched: nothing is
  stored on `%MachineState{}`, so every value of that struct remains a
  complete, inspectable, resumable position exactly as before this record.
- `docs/datamodel.md`'s "once per evaluation site" commitment is unchanged.
  This record changes what a build costs, not how long a built context's
  interval lasts - the site is still the whole executable-content block or
  selection round, never a single expression, and never the whole macrostep.
- `px-rnc` (predicator-ex, mirrors `st-sdh`) proposes memoizing
  `resolve_functions/1`'s per-call provider validation upstream. Re-read
  2026-08-14 (note on `st-l0t`): `px-rnc` is in progress, its own Phases 1-3
  landed but the bead is not closed; `px-10u` (mirrors `st-l0t`, a related
  but separate saving on the same call path - a `normalize: false` vouch that
  removes half the size-scaling term rather than the fixed term) is closed
  and merged. If `px-rnc` lands, it would make this record's compile-time
  hoist redundant rather than wrong: the hoist's `base_context/0` would still
  compute the same constant, just no longer be the only cheap way to get it.
  Predicator owns the shape of its own memoization (ADR-0025 rule 1); this
  record does not pre-empt or wait on that decision.
- The build-*count* reduction - collapsing the two selection-round builds
  into build-once-plus-refresh, which ADR-0028's within-block threading did
  not reach and this record does not reach either - remains future work. It
  would require storing a context across the interval those two builds span,
  which is exactly the storage move ground 2 and ground 3 above still argue
  against. What would reopen it: ground 2 closing (every datamodel write site
  provably re-binding into any context that might be held across it, not
  merely today's evaluation-site set) and ground 3's duplication being
  addressed by construction rather than by discipline - for instance, a
  representation where `data`/`host` are computed views over
  `%MachineState{}` rather than stored copies of it. Neither exists today.

## References

- `docs/adr/0028-executable-content-blocks-thread-one-context.md` - the
  deferral this record answers.
- `docs/adr/0012-debuggability-designed-into-the-core.md` and
  `docs/observability.md` (constraint 1) - cited, not re-argued.
- `docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md` rule 1 -
  predicator owns the shape of its own memoization.
- `docs/plans/260814-st-l0t-provider-host-seam-for-in1.md` - the plan this
  record's Decision implements.
- `bench/results/260814-st-l0t-provider-host-seam.md` - every number cited
  above.
- Bead: `st-l0t` (mirrors `px-10u`, closed and merged; complements `px-rnc`,
  in progress).
