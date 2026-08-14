---
date: 2026-08-14T14:54:23-0600
researcher: Claude
git_commit: f1fe7e123dc6511a354e63f36157fa57b3b760d3
branch: st-l0t-provider-host-seam
repository: statifier-ex
beads_issue: st-l0t
topic: "What predicator 7.0.0's provider/host seam offers, and what adopting it for In/1 would touch"
tags: [research, codebase, datamodel, evaluator, predicator]
status: complete
last_updated: 2026-08-14
last_updated_by: Claude
---

# Research: predicator's provider/host seam, and what adopting it for `In/1` would touch

**Date**: 2026-08-14T14:54:23-0600
**Git Commit**: f1fe7e123dc6511a354e63f36157fa57b3b760d3
**Branch**: st-l0t-provider-host-seam
**Bead**: st-l0t

## Research Question

st-l0t asks to convert `Statifier.Evaluator`'s `In/1` from a captured closure
in `Predicator.Context`'s `functions` map into a `Predicator.FunctionProvider`
reading `context.host`, to refresh the configuration with
`Predicator.Context.put_host/2` instead of rebuilding the functions map, and
then to re-open the storage question the `Statifier.Evaluator` moduledoc's
"Why the built context is not a `MachineState` field" section settles today.

This document records the seam as it exists in the vendored predicator 7.0.0
source, every context-build site in `lib/` and how often each fires, what a
`host` value would have to be, what the moduledoc's two grounds now rest on,
which tests pin today's behavior, and where the acceptance criterion's
before/after benchmark evidence comes from. It documents; it does not decide.

## Summary

**The seam is real, is in the vendored 7.0.0 source, and behaves as the bead
describes - with three divergences worth writing down.**

1. The module is `Predicator.FunctionProvider`, but its file is
   `deps/predicator/lib/predicator/functions/provider.ex`, not the
   `function_provider.ex` path the bead's description implies. The bead was
   written against 5.0.0's layout.
