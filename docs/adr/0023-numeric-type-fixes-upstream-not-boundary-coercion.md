# ADR-0023: Numeric-type gaps are fixed in predicator, never coerced at the boundary

Status: accepted (2026-08-14)

## Context

Three SCION corpus files (`test/scion_tests/targetless_transition/test1..3`)
fail because their accumulator passes through `Math.pow` before an `===`
guard. Predicator's `Math.pow` builtin is backed by Erlang `:math.pow/2` and
always returns a float, while predicator's `===` is Elixir `===`, which is
type-strict: `8.0 === 8` is `false`. ECMAScript has a single Number type, so
SCION's `cond="i === 8"` assumes `Math.pow(2,3) === 8` is `true`. The guard is
silently false - a well-formed `false`, not an error - and the chart never
reaches `done` (st-cw3;
`docs/research/260814-st-cw3-scion-cond-assign-mismatch.md`). The float-ness
is per-builtin, not uniform: `Math.floor(3.7)` returns the integer `3` while
`Math.pow` and `Math.sqrt` return floats, and integer arithmetic (`i * 2`,
`x + 1`) stays integer throughout.

Three places could hold a fix:

1. **Upstream, in predicator**: make integer-valued builtin results integers
   (e.g. `Math.pow(int, non-negative int)` returns an integer when the result
   is exact, as `Math.floor` already does). `===` itself is untouched.
2. **Here, at the statifier evaluator/expression boundary**: normalize
   integer-valued floats to integers on evaluation results or datamodel
   writes.
3. **Nowhere**: accept the three failures permanently.

ADR-0004 already leans on this question: "Gaps predicator has for SCXML use
... are upstreamed into predicator rather than papered over in statifier."
`docs/datamodel.md`'s upstreaming section records six seams handled exactly
that way (typed undefined, vivifying assignment, string builtins, ...), each
via a beads issue here mirrored in predicator-ex. What ADR-0004 does not
settle is whether a numeric coercion shim in statifier's glue counts as
"papering over" - a plausible reading says coercion is legitimate host-side
adaptation. This record settles it.

## Decision

**The numeric-type answer lives upstream. Statifier does not coerce numeric
types at the evaluator or expression boundary, and predicator's `===` keeps
Elixir's type-strict semantics unchanged.**

Concretely:

- A mirror bead is filed in predicator-ex proposing integer-preserving
  results for integer-exact `Math.*` builtins (`Math.pow` first; audit
  `Math.sqrt` and any others while there). The exact design - which builtins,
  exactness rules, large-integer behavior given `:math.pow/2`'s float
  internals - is upstream's call, made in that repo.
- Until that lands and the dependency is bumped, the three
  `targetless_transition` files are a recorded corpus deviation of the
  pending kind: they stay in the tree, stay failing, and stay out of
  `test/passing_tests.json`. They are expected to pass eventually, so they do
  not join `tools/corpus/scion/exclusions.exs` (contrast ADR-0022's two
  permanently-unwinnable files).

Option 2 (boundary coercion) was rejected on blast radius and on principle.
To fix these documents it would have to rewrite every integer-valued float
(`8.0` -> `8`) on every evaluation or write, which *does* change what `===`
observes for every document - including one that legitimately wants
predicator's type-strict `===` to distinguish `8.0` from `8`. A narrower shim
(coerce only `Math.pow` results) is a per-builtin patch-table for upstream
behavior, living in the wrong repo - exactly the glue thickening ADR-0004
forbids. The upstream fix has neither problem: changing what `Math.pow`
*returns* is a documented builtin contract change in the language's own repo,
versioned and release-noted, and `===` comparisons never change meaning -
documents comparing values that were floats before remain floats unless
upstream defines them integer, and that definition is visible in predicator's
docs rather than silently applied in one embedding.

Option 3 (accept permanently) was rejected because the gap is a fixable wart
in a dependency this project's owner also maintains, and the same wart will
resurface in any future corpus or user document mixing `Math.pow` with
integer comparisons.

If upstream declines the change, that outcome converts the three files into
permanent deviations, and the disposition question (exclude with a reason
atom, per ADR-0022's pattern) comes back as an amendment to this record - it
is not decided in advance here.

## Consequences

- `===` semantics are stable and documented in one place (predicator);
  nothing in statifier quietly rewrites numeric types.
- The three `targetless_transition` files remain visible failures until the
  predicator release lands - an honest "pending upstream" signal rather than
  a shim-induced green.
- Follow-up (not this record): file the mirror bead in predicator-ex and a
  tracking bead here for the dependency bump plus `mix test.baseline add` of
  the three files once they pass; add the seam to `docs/datamodel.md`'s
  upstreaming list as its next numbered entry.
- Future numeric mismatches (e.g. a `/` return-type surprise, `Math.sqrt`
  under `===`) have a standing answer: upstream bead, no local coercion.
