---
date: 2026-08-12T14:54:26-0600
researcher: Claude
git_commit: 3780e1b62384876451104485a80d62b82f429ef0
branch: st-p3t-predicator-5-bump
repository: statifier-ex
beads_issue: st-p3t
topic: "What predicator 5.0 changes for statifier-ex, and what the bump requires"
tags: [research, codebase, datamodel, predicator, corpus]
status: complete
last_updated: 2026-08-12
last_updated_by: Claude
---

# Research: What predicator 5.0 changes for statifier-ex, and what the bump requires

**Date**: 2026-08-12T14:54:26-0600
**Git Commit**: 3780e1b62384876451104485a80d62b82f429ef0
**Branch**: st-p3t-predicator-5-bump
**Bead**: st-p3t

## Research Question

This repo pins `{:predicator, "~> 4.0"}`. predicator 5.0.0 shipped 2026-08-12
as a breaking release. What does the bump actually require here, grounded in
this codebase and in the real 5.0 package?

Four sub-questions, from the bead:

1. The breaking custom-function signature change and what it does to
   `Statifier.Evaluator.in_function/1`.
2. Whether the new `Predicator.FunctionProvider` seam can and should replace
   `In/1`'s per-call closure, and at what cost. Evidence only - the decision
   belongs to the plan stage.
3. A concrete reserved-word sweep of the corpus for `if`, `else`, `while`,
   `undefined`.
4. Ground truth on predicator 5.0 itself, and what the bump unlocks for other
   beads.

## Summary

**The bump is small, and the sweep is clean.**

- predicator **5.0.0 exists on hex**, released 2026-08-12 (`mix hex.info
  predicator`). The upstream checkout at `~/repos/github/predicator-ex` is at
  `@version "5.0.0"`, head `19b10f5 Releases v5.0.0`.
- **Reserved-word sweep: zero real hits.** Every one of the 1224
  expression- and location-bearing attribute values in the checked-in corpus
  and internal tests was compiled against a real predicator 5.0.0 and against
  4.0.0. Both versions produce **the same 8 failures**, and all 8 are
  deliberately-invalid negative fixtures or the already-allowlisted
  `conf:illegalItem` value. Nothing regresses. Details and the exact method
  are in "The reserved-word sweep" below.
- **Only one line of `lib/` is affected by the breaking change**: the `@spec`
  on the private `Statifier.Evaluator.in_function/1`
  ([`lib/statifier/evaluator.ex:133-134`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L133-L134)). Behavior is unchanged because the
  closure already ignores its second argument. Note that dialyzer is unlikely
  to force this: `Predicator.Context.t()` is a struct and therefore *is* a
  `map()`, so the existing spec stays technically satisfiable. The spec is
  misleading rather than unsound, so fixing it is a correctness-of-documentation
  change the gate will not fail on.
