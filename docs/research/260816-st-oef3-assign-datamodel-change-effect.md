---
date: 2026-08-16T19:20:24-0600
researcher: Claude
git_commit: 8015033ab029fb81788a2f55b8d014e201cdd03b
branch: st-oef3-assign-datamodel-effect
repository: statifier-ex
beads_issue: st-oef3
topic: "How <assign> executes today, and what an effect carrying the written location and value would have to fit into"
tags: [research, codebase, datamodel, effects, observability]
status: complete
last_updated: 2026-08-16
last_updated_by: Claude
---

# Research: the datamodel-change effect for `<assign>` (st-oef3)

**Date**: 2026-08-16T19:20:24-0600
**Git Commit**: 8015033ab029fb81788a2f55b8d014e201cdd03b
**Branch**: st-oef3-assign-datamodel-effect
**Bead**: st-oef3 (mirrors `sui-t36.1`)

## Research Question

`<assign>` is observable today only as a `Trace.ContentExecuted` naming the
`c_index` that ran; nothing on the effect stream says which location was
written or with what value. st-oef3 asks for an effect carrying at minimum
`{c_index, location_path, new_value}` - ideally the prior value too - so that a
consumer can reconstruct the datamodel from the effect stream alone, including
from a recorded trace, without calling `Session.snapshot/1`.

This document maps what exists today: how `<assign>` executes, where the write
mechanics live and who else calls them, what the effect vocabulary is and every
place that enumerates it exhaustively, how effects reach a consumer, and what
the governing documents commit to. It documents; it does not decide. The
decisions the plan stage owns are collected under Open Questions.

## Summary

