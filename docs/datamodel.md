# Datamodel

**Read this to:** learn what datamodel the engine uses, what it provides, and
how expressions are evaluated.

**Short version:** the datamodel is predicator
([predicator-ex](https://github.com/riddler/predicator-ex), `~> 9.5`). It has no
`eval`. Every evaluation returns `{:ok, value} | {:error, reason}`, and the
interpreter turns errors into `error.execution` events.

The datamodel is permanent, not a stopgap. We do not support the ECMAScript
datamodel. We never evaluate raw Elixir code from a document. Documents declare
`datamodel="predicator"`. The accepted alias is `elixir`, which keeps the
converted W3C tests working.

Decision: [ADR-0004](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0004-predicator-as-the-datamodel.md).

## Why not ECMAScript

- **Security.** A JS engine in the library removes the security benefit of an
  Elixir SCXML engine. Predicator is non-evaluative by design: it has no `eval`
  and no side channels. It is safe for documents that end users write.
- **Conformance limit.** A small, known set of W3C tests requires ECMAScript.
  The corpus tooling rewrites or excludes them. This limits the conformance
  that the engine can reach. The test manifest documents this limit.
- **Host computation.** Real computation belongs in the host application. The
  host receives it through `<invoke>` handlers and external `<send>`, which are
  controlled, typed, and supervised. To register your own `<invoke>` handlers,
  see [docs/extending.md](extending.md).

## What the datamodel provides

- **`<datamodel>` and `<data>`.** They accept `expr`, child content, and `src`.
  Both `binding="early"` and `late` work.
- **`<assign>` with deep paths.** Examples are `account.holder.name` and
  `transactions[0].amount`. It creates intermediate maps automatically, as
  ECMAScript assignment does. The root segment of the path must already exist
  in the datamodel. An undeclared root fails with `error.execution` and the
  engine does not create it. Automatic creation only extends a path under a name
  that the document already declared.
- **`cond` and `expr`.** `cond` works on transitions and on `<if>`/`<elseif>`.
  `expr` works everywhere the spec allows.
- **System variables per spec 5.10.** They are `_event`, `_sessionid` (a `sess_`
  id, stable for the lifetime of the session), `_name`, `_ioprocessors`, and the
  `In(stateId)` predicate.
- **The starting datamodel on the effect stream.** You do not need
  `Session.snapshot/1` to read it. The session emits events in this order:
  1. One `{:datamodel_init, %Statifier.Effect.DatamodelInit{}}` baseline,
     before it evaluates any `<data>` value.
  2. One `{:datamodel_change, %Statifier.Effect.DatamodelChange{}}` for each
     `<data>` that it binds.

  The session emits the baseline once per session.

  A subscriber can rebuild the whole datamodel from the stream alone. It seeds
  from the baseline and applies each binding at its `location_path`. This works
  under both `binding="early"` and `binding="late"`, including a state-scoped
  `<data>` bound late in the run.

**`<data src>` is never fetched.** The engine lowers, validates, and compiles
`src` like any other attribute. It never fetches it, at any binding time. This
is a permanent decided deviation from the fetch MUST in spec 5.3.2.

- A binding-time fetch is I/O inside the pure core.
- Dereferencing URIs that a document names contradicts the security posture
  above.
- A `<data>` with an `src` raises `error.execution`. It leaves the id as an
  empty (nil) data element, which is the shape of the failure clause in 5.3.2.
- An embedder that needs the data fetches it and supplies it through
  environment-provided values for top-level `<data>` ids.
- test552 is the one corpus file that this reddens. It stays failing and
  visible by design.

Decision: [ADR-0024](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0024-data-src-is-never-fetched.md),
[ADR-0003](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0003-pure-core-with-effects.md).

## Evaluation contract

Every evaluation goes through one module with one context type.

**Compiled form.** The engine compiles expressions once, at Machine-build time,
into `{:compiled, %Predicator.Compiled{}, source}`. Static attribute values are
`{:static, value}`. One evaluator function handles both. The
`%Predicator.Compiled{}` envelope comes from upstream (predicator ADR-0009).
Statifier keeps `source` because only statifier knows where the expression sat
in the document.

Decision: [ADR-0014](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0014-expression-spans-in-cond-diagnostics.md), item 2.

**Context scope.** The engine builds the evaluation context once per evaluation
site. Today a site is one executable-content block.

- It never builds the context once per expression.
- It never scopes the context to a whole macrostep. `_event` changes on every
  internal-event round, and `In(stateId)` reads a configuration that changes at
  every microstep. A snapshot for the whole macrostep would be stale before a
  later site in the same macrostep read it.

**Errors.** Every evaluation returns `{:ok, value} | {:error, reason}`. The
interpreter maps errors to `error.execution` internal events per spec. Leaves
never swallow errors.

**Keys.** Datamodel keys are strings at every level, top-level and nested. The
engine checks an embedder-supplied `:datamodel` option for this at
`MachineState.new/2` construction time. It does not trust the option. The
`@doc` on `Statifier.Evaluator.context/1` states the property that this check
supports.

**Event data.** One normalization function with defined rules coerces event
data to and from other types: `Statifier.EventData.coerce/1`. `<param>`,
`<content>`, `namelist`, and `<donedata>` share it.

- It implements the key-value-pairs and space-normalized-string rungs of
  B.2.8.1.
- A predicator-literal rung replaces the JSON rung.
- It does not implement the indicated-format or XML-DOM rungs. The moduledoc of
  `Statifier.EventData` states why for each.

**When a bad expression fails.** Spec 5.9.4 permits either choice: "The SCXML
Processor MAY reject documents containing syntactically ill-formed expressions
at document load time, or it MAY wait and place 'error.execution' in the
internal event queue at runtime". Both halves conform. The clause frames the
choice as one policy for the whole processor. This engine currently makes the
choice for each element class.

- **Defers to runtime:** `<data expr>`, `<assign expr>`, `<script>`, and a
  `namelist` entry on `<send>`/`<invoke>`.
- **Rejected at load time:** an expression that fails to compile anywhere else.
  `cond`, `<log expr>`, `<content expr>`, `<foreach array>`, and the
  `expr`/`location` of a `<param>` element still fail `Compiler.compile/1`.

The engine captures a `<data expr>` or `<assign expr>` that does not compile as
`{:invalid, error}` on the compiled node. It raises the error at binding or
execution time. `<script>` gets the same treatment for a body outside the
statement grammar of predicator.

**Why.** The difference is deliberate, not an oversight.

- `test/scion_tests/data/data_invalid_test.exs` declares an unparseable
  `<data expr="{p1: 'v1'"/>`. It asserts `pass` by catching the resulting
  `error.execution`. Load-time rejection would make that document unloadable
  and the test unpassable.
- `test/scion_tests/assign/assign_invalid_test.exs` requires the same
  treatment for `<assign expr="{p1: 'v1'"/>`.

**If the policy is unified.** It unifies toward deferral. Deferral loads more
documents, and no corpus file requires load-time rejection. Watch for this
trigger: a corpus document with an unparseable `cond` plus an `error.execution`
handler. None exists today. test344 is not one, because its `cond="1"` compiles
and then fails boolean coercion at evaluation.

**The `namelist` trigger.** It fired in st-vwdg. test553
(`test/scxml_tests/mandatory/send/test553_test.exs`) and test554
(`test/scxml_tests/mandatory/invoke/test554_test.exs`) are corpus documents
with an unparseable location expression in a `<send>`/`<invoke>` `namelist`.
Their expected `pass` depends on catching the resulting `error.execution`
instead of failing to load. The response moved that one element class to the
deferring side. It did not unify the whole policy.

- `<param>` keeps rejecting at load time. The runtime rule and the load-time
  rule are separate, and no corpus file forces `<param>` onto the deferring
  side.
- The `cond` half of the trigger has not fired.

Decision: [ADR-0026](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0026-script-as-predicator-statement-programs.md)
for `<script>`.
[ADR-0036](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0036-send-argument-failure-discards-the-message.md)
and
[ADR-0031](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md)
give `<param>` `expr`/`location` the same runtime treatment as a `namelist`
entry.

## Statement sequences and `<script>`

`<script>` is supported. A `<script>` body is a predicator statement program,
not ECMAScript. The no-eval security posture is unchanged. Predicator 5.0.0
added the statement layer:

- `parse_program/2` parses sequences of assignments and expression statements
  over the existing expression language.
- `Predicator.execute/3` runs the program and returns the resulting context.

Rules:

- **Partial writes stay.** A body that fails mid-program keeps every write up to
  the failing statement. (The third element of `{:error, error, %Context{}}` is
  the partial context.) The body raises `error.execution`. This is the
  stop-and-keep error model of spec 4.9, and IRP test156 observes it.
  All-or-nothing rollback is a decided non-option.
- **Load-time script.** The engine evaluates a `<script>` child of `<scxml>` at
  document load time, before it enters the initial state (spec 5.8). This is a
  separate interpreter path from executable content.
- **`<script src>`.** The engine rejects it at load with a named unsupported
  error. External fetch stays the unresolved question that st-322 owns.
- **Limit.** Corpus script bodies are ECMAScript, and the statement grammar of
  predicator is not. Object literals, `typeof`, and function definitions do not
  parse. `if`, `else`, `while`, `undefined`, and `null` are reserved words. Only
  a subset of the once-excluded `:needs_script` corpus files joins the ratchet.

Decision: [ADR-0026](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0026-script-as-predicator-statement-programs.md),
which amends ADR-0004 in part. See also ADR-0024 on `<data src>`.

## Upstreaming to predicator

These seams belong in predicator, not in the glue code of statifier. Each seam
gets a beads issue here and a mirrored issue in predicator-ex when we hit the
seam in implementation.

1. **Persistent bound context.** Build a context once (data plus host functions
   like `In/1`), evaluate many expressions against it, and rebind cheaply when
   data changes. `Predicator.Context.bind/3` is the cheap-rebind path. It would
   let the once-per-block interval above widen again, when a caller needs it.

   - **Landed in predicator 5.0.0.** `Predicator.FunctionProvider` (a module
     that supplies named functions), the `providers:` and `host:` options of
     `Context.new/2`, and `Context.put_host/2` (an O(1)
     `%{context | host: host}` refresh).
   - **Step 1, within-block only.** Measurement showed that context
     construction is most of the cost of one macrostep at realistic datamodel
     scale. `<assign>` and `<foreach>` now bind into the context that an
     executable-content block already threads. They do not rebuild it for each
     write. Decision:
     [ADR-0028](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0028-executable-content-blocks-thread-one-context.md).
   - **Step 2, `In/1`.** `In/1` is a `Predicator.FunctionProvider` that reads
     `host`. It is not an inline `functions:` closure. The resolved `functions`
     map therefore holds no captured configuration. It is identical for every
     context that this library builds. `Statifier.Evaluator.Functions.base_context/0`
     resolves it once at compile time. `context/1` refreshes `host` with
     `put_host/2` and binds each datamodel root with `bind/3`. It never calls
     `Predicator.Context.new/2` on this path. Decision:
     [ADR-0030](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md).
   - **Effect.** This lowers the cost for each site. It does not widen the
     interval. The "once per evaluation site" rule in "Evaluation contract" is
     unchanged. The site is still the whole block or selection round, not the
     individual write and not the whole macrostep. No context is stored on
     `MachineState`. Widening the interval that far remains future work, on the
     grounds of ADR-0030.
   - **Predicator 8.0.** Upstream memoizes the fixed term that `base_context/0`
     hoists. Statifier keeps the compile-time hoist anyway. The memo removes
     re-validation. It does not remove the per-call stamp-and-allocate cost
     that `new/2` still pays, so the constant stays cheaper. The
     `normalize: false` seam that sits beside the memo also exists as of 8.0.
     Statifier does not take it. It would help a whole-map `new/2` call,
     but this path binds for each root and does not construct for each build.
     The amendment to ADR-0030 records this.
2. **Auto-vivifying path assignment.** Path resolution exists
   (`context_location`). Assignment with creation should live beside it.

   - **Landed in predicator 3.6.0.** `Predicator.context_assign/4` and
     `ContextLocation.put/3`. Creation is ECMAScript-like. A container
     collision raises `:not_a_container`. List assignment past the end pads
     with `:undefined`. A negative index raises `:invalid_index`.
   - **Used here (st-af3.4).** `Statifier.Machine.Content.Assign` resolves the
     path with `Predicator.context_location/3` and writes with
     `ContextLocation.put/3`. It does not use the combined `context_assign/4`.
     The split lets the resolve read the normalized context while the write
     lands on the raw `machine_state.datamodel`. See Decisions 1 and 2 of that
     plan.
3. **A typed undefined.** The `:undefined` of predicator leaks into hosts as a
   bare atom that every embedding normalizes ad hoc.

   - **Landed in predicator 5.0.0.** The `undefined` literal (upstream px-ocp).
   - **Used here (st-unt).** The seven boundness templates of
     `conf_predicator.xsl` emit `=== undefined` and `!== undefined`. (Non-strict
     `==` propagates `:undefined` and does not return a boolean.) The 24
     affected W3C corpus files were regenerated. No ratchet update was owed,
     because none of those files is in `test/passing_tests.json`.
   - **Limit.** The literal does not rescue a genuinely unbound root. A
     `Var<n>` boundness cond still waits for st-af3.3 to seed the declared
     `<data>` that it names.
   - **No shim.** Writers spell `:undefined` themselves, and `nil` means only
     the null of predicator. Decision:
     [ADR-0037](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0037-unbound-spelled-undefined-at-the-writer.md).
4. **Statement sequences.** See "Statement sequences and `<script>`" above.

   - **Landed in predicator 5.0.0.** `parse_program/2`, the `store` and `pop`
     instructions, and `Predicator.execute/1,2,3`, which returns the resulting
     context (with the partial context on error). st-af3.17 is the
     statifier-side `<script>` implementation.
   - **Predicator 8.0.0.** It added the `protected_roots:` option on
     `Predicator.execute/3`. This repository uses it under its current `~> 9.5`
     pin. It is the 5.10 half of the same seam. A write to a protected root
     fails at the attempt, with no post-hoc diff needed to catch it. st-i9d
     consumes it, and it replaces the post-hoc root diff as the primary
     enforcement mechanism.
5. **String prefix and substring.** Landed in predicator 3.7.0 (`starts_with/2`,
   `ends_with/2`, `substring/2,3`, `index_of/2`). `conf:varPrefix` (test224) no
   longer needs an exclusion.
6. **List concatenation.** Landed in predicator 3.7.0 (`concat/2`, and list `+`
   list). `conf:extendArray` (test525) no longer needs an exclusion.
7. **Numeric-type builtins.** Not landed. `Math.pow` (and possibly `Math.sqrt`)
   return floats even for integer-exact results. `===` stays type-strict.
   `Math.pow(2, 3) === 8` is therefore `false` under the single-Number-type
   assumption of ECMAScript. ADR-0023 keeps the fix upstream in predicator. The
   engine does not coerce numeric types at the statifier boundary. A mirror bead is filed in predicator-ex. The three
   `test/scion_tests/targetless_transition` files stay failing until the
   dependency is bumped. Decision:
   [ADR-0023](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0023-numeric-type-fixes-upstream-not-boundary-coercion.md).
