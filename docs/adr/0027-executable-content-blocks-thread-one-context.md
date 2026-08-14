# ADR-0027: Executable-content blocks thread one context and bind/3 each write

Status: accepted (2026-08-14)

## Context

`Statifier.Evaluator.context/1` (`lib/statifier/evaluator.ex:108-113`) is the
sole constructor of a `%Predicator.Context{}` over live machine data. Three
sites rebuild it during a macrostep rather than reusing the context already
built for the block they run inside: `<assign>` (once per assign, after the
write, `lib/statifier/machine/content/assign.ex:76-91`), `<script>` (once in
`rebind/2` plus a second build inside `Evaluator.execute/2`,
`lib/statifier/machine/content/script.ex:95-103`), and `<foreach>` (once
before the loop plus once per iteration, `lib/statifier/machine/content/
foreach.ex:276-285`).

`docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md` built the
benchmark this decision needed and pre-registered the rule it would be
judged against before any number existed:

> - **Branch A - rebuilding is fine.** `S_time < 5%` and `S_mem < 5%` at
>   realistic scale, and the `<foreach>` stress case stays under 5% on both
>   axes for N <= 100 iterations.
> - **Branch B - the change is justified.** `S_time >= 5%` or `S_mem >= 5%`
>   at realistic scale, or the `<foreach>` case crosses 5% on either axis at
>   N <= 100.
> - **Modifier C, independent of A/B.** If `T_fixed` is >= 50% of `T_full`
>   at the realistic datamodel size, the fixed per-call provider
>   re-validation dominates and the root fix is upstream memoization in
>   predicator, not statifier glue. Phase 3 then also files a predicator-ex
>   bead and cross-links it per ADR-0025's `mirrors:` protocol. This fires
>   or does not fire on its own evidence; it does not change which of A or
>   B is taken.

`bench/results/260814-context-build.md` (Phase 1) measured the three-term
decomposition and the block-level A/B at a realistic corpus-shaped datamodel
(`:corpus`: 5 roots, matching the observed maximum across
`test/scxml_tests/` and `test/scion_tests/`) and at three stress points. At
`:corpus`: `T_full` (`Evaluator.context/1`) = 2.28 us / 10.92 KB, `T_fixed`
(`Context.new/2` over empty data, isolating `resolve_functions/1`) = 1.29 us
/ 5.51 KB. `T_fixed / T_full` = 56.6%, which is >= 50% - **Modifier C
fires**, independently of the branch decision below.

`bench/results/260814-macrostep.md` (Phase 2) drove real documents through
`Statifier.compile/1`, `Statifier.initialize/2`, and `Statifier.send_event/2`
and derived the share of one macrostep's cost spent building contexts, at
realistic scale and across a `<foreach>` sweep:

- Realistic (the point that decides the bead): `S_time` = 62.04%,
  `S_mem` = 67.10%.
- `<foreach>`, N in `[1, 10, 100, 1000]`: `S_time` ranges 63.89%-80.17%,
  `S_mem` ranges 71.73%-93.47%; every point up to and including N=100 (the
  rule's own bound) is far over 5% on both axes, starting at N=1.

Both figures are more than twelve times the rule's 5% threshold, and the
`<foreach>` curve clears 5% on both axes at N=1, well under the N<=100 bar.
Branch A's requirements (`S_time < 5%` and `S_mem < 5%` at realistic scale,
and the `<foreach>` case staying under 5% for N<=100) fail on every count;
Branch B's disjuncts (`S_time >= 5%` or `S_mem >= 5%`, or the `<foreach>`
case crossing 5% at N<=100) are each independently satisfied by a wide
margin. There is no tie: the rule's "ties and ambiguity resolve to Branch A"
fallback does not apply, because nothing here is close to the 5% line.

## Decision

**Branch B is selected. Executable-content blocks thread one context and
`bind/3` each write.**

Within one executable-content block - the interval `Interpreter.Content.
execute_block/3` (`lib/statifier/interpreter/content.ex:140-162`) already
builds once - `<assign>`, `<script>`, and `<foreach>` bind each write into
the block's existing threaded context with `Predicator.Context.bind/3`
rather than calling `Evaluator.context/1` again. This is within-block
threading only. It is explicitly **not** a stored context on
`Statifier.MachineState`: nothing changes about what a `%MachineState{}`
holds, and nothing widens the interval a context stays valid across.
Widening it *across* blocks - the shape a `MachineState` field would need -
is out of scope here, same as the plan's D3 scoped it, and is a future
decision, not this one.

