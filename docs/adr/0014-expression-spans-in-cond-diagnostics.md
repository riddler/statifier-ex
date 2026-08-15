# ADR-0014: Expression-level spans are part of the retained-location constraint

Status: accepted (2026-08-06) - amended 2026-08-15 (item 4 stops at the predicator seam; engine policy checks are not expression failures)

## Context

ADR-0012 item 3 requires the Machine to retain source locations so trace
effects and error metadata can name what failed and tooling can map it back to
source. So far that constraint has meant SCXML locations - states, transitions,
executable content from the parser. Predicator (ADR-0004) now extends the same
seam through expression evaluation, and the question (bead st-mp4) is whether
`cond` diagnostics adopt it, and in which shape.

Predicator 3.7/3.8 (the current pin, `~> 3.8`) offers point positions:
`compile_with_positions/1` returns the instruction list plus a side table
mapping instruction index to the `{line, column}` of the emitting AST node; a
`:positions` option on `evaluate/3` seeds it; and `EvaluationError`,
`TypeMismatchError` and `UndefinedVariableError` carry an optional `:position`.
Predicator 4.0 (merged upstream, unreleased; consumption tracked as st-2pj)
widens these to spans: `compile_with_spans/1`, `spans: true`, and `:span` on
the same error structs, with exclusive ends matching LSP ranges. A span
underlines the failing subexpression; a point position only puts a caret.

3.8 also added `on_unbound: :error` (an unbound root variable load returns a
`UndefinedVariableError` naming the variable instead of the `:undefined`
sentinel), made `run_prepared/1` return `{:error, error, evaluator}` so
`Evaluator.unbound_loads/1` is reachable on the error path, and added
`Context.bound?/2`.

The timing facts that decide the shape: `lib/` contains no interpreter, no
parser, and no cond wiring - nothing consumes predicator yet - and the bead's
own rule says that if cond wiring has not started when 4.0's span API exists,
target spans directly and skip the intermediate point shape. Retrofitting a
side table into a finished evaluation path is exactly the cost ADR-0012 exists
to avoid; adopting it while the path is being written is cheap.

Upstream, predicator bead px-35i.5 is an open design question on folding the
span side table into an envelope returned with the instructions, precisely
because hand-carrying the companion value is a consumer cost.

## Decision

Expression-level source locations are **in scope** for ADR-0012 item 3, in the
**span** shape:

1. **Spans, not point positions.** Cond wiring targets predicator 4.0's
   `compile_with_spans/1` and `spans: true`, and error metadata carries
   `:span`. The 3.7/3.8 point-position API is skipped. If cond wiring must
   begin before 4.0 ships, it threads the identical seam with
   `compile_with_positions/1` / `:positions` as a stopgap, storing the table in
   the same field, so the st-2pj bump widens it mechanically - the seam is the
   commitment, the width follows the pin.
2. **The table travels with the instructions.** *(Amended 2026-08-08: px-35i.5
   settled.)* px-35i.5 landed the envelope - predicator ADR-0009, merged
   upstream, unreleased, part of 4.0 - so the conditional in this item
   resolves in favor of the upstream shape: there is no statifier-side
   wrapper to build. `%Predicator.Compiled{instructions:, positions:}` is
   returned by both `compile_with_positions/1` and `compile_with_spans/1`;
   the one `positions` field holds a position table or a span table
   depending on which compiled it, since nothing below the facade
   distinguishes them. `Predicator.evaluate/3` accepts the struct directly
   and threads the table itself - no `:positions` keyword; passing a
   `%Compiled{}` and an explicit `:positions` option together raises
   `ArgumentError` rather than silently picking a winner.
   `Predicator.Compiled.new/2` reattaches a table to a bare instruction list.
   The envelope deliberately does not carry the source string (predicator
   ADR-0009 open question 1: it changes the value's size class and privacy
   profile) or an ISA version (that stays computable from the instruction
   list via `Instructions.required_isa/1`). The compiled-expression value
   (`{:compiled, instructions, source}` per `docs/datamodel.md`) therefore
   widens to `{:compiled, %Predicator.Compiled{}, source}` rather than
   growing a fourth element: we keep owning `source` because we are the ones
   who know where the expression sat in the document, while predicator only
   knows offsets within the expression string. When cond wiring lands it
   calls `compile_with_spans/1` and passes the returned struct straight to
   `evaluate/3`, with no `:positions` keyword - that wiring still waits on
   the predicator `~> 4.0` pin (st-2pj), which this amendment does not lift.
   predicator's storage advice (persist `compiled.instructions`, never the
   struct, because a stored span table has no integrity check against a
   different source's instructions) does not apply here: we compile conds
   in-process at Machine-build time and store no instruction lists (st-2pj
   says so explicitly), so the round trip that hazard describes does not
   exist for us.
