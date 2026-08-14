# Datamodel

Statifier's datamodel is **predicator** ([predicator-ex](https://github.com/riddler/predicator-ex),
`~> 7.0`). This is a commitment, not a stopgap ([ADR-0004](adr/0004-predicator-as-the-datamodel.md)):
we do not chase the ECMAScript datamodel, and we never evaluate raw Elixir code from
a document. Documents declare `datamodel="predicator"` (accepted alias: `elixir` for
continuity with v1's converted W3C tests).

## Why not ECMAScript

- Embedding a JS engine trades away the security story that makes an Elixir SCXML
  engine worth having. Predicator is non-evaluative by design: no `eval`, no side
  channels, safe for end-user-authored documents.
- The W3C tests that genuinely require ECMAScript are a bounded, known set; the
  corpus tooling rewrites or excludes them. The conformance ceiling this imposes is
  accepted and documented in the test manifest.
- Real computation belongs in the host application, reached through `<invoke>`
  handlers and external `<send>` - controlled, typed, supervised.

## What the datamodel provides

- `<datamodel>` / `<data>` with `expr`, child content, and `src` - `binding="early"`
  and `late` both supported. `src` is lowered, validated, and compiled like any
  other attribute, but it is **never fetched, at any binding time** - a decided,
  permanent deviation from spec 5.3.2's fetch MUST
  ([ADR-0024](adr/0024-data-src-is-never-fetched.md)): a binding-time fetch is
  I/O inside the pure core (ADR-0003), and dereferencing document-named URIs
  contradicts the security posture above (ADR-0004). A `<data>` with an `src`
  raises `error.execution` and leaves the id as an empty (nil) data element,
  the shape of 5.3.2's failure clause. Embedders that need the data fetch it
  themselves and supply it via environment-provided values for top-level
  `<data>` ids. test552 is the one corpus file this reddens, kept failing and
  visible by design.
- `<assign>` with deep paths (`user.profile.name`, `items[0].sku`), including
  auto-vivification of intermediate maps (ECMAScript-like assignment behavior;
  v1 refused to create intermediates). The root segment of the path must
  already exist in the datamodel - an undeclared root fails with
  `error.execution` rather than being created, so vivification only ever
  extends a path under a name the document already declared.
- `cond` on transitions and `<if>`/`<elseif>`, `expr` everywhere the spec allows.
- System variables per spec 5.10: `_event`, `_sessionid` (a UXID, stable for the
  session's lifetime), `_name`, `_ioprocessors`, and the `In(stateId)` predicate.

## Evaluation contract

Every evaluation goes through one module with one context type:

- Expressions are compiled once at Machine-build time into
  `{:compiled, %Predicator.Compiled{}, source}`; static attribute values are
  `{:static, value}`. One evaluator function handles both. The
  `%Predicator.Compiled{}` envelope is upstream's (predicator ADR-0009), not a
  statifier-side wrapper; we keep owning `source` because only statifier
  knows where the expression sat in the document (see ADR-0014 item 2).
- The evaluation context is built once per evaluation site (once per
  executable-content block today), never once per expression, and never
  scoped to a whole macrostep: `_event` is rewritten on every internal-event
  round and `In(stateId)` reads a configuration that moves at every
  microstep, so a snapshot spanning the whole macrostep would already be
  stale before a later evaluation site in that same macrostep read it.
- Every evaluation returns `{:ok, value} | {:error, reason}`. The interpreter maps
  errors to `error.execution` internal events per spec. Leaves never swallow errors.
- **An expression that fails to compile is rejected at load time everywhere
  except `<data expr>` and `<assign expr>`, which defer to runtime.** Spec
  5.9.4 permits either ("The SCXML Processor MAY reject documents containing
  syntactically ill-formed expressions at document load time, or it MAY wait
  and place 'error.execution' in the internal event queue at runtime"), so
  both halves conform - but the clause frames the choice as one
  processor-wide policy, and this engine currently makes it per element class.
  The asymmetry is deliberate, not an oversight: `test/scion_tests/data/data_invalid_test.exs`
  declares an unparseable `<data expr="{p1: 'v1'"/>` and asserts `pass` by
  *catching* the resulting `error.execution`, so load-time rejection would
  make that document unloadable and the test unpassable.
  `test/scion_tests/assign/assign_invalid_test.exs` requires the identical
  treatment for `<assign expr="{p1: 'v1'"/>`. A `<data expr>` or `<assign
  expr>` that will not compile is therefore captured as `{:invalid, error}`
  on the compiled node and raised at binding/execution time, while `cond` and
  `<log expr>` still fail `Compiler.compile/1`.

  If this is ever unified, it unifies toward deferral rather than away from it:
  deferral loads strictly more documents, and no corpus file requires load-time
  rejection. The trigger to watch for is a corpus document with an unparseable
  `cond` plus an `error.execution` handler - none exists today, and test344 is
  not one (its `cond="1"` compiles, then fails boolean coercion at evaluation).
- Type coercion to/from event data has one normalization function with defined rules,
  `Statifier.EventData.coerce/1`, shared by `<param>`, `<content>`, `namelist`, and
  `<donedata>`. It implements B.2.8.1's key-value-pairs and space-normalized-string
  rungs, plus a predicator-literal rung standing in for the JSON rung; it does not
  implement the indicated-format or XML-DOM rungs (`Statifier.EventData`'s moduledoc
  states why for each).

## Statement sequences and `<script>`

`<script>` is supported
([ADR-0026](adr/0026-script-as-predicator-statement-programs.md), amending
ADR-0004 in part): the statement layer this section once asked for landed in
predicator 5.0.0 - `parse_program/2` parses sequences of assignments and
expression statements over the existing expression language, and
`Predicator.execute/3` runs the program and returns the resulting context. A
`<script>` body is a predicator statement program, not ECMAScript, and the
no-eval security posture is unchanged.

- A body that fails mid-program keeps every write up to the failing statement
  (`{:error, error, %Context{}}`'s third element is the partial context) and
  raises `error.execution` - spec 4.9's stop-and-keep error model, the shape
  IRP test156 observes. All-or-nothing rollback is a decided non-option.
- A `<script>` child of `<scxml>` is evaluated at document load time, before
  the initial state is entered (spec 5.8) - a separate interpreter path from
  executable content.
- `<script src>` is rejected at load with a named unsupported error; external
  fetch stays the unresolved question st-322 owns (see ADR-0024 on
  `<data src>`).
- The ceiling: corpus script bodies are ECMAScript and predicator's statement
  grammar is not - object literals, `typeof`, and function definitions do not
  parse, and `if`/`else`/`while`/`undefined`/`null` are reserved words - so
  only a subset of the once-excluded `:needs_script` corpus files joins the
  ratchet.

## Upstreaming to predicator

Seams found in v1 that belong in predicator rather than in statifier's glue:

1. **Persistent bound context**: build a context once (data + host functions like
   `In/1`), evaluate many expressions against it, rebind cheaply when data changes.
   v1 rebuilt the full context map per expression. `Predicator.Context.bind/3`
   is the cheap-rebind path that would let the once-per-block interval above
   widen again, once a caller needs to. Landed in predicator 5.0.0:
   `Predicator.FunctionProvider` (a module supplying named functions),
   `Context.new/2`'s `providers:` and `host:` options, and `Context.put_host/2`
   (an O(1) `%{context | host: host}` refresh). Not taken here yet: `In/1` is
   still an inline `functions:` closure, which 5.0 still supports and
   dispatches identically to a provider entry. Taken in the within-block
   form only ([ADR-0028](adr/0028-executable-content-blocks-thread-one-context.md)):
   measurement showed context construction is the majority of one
   macrostep's cost at realistic datamodel scale, and `<assign>` and
   `<foreach>` bind into the context an executable-content block already
   threads rather than rebuilding it per write. The "built once per
   evaluation site" commitment above (`docs/datamodel.md:54-59`) is
   unchanged by this - the site is still the whole block, not the
   individual write - and this seam is not taken across blocks: no context
   is stored on `MachineState`, and widening the interval that far remains
   future work.
2. **Auto-vivifying path assignment**: path resolution exists (`context_location`);
   assignment-with-creation should live beside it. Landed in predicator 3.6.0:
   `Predicator.context_assign/4` and `ContextLocation.put/3`. Vivification is
   ECMAScript-like; a container collision raises `:not_a_container`; list
   assignment past the end pads with `:undefined`; a negative index raises
   `:invalid_index`. The statifier-side consumer landed in st-af3.4:
   `Statifier.Machine.Content.Assign` resolves the path with
   `Predicator.context_location/3` and writes with `ContextLocation.put/3`
   (split rather than the combined `context_assign/4`, so the resolve reads
   the normalized context and the write lands on the raw
   `machine_state.datamodel` - see that plan's Decisions 1 and 2).
3. **A typed undefined**: predicator's `:undefined` currently leaks into hosts as a
   bare atom that every embedding normalizes ad hoc. Landed in predicator 5.0.0:
   the `undefined` literal (upstream px-ocp). Consumed here by st-unt:
   `conf_predicator.xsl`'s seven boundness templates emit `=== undefined` /
   `!== undefined` (non-strict `==` propagates `:undefined` rather than
   returning a boolean), and the 24 affected W3C corpus files were regenerated.
   No ratchet update was owed - none of those files is in
   `test/passing_tests.json`. The literal does not rescue a genuinely unbound
   root, so a `Var<n>` boundness cond still waits on st-af3.3 seeding the
   declared `<data>` it names.
4. **Statement sequences** (above). Landed in predicator 5.0.0:
   `parse_program/2`, the `store`/`pop` instructions, and
   `Predicator.execute/1,2,3` returning the resulting context (with the
   partial context on error). Consumed here per ADR-0026; the statifier-side
   `<script>` implementation is st-af3.17.
5. **String prefix/substring**: landed in predicator 3.7.0 (`starts_with/2`,
   `ends_with/2`, `substring/2,3`, `index_of/2`); `conf:varPrefix` (test224) no
   longer needs an exclusion.
6. **List concatenation**: landed in predicator 3.7.0 (`concat/2`, and list `+`
   list); `conf:extendArray` (test525) no longer needs an exclusion.
7. **Numeric-type builtins**: `Math.pow` (and possibly `Math.sqrt`) return
   floats even for integer-exact results, while `===` stays type-strict, so
   `Math.pow(2, 3) === 8` is `false` under ECMAScript's single-Number-type
   assumption. ADR-0023 keeps the fix upstream in predicator rather than
   coercing numeric types at the statifier boundary; a mirror bead is filed
   in predicator-ex. Not yet landed: the three
   `test/scion_tests/targetless_transition` files stay failing until the
   dependency is bumped.

Each of these gets a beads issue here and a mirrored issue in predicator-ex when we
hit the seam in implementation.