The bead's premise checks out exactly. `Statifier.Machine.Content.Assign`'s
`execute/2` returns `{:ok, context, []}` unconditionally - an empty effect list
on every successful write ([`lib/statifier/machine/content/assign.ex:88`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/assign.ex#L88)). The
only trace of an `<assign>` on the stream is the block-level
`Trace.ContentExecuted`, which carries `owner` and a **list** of `c_indexes`
for the whole block, not per-node detail and no values at all
([`lib/statifier/effect/trace/content_executed.ex:51-60`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect/trace/content_executed.ex#L51-L60)). `<log>` really is the
sole content node whose result reaches a consumer, via `Effect.Log`'s `value`
field ([`lib/statifier/machine/content/log.ex:49-68`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/log.ex#L49-L68)).

Four things shape what a new effect would have to fit into:

1. **The write mechanics are shared by four call sites**, not one.
   `Statifier.Interpreter.Datamodel.write_location/4`
   ([`lib/statifier/interpreter/datamodel.ex:121-138`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L121-L138)) is called by `<assign>`,
   `<send idlocation>`, `<invoke idlocation>`, and the empty-`<finalize>`
   auto-assign. Two of those are nodes (inside an `ExecutableContent` defimpl);
   two are in the runner (`Statifier.Interpreter` itself). Only the two node
   sites have a `c_index` in scope.

2. **No call site holds a resolved path or a prior value.** Every caller passes
   a raw path-source string; `write_location/4` resolves it internally through
   its private `resolve_location/2`
   ([`lib/statifier/interpreter/datamodel.ex:145-152`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L145-L152)) and returns only the
   post-write `{machine_state, datamodel_context}`. Reading the prior value at
   the caller would mean duplicating that resolution.

3. **The vocabulary is enumerated exhaustively in six places.** A new effect
   tag is not a one-file change: `Statifier.Effect`'s moduledoc table and
   `@type`, `Session.Effects.plan_one/2` (no catch-all), `Session.Telemetry`'s
   kind lists / `@type`s / shape clauses (ADR-0040), and two table-driven test
   fixtures with hard-coded counts all name every member.

4. **The acceptance criterion reaches past `<assign>`.** "Reconstruct the
   datamodel from the effect stream alone" also needs the *initial* datamodel,
   and `Statifier.Interpreter.Datamodel.initialize/1` returns a bare
   `MachineState.t()` with no effect list at all - deliberately, with the
   reasoning written into its `@doc`
   ([`lib/statifier/interpreter/datamodel.ex:221-232`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L221-L232)). The environment seed and
   `SystemVariables.initial/2` in `MachineState.new/2` are likewise silent.

## Detailed Findings

### `<assign>` today

[`lib/statifier/machine/content/assign.ex:79-90`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/assign.ex#L79-L90) is the whole node:

```elixir
def execute(%Assign{location: location} = node, %Context{} = context) do
  with {:ok, value} <- evaluate_value(node, context),
       {:ok, machine_state, datamodel_context} <-
         Datamodel.write_location(
           context.machine_state,
           context.datamodel_context,
           location,
           value
         ) do
    {:ok, %{context | machine_state: machine_state, datamodel_context: datamodel_context}, []}
  end
end
```

`node.c_index` is in scope and unused. `location` is the raw, uncompiled SCXML
`location` attribute - the moduledoc is explicit that it "cannot be resolved
any earlier than `execute/2` even in principle", since a bracket key such as
`items[i]` reads `i` against the pre-assignment datamodel
([`lib/statifier/machine/content/assign.ex:8-13`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/assign.ex#L8-L13)). The compiled node also
carries `location_location` (the `location` attribute's own span) and
`node_location` (the element's span), so constraint-3 location data is
available on the node.

A `{:invalid, error}` compiled `expr` short-circuits without evaluation
(`assign.ex:100`); every predicator failure returns a bare `{:error, reason}`,
never a raise and never a platform notification of its own - the block runner
is the sole conversion site (ADR-0003).

### `write_location/4` and its four call sites

[`lib/statifier/interpreter/datamodel.ex:121-138`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L121-L138). Five documented steps:
resolve the path against `datamodel_context.data`; reject a `_`-rooted system
variable (spec 5.10); require the resolved root to already be a key of
`machine_state.datamodel`; write into the *raw* `machine_state.datamodel`; bind
just the written root back into `datamodel_context` (ADR-0028).

| # | Call site | Construct | Identity in scope | Prior value cheap? | Effects returned | Node or runner |
|---|---|---|---|---|---|---|
| 1 | [`lib/statifier/machine/content/assign.ex:82`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/assign.ex#L82) | `<assign>` (5.4, 5.9.2) | `node.c_index`, `context.owner` | No - only the raw `location` string | always `[]` | node (defimpl) |
| 2 | [`lib/statifier/interpreter.ex:785`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter.ex#L785) | empty-`<finalize>` auto-assign (6.5) | `state_index`, `invoke_index`; **no `c_index`** | No - only the raw `source` string | none; caller hardcodes `[]` (`interpreter.ex:704`) | runner |
| 3 | [`lib/statifier/machine/content/send.ex:267`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/send.ex#L267) | `<send idlocation>` (6.2.1) | `node.c_index`, `owner`, `send_id` | No - only the raw `idlocation` string | `[{:send, ...}]` / `[{:send_delayed, ...}]` | node (defimpl) |
| 4 | [`lib/statifier/interpreter.ex:1469`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter.ex#L1469) | `<invoke idlocation>` (6.4.1) | `state_index`, `invoke_index`, `invoke_id`; **no `c_index`** | No - only the raw `idlocation` string | `[{:invoke, ...}]` | runner |

In sites 3 and 4 the value written is a generated id (`send_id` /
`invoke_id`), which is already carried on the `:send`/`:send_delayed`/`:invoke`
effect those sites emit - but the *location* it was written to is not.

Failure behavior differs per site and is worth noting for any emission
decision: site 1 propagates `{:error, reason}` to the block runner, which
raises `error.execution` with origin `{:content, c_index, owner}`
([`lib/statifier/interpreter/content.ex:58-69`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/content.ex#L58-L69)); site 2 raises
`error.execution` with origin `{:finalize, state_index, invoke_index}` and
continues the fold (`interpreter.ex:791-796`); site 3 discards the whole
`<send>` message per ADR-0036; site 4 aborts the invocation per ADR-0031.

### The block runner and how a node's effects are accumulated

`Statifier.Interpreter.Content.execute_block/3` builds one
`Evaluator.context/1` for the block and folds `run_nodes/2` over the
`c_indexes`. On `{:ok, new_context, node_effects}` it does
`effects ++ node_effects` ([`lib/statifier/interpreter/content.ex:177-179`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/content.ex#L177-L179)), so
a node returning a non-empty list needs no runner change - the mechanism
already works uniformly (`<send>` uses it). `Trace.ContentExecuted` is appended
*after* the block's own effects, because it reports what ran
(`content.ex:155-158`, moduledoc `:15-33`).

The moduledoc states the seam explicitly:

> "This module builds that context exactly once, before any node in the block
> runs, and never rebuilds it itself - the seam named here is taken in
> `Statifier.Machine.Content.Assign`'s own `execute/2`, never in this runner
> ([`docs/architecture.md:112-114`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/docs/architecture.md#L112-L114)'s 'never a change to the runner')."
> ([`lib/statifier/interpreter/content.ex:50-56`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/content.ex#L50-L56))

[`docs/architecture.md:108-122`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/docs/architecture.md#L108-L122) is the source of that rule: "A new element is a
new `Statifier.Machine.Content.*` struct plus a `defimpl` in the same file -
never a change to the runner or the interpreter (the error *model* itself ...
is a separate, ADR-governed thing from an element's own code)."

### The effect vocabulary

`lib/statifier/effect.ex` is the single definition site: eighteen members, nine
core and nine trace, each `{tag, payload_struct}`. `trace?/1` is a single match
on the `:trace` tag (`effect.ex:147-148`). `Effect.trace/3` is the gate macro
(`effect.ex:163-173`) - single evaluation of `machine_state`, and `fields`
spliced only inside the `if`, so the untraced path allocates nothing and never
evaluates the field expression.

Trace payloads all carry `macrostep`/`microstep`/`round` stamped by an
identical `new/2`; core payloads carry `macrostep`/`microstep` only (with
`BudgetExhausted` the lone core exception carrying `round`). `Effect.Log`
([`lib/statifier/effect/log.ex:23-33`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect/log.ex#L23-L33)) carries `label`, `value`, `c_index`,
`owner`, `macrostep`, `microstep` - and is built as a struct literal in the
node, not through a `new/2` helper
([`lib/statifier/machine/content/log.ex:54-63`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/log.ex#L54-L63)). It is the closest existing
shape to what st-oef3 asks for.

**Every place the vocabulary is enumerated exhaustively**, all of which a new
member must be added to:

- [`lib/statifier/effect.ex:24-43`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect.ex#L24-L43) - the moduledoc vocabulary table.
- [`lib/statifier/effect.ex:113-138`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect.ex#L113-L138) - `@type core` / `@type trace` / `@type t`.
- [`lib/statifier/session/effects.ex:116-150`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/session/effects.ex#L116-L150) - `plan_one/2`, one clause per
  core tag plus one `{:trace, _payload}` clause covering all nine trace
  members. **No catch-all**; an unmatched tag raises `FunctionClauseError`.
- `lib/statifier/session/telemetry.ex` - `@type core_payload` (`:187-197`),
  `@type trace_payload` (`:199-209`), `@effect_kinds` (`:221-231`),
  `@trace_kinds` (`:233-243`), one `core_shape/2` clause per core payload
  (from `:461`), `trace_kind/1` one-liners (`:588-596`), `trace_shape/2`
  clauses (from `:544`). `Telemetry.events/0` returns 25 literal names today.
- [`test/statifier/effect_test.exs:26-124`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/test/statifier/effect_test.exs#L26-L124) - `@core_effects` / `@trace_effects`
  fixture tables driven by a compile-time `for`, plus
  `assert length(@core_effects) + length(@trace_effects) == 18`.
- [`test/statifier/session/effects_test.exs:32`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/test/statifier/session/effects_test.exs#L32) - `@vocabulary`, 21 fixtures
  "across the eighteen-tag vocabulary", with its own count assertion at `:304`.

### How effects reach a consumer

`Statifier.Session.Effects.plan/2` ([`lib/statifier/session/effects.ex:111-114`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/session/effects.ex#L111-L114))
is pure: `effects |> Enum.flat_map(&plan_one/2)`. Every clause prepends
`{:notify, effect}`; `:log` and `:trace` are pure pass-through with nothing
else planned. `Statifier.Session` performs the instruction list as a strict
left fold (`session.ex:912-919`), so subscriber messages arrive in exactly the
core's effect order. Subscribers receive `{:statifier, session_id, {:effect,
effect}}` (`session.ex:64-76`, `notify/2` at `:1381-1386`).

`Session.snapshot/1` returns `state.machine_state` verbatim, datamodel included
(`session.ex:474-475`, `:688`). `status/1` does **not** include the datamodel
(`build_status/1`, `:1401-1416`). Tracing is a `MachineState.new/2` option
(`trace:`, default `false`), forwarded straight through by
`Session.start_link/2` (`session.ex:520-523`).

`Statifier.Replay` (`lib/statifier/replay.ex`) consumes a
`Session.Recording.t()` - the *input* log, not the effect stream - and
re-derives effects by re-driving the real interpreter, then plans them through
the same `Effects.plan/2` and folds its own `perform_instruction/3` over the
result (`:354-460`). It matches on **instruction** shapes, never on effect
tags, and `{:notify, effect}` is opaque to it (except a `{:done, %Done{}}`
special case at `:359-362`). ADR-0034 records that this fold has no catch-all
on purpose: "a new instruction kind is a `FunctionClauseError` at the first
test that produces one, not a silently skipped case"
([`docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md:85-87`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md#L85-L87)). So a
new effect that plans only to `{:notify, _}` needs no replay change; a new
instruction shape does.

**Nothing in `lib/`, `test/`, or `tools/` folds the effect stream to
reconstruct a data structure today.** The nearest precedents are
`Statifier.Replay` (reconstructs the whole terminal `%MachineState{}`, but from
the input log) and `test/support/context_recorder.ex`, a test-only content node
that carries a whole `Predicator.Context.t()` out as an `Effect.Log`'s `value`
- the existing pattern for reading datamodel content back out of the
vocabulary.

### The initial datamodel is not on the stream

`Statifier.Interpreter.Datamodel.initialize/1`
([`lib/statifier/interpreter/datamodel.ex:235-257`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L235-L257)) seeds every declared
`<data>` id to `:undefined`, then binds through `bind_value/4`
(`:305-324`) - `Map.put/3` straight into `machine_state.datamodel`. Its `@doc`
states the omission and its reasoning:

> "Returns a bare `MachineState.t()`, never `{machine_state, [effect]}` like
> every other function in `Statifier.Interpreter`: binding a `<data>` produces
> no trace effect today (`docs/observability.md`'s minimum trace vocabulary is
> a closed table and datamodel binding is not a member of it) and no core
> effect either ... a future trace row would add the second return value at
> that point, with its own caller."
> ([`lib/statifier/interpreter/datamodel.ex:221-232`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L221-L232))

`enter_state/2` (`:391-420`) is the late-binding, per-state counterpart and is
equally silent. Upstream of both, `MachineState.new/2` merges the caller's
`:datamodel` option under `SystemVariables.initial/2` - so `_sessionid`,
`_name`, and any environment seed also never appear on the stream. A consumer
folding effects alone therefore starts from an unknown map, not an empty one.
ADR-0037 governs how an unbound id spells itself (`:undefined` at the writer),
which is what a reconstruction would have to reproduce for a seeded-but-unbound
id.

## Code References

- [`lib/statifier/machine/content/assign.ex:79-90`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/assign.ex#L79-L90) - `<assign>`'s `execute/2`, returning `[]`
- [`lib/statifier/machine/content/assign.ex:98-104`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/assign.ex#L98-L104) - the value ladder, `{:invalid, _}` short-circuit
- [`lib/statifier/interpreter/datamodel.ex:121-138`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L121-L138) - `write_location/4`
- [`lib/statifier/interpreter/datamodel.ex:145-152`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L145-L152) - `resolve_location/2`, the only path resolution
- [`lib/statifier/interpreter/datamodel.ex:203-208`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L203-L208) - the write against the raw datamodel
- [`lib/statifier/interpreter/datamodel.ex:221-232`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/datamodel.ex#L221-L232) - why `initialize/1` returns no effects
- [`lib/statifier/interpreter.ex:785`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter.ex#L785) - the empty-`<finalize>` auto-assign write
- [`lib/statifier/interpreter.ex:1469`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter.ex#L1469) - the `<invoke idlocation>` write
- [`lib/statifier/machine/content/send.ex:267`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/send.ex#L267) - the `<send idlocation>` write
- [`lib/statifier/interpreter/content.ex:50-56`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/content.ex#L50-L56) - "the seam ... is taken in the node, never in this runner"
- [`lib/statifier/interpreter/content.ex:177-179`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/content.ex#L177-L179) - node effects accumulated by the block runner
- [`lib/statifier/interpreter/content.ex:155-158`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/interpreter/content.ex#L155-L158) - `Trace.ContentExecuted` appended after the block
- [`lib/statifier/effect.ex:24-43`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect.ex#L24-L43) - the eighteen-member vocabulary table
- [`lib/statifier/effect.ex:147-148`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect.ex#L147-L148) - `trace?/1`
- [`lib/statifier/effect.ex:163-173`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect.ex#L163-L173) - the `trace/3` gate macro
- [`lib/statifier/effect/log.ex:23-33`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect/log.ex#L23-L33) - `Effect.Log`'s fields
- [`lib/statifier/effect/trace/content_executed.ex:51-60`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/effect/trace/content_executed.ex#L51-L60) - `c_indexes` is a list, no values
- [`lib/statifier/machine/content/log.ex:49-68`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/machine/content/log.ex#L49-L68) - the only node whose result reaches a consumer
- [`lib/statifier/session/effects.ex:116-150`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/session/effects.ex#L116-L150) - `plan_one/2`, no catch-all
- [`lib/statifier/session/telemetry.ex:221-243`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/session/telemetry.ex#L221-L243) - `@effect_kinds` / `@trace_kinds`
- [`lib/statifier/replay.ex:354-460`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/replay.ex#L354-L460) - `perform_instruction/3`, matches instructions not effect tags
- [`lib/statifier/session.ex:474-475`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/lib/statifier/session.ex#L474-L475) - `snapshot/1` returns the whole `MachineState`
- [`test/statifier/effect_test.exs:26-124`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/test/statifier/effect_test.exs#L26-L124) - the table-driven vocabulary fixtures and the `== 18`
- [`test/statifier/session/effects_test.exs:32`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/test/statifier/session/effects_test.exs#L32) - `@vocabulary`, 21 fixtures
- `test/support/context_recorder.ex` - carrying a datamodel context out as an `Effect.Log` value

## Architecture Documentation

- **ADR-0003** (pure core with effects) establishes the shape any new effect
  must fit - `(state, event) -> {state, [effect]}`, effects are data
  interpreted outside the core - and lists a founding set that has since grown
  (ADR-0019 added `:budget_exhausted`; `<invoke>` added `:cancel_invoke` and
  `:autoforward`). It does not constrain *what* may join the vocabulary.
- **ADR-0012 / `docs/observability.md`** make the six constraints binding.
  Constraint 2's table header reads "Minimum trace vocabulary (shapes settled
  at implementation, the set is the commitment)", but the document glosses that
  itself at [`docs/observability.md:72-78`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/docs/observability.md#L72-L78): the commitment is about *shapes*
  being settled, "not about the table being closed to boundaries Appendix D had
  not yet been ported far enough to need." The precedent for adding a row
  (`InvokePass`, `FinalizeAutoforward`) is that the row names a phase boundary
  Appendix D itself names. A datamodel write is not such a boundary - it sits
  *inside* the existing "content executed" row.
- **Constraint 3** gives the identities a payload should carry (`c_index`,
  `t_index`, state index) and keeps source locations on the Machine;
  **constraint 4** requires the step counters on every trace payload.
- **ADR-0040** (session telemetry contract) is the concrete integration
  surface: every core effect gets `[:statifier, :session, :effect, kind]` and
  every trace effect `[:statifier, :session, :trace, kind]`, with `kind`
  derived by a literal-atom multi-clause function (never `String.to_atom/1`,
  per `Credo.Check.Warning.UnsafeToAtom`), and `events/0` enumerating all 25
  names. Its amendment (st-ii9v, 2026-08-16) settles that **no trace event
  carries a `location` key at all**, while a *core* effect carrying exactly one
  resolvable index does get `metadata.location` resolved through
  `Machine.content/2` at emission. That asymmetry bears directly on the
  trace-vs-core choice below.
- **ADR-0028** governs the context threading `write_location/4`'s final
  `Evaluator.bind/3` implements; it is a context-reuse decision, explicitly not
  an observability one, and explicitly stores nothing on `MachineState`.
- **ADR-0034** fixes replay as a fold over the recorded *input*, not over the
  effect stream, and records that both `Effects.plan_one/2` and
  `Replay.perform_instruction/3` deliberately lack catch-alls.
- **ADR-0037** spells an unbound value `:undefined` at the writer.
- **ADR-0025** governs the cross-repo half: st-oef3 mirrors `sui-t36.1`, and
  the SCXML mapping and effect vocabulary are this repo's decision to own. Note
  that **nothing in this repo's `docs/` mentions statifier-ui, `sui-`, or its
  ADR-0005 wire format** - the acceptance criterion's non-Elixir-consumer
  rationale lives entirely in the other tracker.

## Historical Context

- `docs/plans/260809-st-wju.2-machine-state-event-effects-vocabulary.md` -
  where the vocabulary and the trace gate were built (Phase 3); the canonical
  precedent for adding a member.
- `docs/research/260815-st-cmq.3-send-cancel-content-nodes-and-effects.md` and
  its plan - the closest sibling: a content node that produces a core effect,
  including the `owner`/`c_index` fields on `Effect.Send`.
- `docs/research/260813-st-af3.4-assign-deep-path-vivification.md` and its plan
  - where `<assign>`'s deep-path write and the resolve/put split came from;
  `Predicator.ContextLocation.location_path()` is `[binary() | integer()]`.
- `docs/research/260816-st-cmq.1-session-telemetry-effect-trace-streams.md` and
  its plan - the telemetry bridge a new effect must extend.
- `docs/research/260815-st-dtm-replay-recorder-session-boundary.md` - the
  recorder; `Recording.put_internal/5`'s doc already notes that at least one
  input is "not deterministic from the recorded effect stream alone".
- `docs/research/260812-st-af3.3-datamodel-data-early-late-binding.md` -
  early/late `<data>` binding, the init-side half of the reconstruction
  question.

No document in this repo proposes an `:assign` or `:datamodel_change` tag, and
none discusses capturing a prior value at a write site. The question is open in
the record, not settled either way.

## Related Research

- `docs/research/260813-st-af3.4-assign-deep-path-vivification.md`
- `docs/research/260815-st-cmq.3-send-cancel-content-nodes-and-effects.md`
- `docs/research/260816-st-cmq.1-session-telemetry-effect-trace-streams.md`
- `docs/research/260815-st-dtm-replay-recorder-session-boundary.md`
- `docs/research/260812-st-af3.3-datamodel-data-early-late-binding.md`

## Open Questions

These are the decisions the plan stage owns. Nothing in the codebase or the
accepted ADRs settles them; each is recorded here rather than guessed at.

1. **Trace-gated or core effect?** A trace effect fits "an `<assign>` ran" as
   debugging detail and costs nothing when `trace: false`, but ADR-0040's
   amendment means no trace event may carry a `location` key, and constraint
   2's row-admission test ("a phase boundary Appendix D names") does not
   obviously admit a datamodel write, which sits inside the existing "content
   executed" row. A core effect carries an unconditional cost on the hot path
   and needs a `plan_one/2` clause, but is the family `Effect.Log` already
   belongs to and the family whose telemetry shape may resolve a location. The
   bead's acceptance criterion - reconstructing the datamodel from the stream -
   also argues against gating, since a gated effect makes reconstruction
   possible only in traced runs.

2. **Do the other three `write_location/4` call sites emit too?** Consistency
   says a datamodel-change effect should name every datamodel change, and the
   acceptance criterion ("reconstruct the datamodel") is not satisfiable if
   `<send idlocation>`, `<invoke idlocation>`, and the empty-`<finalize>`
   auto-assign write silently. But two of those are in the runner, where
   [`docs/architecture.md:108-122`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/docs/architecture.md#L108-L122) and `content.ex:50-56` locate no seam, and
   neither has a `c_index` to put in the payload - so an effect whose payload
   requires `c_index` cannot serve them unchanged. Scoping this bead to
   `<assign>` alone and filing the other three is a legitimate answer, but it
   has to be a stated one.

3. **What identity does the payload carry when there is no `c_index`?**
   `Effect.Log` allows `c_index: nil` (for a global `<script>`), and ADR-0040
   already handles a `nil` index by omitting the `location` key. Whether the
   finalize/invoke sites would carry `{state_index, invoke_index}` instead, or
   a widened `owner`-style tagged tuple like
   `Trace.ContentExecuted`'s `{:global_script, index}`, is undecided.

4. **Prior value: captured, and if so where?** No call site holds one, and the
   path is resolved only inside `write_location/4`. The cheap option is for
   `write_location/4` to return it (it has the resolved `path` and the
   pre-write `machine_state.datamodel` in hand at
   `datamodel.ex:128-137`), which changes a shared function's signature and
   every one of its four callers. The alternative - resolving the path a second
   time at the caller - doubles the resolution cost on the hottest datamodel
   path. Also undecided: how "no prior value" spells itself (`:undefined` per
   ADR-0037, a distinct `:absent`, or the key simply omitted), and whether the
   prior value is the value at the full path or the whole prior root.

5. **Where does emission live?** `content.ex:50-56` and
   [`docs/architecture.md:108-122`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/docs/architecture.md#L108-L122) say the seam is taken in the node, never in
   the runner, and the block runner already accumulates a node's effects with
   no change needed. But emitting inside `write_location/4` is the only place
   that serves all four call sites with one implementation and the only place
   with the resolved path. Whether `write_location/4` returning an effect list
   counts as "the runner emitting" - it is `Interpreter.Datamodel`, a shared
   mechanics module, not `Interpreter.Content` - is exactly the judgment the
   plan has to make and record.

6. **Is the initial datamodel in scope?** The acceptance criterion says
   "reconstruct the datamodel from the effect stream alone", but
   `initialize/1`, `enter_state/2`, the `:datamodel` environment seed, and
   `SystemVariables.initial/2` all write without emitting. A reconstruction
   from effects alone is therefore impossible today no matter what `<assign>`
   emits. Options include: emitting for `<data>` binding too (which the
   `initialize/1` `@doc` at `:221-232` anticipates, "a future trace row would
   add the second return value at that point"); an init-time snapshot effect;
   or narrowing the criterion to "reconstruct the *changes*" and having the
   consumer obtain the initial map some other way. This is the largest scoping
   question in the bead.

7. **What shape is `location_path`?** The raw author string (`"items[i]"`,
   which a consumer cannot index a map with) or predicator's resolved
   `[binary() | integer()]` path (which is what a consumer actually needs to
   apply the write, and which is what makes `items[i]` reproducible). Carrying
   both is possible; ADR-0025 puts the shape decision on this repo's side of
   the mirror, but it is what statifier-ui has to consume.

8. **Serializability of `new_value`.** A payload field on the wire for a
   non-Elixir consumer constrains what may go in it; predicator values are
   already JSON-ish, but `:undefined` is an atom and nothing in this repo
   commits to a serialization. [`docs/observability.md:175`](https://github.com/riddler/statifier-ex/blob/8015033ab029fb81788a2f55b8d014e201cdd03b/docs/observability.md#L175) lists "no wire
   format" as an explicit non-goal here.

9. **Does a *failed* write emit anything?** All four sites already produce an
   `error.execution` (or discard/abort) on failure. Whether the new effect is
   emitted only on success is the simple answer, but a consumer reconstructing
   state benefits from knowing an attempted write did not land.

10. **The exhaustive-enumeration cost.** Adding a member touches at minimum:
    a new file under `lib/statifier/effect/` (or `effect/trace/`),
    `Effect`'s moduledoc table and `@type`, `Session.Telemetry`'s `@type` +
    kind list + shape/kind clauses (and `events/0`'s count moving 25 -> 26),
    `Session.Effects.plan_one/2` (core only), `effect_test.exs`'s fixture and
    its `== 18`, and `session/effects_test.exs`'s `@vocabulary` and its `21`.
    Whether `docs/observability.md`'s constraint-2 table also gains a row (and
    therefore whether this needs an ADR of its own, as `InvokePass` and
    `FinalizeAutoforward` did not) is a plan-stage call.