3. **Spans are always on.** The table is compile-time-immutable Machine data,
   the same as SCXML locations under ADR-0012 item 3: no gate, no option, no
   runtime cost beyond memory and a per-error lookup.
4. **What an expression failure names.** When a cond (or any expression) fails
   to evaluate and the interpreter raises `error.execution`, the event's data
   and the corresponding trace effect carry: the constraint-3 identity of the
   owning node (e.g. the transition's document-order index), the expression
   source string, the predicator error struct, and its `:span` (nil when
   predicator cannot attribute one). Exact payload shape is settled at
   implementation; the fields are the commitment.

   *(Amended 2026-08-15: where this item stops.)* "Fails to evaluate" is the
   boundary, and it sits at the predicator seam: this item reaches an
   `error.execution` exactly when a predicator call itself returned
   `{:error, error}` - `Statifier.Evaluator.evaluate/2`,
   `Predicator.context_location/2`, `Predicator.ContextLocation.put/3` -
   and the payload then wraps that struct verbatim via
   `Statifier.Evaluator.Error`. An engine policy check applied *after*
   predicator succeeded is not an expression failure, and this item does
   not reach it. The two members today are
   `Statifier.Interpreter.Datamodel.write_location/4`'s post-resolution
   checks: the spec 5.10 rejection of a write to a `_`-rooted system
   variable (`{:error, {:system_variable, root}}`) and the
   no-undeclared-root half of 5.9.2's valid-location requirement
   (`{:error, {:unbound_location, path_source}}`). On both paths predicator
   resolved the whole location successfully, so there is no predicator
   error struct in existence to carry and no failing *subexpression* for a
   span to underline - the culprit is the resolved root or the whole path,
   and the tuple names it directly, which is the whole diagnostic. The
   parenthetical above ("nil when predicator cannot attribute one") covers
   a predicator error that lacks a span, such as `ParseError`; it is not
   license to ship a span-less payload built around a fabricated predicator
   error, which would misattribute an engine decision to the expression
   layer and break `Evaluator.Error`'s error-carried-verbatim contract. The
   owning-node identity this item names still arrives on these paths, as on
   every `error.execution` alike, from the raise site's origin stamp
   (`docs/observability.md` constraint 4) - the same division of labor that
   keeps `Evaluator.Error` itself owner-free.
5. **Unbound variables are errors, not sentinels.** Cond evaluation passes
   `on_unbound: :error`, so a cond referencing a missing datamodel location
   fails with a `UndefinedVariableError` naming the variable and carrying its
   span. This supersedes after-the-fact `unbound_loads/1` inspection for that
   common case. `unbound_loads/1` remains useful for the loads a
   short-circuit skipped and is reachable on the error path since 3.8; the
   error diagnostic may include it as a supplementary field, but it is not
   part of the committed payload.
6. **`Context.bound?/2` is not part of cond diagnostics.** `on_unbound:
   :error` covers the failure path without a pre-flight check. It stays
   available for later uses (e.g. `<assign>` location validation) with no
   commitment here.

## Consequences

- `error.execution` for a failed cond can say "columns 22-27 of
  `user.age > 18 AND score > 5` loaded an unbound `score`" instead of "the
  cond on transition 4 errored" - the payoff ADR-0012 item 3 exists for, at
  expression granularity.
- Cond wiring has a hard dependency on the predicator 4.0 release (st-2pj)
  for the span shape, or accepts the point-position stopgap in item 1 with a
  known mechanical widening. Whoever wires cond does not re-litigate this;
  they check whether 4.0 shipped and whether px-35i.5 settled, then follow
  items 1-2.
- The Machine carries a span table per compiled expression - the same modest
  permanent weight ADR-0012 already accepts for locations and indexes.
- Open question recorded, not blocking: the concrete compiled-expression
  shape settled per item 2's 2026-08-08 amendment (the upstream px-35i.5
  envelope, not a statifier-side wrapper). The exact `error.execution`
  payload shape remains an implementation-time decision bounded by item 4.
- Open question recorded, not blocking (2026-08-15 amendment):
  `{:system_variable, root}` carries the resolved root but not the raw
  `path_source` the author wrote, unlike `{:unbound_location, path_source}`.
  Nothing in this record obliges it to - the policy tuples are outside item
  4 - but adding the source string would cost nothing and read better when
  the offending root was reached through a longer path. An ergonomic
  improvement for whoever next touches `write_location/4`, not a defect.