Modifier C also fired (Context, above): Phase 3 filed and cross-linked a
predicator-ex bead for memoizing `resolve_functions/1`'s per-call
`Code.ensure_loaded?/1` and `function_exported?/3` validation
(`deps/predicator/lib/predicator/context.ex:158-207`) - `px-rnc`, carrying
`mirrors: st-sdh` as its description's first line; `st-sdh`'s own
description now carries `mirrors: px-rnc`. This fires independently of the
branch decision above and does not change it; predicator owns whatever
shape the memoization takes, per ADR-0025's rule 1.

## Consequences

- `docs/datamodel.md`'s "once per evaluation site" commitment
  (`docs/datamodel.md:54-59`) is unchanged. Within-block threading is still
  one context per evaluation site - the site is the whole block, not the
  individual write inside it, and that was already the boundary the
  commitment names. `bind/3` changes how a write inside that interval
  updates the context, not how long the interval lasts.
- ADR-0012 constraint 1 (`docs/observability.md:26-49`, a resumable
  `%MachineState{}`) is untouched, because nothing is stored on
  `MachineState`. The context a block threads lives on the stack of the
  block's own execution, the same as it does today; only the three rebuild
  sites inside that stack change from a fresh `Evaluator.context/1` call to
  a `bind/3` on the context already in hand.
- The next phase (Phase 4 of the plan) implements the change: a public
  `Evaluator.bind/3` helper, and `<assign>`/`<foreach>` (and `<script>` if
  it proves safe) replaced to bind rather than rebuild. Phase 4 is
  executed because this record names Branch B; had it named Branch A,
  Phase 4 would not run.
- Phase 4 shipped, and `<script>` threading proved safe: it did not go the
  rebuild-fallback route this record left open. `Evaluator.run_program/2`
  (a new function alongside the unchanged `execute/2`) returns the
  post-run `Predicator.Context.t()` `Predicator.execute/3` already builds,
  and `Statifier.Machine.Content.Script` threads it straight onto the
  block's `datamodel_context` instead of calling `context/1` again -
  `execute/2` itself, and its one other caller
  (`Statifier.Interpreter.run_global_script/3`, Appendix D's global-script
  step, untouched by this phase), keep their original two/three-element
  shape. `mix test --include scion --include scxml_w3` passed at exactly
  the same counts before and after (1661 tests, 107 failures, both runs;
  `mix test.regression` at 1522/0 both times), so the threaded context is
  observationally identical to a rebuilt one across the whole corpus. One
  difference *was* found outside the corpus, by direct construction: a
  script assigning the null literal (`x = null;`) and reading `x` back
  later in the *same* block now sees `nil`, where a fresh rebuild would
  have round-tripped that `nil` through `undefine_nils/1` a second time and
  flipped it to `:undefined` - the exact gap `Statifier.Evaluator`'s own
  `undefine_nils/1` note already names as latent and not something any
  corpus document exercises. Threading fixes that gap for `<script>`
  writes as a side effect rather than introducing a new one; it is
  recorded here because it is the one place this phase's behavior is not
  bit-for-bit identical to the rebuild it replaced.
- `bench/results/260814-macrostep.md`'s "Phase 4 verification" section has
  the before/after numbers: every corpus-reachable document is faster and
  lighter, from ~1.2x at `assign-heavy n=1` to ~64x at `foreach n=1000`,
  consistent with an O(1)-in-datamodel-size `bind/3` replacing an
  O(datamodel size) rebuild at each write. `cond`-bearing selection is
  unchanged within noise, as expected - Branch B is scoped to executable
  content and the selection round still calls `Evaluator.context/1`
  directly.
- Widening the threaded interval *across* blocks - so a context could
  survive a whole macrostep or live on `MachineState` - remains future
  work, gated on the same two grounds `Statifier.Evaluator`'s moduledoc
  already states under "Why the built context is not a `MachineState`
  field": the closure-in-`functions` non-resumability ground (dissolvable
  by the `px-8ii` provider seam, already landed upstream but not taken
  here) and the staleness ground (structural, survives any provider seam,
  because `In/1` still answers against whatever configuration it captured
  at build time). Neither ground is contradicted by within-block
  threading, because a block never outlives the microstep it runs inside.
- Two things would reopen this decision rather than being folded in
  silently: a datamodel materially larger than the realistic `:corpus`
  point this record measured, or `cond` on transitions becoming reachable
  from the corpus (today `FeatureDetector` marks `conditional_transitions`
  `:unsupported`, `lib/statifier/interpreter/selection.ex:277-280`), which
  would put a context build on every selection round rather than only
  inside executable content. `bench/` is the way to re-decide either
  question, not a re-argument of this record.
