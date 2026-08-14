---
date: 2026-08-14T13:05:47-0600
researcher: Claude
git_commit: 0f943a09002c21672e13b742f0c03e3b9981a13d
branch: st-sdh-context-rebuild-benchmark
repository: statifier-ex
beads_issue: st-sdh
topic: "Where predicator contexts are built and rebuilt today, and what a bind/3-vs-rebuild benchmark would have to measure"
tags: [research, codebase, datamodel, evaluator, predicator, performance]
status: complete
last_updated: 2026-08-14
last_updated_by: Claude
---

# Research: context rebuild vs `bind/3`, as the codebase stands at st-cmq.4

## Research Question

st-sdh asks for a benchmark over a realistic datamodel and block count, and
then either a `bind/3`-threading change justified by it or a recorded decision
that rebuilding is fine. This document establishes the ground the benchmark
would stand on: every site that builds a predicator context and how often it
runs, what the installed predicator actually offers, what the moduledoc and
`docs/datamodel.md` constrain, and what infrastructure exists for running a
benchmark at all.

## Summary

**One constructor, eleven live call sites.** `Statifier.Evaluator.context/1`
([`lib/statifier/evaluator.ex:108-113`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L108-L113)) is the only function that builds a
`%Predicator.Context{}` over live machine data. Every other site calls it.
`Predicator.Context.bind/3` and `Predicator.Context.put_host/2` are called
nowhere in `lib/`.