2. `Predicator.Context.put_host/2` is exactly the literal struct update the
   bead cites, at exactly the cited lines
   ([`deps/predicator/lib/predicator/context.ex:256-257`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator/context.ex#L256-L257)). Measured here at
   **0.0478 μs / 0.0859 KB**, against `Evaluator.context/1`'s **2.54 μs /
   10.92 KB** at the `:corpus` size point - **~53x faster and ~127x lighter**.
3. **The provider seam does not make a context build cheaper.** Measured,
   `Context.resolve_functions/1` costs 1.46 μs / 5.80 KB with a provider and
   1.39 μs / 5.59 KB with today's inline closure - the same, within noise. The
   provider seam's whole contribution is that it makes a built context
   *refreshable in O(1)* and *closure-free*. Any speedup has to come from
   building fewer contexts, not from building each one faster. This is the
   single most load-bearing correction to the bead's framing.

A working provider was built and run against the real engine (probe script,
not committed): it answers `In('s1') => {:ok, true}`, `In('nope') => {:ok,
false}` identically to today's closure, and resolves to the entry
`{1, {ProbeProvider, :in_state}}` in a `functions` map otherwise identical to
the closure version's.

On the storage question: **ground 1 does dissolve, on the evidence.** With a
provider entry and a `host` of `{machine, configuration}`, a built context
contains no `function()` value anywhere - `functions` is entirely
`{module, atom}` pairs (verified for all 25 resolved entries, builtins
included), and `host` is a `%Statifier.Machine{}` plus a `MapSet` of integers,
both already required to be resumable because they already live on
`%MachineState{}`. **Ground 2 does not dissolve; it changes species.** It stops
being "a stored context is stale by construction" and becomes "a stored context
is stale unless every one of six datamodel write sites and every microstep
boundary refreshes it" - an exhaustiveness obligation rather than an
impossibility. Two of those six sites do not go through `Evaluator.bind/3`
today.

## Detailed Findings

### 1. The predicator 7.0.0 seam, verified against vendored source

Pinned version: [`deps/predicator/mix.exs:5`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/mix.exs#L5) is `@version "7.0.0"`; `mix.exs`
pins `~> 7.0`.

**`Predicator.FunctionProvider`** ([`deps/predicator/lib/predicator/functions/provider.ex:1-52`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator/functions/provider.ex#L1-L52)).
A behaviour with one callback, `functions() :: %{name() => entry()}`, where
`entry()` is `{arity, atom}` - the atom naming a `def` on the same module with
signature `(args, context) :: {:ok, value} | {:error, binary()}`. The
moduledoc states the design reason directly
([`deps/predicator/lib/predicator/functions/provider.ex:8-11`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator/functions/provider.ex#L8-L11)):

> Naming the implementation by atom, rather than exposing a closure directly,
> is what lets a caller resolve `module` and `atom` separately - `apply/3`
> against the pair - instead of carrying a `function()` value around.

`builtin_providers/0` (`.../provider.ex:44-51`) names the four default modules.

**The `host` slot** ([`deps/predicator/lib/predicator/context.ex:22-29`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator/context.ex#L22-L29)):

> `host` is an opaque carrier for whatever a function provider needs at call
> time [...] It is stored exactly as given, with no normalization: unlike
> `data`, atom keys inside a `host` term are never touched. It is never
> readable from predicate text - there is no syntax that reaches it - and it
> is never merged into `data`.

It is a struct field with default `nil` (`context.ex:68,71`), set by `new/2`'s
`:host` option (`context.ex:134`) or `put_host/2` (`context.ex:256-257`,
`def put_host(%__MODULE__{} = context, host), do: %{context | host: host}`).

**Resolution and precedence** (`context.ex:158-167`, `resolve_functions/1`).
Three sources folded left, each later one shadowing a same-named earlier
entry:

1. the four builtin providers (unless `builtins: false`),
2. `:providers`, a list of `FunctionProvider` modules, left to right,
3. `:functions`, an inline `%{name => {arity, fun}}` closure map, merged last.

So a provider-supplied `"In"` is shadowed by an inline `functions:` `"In"` if
both are passed. Nothing among the 25 builtin names collides with `"In"`
(verified by listing the resolved key set).

Provider validation (`context.ex:188-207`) raises `ArgumentError` when the
module fails `Code.ensure_loaded?/1`, does not export `functions/0`, or names
an atom not exported at arity 2. This validation runs **on every
`Context.new/2` call** - it is the `T_fixed` term ADR-0028's Modifier C fired
on, and the subject of the mirrored upstream bead `px-rnc`.

**Invocation** ([`deps/predicator/lib/predicator/evaluator.ex:1289-1325`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator/evaluator.ex#L1289-L1325)).
`call_function/3` builds a `%Predicator.Context{}` at call time from the
evaluator's live state and hands it to both entry shapes identically:

```elixir
context = %Predicator.Context{
  data: evaluator.context,
  functions: evaluator.functions,
  host: evaluator.host,
  on_unbound: evaluator.on_unbound
}
```

then `dispatch({module, fun_atom}, args, context)` → `apply(module, fun_atom,
[args, context])` (`evaluator.ex:1319-1321`) or `fun.(args, context)`
(`evaluator.ex:1323-1325`). **A provider entry therefore does receive the full
`%Context{}`, and thus `host`.** `host` reaches the evaluator through
`build_evaluator/3` ([`deps/predicator/lib/predicator.ex:236-247`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator.ex#L236-L247), `host:
context.host`) and is carried on the `Evaluator` struct
(`evaluator.ex:46,85,328`).

`Predicator.execute/3`'s returned context preserves `host` (and `functions`
and `on_unbound`): `execute_instructions/3` returns `%{context | data:
final.context}` (`deps/predicator/lib/predicator.ex`, both the `:ok` and
`:error` arms) - only `data` is replaced. This matters because
`Evaluator.run_program/2` already relies on that carry-over for `functions`
([`lib/statifier/evaluator.ex:307-311`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L307-L311)).

**Divergences from the bead's recollection**, all cosmetic or in statifier's
favor:

| Bead says | 7.0.0 reality |
|---|---|
| `lib/predicator/function_provider.ex` | module name right; file is `lib/predicator/functions/provider.ex` |
| `context.ex:256-257` for `put_host/2` | exact, unchanged |
| seam landed in 5.0.0 | still present and unchanged in 7.0.0; `builtins:` is an additional 7.0.0-visible knob the bead does not mention |
| n/a | predicator 6.0 dropped `nil` → `:undefined` normalization; `Evaluator.undefine_nils/1` ([`lib/statifier/evaluator.ex:127-155`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L127-L155)) now carries it, and a provider rewrite does not touch that |

### 2. What `In/1` needs, and the shape of a `host`

`in_function/1` ([`lib/statifier/evaluator.ex:373-382`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L373-L382)) closes over exactly two
things and ignores its `%Context{}` argument entirely:

```elixir
defp in_function(%MachineState{machine: machine, configuration: configuration}) do
  fn [state_id], _predicator_context ->
    case Machine.index(machine, state_id) do
      {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
      :error -> {:ok, false}
    end
  end
end
```

So `host` needs `{machine, configuration}` and nothing else - `machine` for
`Machine.index/2`'s string-id → interned-index lookup (ADR-0005), and
`configuration` (a `MapSet` of integer indexes) for the membership test. A
provider transcription is mechanical:

```elixir
def in_state([state_id], %Predicator.Context{host: {machine, configuration}}) do
  case Machine.index(machine, state_id) do
    {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
    :error -> {:ok, false}
  end
end
```

**Resumability of that `host`.** `%Statifier.Machine{}` is tuples of
`%Machine.State{}`/`%Machine.Transition{}` structs, maps, lists, and
`%Predicator.Compiled{}` values; `configuration` is `MapSet.new([integer])`.
Both already live on `%MachineState{}` (`lib/statifier/machine_state.ex:191,193`)
and are therefore already held to constraint 1's bar. Neither is a closure.
The `host` slot is stored verbatim with no normalization
(`context.ex:102-103`), so nothing about it changes shape in transit.

**A `{machine, configuration}` host duplicates `machine_state.machine`.** The
machine is large and immutable; a stored context would hold a second reference
to it (a reference, not a copy, in the BEAM - but a second reference that a
serializer would flatten into a second copy). A narrower host - just the
`id_to_index` map plus the configuration - is available: `Machine.index/2`
reads only `id_to_index` (`lib/statifier/machine.ex`), and the `id_to_index`
map for a corpus document is a handful of string keys. This document records
the option; choosing between them is a design call.

**Measured cost of the refresh** (probe script, same `:corpus` size point
[`bench/support/workload.exs:138`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/bench/support/workload.exs#L138) defines, Apple M3, Elixir 1.18.3 / Erlang
27.3, benchee 1.5.1 - the same machine class as `bench/results/260814-*.md`):

| Operation | Time | Memory |
|---|---|---|
| `Context.put_host/2` | 0.0478 μs | 0.0859 KB |
| `Context.resolve_functions/1`, builtins + inline closure | 1.39 μs | 5.59 KB |
| `Context.resolve_functions/1`, builtins + provider | 1.46 μs | 5.80 KB |
| `Context.new/2`, providers + host, raw datamodel | 2.15 μs | 9.22 KB |
| `Evaluator.context/1` (today) | 2.54 μs | 10.92 KB |

`put_host/2` is ~53x cheaper in time and ~127x cheaper in memory than a
rebuild. **The two `resolve_functions/1` rows are the finding that matters**:
a provider costs the same as a closure to resolve, so swapping `In/1` to a
provider *by itself* changes no benchmark number. The last two rows are not a
like-for-like comparison - the `Context.new/2` row skips
`Evaluator.undefine_nils/1`, which `Evaluator.context/1` performs - so the
0.39 μs gap between them is the `undefine_nils/1` walk, not a provider saving.

### 3. Every context-build site, and which could become build-once-plus-refresh

Eight `Evaluator.context/1` call sites exist in `lib/`. Frequencies below are
per the surrounding call chain.

| # | Site | Fires | Datamodel moved since last build? | `_event` moved? | Configuration moved? | Threaded onward? |
|---|---|---|---|---|---|---|
| 1 | [`lib/statifier/interpreter/exit_entry.ex:959`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/exit_entry.ex#L959) `evaluate_donedata/3` | once per `<final>` with a compiled `<donedata>` `expr` | yes | yes | yes | discarded |
| 2 | [`lib/statifier/interpreter/exit_entry.ex:992`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/exit_entry.ex#L992) `evaluate_donedata_params/3` | once per `<final>` with `<param>`-only `<donedata>`; reused across every `<param>` sibling | yes | yes | yes | discarded after the fold |
| 3 | [`lib/statifier/interpreter/content.ex:144`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/content.ex#L144) `execute_block/3` | once per executable-content block: per `<onentry>`, per `<onexit>`, per fired transition's content | yes | no (a block never spans a microstep) | no | **threaded** - becomes `ExecutableContent.Context.datamodel_context` (ADR-0028) |
| 4 | [`lib/statifier/interpreter/selection.ex:285`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/selection.ex#L285) `condition_match/2` | once per `cond`-bearing transition tested this way; not corpus-reachable today (`selection.ex:277-280`, `FeatureDetector` marks `conditional_transitions` `:unsupported`) | yes | yes | yes | discarded |
| 5 | [`lib/statifier/interpreter/selection.ex:332`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/selection.ex#L332) `select_transitions/2` | once per selection round - one external event (`interpreter.ex:398`) or one dequeued internal event (`interpreter.ex:689`); reused across every atomic state's walk in that round | yes | **yes** - built right after `MachineState.put_event/2` wrote `_event` for this round | yes | discarded |
| 6 | [`lib/statifier/interpreter/selection.ex:364`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/selection.ex#L364) `select_eventless_transitions/1` | once per microstep (`interpreter.ex:521`), including the terminal quiescence probe | yes | no | **yes** - this is the per-microstep site the bead names | discarded |
| 7 | [`lib/statifier/interpreter/datamodel.ex:133`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/datamodel.ex#L133) `initialize/1` | once per machine instantiation, for the whole top-level `<datamodel>` binding pass | n/a (first bind) | n/a | n/a | discarded |
| 8 | [`lib/statifier/interpreter/datamodel.ex:292`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/datamodel.ex#L292) `bind_state_data/4` (`:late` clause) | once per non-root state's first entry under `binding: :late` | yes | yes | yes | discarded |

Sites 3 and 5/6 are the acceptance criterion's "per-block" and "per-selection-round"
builds respectively.

**Could become build-once-plus-`put_host/2`-refresh.** Sites 5 and 6 are the
clean candidates: within one macrostep they differ from each other only in the
configuration (site 6) and in `_event` (site 5). A stored context refreshed
with `put_host/2` at each microstep boundary would serve site 6 outright, and
site 5 with one additional `bind/3` of `_event`. Site 3 is the next candidate,
because a block already builds once and threads.

**Must still rebuild, or must be accompanied by a `bind/3`.** Site 7 is the
constructor of the first context and has nothing to reuse. Site 5's `_event`
write is a plain `Map.put` on `machine_state.datamodel`
([`lib/statifier/machine_state.ex:345-347`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine_state.ex#L345-L347)) and would have to be mirrored into
a stored context's `data`. Sites 1, 2, 4, 8 are each preceded by arbitrary
datamodel and configuration movement, so each needs whatever refresh discipline
the design adopts rather than being free.

**The six sites that write `machine_state.datamodel`**, which a stored
context's `data` would have to track:

| Site | What writes | Already binds into a context? |
|---|---|---|
| [`lib/statifier/machine_state.ex:276`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine_state.ex#L276) | initial seed (author data + `SystemVariables.initial/2`) | n/a - predates any context |
| [`lib/statifier/machine_state.ex:346`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine_state.ex#L346) `put_event/2` | `_event` | **no** |
| [`lib/statifier/interpreter/datamodel.ex:146`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/datamodel.ex#L146) | `Map.put_new(id, nil)` seeding a declared `<data>` | **no** |
| [`lib/statifier/interpreter/datamodel.ex:201`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/datamodel.ex#L201) | a bound `<data>` value | no - rebuilds instead (sites 7/8) |
| [`lib/statifier/evaluator.ex:334`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L334) `run_program/2` merge | `<script>` writes | yes, via the `post_context` predicator returns |
| [`lib/statifier/machine/content/assign.ex:86`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine/content/assign.ex#L86) | `<assign>` writes | yes, `Evaluator.bind/3` at `assign.ex:93-94` |
| [`lib/statifier/machine/content/foreach.ex:302`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine/content/foreach.ex#L302) | `<foreach>` `item`/`index` | yes, `Evaluator.bind/3` via `bind_names/4` at `foreach.ex:301-309` |

### 4. The two grounds in "Why the built context is not a `MachineState` field"

The section under examination is [`lib/statifier/evaluator.ex:37-84`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L37-L84).

**Ground 1 - "It would not be a resumable position, today"**
(`evaluator.ex:42-52`). Its own text already concedes the contingency: "This
ground is contingent on the closure: taking the px-8ii seam below (a
`FunctionProvider` bound by name instead of a captured fun) would dissolve it."

The evidence supports that concession, and adds a detail the moduledoc does not
state. Under the provider seam **every** entry in `functions` is a
`{module, atom}` pair, not only `"In"` - the probe's resolved map showed all 25
entries in that shape (`{1, {ProbeProvider, :in_state}}`,
`{1, {Predicator.Functions.MathFunctions, :call_abs}}`, and so on). Today's
context is *already* closure-free except for `In/1`, so `In/1` is the last
closure and removing it makes the whole struct free of `function()` values. A
`{module, atom}` pair is a name, and survives the three failures
`evaluator.ex:46-48` names: a node boundary, a code reload, and a
write-to-disk-and-read-back. It is also diffable, which `evaluator.ex:48` says
a closure is not.

What the moduledoc does not currently weigh, and what a rewrite would have to:
`docs/observability.md` never actually mentions serialization, node
boundaries, or code reload. Constraint 1 ([`docs/observability.md:35-38`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/docs/observability.md#L35-L38)) says
"Any machine_state value is a complete, inspectable, resumable position", and
its stated payoff (`observability.md:48-49`) is "a step debugger is
`microstep/1` in a REPL". ADR-0012's decision item 1 is equally local:
"mid-macrostep state never lives only in loop variables or on the call stack."
The serialization framing in `evaluator.ex:46-48` is the moduledoc's own gloss
on constraint 1, not a quotation from it. That does not weaken ground 1's
conclusion - it strengthens it, since the weaker in-REPL reading is satisfied
by a `{module, atom}` pair even more easily than the serialization reading is.

A second, *new* observability consideration the provider seam introduces, which
neither ground names: a stored context duplicates state that `%MachineState{}`
already holds. `context.data` is a normalized copy of `machine_state.datamodel`,
and a `{machine, configuration}` host is a second reference to
`machine_state.machine` and `machine_state.configuration`. Constraint 1 wants a
struct that is inspectable and unambiguous; two fields that must agree and can
silently disagree is a different failure mode from a closure, not the same one
solved. `machine_state.ex:169-180` already documents a related sharp edge (`==`
on two `%MachineState{}` values is not a position-equality test), and
`machine_state.ex:33-41` records the precedent of deliberately *not* adding a
field ahead of a caller that needs it.

**Ground 2 - "It would be stale by construction"** (`evaluator.ex:53-61`). Its
own text claims it "is structural and survives the px-8ii seam entirely:
whatever builds `functions`, a stored context still answers against a
configuration the machine has moved past."

That sentence is true of a context that is stored and *not refreshed*. What the
seam changes is the cost of refreshing: from a 2.54 μs / 10.92 KB rebuild to a
0.0478 μs / 0.0859 KB `put_host/2`. So the accurate restatement is that ground
2 stops being a reason the field is impossible and becomes a reason the field
carries an obligation. On the evidence the obligation has two parts, and the
second is the larger one:

- **Configuration staleness** is a single-site problem. The configuration moves
  in `enter_states`/`exit_states`, and a refresh at the microstep boundary is
  one `put_host/2`. The bead's "an O(1) refresh" describes this half exactly.
- **`data` staleness** is a seven-site problem, and the seam does nothing for
  it. The table in section 3 shows two writers -
  `MachineState.put_event/2` and `Datamodel`'s `Map.put_new(id, nil)` seed -
  that do not bind into any context today because no context outlives them.
  Under a stored context each becomes a site that must bind or the stored
  `data` goes stale. `_event` in particular is the one the moduledoc's own
  "Never scoped to a whole macrostep" section (`evaluator.ex:25-35`) names
  first: "`_event` is rewritten on every internal-event round".

So: **ground 1's stated contingency is met and the ground dissolves. Ground 2's
claim that it "survives the seam entirely" is too strong as written - the seam
converts it from a correctness impossibility into an exhaustiveness
obligation over seven write sites - but it is not dissolved either.** Which of
those two facts is decisive for the field is a design judgment this document
does not make.

### 5. Tests that pin today's behavior

**`test/statifier/evaluator_test.exs`** is the primary pin.

- `In/1` semantics: `:133-136` (true for a state in the configuration),
  `:142-145` (false for a declared state not in the configuration), `:153-156`
  (false for an id the machine never declared - the only test reaching
  `Machine.index/2`'s `:error` branch).
- `:165-181` **"the built context is a snapshot"** - asserts that `In/1`'s
  captured configuration does *not* follow a later mutation of the
  `machine_state`. This test encodes the closure's capture semantics as an
  assertion. A provider reading `context.host` reproduces it - a `%Context{}`
  built with one host answers against that host until `put_host/2` replaces it -
  but this is the test most directly coupled to the mechanism being changed and
  the one to read first.
- `on_unbound: :error`: `:106-118` (unbound root → `UndefinedVariableError`
  with a non-nil span), and `:395-401` (survives a `bind/3`).
- `In/1` survives the other context paths: `:308-315` (through `execute/2`'s
  rebuilt post-run context), `:381-386` (through `bind/3`).
- `nil` → `:undefined`: `:202-207` (`_event`/`_event.data` before any event),
  `:217-223` (the test319 shape - an unbound-probe comparison evaluates rather
  than errors), `:229-238` (`put_event/2` replaces the seeded undefined),
  `:340-346`/`:410-415` (`bind/3` normalizes, including nested).
- [`test/statifier/evaluator/system_variables_test.exs:101-137`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/test/statifier/evaluator/system_variables_test.exs#L101-L137) is the unit-level
  `emptyEventData` counterpart.

**Executable-content threading** (all ADR-0028 behavior):
[`test/statifier/machine/content/assign_test.exs:272-278`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/test/statifier/machine/content/assign_test.exs#L272-L278) and `:286-295`,
[`test/statifier/machine/content/foreach_test.exs:259-266`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/test/statifier/machine/content/foreach_test.exs#L259-L266) and `:275-283`,
[`test/statifier/machine/content/script_test.exs:125-133`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/test/statifier/machine/content/script_test.exs#L125-L133). These assert
*behavior* (a read-back through the returned `datamodel_context` sees the
write). Note that `assign_test.exs:267-271`'s sabotage comment still describes
the pre-ADR-0028 mechanism (`Evaluator.context(ms)`) while `assign.ex:93-94`
binds - the assertion is current, the comment's prose is not.

**Interpreter-level `nil` pins**:
[`test/statifier/interpreter/datamodel_test.exs:33-47`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/test/statifier/interpreter/datamodel_test.exs#L33-L47) (raw storage stays `nil`),
`:54-69` (`Var1 === undefined` is `{:ok, true}`), `:242-273` (normalization does
not mutate `machine_state.datamodel`).

**Conformance `In()` coverage**: `test/scxml_tests/mandatory/selecting_transitions/`
`test409_test.exs`, `test411_test.exs`, `test413_test.exs`;
`test/scxml_tests/mandatory/history/test580_test.exs`;
`test/scxml_tests/mandatory/expressions/test310_test.exs`;
`test/scion_tests/in/test_in_predicate_test.exs` (ten transitions over
`In('a1')`, `In('r1')`, `In('p1')`, `!In('e2')`, `!In('c2')`, `In('a2')`,
`In('b2')`, `In('c2')`, `In('d2')`, `In('e2')`).

**test319/335/337/339**, all in `test/scxml_tests/mandatory/system_variables/`:
test319 asserts `_event` is unbound at initialization (`_event !== undefined`
must take the `<else>` branch); test335/337/339 assert `_event.origin`,
`_event.origintype`, `_event.invokeid` each read `undefined` after a
`<raise>`. All four go through `Evaluator.undefine_nils/1`, which a provider
rewrite does not touch - but all four are registered individually in the
ratchet.

**Ratchet mechanics** (`test/passing_tests.json`): `internal_tests` is
**glob-based** (`test/statifier/**/*_test.exs`), so every unit test above is
already ratcheted with no JSON edit. `scion_tests` and `w3c_tests` are explicit
per-file arrays; the six `In()` files and test319/335/337/339 are each listed.
`mix test.regression` therefore catches an `In/1` regression from both
directions.

**What would have to keep passing**: `mix test.regression` at its current
counts, and `mix test --include scion --include scxml_w3` at the counts
ADR-0028's Phase 4 recorded - **1661 tests, 107 failures; `mix test.regression`
1522/0** (`docs/adr/0028-...:117-119`). Those are the numbers a provider
rewrite has to reproduce exactly, the same way Phase 4 did.

### 6. Where the before/after benchmark evidence comes from

`bench/macrostep.exs` (387 lines) drives real documents through the public
boundary - `Statifier.compile/1`, `Statifier.initialize/2`,
`Statifier.send_event/2` - over four hand-built document families
(`Documents.realistic/0`, `assign_heavy/1`, `foreach/1`, `cond_selection/0`,
[`bench/macrostep.exs:39-161`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/bench/macrostep.exs#L39-L161)). [`bench/support/workload.exs:136-143`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/bench/support/workload.exs#L136-L143) supplies the
`:corpus` size point (5 roots, depth 1, breadth 2), derived from an actual scan
of the corpus rather than guessed (`workload.exs:108-129`).

**The script's derived `S_time`/`S_mem` figures are already dead.**
`bench/results/260814-macrostep.md`'s Phase 4 section says so in terms:

> This script's own `S_time`/`S_mem` figures are no longer meaningful after
> Phase 4 and are not reported below: the "estimated build cost" they divide
> by is `build count * Evaluator.context/1`'s per-build cost - a model of the
> *old* per-write-rebuild behavior.

The hardcoded build counts that feed that estimate ([`bench/macrostep.exs:269-272`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/bench/macrostep.exs#L269-L272)
= `7` and `n + 3`; `:308` = `n + 4`; `:350-348` = `2`) were read off the
pre-ADR-0028 call-site table and no longer describe the code.

**So the comparable before/after is the same one Phase 4 used**: Benchee's
direct `measured macrostep` timing of `Statifier.send_event/2`, per document,
before and after. That table is already in
`bench/results/260814-macrostep.md`'s Phase 4 section and is the "before" row
set a st-l0t run compares against - same machine, same benchee version, same
documents, `lib/` the only thing that changed. Reproducing it is
`mix run bench/macrostep.exs` and reading the `measured macrostep` line out of
each `Bench.derive/4` block.

Two caveats specific to this bead's acceptance criterion, which asks for "the
per-block and per-selection-round builds reduced":

- **`bench/macrostep.exs` cannot currently show a per-selection-round
  reduction on any corpus-shaped document, because none of its documents
  evaluates `In()`.** The four builders' datamodels are `a`..`e` scalars and
  their transitions are plain or `cond="a==99"`-shaped
  (`bench/macrostep.exs:42-48,151-153`). `In()` never appears. The
  `cond_selection/0` document is the only one whose selection round evaluates
  anything at all, and Phase 4 measured it at 8.657 → 9.007 μs, "-4.0%
  (noise)". A run that wants to show the selection-round build reduced would
  need either a new document family or a change to the existing ones - a
  `bench/` change, outside every gate stage (`bench/README.md`).
- **A provider swap alone moves no number** (section 2's `resolve_functions/1`
  rows). The measurable win comes from builds *eliminated*, so the benchmark
  only registers the change if the same increment also stops building
  somewhere - which is what sites 5 and 6 in section 3 are.

`bench/context_build.exs` is the other half: its `T_fixed` scenario
(`context_build.exs:31-33`) isolates `resolve_functions/1`, and would be the
natural place to add the provider-versus-closure and `put_host/2` rows this
document measured ad hoc.

## Code References

- [`lib/statifier/evaluator.ex:37-84`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L37-L84) - the "Why the built context is not a `MachineState` field" section, both grounds
- [`lib/statifier/evaluator.ex:119-125`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L119-L125) - `context/1`, the sole constructor
- [`lib/statifier/evaluator.ex:127-155`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L127-L155) - `undefine_nils/1` and its predicator-6.0 note
- [`lib/statifier/evaluator.ex:183-185`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L183-L185) - `bind/3`
- [`lib/statifier/evaluator.ex:317-348`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L317-L348) - `run_program/2` and its `post_context`
- [`lib/statifier/evaluator.ex:373-382`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/evaluator.ex#L373-L382) - `in_function/1`, the closure to be replaced
- [`lib/statifier/machine_state.ex:189-205`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine_state.ex#L189-L205) - the struct; `:345-347` - `put_event/2`
- [`lib/statifier/interpreter/content.ex:141-145`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/interpreter/content.ex#L141-L145) - the per-block build; `:174-193` - the threading fold
- `lib/statifier/interpreter/selection.ex:285,332,364` - the three selection-side builds
- `lib/statifier/interpreter/datamodel.ex:133,146,201,292` - initialization and late-binding builds and writes
- `lib/statifier/interpreter/exit_entry.ex:959,992` - the two `<donedata>` builds
- [`lib/statifier/machine/content/assign.ex:86-95`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine/content/assign.ex#L86-L95) - the ADR-0028 bind
- [`lib/statifier/machine/content/foreach.ex:301-309`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine/content/foreach.ex#L301-L309) - `bind_names/4`
- [`lib/statifier/machine/content/script.ex:98-105`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/machine/content/script.ex#L98-L105) - `rebind/3`
- [`lib/statifier/executable_content/context.ex:63-69`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/lib/statifier/executable_content/context.ex#L63-L69) - the `datamodel_context` field
- [`deps/predicator/lib/predicator/functions/provider.ex:1-52`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator/functions/provider.ex#L1-L52) - the behaviour
- `deps/predicator/lib/predicator/context.ex:22-29,68-71,128-136,158-207,240-260` - host slot, struct, `new/2`, `resolve_functions/1`, `bind/3`, `put_host/2`
- [`deps/predicator/lib/predicator/evaluator.ex:1289-1325`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator/evaluator.ex#L1289-L1325) - `call_function/3` and `dispatch/3`
- [`deps/predicator/lib/predicator.ex:236-247`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/deps/predicator/lib/predicator.ex#L236-L247) - `build_evaluator/3`, where `host` crosses over

## Architecture Documentation

- **ADR-0004** commits the datamodel to predicator, `~> 7.0` ([`docs/datamodel.md:3-4`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/docs/datamodel.md#L3-L4)). This is a commitment, not a stopgap.
- **ADR-0005** interns state ids to integer indexes below the `Statifier` boundary - which is why `In/1` needs `machine` at all, for `Machine.index/2`'s string→index lookup.
- **ADR-0012** / [`docs/observability.md:26-49`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/docs/observability.md#L26-L49) constraint 1: "Any machine_state value is a complete, inspectable, resumable position." Notably it never mentions serialization, node boundaries, or code reload - see section 4.
- **ADR-0026** makes `<script>` a predicator statement program, which is why `run_program/2` returns a context at all.
- **ADR-0028** (`docs/adr/0028-executable-content-blocks-thread-one-context.md`) took within-block threading and explicitly left the across-blocks context untaken (`:73-79`, `:140-149`). Its consequence list names both grounds this bead reopens and describes the closure ground as "dissolvable by the `px-8ii` provider seam, already landed upstream but not taken here". It also names the two things that would reopen it: a materially larger datamodel, or `cond` on transitions becoming corpus-reachable.
- **ADR-0025** governs the `mirrors:` protocol with `px-10u`; the bead's own note (2026-08-14) records that pairing as *complements*, not *blocks*, and that no predicator change is needed.
- [`docs/datamodel.md:54-59`](https://github.com/riddler/statifier-ex/blob/f1fe7e123dc6511a354e63f36157fa57b3b760d3/docs/datamodel.md#L54-L59) holds the "once per evaluation site" commitment, and `:118-141` the upstream-seams section, which already records this exact seam as landed-but-not-taken and states "**no context is stored on `MachineState`, and widening the interval that far remains future work.**"

## Historical Context

- `docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md` pre-registered the decision rule ADR-0028 was judged against, before any number existed.
- `bench/results/260814-context-build.md` measured the three-term decomposition: at `:corpus`, `T_full` = 2.28 μs / 10.92 KB, `T_fixed` = 1.29 μs / 5.51 KB, `T_fixed / T_full` = 56.6%. This fired Modifier C and produced the mirrored upstream bead `px-rnc` (memoize `resolve_functions/1`'s per-call `Code.ensure_loaded?/1` and `function_exported?/3`). That upstream work is orthogonal to this bead but lands on the same line of code.
- `bench/results/260814-macrostep.md` Phase 4 verification holds the before/after table this bead's own run compares against, and its explicit statement that the script's derived shares are invalidated.
- `docs/research/260812-st-unt-*` and `docs/research/260812-st-af3.3-*` already record the genuine-`null`-versus-unbound gap as latent, which is why `undefine_nils/1` is out of scope here.
- `px-8ii` was closed 2026-08-11 as superseded by epic `px-e1n`, which shipped. The gap is statifier-side adoption.

## Related Research

- `docs/research/260814-st-sdh-context-rebuild-vs-bind-benchmark.md` - section 1's call-site table is the direct ancestor of section 3 above
- `docs/research/260812-st-unt-*`, `docs/research/260812-st-af3.3-*` - the `nil`/`:undefined` gap

## Open Questions

No human was available during this research; these are recorded rather than
resolved.

1. **How wide should `host` be?** `{machine, configuration}` is the literal
   transcription; `{id_to_index, configuration}` is narrower and duplicates
   less of `%MachineState{}`. Both satisfy `In/1`. Whether a future host
   function needs more of the machine is unknown.
2. **Does the acceptance criterion's "per-selection-round builds reduced"
   require a `bench/` document change?** No existing benchmark document
   evaluates `In()`, and `cond_selection/0` measured as noise across Phase 4.
   Either the criterion is read as covering the per-block builds only, or
   `bench/macrostep.exs` gains a document family - a `bench/` change is outside
   every gate stage but is still a change the bead's scope does not name.
3. **Does ground 2's restatement need an ADR, or a moduledoc rewrite?** The
   acceptance criterion says "the Evaluator moduledoc's storage section is
   rewritten or re-justified against the new grounds". ADR-0028 recorded the
   *narrow* decision and named the wide one as future work; whether taking the
   wide one is an ADR-worthy decision is a call for the plan stage.
4. **Is the state duplication a stored context introduces (its `data` versus
   `machine_state.datamodel`, its `host` versus `machine`/`configuration`) a
   constraint-1 concern in its own right?** This document names it because
   neither existing ground does; it is not asserted to be disqualifying.
5. **`px-rnc`'s memoization would change the arithmetic in section 2.** If
   `resolve_functions/1` becomes cheap upstream, the case for building fewer
   contexts weakens by exactly `T_fixed`. Per ADR-0025 the shape of that
   memoization is predicator's call, and the reconciliation note in this bead's
   description was last refreshed 2026-08-14.