- **The `FunctionProvider` seam is real and it does what st-sdh predicted.**
  `Context.new/2` gains `providers:` and `host:`; `Context.put_host/2` is a
  single `%{context | host: host}`. Converting `In/1` to a provider is
  mechanically small (one new module, one changed `context/1`), but on its own
  it buys nothing measurable today, and it interacts with two commitments this
  repo has written down (ADR-0012's resumable-position rule and
  `Statifier.Evaluator`'s "never a `MachineState` field" moduledoc section).
  Evidence and the cost breakdown are in "The FunctionProvider seam" below.
  **Not decided here.**

## Detailed Findings

### 1. Where predicator is consumed in this repo

Two modules, plus one tool.

- `lib/statifier/compiler/expressions.ex` - the compile seam.
  `Predicator.compile_with_spans/1` at [`lib/statifier/compiler/expressions.ex:63`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/compiler/expressions.ex#L63),
  with a failure-path-only `Predicator.parse(source, spans: true)` at
  [`lib/statifier/compiler/expressions.ex:85`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/compiler/expressions.ex#L85) to recover `{line, column}`.
  **Nothing in 5.0 touches either call.**
- `lib/statifier/evaluator.ex` - the evaluate seam. `Predicator.Context.new/2`
  at [`lib/statifier/evaluator.ex:90-93`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L90-L93), `Predicator.evaluate/3` (arity-2 form)
  at [`lib/statifier/evaluator.ex:120`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L120), and the `In/1` closure at
  [`lib/statifier/evaluator.ex:133-142`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L133-L142).
- [`lib/statifier/machine.ex:82`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/machine.ex#L82) - the `expr()` sum type mentions
  `%Predicator.Compiled{}`.
- [`tools/corpus/scxml_w3/check_exprs.exs:71-72`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/tools/corpus/scxml_w3/check_exprs.exs#L71-L72) - `Predicator.compile/1` and
  `Predicator.context_location/3`, the corpus checker.

`Statifier.Evaluator.context/1` has exactly **one production caller**:
[`lib/statifier/interpreter/content.ex:105`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/interpreter/content.ex#L105), inside `execute_block/3`. Everything
else calling it is a test.

### 2. The breaking custom-function signature change

Upstream, verbatim from `~/repos/github/predicator-ex/CHANGELOG.md`, 5.0.0
`### Changed`:

> **Every custom function's second argument is now the `%Predicator.Context{}`
> struct, not the bare data map.** Read the data namespace with `context.data`
> (was: the second argument itself) and, for a provider function, host state
> with `context.host`.

The 4.0 guide (`git show v4.0.0:docs/guides/custom-functions.md`) had
`Map.get(context, "current_user_role", "guest")`; the 5.0 guide
(`~/repos/github/predicator-ex/docs/guides/custom-functions.md:65-69`) has
`Map.get(context.data, ...)`.

What this repo's `In/1` looks like today, at
[`lib/statifier/evaluator.ex:133-142`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L133-L142):

```elixir
@spec in_function(machine_state :: MachineState.t()) ::
        (list(), map() -> {:ok, boolean()})
defp in_function(%MachineState{machine: machine, configuration: configuration}) do
  fn [state_id], _raw_context ->
    case Machine.index(machine, state_id) do
      {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
      :error -> {:ok, false}
    end
  end
end
```

The second argument is discarded, so the runtime behavior is identical under
5.0. **Verified empirically**: building the exact context `context/1` builds,
against predicator 5.0.0, and evaluating `In('a1')` returns `{:ok, true}`, with
the second argument arriving as `%Predicator.Context{data: ..., functions: ...,
host: ..., on_unbound: ...}`.

So the change here is exactly two lines: the `@spec` return type becomes
`(list(), Predicator.Context.t() -> {:ok, boolean()})`, and the parameter name
`_raw_context` no longer describes what it receives.

The relevant upstream types are
`~/repos/github/predicator-ex/lib/predicator/context.ex:58-69`:

```elixir
@type on_unbound :: :undefined | :error
@type function_entry :: {module(), atom()} | function()
@type t :: %__MODULE__{
        data: Types.context(),
        functions: %{binary() => {Evaluator.function_arity(), function_entry()}},
        on_unbound: on_unbound(),
        host: term()
      }
```

An inline `functions:` closure map is still supported in 5.0 - it is called
under the same `(args, context)` convention as a provider MFA entry
(`~/repos/github/predicator-ex/lib/predicator/evaluator.ex:1285-1320` dispatches
both shapes identically). So `context/1` compiles and runs unchanged under 5.0;
only the spec lies.

### 3. The `FunctionProvider` seam

#### What 5.0 actually ships

- `Predicator.FunctionProvider`, at
  `~/repos/github/predicator-ex/lib/predicator/functions/provider.ex` (note the
  module name and the path differ). One callback,
  `provider.ex:31`: `@callback functions() :: %{name() => entry()}` where
  `entry :: {Predicator.Evaluator.function_arity(), atom()}`. The atom names a
  function the module exports at arity 2, called as `(args, %Context{})`.
- `Context.new/2` options, documented at
  `~/repos/github/predicator-ex/lib/predicator/context.ex:79-94`: `:builtins`
  (default `true`), `:providers` (list of provider modules), `:functions`
  (inline closure map, merged **last**, so it shadows providers), `:on_unbound`,
  and `:host` (opaque, `Keyword.get(opts, :host)`, **stored with no
  normalization**, never reachable from predicate text).
- `Context.put_host/2` at `context.ex:250-251`:
  `def put_host(%__MODULE__{} = context, host), do: %{context | host: host}` -
  literally O(1), independent of the data map's size.
- `Context.bind/3` at `context.ex:234-237` - `Map.put` plus
  `normalize_value(value)` on the bound value only; carries `functions`,
  `on_unbound` and `host` over unchanged.

The upstream recipe is written against this exact use case,
`~/repos/github/predicator-ex/README.md:65-110`:

```elixir
defmodule MyApp.StateFunctions do
  @behaviour Predicator.FunctionProvider

  @impl Predicator.FunctionProvider
  def functions, do: %{"In" => {1, :call_in}}

  def call_in([state_id], context), do: {:ok, context.host.current_state == state_id}
end
```

> This mirrors how a state machine library wires an SCXML `In(stateId)` guard
> into a running machine - the guard reads current state through `context.host`
> rather than the caller re-threading it as an ordinary predicate argument.

The reasoning is `~/repos/github/predicator-ex/docs/adr/0014-functions-are-provided-by-modules.md`,
which was written about statifier by name.

#### What that would look like here

`context/1` at [`lib/statifier/evaluator.ex:89-94`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L89-L94) becomes something like:

```elixir
Predicator.Context.new(machine_state.datamodel,
  providers: [Statifier.Evaluator.Functions],
  host: machine_state,
  on_unbound: :error
)
```

with the provider's `call_in/2` doing exactly what the closure body does today,
reading `machine` and `configuration` off `context.host` instead of off a
capture. `Machine.index/2`'s `:error -> {:ok, false}` arm is unaffected.

#### Verified properties

Probed against a real predicator 5.0.0:

| Probe | Result |
|---|---|
| `Context.new/2` struct keys | `[:data, :functions, :host, :on_unbound]` |
| `host:` stored as given | yes, a `%{conf: MapSet}` came back identical |
| `put_host/2` replaces it | yes |
| 4.0-shaped `functions:` closure under 5.0 | still called, second arg is `%Context{}` |

One correction worth recording, because st-sdh's note and the upstream
CHANGELOG both state it more strongly than the probe supports: a context
carrying a closure **did** survive `:erlang.term_to_binary/1` +
`binary_to_term/1` in-node, and the round-tripped context still evaluated
`In('a1')` correctly. What is true is narrower - a local fun in a term is a
reference to a specific module and code version, so it does not survive a node
boundary, a code reload, or being written to disk and read back later. That is
still enough to break ADR-0012's "written out and read back" phrasing
([`lib/statifier/evaluator.ex:42-48`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L42-L48)), but "not serializable" overstates it and
a plan that leans on the strong claim should lean on the narrow one instead.

#### The cost and the tension

Arguments the evidence supports, in both directions. **This research does not
pick one.**

For converting now, at the bump:

- It is the whole point of upstream px-8ii, which this repo filed and which
  landed specifically for statifier (st-sdh's 2026-08-12 note).
- It is mechanically small: one new module, a four-line change to `context/1`,
  no change to `evaluate/2` or to any caller.
- It removes the closure from the context, which is the thing
  [`lib/statifier/evaluator.ex:42-54`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L42-L54) names as ruling out ever caching a context
  on `MachineState`. With `host:` holding the `MachineState` (or just the
  `machine` plus `configuration`), a stored context becomes refreshable in O(1)
  with `put_host/2` rather than stale by construction.
- Doing it in the same change as the `@spec` fix means `in_function/1` is
  touched once, not twice.

Against converting now, or for splitting it out:

- **Nothing measures it.** st-sdh is explicitly `DEFERRED ON PURPOSE`
  ("nothing evaluates in a hot path yet, so there is nothing to measure. Do not
  optimize this before there is a benchmark showing it matters"). The conversion
  on its own changes no observable behavior; it only makes a later optimization
  possible.
- The win it enables is **not** realized by the conversion alone.
  `Statifier.Interpreter.Content.execute_block/3` still calls
  `Evaluator.context(machine_state)` once per block
  ([`lib/statifier/interpreter/content.ex:105`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/interpreter/content.ex#L105)), which still runs
  `Context.new/2`'s deep normalization of the whole datamodel. Getting the O(1)
  refresh means also finding a place to *store* the context between blocks -
  which is the `MachineState`-field question that
  [`lib/statifier/evaluator.ex:37-63`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L37-L63) argues against on ADR-0012 grounds, and
  st-sdh's own note frames as "the question stops being bind/3-vs-rebuild and
  becomes where to store it."
- **Two moduledoc sections and one doc would go stale.**
  [`lib/statifier/evaluator.ex:37-63`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L37-L63) ("Why the built context is not a
  `MachineState` field") argues from the closure's existence; the position-
  snapshot note on `context/1` ([`lib/statifier/evaluator.ex:83-86`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L83-L86)) says "`In/1`'s
  closure captures `machine_state.machine` and `machine_state.configuration`";
  and [`docs/datamodel.md:69-73`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/datamodel.md#L69-L73) (upstream seam 1) is written as an open seam.
  A conversion that leaves those in place leaves the repo arguing for a design
  it no longer has.
- st-sdh is a separate, open, `p3` bead with its own acceptance criteria ("a
  benchmark over a realistic datamodel and block count"). Doing the provider
  half here without the benchmark half leaves st-sdh in an odd state.
- The bead's own acceptance criteria do **not** ask for it: "mix.exs pins
  ~> 5.0, mix.lock updated; in_function @spec fixed; corpus swept ...; full
  mix quality green."

One upstream gotcha that would bite either way, from
`~/repos/github/predicator-ex/lib/predicator.ex:235-247` and `:544-546`: when a
prebuilt `%Context{}` is passed to `Predicator.evaluate/3`, the `:functions`,
`:providers`, `:builtins`, `:host` and `:on_unbound` options are **silently
ignored** - those come from the struct. Only `:positions`,
`:segment_positions` and `:loop_budget` are read from `opts` on that path. This
repo already never passes them ([`lib/statifier/evaluator.ex:105-110`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L105-L110) documents
exactly that), so it is a non-issue today, but it constrains any future design
that wants to vary `host` per call.

### 4. The reserved-word sweep

#### What the prior 4.0 bump actually did

The bead frames this as "mirror the 4.0 bare-`=` sweep". The finding is that
**no ad-hoc sweep happened at the 4.0 bump**, because the generator had already
been fixed and a permanent checker already existed.

- The bump commit is `e613a0e` "Bumps predicator to ~> 4.0" (Refs: st-wju.1,
  2026-08-09). It touched `mix.exs`, `mix.lock`, `docs/datamodel.md` and two
  plan/research docs. Its message: "a pre-flight trial bump found zero lib/
  source changes required and the corpus predicator converter already emits
  ==/=== throughout, so this subsumes st-2pj's acceptance criteria with no code
  change beyond the pin."
- The `=` -> `==` work predates it, in `86a2f82` "Rewrites W3C conf XSL for the
  predicator datamodel (st2-00p.5)", which authored
  `tools/corpus/scxml_w3/conf_predicator.xsl` emitting `==`/`===` from the
  start. st-2pj was never worked as its own bead.
- The method, recorded in
  [`docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md:349-400`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md#L349-L400),
  was three things: a **pre-flight trial bump** in a scratch tree with `mix test`
  and `mix test test/corpus/` then reverted; **one deterministic grep on the
  generator only**, promoted to an automated phase criterion -
  `git grep -nE '=[^=~<>!]' -- tools/corpus/scxml_w3/conf_predicator.xsl`; and a
  **full conformance run** (`mix quality`, `mix gate.check`,
  `mix test.regression`, `mix test --include scion --include scxml_w3`). No
  exclusions were added, no corpus was regenerated, no gate-guard ledger entry
  was needed.
- The framing sentence is
  [`docs/research/260809-st-wju.1-compile-document-to-interned-machine.md:409-411`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/research/260809-st-wju.1-compile-document-to-interned-machine.md#L409-L411):
  "`=` is no longer equality ... This is what makes st-2pj a corpus-converter
  sweep and not just a version bump."

The standing checker is `tools/corpus/scxml_w3/check_exprs.exs`. `run/3`
(`:100-138`) walks `**/*.scxml` under a cases root, drops excluded test ids,
extracts every expression/location attribute via Saxy simple-form recursion
(`collect_attributes/1`, `:46-62`), compiles each, and reports
`unexpected_failures` plus `stale_allowlist`. Invoked as `mise run corpus:check`
([`mise.toml:167-171`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/mise.toml#L167-L171)). Its attribute list at
[`tools/corpus/scxml_w3/check_exprs.exs:15-16`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/tools/corpus/scxml_w3/check_exprs.exs#L15-L16) is the authoritative one:

```elixir
@expression_attrs ~w(cond expr eventexpr targetexpr typeexpr delayexpr sendidexpr srcexpr array)
@location_attrs   ~w(location item idlocation)
```

Two gaps in it: it runs against **mandatory W3C only** (not `optional/`, not
SCION at all), and it runs against the **gitignored** transformed tree under
`tools/corpus/scratch/`, so using it requires a full corpus fetch + transform
first.

#### The sweep run for this bead

Because the checker cannot reach the SCION half or the `optional/` half without
a fetch, the sweep here was run directly against the **checked-in** corpus,
which is what actually ships in the repo: 277 generated `_test.exs` files with
the SCXML embedded in heredocs, plus the internal tests.

Method, all read-only, nothing in this repo modified:

1. A Ruby extractor pulled every `cond|expr|eventexpr|targetexpr|typeexpr|
   delayexpr|sendidexpr|srcexpr|array|location|item|idlocation` attribute value
   out of every file under `test/scion_tests`, `test/scxml_tests`,
   `test/corpus`, `test/fixtures`, `test/statifier`, `test/support` and
   `test/mix`, with file and line. **1224 values across 212 files.**
2. XML entities (`&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`) were decoded, since
   the values live inside XML in heredocs.
3. Two throwaway mix projects were built in the scratchpad, one pinned
   `{:predicator, "== 4.0.0"}` and one `{:predicator, "~> 5.0"}` (resolved to
   5.0.0 from hex), and every value was run through `Predicator.compile/1`
   (expressions) or `Predicator.context_location/2` (locations) under each.

**Result: 1224 checked, 8 failures under 5.0.0, and byte-identical 8 failures
under 4.0.0.**

| File:line | Kind | Value | Judgement |
|---|---|---|---|
| [`test/scion_tests/assign/assign_invalid_test.exs:38`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scion_tests/assign/assign_invalid_test.exs#L38) | expression | `{p1: 'v1'` | Not a break. Deliberately malformed - the test's whole point is an invalid `expr`. Fails identically on 4.0. |
| [`test/scion_tests/data/data_invalid_test.exs:24`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scion_tests/data/data_invalid_test.exs#L24) | expression | `{p1: 'v1'` | Same. |
| [`test/scxml_tests/mandatory/foreach/test152_test.exs:45`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scxml_tests/mandatory/foreach/test152_test.exs#L45) | location | `'continue'` | Not a break. This is the one entry already on `check_exprs.exs`'s allowlist (`conf:illegalItem`). Fails identically on 4.0. |
| [`test/corpus/check_exprs_test.exs:34`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/corpus/check_exprs_test.exs#L34) | location | `42` | Not a break. A hand-written fixture inside the checker's own test, asserting that an invalid location is reported. |
| [`test/corpus/check_exprs_test.exs:48`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/corpus/check_exprs_test.exs#L48) | location | `42` | Same. |
| [`test/statifier/machine/transition_test.exs:310`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/statifier/machine/transition_test.exs#L310) | expression | `score >` | Not a break. Negative fixture for compile-error diagnostics. |
| [`test/statifier/machine/transition_test.exs:313`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/statifier/machine/transition_test.exs#L313) | expression | `1 +` | Same. |
| [`test/statifier/compiler/acceptance_test.exs:179`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/statifier/compiler/acceptance_test.exs#L179) | expression | `1 >` | Same. |

**Zero of the 8 involve a reserved word, and zero are new in 5.0.**

Textual cross-check on the same corpus, independently:

- A regex for `\b(if|else|while|undefined)\b` over all 1224 extracted attribute
  values: **0 hits**. This shape catches all three rejection positions at once -
  a bare identifier, `foo.if`, and `{if: 1}`.
- `else` appears 14 times in the corpus and every occurrence is the SCXML
  `<else/>` **element**, not an expression (`test/scion_tests/if_else/test0_test.exs`,
  [`test/scxml_tests/mandatory/if/test147_test.exs:35`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scxml_tests/mandatory/if/test147_test.exs#L35),
  [`test/scxml_tests/mandatory/if/test148_test.exs:35`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scxml_tests/mandatory/if/test148_test.exs#L35),
  [`test/scxml_tests/mandatory/foreach/test153_test.exs:35`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scxml_tests/mandatory/foreach/test153_test.exs#L35),
  [`test/scxml_tests/mandatory/system_variables/test319_test.exs:24`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scxml_tests/mandatory/system_variables/test319_test.exs#L24)) or English
  prose in a comment or `description`.
- `while` appears once, in an English `description` string
  ([`test/scxml_tests/mandatory/invoke/test232_test.exs:62`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scxml_tests/mandatory/invoke/test232_test.exs#L62)).
- `undefined` appears **zero** times anywhere in `test/scion_tests` or
  `test/scxml_tests`.
- Variable-name surfaces were checked separately, since a `<data id="if">` would
  create a binding named `if`: every `<data id>` in the corpus is one of `Var1`
  ... `Var5`, `x`, `i`, `o1`, `foo`, `bar`, `bat`, `sum`, `myItem`, `myIndex`,
  `myArray`, `indexSum`, `httpid`. Every `<foreach index>` is `myIndex`, `Var2`,
  `Var3` or `Var5`. No reserved word.
- There is **no `<script>` element anywhere in the checked-in corpus** (the
  script family is excluded wholesale), so there are no statement bodies to
  sweep.

#### Exactly where 5.0 rejects a reserved word

Probed directly against predicator 5.0.0 and 4.0.0, so the sweep's negative
result can be trusted to be looking at the right thing:

| Shape | 4.0.0 | 5.0.0 |
|---|---|---|
| `if` (bare) | `{:ok, _}` | error: "'if' is a statement keyword, not an expression - control flow is only valid in a program (Predicator.parse_program/2)." |
| `foo.if` | `{:ok, _}` | error: "Expected property name after '.' but found 'if'" |
| `{if: 1}` | `{:ok, _}` | error: "Expected identifier or string for object key but found 'if'" |
| same three for `else`, `while` | `{:ok, _}` | same three errors |
| `undefined` (bare) | `{:ok, _}` (a variable load) | `{:ok, _}` (a **literal**, meaning changed silently) |
| `foo.undefined`, `{undefined: 1}` | `{:ok, _}` | parse errors, same two messages |

Upstream sources: the keyword table is `classify_identifier/1` at
`~/repos/github/predicator-ex/lib/predicator/lexer.ex:498-520`; the four new
entries are `undefined` (`:501`), `if` (`:512`), `else` (`:513`), `while`
(`:514`). Only the lowercase spelling is reserved - `IF`, `Else`, `UNDEFINED`
stay ordinary identifiers. The three rejection points are
`~/repos/github/predicator-ex/lib/predicator/parser.ex:1442-1446` (expression
position), `:1285` (property name after `.`) and `:1780` (bare object key). The
documented migration for an object key is to quote it: `{"if": 1}` still parses.
Upstream's own coverage is `~/repos/github/predicator-ex/test/predicator/reserved_words_test.exs`.

The `undefined` row is the one that is not a parse error and therefore not
caught by a compile-only sweep. In 5.0 a bare `undefined` in an expression stops
being a variable load and becomes the literal `:undefined`. Nothing in this
corpus writes it, so nothing changes here - but a compile sweep would not have
found it if something did.

#### What the sweep does not cover

Stated so the plan stage does not over-read the clean result:

- **Excluded tests are not in the checked-in corpus at all**, so a reserved word
  hiding in one is invisible to this sweep. The excluded set is 14 W3C tests
  (`tools/corpus/scxml_w3/exclusions.exs`: `test302`/`303`/`304` `:needs_script`,
  eleven `:needs_basichttp`) and five SCION entries
  (`tools/corpus/scion/exclusions.exs`: `w3c-ecma`, `script`, `script-src`,
  `error`, `assign-current-small-step/test0`). All are already out for other
  reasons.
- **`conf_predicator.xsl` was not compiled**, only read. It emits `==`/`===` and
  routes absent-ness through `_statifier_unbound`
  ([`tools/corpus/scxml_w3/conf_predicator.xsl:5-9`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/tools/corpus/scxml_w3/conf_predicator.xsl#L5-L9), `:448`, `:477-517`); it does
  not emit any of the four words. But the generated corpus is the checked-in
  corpus, and that is what was compiled, so the XSL is covered transitively for
  everything currently emitted.
- **The optional W3C half and all of SCION are outside `mise run corpus:check`**,
  which is why the sweep was run this way rather than through the existing tool.
  A plan that wants a standing guard rather than a one-off would be extending
  `check_exprs.exs` to cover them - that is a real gap, not a finding about 5.0.
- Two bare `=` remain in the corpus and are benign: string literals in
  [`test/scion_tests/misc/deep_initial_test.exs:21`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/test/scion_tests/misc/deep_initial_test.exs#L21) and `:28`
  (`expr="'onentry s1 _sessionid=' + _sessionid"`).

### 5. What the bump unlocks elsewhere

Recorded so the plan stage can see the shape, **not scoped into st-p3t**.

- **st-unt** (boundness sentinel vs `on_unbound: :error`, `p1`, open): 5.0 adds
  the `undefined` literal that upstream px-ocp asked for, which is that bead's
  option 3. Verified against 5.0.0 with a context shaped like `context/1`'s:
  `_event.data === undefined` -> `{:ok, true}`; `_event.data == undefined` ->
  `{:ok, :undefined}` (non-strict propagates, so the XSL must emit `===`);
  `nosuch === undefined` -> `{:error, %UndefinedVariableError{}}`, because the
  root `load` fails before the comparison runs under `on_unbound: :error`. The
  corpus sentinel is property-shaped against a seeded-bound `_event`, so the
  literal form works under ADR-0014 item 5 as-is. Taking it means an XSL edit, a
  corpus regeneration and a ratchet update, which is st-unt's work, not this
  bead's.
- **st-t3f** (script-body converter, `p3`, open): 5.0's `if`/`else`/`while`
  statements parse, compile (ISA v5 `jump`/`pop_jump_if_falsy`, ISA v6
  `jump_backward`), execute and round-trip through `decompile/2`, with `while`
  bounded by a `:loop_budget` (default 10,000, exhaustion is an
  `EvaluationError` with `reason: "loop_budget_exceeded"`, never a hang). That
  widens the converter's statement-form targets from assignment/increment
  sequences to bodies with control flow. The `<assign>`-sequence path cannot
  express those, so such a body becomes statement-form-only.
- **st-sdh** (context rebuild vs `bind/3`, `p3`, open): see "The
  FunctionProvider seam" above. The upstream seam it was waiting on has landed;
  the bead stays deferred on its own terms until something evaluates in a hot
  path.
- Also new and not currently needed here: type casts (`::`, failure is
  `:undefined` rather than an error), and `Predicator.execute_value/1,2,3`.
  `Predicator.execute/3` ships the px-h66 three-element error tuple
  (`{:error, error, %Context{}}`), which st-t3f's 2026-08-11 note already
  records.

### 6. Removed in 5.0, and whether this repo used it

`Evaluator.merge_functions/1` and `all_functions/0` on the four builtin function
modules were removed. **Neither appears anywhere in this repo** - the only
predicator entry points used are listed in section 1.

## Code References

- [`mix.exs:41`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/mix.exs#L41) - `{:predicator, "~> 4.0"}`, the pin to change
- `mix.lock` - locked at `predicator 4.0.0`
- [`lib/statifier/evaluator.ex:88-94`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L88-L94) - `context/1`, the single `Context.new/2` call site
- [`lib/statifier/evaluator.ex:112-124`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L112-L124) - `evaluate/2`, unaffected by 5.0
- [`lib/statifier/evaluator.ex:133-142`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L133-L142) - `in_function/1` and the `@spec` that must change
- [`lib/statifier/evaluator.ex:37-63`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L37-L63) - the "not a `MachineState` field" argument, written from the closure's existence
- [`lib/statifier/evaluator.ex:83-86`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L83-L86) - the position-snapshot note, also written from the closure
- [`lib/statifier/interpreter/content.ex:101-106`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/interpreter/content.ex#L101-L106) - the only production caller of `context/1`
- [`lib/statifier/interpreter/content.ex:42-52`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/interpreter/content.ex#L42-L52) - "The datamodel context, built once per block"
- [`lib/statifier/compiler/expressions.ex:63`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/compiler/expressions.ex#L63) - `Predicator.compile_with_spans/1`
- [`lib/statifier/compiler/expressions.ex:85`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/compiler/expressions.ex#L85) - failure-path `Predicator.parse/2`
- [`lib/statifier/machine.ex:82`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/machine.ex#L82) - the `expr()` sum type
- [`tools/corpus/scxml_w3/check_exprs.exs:15-16`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/tools/corpus/scxml_w3/check_exprs.exs#L15-L16) - the authoritative expression/location attribute lists
- [`tools/corpus/scxml_w3/check_exprs.exs:18-32`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/tools/corpus/scxml_w3/check_exprs.exs#L18-L32) - the one-entry allowlist and its stale-entry guard
- [`tools/corpus/scxml_w3/check_exprs.exs:100-138`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/tools/corpus/scxml_w3/check_exprs.exs#L100-L138) - `run/3`, the standing sweep
- `tools/corpus/scxml_w3/exclusions.exs` - 14 excluded W3C tests
- `tools/corpus/scion/exclusions.exs` - 5 excluded SCION entries
- [`docs/datamodel.md:3-4`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/datamodel.md#L3-L4) - the `~> 4.0` version string in prose, which drifts at the bump
- [`docs/datamodel.md:68-91`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/datamodel.md#L68-L91) - the upstream seam list, seams 1 and 3 both affected by 5.0
- `test/passing_tests.json` - the ratchet registry; shrinking it trips `mix gate.check` ([`lib/mix/statifier/gate_guard.ex:38`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/mix/statifier/gate_guard.ex#L38))

Upstream, at `~/repos/github/predicator-ex`:

- `CHANGELOG.md` - the 5.0.0 entry, four breaking items
- `lib/predicator/context.ex:58-69` - the `Context` types
- `lib/predicator/context.ex:79-94` - `new/2`'s option list
- `lib/predicator/context.ex:123-131` - `new/2`
- `lib/predicator/context.ex:150-162` - `resolve_functions/1`, the precedence order
- `lib/predicator/context.ex:234-237` - `bind/3`
- `lib/predicator/context.ex:250-251` - `put_host/2`
- `lib/predicator/functions/provider.ex:19-31` - the `FunctionProvider` behaviour
- `lib/predicator/evaluator.ex:1285-1320` - how a function is dispatched with `%Context{}`
- `lib/predicator/lexer.ex:498-520` - the complete keyword table
- `lib/predicator/parser.ex:1442-1446`, `:1285`, `:1780` - the three rejection points
- `lib/predicator.ex:235-247`, `:544-546` - options silently ignored when a `%Context{}` is passed
- [`README.md:65-110`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/README.md#L65-L110) - the `In/1`-as-a-provider recipe
- `docs/adr/0014-functions-are-provided-by-modules.md` - the reasoning, written about statifier
- `docs/guides/custom-functions.md:65-69` - the 5.0 function signature
- `test/predicator/reserved_words_test.exs` - upstream's own coverage of all three rejection points

## Architecture Documentation

- **ADR-0004** (predicator as the datamodel) is what makes a major predicator
  bump a first-class piece of work here rather than a dependency chore.
- **ADR-0014** (expression spans in cond diagnostics) governs the compile seam:
  item 1 requires `compile_with_spans/1`, item 2 forbids passing `:positions`
  alongside a `%Predicator.Compiled{}`, item 5 sets `on_unbound: :error` for
  `cond`. Nothing in 5.0 disturbs any of the three; the `undefined` literal
  interacts with item 5 in st-unt's favor rather than against it.
- **ADR-0012** (debuggability designed into the core) constraint 1 - any
  `%MachineState{}` is a complete, inspectable, resumable position - is the
  constraint the closure violates and a provider-plus-host context would not.
  It is the load-bearing argument on the `FunctionProvider` question and it
  belongs to this repo, not to upstream.
- **ADR-0003** (pure core with effects) and the errors-are-events rule are
  untouched: `evaluate/2` still returns `{:ok, _} | {:error, _}` and
  `lib/statifier/interpreter/content.ex` is still the only place that turns one
  into `error.execution`.
- **ADR-0011** (quality-gate config not agent-editable): `mix.exs` carries
  gate-relevant lines, so a plan should check whether changing the predicator
  dependency line trips `mix gate.check`'s `mix.exs` rule and therefore needs a
  human-written entry in `docs/quality-gate-changes.md`. The 4.0 bump
  (`e613a0e`) did **not** need one, which is evidence the dependency line is not
  in the guarded set - but it is worth re-confirming rather than assuming.

## Historical Context

- [`docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md:349-400`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md#L349-L400) -
  "Phase 1: Bumps the predicator pin to 4.0", the pre-flight-then-pin method
  this bump can copy, including the promotion of one grep to an automated phase
  criterion.
- [`docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md:163-166`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/plans/260809-st-wju.1-compile-document-to-interned-machine.md#L163-L166),
  `:980-990` - the "What We're NOT Doing" and "Corpus/Ratchet Notes" entries
  recording that the 4.0 bump regenerated nothing and touched
  `passing_tests.json` not at all.
- [`docs/research/260809-st-wju.1-compile-document-to-interned-machine.md:409-411`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/research/260809-st-wju.1-compile-document-to-interned-machine.md#L409-L411)
  - the sentence that framed `=` as a corpus sweep rather than a version bump;
  the 5.0 twin of that sentence is the reserved-word section above.
- Commit `86a2f82` - authored `conf_predicator.xsl` emitting `==`/`===`, which
  is why the 4.0 sweep found nothing.
- Commit `e613a0e` - the 4.0 bump itself: `mix.exs`, `mix.lock`,
  `docs/datamodel.md`, two docs. The smallest possible shape.
- Commit `5a1e1bc` "Un-excludes W3C test224 and test525" - the closest existing
  template for a commit that drops exclusions because an upstream feature
  landed, if the plan decides to fold any st-unt work in (it should not, but the
  template is worth knowing).
- st-sdh's 2026-08-12 note - the fullest existing statement of what the
  `FunctionProvider` seam buys, written before anyone had run 5.0.

## Related Research

- `docs/research/260809-st-wju.1-compile-document-to-interned-machine.md` - the
  4.0 bump's research, sections on `=` and on `%Predicator.Compiled{}`
- `docs/research/260803-st2-qjs-predicator-path-assign.md` - the path-assignment
  seam (predicator 3.6), the prior example of a seam landing upstream and being
  consumed here
- `docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md` - where
  `context/1` and the per-block interval were designed

## Open Questions

Recorded rather than asked, since no human was available during this research.

1. **The design record the bead names does not exist.** The bead points at
   `~/repos/github/predicator-ex/docs/design/2026-08-03-statifier-seams.md`. That
   file is not in the checkout, is not in `docs/design/` (which holds only
   `260806-px-35i.4-...`, `260806-px-l5s-...`, `260807-px-h66-...`), and
   `git log --all --diff-filter=A` shows it was never committed on any branch.
   Upstream records the same absence at
   `~/repos/github/predicator-ex/docs/plans/260804-px-8um.4-undefined-bound-check.md:67-69`.
   The substitutes used here are [`README.md:65-110`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/README.md#L65-L110) (the `In/1` recipe) and
   `docs/adr/0014-functions-are-provided-by-modules.md` (the reasoning). If the
   file exists somewhere else, it may say something these two do not.
2. **Does the `FunctionProvider` conversion belong in this bead?** Laid out in
   section 3 with evidence both ways and deliberately not decided. The bead's
   own acceptance criteria do not ask for it; the bead's description raises it
   as "consider going further". A plan needs to pick one, and if it picks
   "convert", it also needs to decide what happens to
   [`lib/statifier/evaluator.ex:37-63`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/lib/statifier/evaluator.ex#L37-L63), `:83-86` and [`docs/datamodel.md:69-73`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/datamodel.md#L69-L73),
   all three of which argue from the closure's existence.
3. **Does changing the predicator line in `mix.exs` trip `mix gate.check`?**
   The gate guard watches "a gate-relevant `mix.exs` line" and a trip needs a
   human-written ledger entry in `docs/quality-gate-changes.md` (which an agent
   may not write for itself, per ADR-0011). The 4.0 bump did not need one, which
   is good evidence, but it should be confirmed by running `mix gate.check`
   after the pin change rather than assumed.
4. **Should `check_exprs.exs` grow to cover `optional/` and SCION?** The sweep
   above had to be run outside the tool because the tool covers mandatory W3C
   only, against a gitignored tree. That is a standing gap in what the project
   checks, independent of 5.0. It is a candidate bead, not work for st-p3t.
5. **[`docs/datamodel.md:3-4`](https://github.com/riddler/statifier-ex/blob/3780e1b62384876451104485a80d62b82f429ef0/docs/datamodel.md#L3-L4) hardcodes `~> 4.0` in prose.** The 4.0 bump commit
   fixed the equivalent drift in the same commit as the pin. Whether to do the
   same here, or whether more of `docs/datamodel.md`'s seam list (seams 1 and 3
   both moved) should be updated in this bead or a follow-up, is a plan-stage
   call.
6. **The "not serializable" claim is stronger than what was observed.** See
   section 3: a closure-bearing context did round-trip `term_to_binary` in-node.
   The accurate claim is that a local fun reference does not survive a node
   boundary, a code reload, or a write-and-read-later. Any plan or moduledoc
   text that relies on the strong form should be written to the narrow one.