**The rebuild is two costs, not one.** `Predicator.Context.new/2`
([`deps/predicator/lib/predicator/context.ex:128-136`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator/context.ex#L128-L136)) pays
`normalize_value/1`, an O(total nodes in the datamodel) deep rebuild, **plus**
`resolve_functions/1`, which re-resolves and re-validates the four builtin
function providers on every call with `Code.ensure_loaded?/1` and a
`function_exported?/3` check per named function
(`context.ex:158-207`). That second cost is fixed and independent of datamodel
size. On top of both, `Statifier.Evaluator.context/1` runs its own
`undefine_nils/1` deep walk ([`lib/statifier/evaluator.ex:136-143`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L136-L143)) *before*
handing the map to `new/2` - so the datamodel is walked twice per build. A
benchmark that varies only datamodel size will not separate these three terms;
it needs to vary datamodel size and block count independently.

**Threading is already the default; rebuild-on-write is the exception.**
Within any one evaluation site - a selection round, a content block, a
`<datamodel>` binding pass, a `<param>` fold - one context is built and
threaded unchanged. `Statifier.ExecutableContent.Context` already carries the
built context in its `datamodel_context` field
([`lib/statifier/executable_content/context.ex:64`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/executable_content/context.ex#L64)). Only three nodes rebuild:
`<assign>` (once per assign), `<script>` (twice per script), and `<foreach>`
(once before the loop plus once per iteration). `<foreach>` is the one
construct whose cost is multiplicative.

**The upstream seam is fully available and unused.** predicator is pinned at
`~> 7.0` / 7.0.0 ([`mix.exs:41`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.exs#L41), [`mix.lock:19`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.lock#L19)) - not 5.0 as the bead's note
says, though px-8ii's seam landed in 5.0 and survives unchanged in 7.0.
`put_host/2` is a literal one-line struct update (`context.ex:257`), `bind/3`
is `Map.put` plus normalizing the bound value only (`context.ex:241-243`), and
the `functions:` closure map this repo uses today is still supported and
dispatches identically to a provider entry.

**No benchmarking infrastructure exists.** No `bench/` directory, no benchee,
no bench task in `mise.toml`, and no mention of any benchmarking tool anywhere
in `docs/`. predicator ships none either. A new `bench/` directory would be
invisible to every gate stage, and a plain dev-only dep would not trip the gate
guard - but a `mix bench` alias would.

## Detailed Findings

### 1. Every context build site, and how often it runs

`Statifier.Evaluator.context/1` ([`lib/statifier/evaluator.ex:108-113`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L108-L113)) is the
sole constructor over live data:

```elixir
Predicator.Context.new(undefine_nils(machine_state.datamodel),
  functions: %{"In" => {1, in_function(machine_state)}},
  on_unbound: :error
)
```

Two `Predicator.Context.new/2` calls exist outside it, both throwaway empty
compile-time contexts unrelated to the datamodel:
[`lib/statifier/compiler/expressions.ex:141`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/compiler/expressions.ex#L141) and [`lib/statifier/event_data.ex:73`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/event_data.ex#L73).

| Site | `file:line` | Frequency |
|---|---|---|
| `Interpreter.Datamodel.initialize/1` | [`lib/statifier/interpreter/datamodel.ex:133`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/datamodel.ex#L133) | Once per session, for the whole binding pass |
| `Interpreter.Datamodel.bind_state_data/4` | [`lib/statifier/interpreter/datamodel.ex:292`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/datamodel.ex#L292) | Once per late-bound non-root state's first entry, for that state's whole `data` list |
| `Selection.condition_match/2` | [`lib/statifier/interpreter/selection.ex:285`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/selection.ex#L285) | Once per call - the standalone spec-named entry point, kept callable from a machine_state alone per `docs/observability.md` constraint 5 |
| `Selection.select_transitions/2` | [`lib/statifier/interpreter/selection.ex:332`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/selection.ex#L332) | **Once per selection round**, threaded through every atomic state x every transition candidate |
| `Selection.select_eventless_transitions/1` | [`lib/statifier/interpreter/selection.ex:364`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/selection.ex#L364) | **Once per selection round**, same threading |
| `Interpreter.Content.execute_block/3` | [`lib/statifier/interpreter/content.ex:144`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/content.ex#L144) | **Once per non-empty executable-content block** - an empty block short-circuits and builds nothing (`content.ex:135-138`) |
| `ExitEntry.evaluate_donedata/3` | [`lib/statifier/interpreter/exit_entry.ex:959`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/exit_entry.ex#L959) | Once per `done.state.*` raise |
| `ExitEntry.evaluate_donedata_params/3` | [`lib/statifier/interpreter/exit_entry.ex:992`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/exit_entry.ex#L992) | Once per `<donedata>` `<param>` fold, not per param |
| `Machine.Content.Assign.execute/2` | [`lib/statifier/machine/content/assign.ex:88`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/assign.ex#L88) | **Once per `<assign>` execution**, after the write |
| `Machine.Content.Script.rebind/2` | [`lib/statifier/machine/content/script.ex:101`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/script.ex#L101) | Once per `<script>`, plus a second build inside `Evaluator.execute/2` |
| `Machine.Content.Foreach.rebuild/2` | [`lib/statifier/machine/content/foreach.ex:283`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/foreach.ex#L283) | **Once pre-loop plus once per iteration** |
| `Evaluator.execute/2` | [`lib/statifier/evaluator.ex:252`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L252) | Once per program run - `<script>` nodes and each top-level `<script>` ([`lib/statifier/interpreter.ex:354`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter.ex#L354)) |

Per microstep, the block-runner sites multiply: `execute_block/3` is called
once per exited state's `<onexit>` (`exit_entry.ex:242-253`), once per entered
state's `<onentry>` (`exit_entry.ex:668-681`), and once per fired transition's
inline content (`exit_entry.ex:732-742`).

`Statifier.Session` builds no context of its own. It calls
`Interpreter.initialize/2` ([`lib/statifier/session.ex:285`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/session.ex#L285)) once at startup and
`Interpreter.handle_event/2` ([`lib/statifier/session.ex:431`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/session.ex#L431)) once per dequeued
external event, which is why st-cmq.4 is the dependency that made this bead
constructible: it is the first thing that drives the core in a loop.

### 2. What `<assign>`, `<script>` and `<foreach>` actually do

`<assign>` ([`lib/statifier/machine/content/assign.ex:76-91`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/assign.ex#L76-L91)) reads against the
block's existing `context.datamodel_context` for both `evaluate_value/2` and
`resolve_location/2`, writes into the raw `machine_state.datamodel`, then
rebuilds:

```elixir
{:ok,
 %{
   context
   | machine_state: machine_state,
     datamodel_context: Evaluator.context(machine_state)
 }, []}
```

So a block of *n* `<assign>` nodes normalizes the whole datamodel *n* times
plus once for the block. This is exactly the shape `bind/3` would replace: the
write is a single root, and `bind/3` is O(size of the written value) rather
than O(size of the datamodel).

`<script>` ([`lib/statifier/machine/content/script.ex:95-103`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/script.ex#L95-L103)) costs two builds
per node - one inside `Evaluator.execute/2` to run the program, one in
`rebind/2` to refresh the block snapshot. Note that `Predicator.execute/3`
already returns a `%Context{}` whose `functions`/`host`/`on_unbound` survived
the run ([`deps/predicator/lib/predicator.ex:559`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator.ex#L559)), so the post-run context
already exists and is discarded in favour of a fresh build.

`<foreach>` ([`lib/statifier/machine/content/foreach.ex:276-285`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/foreach.ex#L276-L285)) is the
multiplicative case: `declare/2` rebuilds once before the loop, and
`write_iteration/4` rebuilds once per element. An N-element `<foreach>` costs
at minimum N+1 builds before counting any nested `<assign>` in the body. Each
iteration writes only `item` and (optionally) `index` - two single-root writes,
the canonical `bind/3` shape.

`<if>` (`lib/statifier/machine/content/if.ex`), `<log>`, and `<raise>` never
rebuild. `<send>` is not implemented.

### 3. What `Statifier.Evaluator`'s moduledoc constrains

The section "Why the built context is not a `MachineState` field"
([`lib/statifier/evaluator.ex:37-72`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L37-L72)) rules out caching on two grounds of
explicitly different weight:

- **Ground 1, the resumability ground**: `context/1` puts a closure in
  `functions`, and "a struct carrying one does not survive a node boundary, a
  code reload, or being written to disk and read back later, and it cannot be
  meaningfully diffed" - `docs/observability.md` constraint 1 (ADR-0012)
  commits to any `%MachineState{}` being a complete, inspectable, resumable
  position. The moduledoc itself states this ground "is contingent on the
  closure: taking the px-8ii seam below (a `FunctionProvider` bound by name
  instead of a captured fun) would dissolve it."
- **Ground 2, the staleness ground**: the closure captures the configuration,
  which moves at every microstep. The moduledoc says this ground "is structural
  and survives the px-8ii seam entirely: whatever builds `functions`, a stored
  context still answers against a configuration the machine has moved past."

**What this constrains for st-sdh.** Ground 1 is dissolvable and the moduledoc
says so. Ground 2 as written is about a context stored *and not refreshed*;
`put_host/2` is precisely an O(1) refresh of the term a provider-based `In/1`
would read the configuration from. A change that stores a context on
`MachineState` would have to rewrite both bullets, and `docs/datamodel.md` seam
1 with them. The moduledoc also already names st-sdh by ID at
[`lib/statifier/evaluator.ex:68`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L68) - note ADR-0018 forbids bead IDs in new
comments, so that existing line is prior art, not a licence to add more.

The position-snapshot `@doc` on `context/1` itself
([`lib/statifier/evaluator.ex:96-106`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L96-L106)) makes the same commitment at the call
site: "callers rebuild per evaluation site rather than caching across one."

### 4. `docs/datamodel.md` upstream seam 1

Quoted in full ([`docs/datamodel.md:120-132`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/datamodel.md#L120-L132)):

> 1. **Persistent bound context**: build a context once (data + host functions
>    like `In/1`), evaluate many expressions against it, rebind cheaply when
>    data changes. v1 rebuilt the full context map per expression.
>    `Predicator.Context.bind/3` is the cheap-rebind path that would let the
>    once-per-block interval above widen again, once a caller needs to. Landed
>    in predicator 5.0.0: `Predicator.FunctionProvider` (a module supplying
>    named functions), `Context.new/2`'s `providers:` and `host:` options, and
>    `Context.put_host/2` (an O(1) `%{context | host: host}` refresh). Not
>    taken here yet: `In/1` is still an inline `functions:` closure, which 5.0
>    still supports and dispatches identically to a provider entry. Taking this
>    seam is st-sdh's call, deferred until something evaluates in a hot path
>    worth benchmarking.

The evaluation-contract section ([`docs/datamodel.md:54-59`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/datamodel.md#L54-L59)) states the
commitment the seam would widen: "built once per evaluation site (once per
executable-content block today), never once per expression, and never scoped to
a whole macrostep."

### 5. What predicator 7.0.0 actually offers

Pinned at `{:predicator, "~> 7.0"}` ([`mix.exs:41`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.exs#L41)), locked at 7.0.0
([`mix.lock:19`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.lock#L19)). The bead's note says predicator 5.0; the seam it names is the
same one, unchanged through 7.0.

`Context.new/2` ([`deps/predicator/lib/predicator/context.ex:128-136`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator/context.ex#L128-L136)):

```elixir
@spec new(Types.context(), keyword()) :: t()
def new(data \\ %{}, opts \\ []) when is_map(data) do
  %__MODULE__{
    data: normalize_value(data),
    functions: resolve_functions(opts),
    on_unbound: validate_on_unbound!(Keyword.get(opts, :on_unbound, :undefined)),
    host: Keyword.get(opts, :host)
  }
end
```

Options: `:builtins` (default `true`), `:providers`, `:functions`,
`:on_unbound`, `:host`. `normalize_value/1` (`context.ex:335-344`) recurses
through maps and lists; structs pass through; `nil` is preserved (changed in
6.0 - see below). `resolve_functions/1` (`context.ex:158-167`) resolves the
four builtin providers plus `:providers` and merges `:functions` last, via
`validated_entries!/1` (`context.ex:188-207`) which does `Code.ensure_loaded?/1`
per module and `function_exported?/3` per named function - **on every
`Context.new/2` call**.

`Context.bind/3` (`context.ex:240-243`):

```elixir
@spec bind(t(), binary(), Types.value()) :: t()
def bind(%__MODULE__{data: data} = context, name, value) when is_binary(name) do
  %{context | data: Map.put(data, name, normalize_value(value))}
end
```

Its `@doc` (`context.ex:218-228`) states the complexity claim directly: "O(1):
a single `Map.put/3`, plus normalizing `value` itself (O(size of `value`), not
O(size of `data`) - `data` is already normalized from construction or a prior
`bind/3`)"; and "`functions`, `on_unbound`, and `host` are carried over
unchanged."

`Context.put_host/2` (`context.ex:256-257`):

```elixir
@spec put_host(t(), term()) :: t()
def put_host(%__MODULE__{} = context, host), do: %{context | host: host}
```

"Replaces `context`'s `host` term, leaving `data`, `functions`, and
`on_unbound` untouched. The new `host` is stored exactly as given - no
normalization" (`context.ex:245-248`).

Other mutation API: `assign/3` (`context.ex:313-318`), which writes through
`ContextLocation.put/3` at a path and, unlike `bind/3`, does **not** normalize
the value. There is no `unbind`, `merge`, `put_data`, or `put_functions`.

`Predicator.FunctionProvider` lives at
`deps/predicator/lib/predicator/functions/provider.ex` - note the module name
and the path differ. One callback, `@callback functions() :: %{name() =>
entry()}` (`provider.ex:31`), where an entry is `{arity, atom}` naming a
public function on the same module with signature `(args, context)`.
`builtin_providers/0` (`provider.ex:43-51`) returns the four builtin modules.
Resolution to `{arity, {module, atom}}` happens once at construction; at
evaluation time `Predicator.Evaluator.dispatch/3`
([`deps/predicator/lib/predicator/evaluator.ex:1319-1325`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator/evaluator.ex#L1319-L1325)) does `apply/3` for a
provider pair and `fun.(args, context)` for a closure - **the same dispatch for
both**, which is what `docs/datamodel.md` seam 1 means by "dispatches
identically."

The `functions:` closure map is still fully supported in 7.0
(`context.ex:88-91`, merged last at `context.ex:166`), so nothing forces a
conversion.

One evaluation-path fact a benchmark must not trip over: passing a **bare map**
to `Predicator.evaluate/3` re-runs the whole `Context.new/2` cost on every call
([`deps/predicator/lib/predicator.ex:265-267`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator.ex#L265-L267)), while passing a prebuilt
`%Context{}` does not. This repo always passes a prebuilt context
([`lib/statifier/evaluator.ex:169`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L169)). Relatedly, when a `%Context{}` is passed,
`:functions`, `:providers`, `:builtins`, `:host` and `:on_unbound` in `opts`
are silently ignored - they come from the struct
([`deps/predicator/lib/predicator.ex:236-247`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator.ex#L236-L247)).

CHANGELOG context: 5.0.0 shipped the px-8ii seam
([`deps/predicator/CHANGELOG.md:247-265`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/CHANGELOG.md#L247-L265)) and made every custom function's
second argument the `%Context{}` struct (`:269-281`). 6.0.0 stopped rewriting a
bound `nil` to `:undefined` (`:78-87`) - which is why
`Statifier.Evaluator.undefine_nils/1` exists at all
([`lib/statifier/evaluator.ex:115-143`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L115-L143)), reproducing predicator 5.x's
normalization statifier-side. 7.0.0 touches only `Math.pow`/`Math.sqrt`
(`:8-28`); nothing in Context changed.

### 6. How `In/1` is wired today

Via the **older closure-capture approach**, not the providers/host seam:
`functions: %{"In" => {1, in_function(machine_state)}}`
([`lib/statifier/evaluator.ex:110`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L110)), with `in_function/1`
([`lib/statifier/evaluator.ex:304-313`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L304-L313)) returning a fresh closure per call that
captures `machine_state.machine` and `machine_state.configuration`.

What that means for how much must be rebuilt when configuration moves: today,
**everything** - a moved configuration means a new closure, and the only way
this codebase builds a `functions` map is through `Context.new/2`, which
re-normalizes the whole datamodel and re-resolves the builtin providers on the
way. Under the provider seam the answer would be `put_host/2`, one struct
update, with `data` and `functions` untouched. `host` is stored without
normalization (`context.ex:102-103`), so a `machine` plus a `configuration`
MapSet can go in as-is.

The upstream recipe is written against this exact use case; predicator's own
ADR-0014 (`docs/adr/0014-functions-are-provided-by-modules.md` in that repo)
was written about statifier by name, per
[`docs/research/260812-st-p3t-predicator-5-bump.md:198-199`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/research/260812-st-p3t-predicator-5-bump.md#L198-L199).

### 7. Benchmarking infrastructure

**None exists.** Confirmed:

- No `bench/` directory.
- [`mix.exs:39-57`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.exs#L39-L57) deps are `predicator`, `saxy`, `uxid`, and the dev/test set
  `ex_quality`, `credo`, `dialyxir`, `excoveralls`, `sobelow`, `ex_doc`,
  `doctor`. No benchee, no benchfella.
- `mise.toml` tasks are corpus and spec-fetch stages only; no bench task.
- No mention of benchee, profiling, `:timer.tc`, `:eprof` or `:fprof` anywhere
  in `lib/`, `test/`, `tools/` or `docs/`.
- predicator ships no benchmarks either, so there is no upstream model to copy.

**How `mix quality` would treat a new top-level `bench/` directory: it would
not see it at all.**

- `.formatter.exs` inputs are `["{mix,.formatter}.exs",
  "{config,lib,test,tools}/**/*.{ex,exs}"]` - `bench/` is absent, so the Format
  stage would neither check nor format it.
- `.credo.exs` `included` is `["lib/", "src/", "test/", "web/", "apps/*/..."]`
  (`.credo.exs:38-47`) - `bench/` is absent.
- `elixirc_paths` is `["lib"]`, or `["lib", "test/support"]` under `:test`
  ([`mix.exs:36-37`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.exs#L36-L37)), so Compile, Dialyzer and Doctor never analyze `bench/`.
- `coveralls.json` measures compiled modules against a 90% minimum; a directory
  outside `elixirc_paths` does not enter the calculation.
- `.doctor.exs` holds 100% thresholds on every axis with empty `ignore_paths`,
  but only over compiled modules - so an uncompiled `bench/*.exs` script owes
  no `@moduledoc` or `@spec`.

That invisibility cuts both ways and is worth recording as a fact rather than a
verdict: a `bench/` script would be unformatted, unlinted, and untyped by the
gate.

**How the gate guard would treat a `mix.exs` edit.** `mix gate.check` matches
`mix.exs` by **line content, not path**
([`lib/mix/statifier/gate_guard.ex:40-43`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/mix/statifier/gate_guard.ex#L40-L43)):

```elixir
# `mix.exs` is matched by line content rather than by path: most edits to it
# (a dep bump, an unrelated alias) have nothing to do with the gate, and a
# path-level guard would make every dependency change need a ledger entry.
@mix_exs_pattern ~r/test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir|:sobelow|:doctor/
```

So:

- Adding `{:benchee, "~> 1.3", only: :dev, runtime: false}` to `deps/0` matches
  none of those alternatives - **no ledger entry required**. This is consistent
  with the empirical note in
  [`docs/research/260812-st-p3t-predicator-5-bump.md:567-572`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/research/260812-st-p3t-predicator-5-bump.md#L567-L572) that the
  predicator 4.0 bump changed the pin and needed no entry.
- **But placement matters.** The pattern is applied over both added and removed
  diff lines (`gate_guard.ex:187-195`, with `text/1` at `:304-305` covering
  `{:added, _}` and `{:removed, _}`). The deps list ends at [`mix.exs:55`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.exs#L55) with
  `{:doctor, "~> 0.23", only: :dev, runtime: false}` and no trailing comma, so
  *appending* a dep after it rewrites that line to add one - producing a
  `-`/`+` pair matching `:doctor`, and a ledger entry requirement, for what is
  really punctuation. Inserting the dep so that the `:doctor`, `:sobelow`,
  `:credo`, `:excoveralls`, `:dialyxir` and `:ex_quality` lines stay untouched
  avoids it.
- Adding an `aliases:` key to `project/0` to give the benchmark a `mix bench`
  entry point **would** match (`aliases`) and **would** require a
  `docs/quality-gate-changes.md` entry with an `Approved-by:` line - which per
  ADR-0011 and that file's own preamble ([`docs/quality-gate-changes.md:1-14`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/quality-gate-changes.md#L1-L14))
  is a human's call to write, not an agent's. `project/0` has no `aliases:` key
  today ([`mix.exs:8-27`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/mix.exs#L8-L27)).

The Dependencies stage runs `mix deps.unlock --check-unused`
([`deps/ex_quality/lib/ex_quality/stages/dependencies.ex:104-112`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/ex_quality/lib/ex_quality/stages/dependencies.ex#L104-L112)), which
detects lock entries **not declared in `mix.exs`** - the reverse direction. A
declared-but-only-used-from-`bench/` dep is declared, so it does not trip that
check, and nothing else checks whether `lib/` actually uses a dep. There is no
`mix_audit` dep, so the security-audit half of that stage is skipped.

The guard's untracked-file scan is also scoped (`gate_guard.ex:140-142`):

```elixir
defp interesting?(path) do
  path in [@ledger_path, "mix.exs" | @guarded_paths] or String.starts_with?(path, "test/")
end
```

so untracked files under `bench/` are invisible to it.

### 8. Prior art in this repo's own documents

`docs/research/260812-st-p3t-predicator-5-bump.md` section 3 (lines 157-298) is
the fullest existing treatment of the seam and reaches these conclusions
without deciding the question:

- The conversion alone realizes no win: "`execute_block/3` still calls
  `Evaluator.context(machine_state)` once per block ... Getting the O(1)
  refresh means also finding a place to *store* the context between blocks -
  which is the `MachineState`-field question" (lines 265-274).
- **A correction worth carrying forward** (lines 228-237): a context carrying a
  closure *did* survive `:erlang.term_to_binary/1` round-trip in-node under a
  real probe. The true, narrower claim is that a local fun does not survive a
  node boundary, a code reload, or disk. "'not serializable' overstates it and
  a plan that leans on the strong claim should lean on the narrow one instead."
- Converting would make two moduledoc sections and `docs/datamodel.md` seam 1
  go stale (lines 275-282).

Every `st-af3.x` plan that touched evaluation deferred here explicitly:

- [`docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md:782-795`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md#L782-L795) -
  "at one build per executable-content block over corpus-sized datamodels this
  is not measurable, and correctness (a context that cannot be stale) is worth
  more than the allocation."
- [`docs/plans/260813-st-af3.4-assign-deep-path-vivification.md:768-780`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/plans/260813-st-af3.4-assign-deep-path-vivification.md#L768-L780) - "A
  block of *n* `<assign>` nodes therefore normalizes the datamodel *n* times
  rather than once."
- [`docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md:1005-1023`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md#L1005-L1023) -
  "`<foreach>` ... is the first construct in this engine whose cost is
  *multiplicative* rather than additive."

### 9. What a realistic workload looks like today

The bead asks for "a realistic datamodel and block count." The corpus is the
only realistic source, and it is small: 24 files under
`test/scxml_tests/mandatory/` and 28 under `test/scion_tests/`, with
corpus-sized datamodels of a handful of `<data>` roots. `cond` on transitions
is additionally not reachable from the corpus today -
[`lib/statifier/interpreter/selection.ex:277-280`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/selection.ex#L277-L280) records that `FeatureDetector`
marks `conditional_transitions` `:unsupported`, so no compiled corpus document
carries a `cond`-bearing transition through selection. A benchmark that wants
to exercise the selection-round rebuild has to build its documents by hand.

## Code References

- [`lib/statifier/evaluator.ex:37-72`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L37-L72) - "Why the built context is not a `MachineState` field"
- [`lib/statifier/evaluator.ex:108-113`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L108-L113) - the sole context constructor
- [`lib/statifier/evaluator.ex:136-143`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L136-L143) - `undefine_nils/1`, the statifier-side deep walk
- [`lib/statifier/evaluator.ex:248-279`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L248-L279) - `execute/2`, which builds its own context
- [`lib/statifier/evaluator.ex:304-313`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L304-L313) - `in_function/1`, the closure capture
- [`lib/statifier/executable_content/context.ex:64`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/executable_content/context.ex#L64) - `datamodel_context` field
- [`lib/statifier/interpreter/content.ex:140-162`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/content.ex#L140-L162) - one context per block
- [`lib/statifier/interpreter/selection.ex:332`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/selection.ex#L332) - one context per selection round
- [`lib/statifier/interpreter/selection.ex:364`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/selection.ex#L364) - the eventless twin
- [`lib/statifier/interpreter/datamodel.ex:124-137`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/interpreter/datamodel.ex#L124-L137) - one context for the whole binding pass, with the B.2.2 licence in the comment
- [`lib/statifier/machine/content/assign.ex:76-91`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/assign.ex#L76-L91) - rebuild per assign
- [`lib/statifier/machine/content/script.ex:95-103`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/script.ex#L95-L103) - rebuild per script
- [`lib/statifier/machine/content/foreach.ex:276-285`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/machine/content/foreach.ex#L276-L285) - rebuild per iteration
- [`lib/mix/statifier/gate_guard.ex:40-43`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/mix/statifier/gate_guard.ex#L40-L43) - the `mix.exs` content pattern
- [`deps/predicator/lib/predicator/context.ex:128-136`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator/context.ex#L128-L136) - `new/2`
- [`deps/predicator/lib/predicator/context.ex:240-243`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator/context.ex#L240-L243) - `bind/3`
- [`deps/predicator/lib/predicator/context.ex:256-257`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator/context.ex#L256-L257) - `put_host/2`
- [`deps/predicator/lib/predicator/context.ex:158-207`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/deps/predicator/lib/predicator/context.ex#L158-L207) - `resolve_functions/1` and per-call provider validation

## Architecture Documentation

- **ADR-0004** (predicator as the datamodel, accepted, amended in part by
  ADR-0026): gaps predicator has for SCXML use, "persistent bound contexts"
  named first among them, are upstreamed rather than papered over in statifier.
  This is what makes seam 1 a commitment rather than a note.
- **ADR-0012** (debuggability designed into the core, accepted): constraint 1's
  "any machine_state value is a complete, inspectable, resumable position"
  ([`docs/observability.md:26-49`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/observability.md#L26-L49)) is the load-bearing constraint on storing a
  context on `MachineState`, and the one a provider-plus-host context would
  satisfy where a closure does not.
- **ADR-0014** (expression spans): item 5 fixes `on_unbound: :error`, which is
  baked into the context at construction and is therefore part of whatever gets
  threaded or rebuilt.
- **ADR-0011** (quality-gate config not agent-editable): governs whether a
  `mix.exs` edit needs a ledger entry; see section 7.
- **ADR-0018** (no process jargon in code comments): a new comment must not
  name a bead ID. Existing ones ([`lib/statifier/evaluator.ex:68`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/lib/statifier/evaluator.ex#L68)) predate the
  guard's line-based check.
- **ADR-0026** (`<script>` as predicator statement programs): why
  `Evaluator.execute/2` exists and pays its own context build.

## Historical Context

- `docs/research/260812-st-p3t-predicator-5-bump.md` - the fullest prior
  treatment of the seam; deliberately undecided, with a for/against list and
  the serializability correction noted above.
- [`docs/plans/260812-st-p3t-predicator-5-bump.md:461-463`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/plans/260812-st-p3t-predicator-5-bump.md#L461-L463) - explicitly refused
  to rewrite the moduledoc's conclusion, because "rewriting it would pre-decide
  st-sdh."
- [`docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md:104-115`](https://github.com/riddler/statifier-ex/blob/0f943a09002c21672e13b742f0c03e3b9981a13d/docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md#L104-L115) - the
  amendment that replaced "once per macrostep" with "once per evaluation site",
  with a grep as a success criterion.

## Related Research

- `docs/research/260812-st-p3t-predicator-5-bump.md`
- `docs/research/260813-st-af3.4-assign-deep-path-vivification.md`
- `docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md`

## Open Questions

1. **What counts as "realistic" here, given the corpus is small and `cond` is
   unreachable from it?** The corpus datamodels are a handful of roots, and no
   corpus document exercises the per-selection-round rebuild at all. A
   benchmark can either measure the corpus as it is (and will likely find the
   cost unmeasurable, confirming every prior plan's prediction) or measure
   hand-built documents at a scale no corpus file reaches. Which of those
   answers the bead's acceptance criterion is a judgment call this document
   does not make. No human was available to ask.
2. **Does the benchmark need to separate the three cost terms?**
   `undefine_nils/1`, `normalize_value/1`, and per-call builtin-provider
   re-validation are three independent costs inside one call, and only the
   first two scale with datamodel size. A benchmark that varies only datamodel
   size cannot distinguish "rebuilding is fine" from "rebuilding is fine at
   this datamodel size and dominated by a fixed cost `bind/3` would also pay".
3. **Where would a stored context live, if the benchmark justifies threading?**
   The moduledoc's ground 2 is written against a context stored and not
   refreshed; `put_host/2` refreshes in O(1). Whether that dissolves ground 2
   or merely relocates it is the `MachineState`-field question
   `260812-st-p3t` left open, and it is a design decision, not a measurement.
4. **Does a `bench/` directory being invisible to every gate stage need
   addressing?** Recorded as a fact in section 7; whether it is acceptable for
   benchmark code to be unformatted and unlinted is a project-policy call.
5. **The bead's note says predicator 5.0; the pin is 7.0.0.** The seam is
   unchanged between them, so nothing is broken, but the note is out of date on
   its face.
