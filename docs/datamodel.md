# Datamodel

Statifier's datamodel is **predicator** ([predicator-ex](https://github.com/riddler/predicator-ex),
`~> 5.0`). This is a commitment, not a stopgap ([ADR-0004](adr/0004-predicator-as-the-datamodel.md)):
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

- `<datamodel>` / `<data>` with `expr`, child content, and `src` (fetch at
  document-load time only, `binding="early"` and `late` both supported).
- `<assign>` with deep paths (`user.profile.name`, `items[0].sku`), including
  auto-vivification of intermediate maps (ECMAScript-like assignment behavior;
  v1 refused to create intermediates).
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
- Type coercion to/from event data has one normalization function with defined rules,
  shared by `<param>`, `<content>`, `namelist`, and `<donedata>`.

## Statement sequences and `<script>`

`<script>` (ECMAScript statements) stays unsupported. The direction we want instead:
a small, safe statement layer in predicator itself - sequences of assignments and
expression statements over the existing expression language, upstreamed as a
predicator feature so every predicator embedding gets it. Until that exists,
multi-step mutation is expressed as a sequence of `<assign>` elements, which covers
most real `<script>` usage in the corpora.

A possible follow-on (tracked as an issue, not promised): a converter that rewrites
the *basic* `<script>` bodies found in the SCION corpus (assignments, increments)
into `<assign>` sequences or the predicator statement form, so those tests can join
the ratchet.

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
   dispatches identically to a provider entry. Taking this seam is st-sdh's
   call, deferred until something evaluates in a hot path worth benchmarking.
2. **Auto-vivifying path assignment**: path resolution exists (`context_location`);
   assignment-with-creation should live beside it. Landed in predicator 3.6.0:
   `Predicator.context_assign/4` and `ContextLocation.put/3`. Vivification is
   ECMAScript-like; a container collision raises `:not_a_container`; list
   assignment past the end pads with `:undefined`; a negative index raises
   `:invalid_index`.
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
4. **Statement sequences** (above).
5. **String prefix/substring**: landed in predicator 3.7.0 (`starts_with/2`,
   `ends_with/2`, `substring/2,3`, `index_of/2`); `conf:varPrefix` (test224) no
   longer needs an exclusion.
6. **List concatenation**: landed in predicator 3.7.0 (`concat/2`, and list `+`
   list); `conf:extendArray` (test525) no longer needs an exclusion.

Each of these gets a beads issue here and a mirrored issue in predicator-ex when we
hit the seam in implementation.
