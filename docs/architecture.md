# Architecture

**Read this to:** learn how the engine is built before you change it.
**Short version:** the engine is a literal port of the W3C algorithm. It is a
pure function that returns effects as data. A `Machine` is valid by
construction.

Statifier rewrites [statifier](https://github.com/riddler/statifier) (read-only
copy in `../statifier`). The reasoning for each decision is in `docs/adr/`.

## Design principles

1. **Port the W3C algorithm literally.**
   - The interpreter follows the SCXML Appendix D pseudocode function for
     function. It keeps the spec names: `select_transitions`,
     `remove_conflicting_transitions`, `get_transition_domain`,
     `compute_exit_set`, `compute_entry_set`, `add_descendant_states_to_enter`,
     `microstep`, `enter_states`, `exit_states`, `main_event_loop`,
     `exit_interpreter`.
   - Internal, external, and targetless transitions share one code path through
     the transition domain.
   - When a conformance test fails, diff the function against the pseudocode.
     Do not tune a heuristic.
   - Diff against the cached text, not against memory. Run
     `mise run spec:fetch`. The cache is in
     `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/`.
     See [`tools/spec/README.md`](https://github.com/riddler/statifier-ex/blob/main/tools/spec/README.md).
   - Decision: [ADR-0002](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0002-literal-w3c-appendix-d-port.md).

2. **Keep the core pure. Put effects at the edge.**
   - The core is a pure function:
     `(machine_state, event) -> {machine_state, [effect]}`.
   - It returns delayed sends, external sends, invocations, cancellations, and
     log/trace entries as effect data.
   - A GenServer session, a test harness, or an iex user runs the effects
     outside the core.
   - The same document has the same semantics through every API.
   - Decision: [ADR-0003](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0003-pure-core-with-effects.md).

3. **Treat errors as events.**
   - SCXML says an evaluation failure raises `error.execution` on the internal
     queue.
   - Every evaluation in the core returns `{:ok, value} | {:error, reason}`.
     The interpreter decides what the error means.
   - Do not use `rescue`-to-`false` at the leaves.

4. **Make invalid states unrepresentable.**
   - Parsing produces a `Document`. Validation produces a `Machine`, which is
     interned, optimized, and valid by construction.
   - The interpreter accepts only a `Machine`. No "validate if not yet
     validated" fallback exists.
   - A finding that gates this boundary is an error. Any other finding is a
     warning. A warning stays on the `Machine` and never blocks compilation.
   - Decision: [ADR-0033](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0033-validator-warning-tier.md).

## Layers

```
XML string
   |  Parser (Saxy SAX -> generic DOM with source locations)
   v
DOM (element name, attrs, children, location)
   |  Lowering (typed per-element builders)
   v
Document (typed structs, source locations, uncompiled expressions)
   |  Validator (structural + semantic checks; two channels - errors gate
   |  compilation, warnings ride on the Machine instead, ADR-0033)
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

- The parser makes a generic DOM node: `name`, `attributes`, `children`,
  `location`.
- A separate pass lowers the DOM to typed structs.
- To add an element, change one builder.
- Every DOM node has a source location from the start.

### Machine: interned and indexed

- The compiler interns state IDs to integers.
- It stores states in a flat array. Each state has a parent pointer and a
  descendant index range in document order.
- Ancestor checks, descendant checks, LCCA, and exit-set computation are
  integer comparisons.
- The compiler compiles each expression once into one type:

      @type expr :: {:static, term()} | {:compiled, Predicator.Compiled.t(), source :: String.t()}

- Each `foo` / `fooexpr` attribute pair stores one `expr`. One function
  evaluates it.

### Interpreter: the Appendix D core

`Statifier.MachineState` is the `state` in `{state, [effect]}`.
`Statifier.Effect` is the `effect`.

- The interpreter stores the full active configuration, ancestors included
  ([ADR-0005](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0005-full-configuration-and-interned-state-indexes.md)).
  "Leaf states" is a view that the engine derives on demand.
- A `running` flag provides real termination. Entry to a top-level `<final>`
  stops the machine, runs `<donedata>`, and emits the terminal effect.
- The interpreter generates `done.state.<id>` events for compound and parallel
  completion.
- Event descriptor matching follows spec 3.13 exactly. `foo.*` matches `foo`.

| Block | Module |
|---|---|
| Transition selection | `Statifier.Interpreter.Selection` |
| Spec 3.13 matching | `Statifier.Interpreter.NameMatch` |
| Exit and entry, including history and `done.state.*` | `Statifier.Interpreter.ExitEntry` |

Do not persist a `MachineState` without reading
[docs/persistence.md](persistence.md). Its configuration is interned integer
indexes, and they are stable only within one `Machine` build.

### Executable content

- `Statifier.ExecutableContent` is a node protocol:
  `execute(node, context) -> {:ok, context, [effect]} | {:error, reason} | {:error, context, reason}`.
  `context` is a `Statifier.ExecutableContent.Context`.
- `Statifier.Interpreter.Content` runs a block. It walks the nodes in document
  order and stops at the first error.
- It is the only place that turns a node error into `error.execution`. This
  includes the non-fatal spec-5.9.1 channel in `context.pending_errors`.
- To add an element, add a `Statifier.Machine.Content.*` struct and a `defimpl`
  in the same file. Do not change the runner or the interpreter.
- ADRs govern the error model. Decision 5 of
  `docs/plans/260813-st-af3.5-if-elseif-else-conditional-executable-content.md`
  explains why it was widened once.

### Sessions and invoke

**What the session owns.** `Statifier.Session` is the GenServer effect
interpreter. It owns the `while running` loop, the waiting external events, the
delayed-send timers, the effect of `<cancel>`, and the fan-out of effects to
subscribers.

A host can take over the timers. See [docs/durable-timers.md](durable-timers.md)
and [ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md).

**What the core does for `<invoke>`:**

- Lowers, validates, and compiles it
  ([ADR-0031](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md)).
- Runs the `statesToInvoke` and cancel-invoke passes
  ([ADR-0032](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0032-round-budget-spans-the-invoke-re-entry.md)
  covers the round budget after re-entry).
- Runs `<finalize>` before transition selection.
- Emits `{:invoke, _}`, `{:cancel_invoke, _}`, and `{:autoforward, _}`.

**What the session does for `{:invoke, _}`:**

- It resolves the child source through `Statifier.Invoke.Source`
  ([ADR-0038](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md)).
  The library never fetches `src`. An embedder-supplied `invoke_source`
  resolver does. With no resolver, the invocation raises `error.communication`.
- It seeds the child datamodel by the name-matched `<param>`/namelist rule of
  6.4.3.
- It starts the child on `Statifier.SessionSupervisor` with
  `invoked_by: {parent_pid, invoke_id}`. Both sessions monitor each other.
- The runtime is the one that
  [ADR-0027](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0027-embedder-placed-session-runtime.md)
  decided. `Statifier.Supervisor` holds a `Statifier.Registry` and a flat
  `Statifier.SessionSupervisor` (`:rest_for_one`).
- `:inherit_observers` on `Statifier.Session.start_link/2` passes the parent
  `:trace` and subscribers to the child
  ([ADR-0050](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0050-invoked-children-inherit-observation-by-opt-in.md)).
  `Statifier.Session.invocations/1` lists the live children.

**Routing:**

| Target | Resolves through |
|---|---|
| `#_parent`, `_parent` | the `invoked_by` link |
| `done.invoke.<invokeid>` of a live invocation | the `invoked_by` link |
| `#_<invokeid>` | `Statifier.Session.Invocations.fetch/2`. A live entry gets the event in its external queue. |
| an `invokeid` with no live invocation | the `error.communication` path (st-xcgr) |

**Autoforward.** `{:autoforward, _}` copies every external event that the
parent removes from its queue to each autoforwarding invocation, unmodified.

**Cancel.** `{:cancel_invoke, _}` stops the child with `Session.cancel/1`, not
`stop/2`, so its `<onexit>` handlers run. It pops the table entry before the
stop.

**The drain-time discard.** The session drops a queued entry that an invocation
delivered, if that invocation is no longer live. Spec 6.4.3: "MUST NOT insert
them into the external event queue".

- The discard reads the origin of the queue entry: `{:invoked_event, _, _}` of
  `Statifier.Session.Inbox`. Only the child-to-parent direction sets it.
- It does not read the `invokeid` field of the event. Spec 6.4.2 requires an
  autoforwarded copy to keep every 5.10.1 field. A copy sent down to a child
  carries the id of a sibling invocation. A discard keyed on that field would
  drop a copy that 6.4.2 requires the engine to deliver.

**Not yet supported.** Inline `<content><scxml>...</scxml></content>` does not
lower. It is deferred to st-53ys. A `<content>` with markup as a text/CDATA
binary works today.

**Custom invoke types.** A host registers a `Statifier.Invoke.Handler` per
session for any `<invoke type="...">` beyond the built-in `scxml`/bare-URI set
([ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md)).
The built-in `Statifier.Invoke.Handler.Scxml` uses the same interface. See
[docs/extending.md](extending.md).

**Generated IDs**
([ADR-0008](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0008-uxid-for-identifiers.md)).

- Outside the core, the engine mints the session id. It is sortable, prefixed
  `sess_`, and stable for the session.
- Inside the core, an id is a deterministic value derived from
  `%MachineState{}` alone. The core cannot read the wall clock or a CSPRNG
  ([ADR-0003](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0003-pure-core-with-effects.md)).
- Today only the invoke id is minted inside the core. Spec 6.4.1 fixes its
  shape: the id of the invoking state, a dot, then `inv_` and a session-global
  counter. With no state id, the shape is `inv_<counter>`.
- A future `<send idlocation>` generator follows the same no-entropy rule.

## Out of scope

- **ECMAScript datamodel.** The datamodel is predicator
  ([ADR-0004](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0004-predicator-as-the-datamodel.md)).
  No JS engine, no `eval`, no raw Elixir in documents. Use `<invoke>` for real
  computation.
- **v1 API compatibility.** The conformance corpus is the compatibility
  contract, not the v1 module surface.
