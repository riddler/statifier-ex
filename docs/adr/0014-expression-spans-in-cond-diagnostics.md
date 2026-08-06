# ADR-0014: Expression-level spans are part of the retained-location constraint

Status: accepted (2026-08-06)

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
2. **The table travels with the instructions.** The compiled-expression value
   (`{:compiled, instructions, source}` per `docs/datamodel.md`) widens to also
   carry the span table, so it cannot be dropped separately from the
   instructions. Its exact shape is settled at implementation; if px-35i.5
   lands an upstream envelope first, adopt that instead of a statifier-side
   wrapper. px-35i.5 is not a blocker - check how it settled before writing
   the plumbing.
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
  shape (statifier-side wrapper vs. an upstream px-35i.5 envelope) and the
  exact `error.execution` payload shape are implementation-time decisions
  bounded by items 2 and 4.
