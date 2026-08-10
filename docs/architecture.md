# Architecture

Statifier is a ground-up rewrite of [statifier](https://github.com/riddler/statifier)
(the original, kept as a read-only reference in `../statifier`). The rewrite exists
to fix structural problems the original could only patch around; the reasoning for
each major decision lives in `docs/adr/`.

## Design principles

1. **The W3C algorithm is ported literally, not re-derived** ([ADR-0002](adr/0002-literal-w3c-appendix-d-port.md)).
   The interpreter implements the SCXML Appendix D pseudocode function-for-function,
   keeping the spec's names: `select_transitions`, `remove_conflicting_transitions`,
   `get_transition_domain`, `compute_exit_set`, `compute_entry_set`,
   `add_descendant_states_to_enter`, `microstep`, `enter_states`, `exit_states`,
   `main_event_loop`, `exit_interpreter`. When a conformance test fails, the debugging
   move is "diff the function against the pseudocode", never "tune the heuristic".
   Internal, external, and targetless transitions share one code path via the
   transition domain.

2. **Pure functional core, effects at the edge** ([ADR-0003](adr/0003-pure-core-with-effects.md)).
   The core engine is a pure function: `(machine_state, event) -> {machine_state, [effect]}`.
   Delayed sends, external sends, invocations, cancellations, and log/trace entries are
   returned as effect data. Interpreters of effects (a GenServer session, a test harness,
   an iex user) live outside the core. The same document has the same semantics through
   every API - v1's "delayed send silently becomes immediate in the sync API" class of
   bug is unrepresentable.

3. **Errors are events.** SCXML defines an error model: evaluation failures raise
   `error.execution` on the internal queue. Every evaluation in the core returns
   `{:ok, value} | {:error, reason}` and the interpreter decides what an error means.
   No `rescue`-to-`false` at the leaves (a dozen places in v1 swallowed errors this way).

4. **Make invalid states unrepresentable.** Parsing produces a `Document`; validation
   produces a distinct `Machine` type (interned, optimized, guaranteed valid). The
   interpreter only accepts a `Machine`, so "validate if not already validated"
   fallback branches do not exist.

## Layers

```
XML string
   |  Parser (Saxy SAX -> generic DOM with source locations)
   v
DOM (element name, attrs, children, location)
   |  Lowering (typed per-element builders)
   v
Document (typed structs, source locations, uncompiled expressions)
   |  Validator (structural + semantic checks)
   |  Compiler (intern IDs, index hierarchy, compile expressions)
   v
Machine (valid by construction, integer state indexes, compiled Expr values)
   |  Interpreter (pure Appendix D core)
   v
{state, [effect]}
   |  Effect interpreters
   v
Statifier.Session (GenServer) | test harness | embedding application
```

### Parser: DOM first, then lowering

v1's SAX handler lowered elements directly into typed structs, which required a
handler clause per (element type x parent context) pair - 73 clauses in one 903-line
module. v2 parses into a generic DOM node (`name`, `attributes`, `children`,
`location`), then lowers the DOM to typed structs in a separate pass. Adding an
element touches one builder, not a clause matrix. Source locations are a property of
every DOM node, not bolted-on bookkeeping.

### Machine: interned and indexed

The compiler pass interns state IDs to integers and stores states in a flat array
with parent pointers and descendant index ranges in document order. Ancestor checks,
descendant checks, LCCA, and exit-set computation become integer comparisons - no
precomputed cache module, no four separate ways to fetch ancestors.

Expressions are compiled once, here, into a single sum type:

    @type expr :: {:static, term()} | {:compiled, Predicator.Compiled.t(), source :: String.t()}

Every attribute that accepts `foo` / `fooexpr` pairs stores one `expr` value,
evaluated by one function. (v1 carried `x` / `x_expr` / `compiled_x_expr` triples on
every action struct.)

### Interpreter: the Appendix D core

`Statifier.MachineState` is the `state` in the `{state, [effect]}` pipeline
above, and `Statifier.Effect` is the `effect`.

- The full active configuration (ancestors included) is stored, as the spec's
  algorithm assumes ([ADR-0005](adr/0005-full-configuration-and-interned-state-indexes.md)).
  "Leaf states" is a view derived on demand, not the storage model.
- A `running` flag with real termination: top-level `<final>` entry stops the
  machine, runs `<donedata>`, and emits the terminal effect.
- `done.state.<id>` events are generated for compound and parallel completion.
- Event descriptor matching follows spec 3.13 exactly (including `foo.*` matching `foo`).
- The transition-selection block lives in `Statifier.Interpreter.Selection`;
  `Statifier.Interpreter.NameMatch` is the 3.13 matcher above.
- The exit and entry blocks - history recording/restoration and
  `done.state.*` generation included - live in `Statifier.Interpreter.ExitEntry`.

### Executable content

One `Statifier.ExecutableContent` node protocol with
`execute(node, context) -> {:ok, context, [effect]} | {:error, reason}`, where
`context` is a `Statifier.ExecutableContent.Context`. No central dispatcher
with per-struct clauses and a parallel summary function to keep in sync.
`Statifier.Interpreter.Content` is the block runner: it walks a block's nodes
in document order, stopping at the first error, and is the only place that
converts a node's `{:error, _}` into `error.execution`. A new element is a new
`Statifier.Machine.Content.*` struct plus a `defimpl` in the same file - never
a change to the runner or the interpreter.

### Sessions and invoke

`Statifier.Session` is the GenServer effect-interpreter: it owns timers for delayed
sends, processes `<cancel>`, and supervises child sessions. `<invoke type="scxml">`
(v1 never implemented it) spawns a real child session with `#_parent` routing,
`autoforward`, and `<finalize>`. v1's handler-registry invoke is kept as an explicit
extension type - a useful, safe escape hatch, but not the definition of `<invoke>`.

Session, send, and invoke IDs are UXIDs ([ADR-0008](adr/0008-uxid-for-identifiers.md)):
sortable, prefixed (`sess_`, `send_`, `inv_`), and stable per session (v1 regenerated
`_sessionid` on every expression evaluation).

## What is deliberately out of scope

- **ECMAScript datamodel.** The datamodel is predicator
  ([ADR-0004](adr/0004-predicator-as-the-datamodel.md)). No JS engine, no `eval`,
  and no raw Elixir code in documents - safety is the point; `<invoke>` is the
  escape hatch for real computation.
- **v1 API compatibility.** The conformance corpus is the compatibility contract,
  not v1's module surface.
