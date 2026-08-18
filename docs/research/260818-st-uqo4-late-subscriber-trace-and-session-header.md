---
date: 2026-08-18T16:09:39-0600
researcher: Claude
git_commit: 909682a8349544b52b805b468c6e2f1f0b56b6a8
branch: st-uqo4-late-subscriber-trace
repository: statifier-ex
beads_issue: st-uqo4
topic: "How a subscriber attached after Statifier.Session.start_link/2 could obtain the effects it missed, and what a self-describing session header effect would carry"
tags: [research, codebase, session, observability, effects]
status: complete
last_updated: 2026-08-18
last_updated_by: Claude
---

# Research: the late subscriber and the missing session header

**Date**: 2026-08-18T16:09:39-0600
**Git Commit**: 909682a8349544b52b805b468c6e2f1f0b56b6a8
**Branch**: st-uqo4-late-subscriber-trace
**Bead**: st-uqo4

## Research Question

st-uqo4 states two halves of one problem.

(a) `Statifier.Session.start_link/2` runs `Statifier.Interpreter.initialize/2`
to quiescence before it returns, so a pid added by `subscribe/2` afterwards has
already missed the initial `Trace.EntrySet`, `Trace.ContentExecuted`,
`Trace.InvokePass`, and `Trace.MacrostepStable`. Only the `:subscribers` start
option avoids that, and it is not always available.

(b) The effect stream opens with a bare `Trace.EntrySet`; no effect names the
session, its `session_id`, or the document being traced, so a consumer joining
mid-stream has no self-describing header. `:record`/`recording/1` (ADR-0029)
records inputs, not emitted effects, so it does not answer this either.

This document maps the code and the settled decisions as they stand today. It
proposes nothing.

## Summary

Both halves of the bead's description check out against the code exactly as
written.

**Half (a) is structural, not incidental.** `init/1` calls
`Interpreter.initialize/2` inline ([`lib/statifier/session.ex:558`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L558)) and builds
the subscriber map from `opts[:subscribers]` immediately after
([`lib/statifier/session.ex:560-563`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L560-L563)). The effects that call produced are not
performed in `init/1` at all; they ride a `{:continue, {:initialize, effects,
start_time, span_ref}}` term ([`lib/statifier/session.ex:597`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L597)) and are performed
one message-loop turn later in `handle_continue/2`
([`lib/statifier/session.ex:723`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L723)). Because a `handle_continue` runs before any
message reaches the process, and because `subscribe/2` is a `GenServer.call`
([`lib/statifier/session.ex:517`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L517), handled at [`lib/statifier/session.ex:805-813`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L805-L813)),
a `subscribe/2` issued the instant `start_link/2` returns is still strictly
after the whole initialize batch has been notified. There is no window.

**Nothing in the repo buffers an emitted effect.** `notify/2`
([`lib/statifier/session.ex:1589-1594`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1589-L1594)) is an unconditional `send/2` per
subscriber pid with no copy retained. The `%State{}` struct
([`lib/statifier/session.ex:289-341`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L289-L341)) holds exactly two effect-shaped things and
neither is a history: `deferred` is a within-`perform/3` work queue of effects
*not yet delivered* ([`lib/statifier/session.ex:307`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L307), `:330-339`, `:1071-1078`),
documented as always `[]` outside a `perform/3` call; `done_effect` retains the
single `%Effect.Done{}` for the halted `configuration` projection and the
`done.invoke.*` donedata ([`lib/statifier/session.ex:1088`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1088), `:1242`, `:1637`).
`Statifier.Session.Recording` stores the ADR-0029 four inputs and the only
effects in it are `interpret/2` batches, which are inputs
([`lib/statifier/session/recording.ex:96-105`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/recording.ex#L96-L105)). The one place a whole emitted
stream is ever materialized as a value is `Statifier.Replay`'s
`result().stream` ([`lib/statifier/replay.ex:159-168`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/replay.ex#L159-L168)), which is a pure return
value produced offline from a recording and is called only from tests.

**Half (b) checks out too, and there is a close precedent.** The subscriber
message envelope already names the session -
`{:statifier, session_id, message}` ([`lib/statifier/session.ex:1591`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1591),
[`docs/observability.md:177-178`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/docs/observability.md#L177-L178)) - but no *effect* names it, and nothing names
the document at all. `Statifier.Effect.DatamodelInit` is the existing
once-per-`initialize/2` opening effect, emitted unconditionally even for a
chart with no `<datamodel>` "so a consumer always has a starting point with
nothing to special-case"; it is the nearest structural precedent for a header
effect, and it deliberately carries values only, never machine facts, on
`docs/observability.md` constraint 3's reasoning that tooling resolves machine
facts through the `%Machine{}`.

**Two settled decisions constrain any design here.** ADR-0044 decision 1 makes
non-decreasing `(macrostep, round)` arrival the subscriber-stream contract, and
says it is "the same order `Statifier.Replay` produces for the same recording";
ADR-0046 rejected a session-side stamp on effect structs precisely because
`Statifier.Replay` re-derives effects with no session behind it, so a
session-applied field "would exist in live streams and not in replayed ones,
breaking the stream equality". That equality is asserted literally, as
`result.stream == stream`, at
[`test/statifier/replay_round_trip_test.exs:109`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/replay_round_trip_test.exs#L109).

**One finding from the downstream repo materially narrows half (b).**
statifier-ui already builds its own `session.start` manifest at its own
subscription boundary, and its ADR-0005 records explicitly that "GAP 6 /
st-uqo4 is not a precondition for it". See Open Questions.

## Detailed Findings

### Session start sequencing and the subscriber lifecycle

`start_link/2` ([`lib/statifier/session.ex:399-402`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L399-L402)) splits `:name` off and
hands everything else to `GenServer.start_link/3`. Its `@doc`
([`lib/statifier/session.ex:363-397`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L363-L397)) states the behavior the bead names:
"running `Statifier.Interpreter.initialize/2` to quiescence before returning",
and lists `:subscribers` as "pids to monitor and forward the effect stream to
from the start (default `[]`); `subscribe/2` adds more afterward".

`init/1` ([`lib/statifier/session.ex:544-598`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L544-L598)) in order:

1. resolves `session_id` locally, `MachineState.generate_session_id/0` by
   default (`:545`);
2. registers under `Statifier.Registry` (`:546`, `register_session/1` at
   `:643-650`) - moved ahead of `initialize/2` by ADR-0048 decision 2;
3. builds `machine_opts` including the ADR-0048 route snapshot (`:550-554`);
4. **runs `Interpreter.initialize(machine, machine_opts)`** (`:558`), producing
   `{machine_state, effects}`;
5. builds the subscriber map from `opts[:subscribers]`, monitoring each
   (`:560-563`);
6. emits `Telemetry.init/4` and opens the `:initialize` macrostep span
   (`:567-568`);
7. builds `%State{}` and returns `{:ok, state, {:continue, {:initialize,
   effects, start_time, span_ref}}}` (`:597`).

The effects are performed in `handle_continue({:initialize, ...}, state)`
([`lib/statifier/session.ex:723-737`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L723-L737)), which calls `perform(state, effects)` and
then closes the span. The comment at [`lib/statifier/session.ex:587-596`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L587-L596) records
why the split exists: performing a `{:start_child, %Invoke{}, _}` from inside
`init/1` would deadlock against the `Statifier.SessionSupervisor` process that
is still serving this session's own start. It also notes "A `handle_continue`
runs before any message reaches this process, so nothing observes the split",
which is exactly why `subscribe/2` cannot slip in.

`subscribe/2` ([`lib/statifier/session.ex:516-517`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L516-L517)) is
`GenServer.call(server, {:subscribe, pid})`; the handler
([`lib/statifier/session.ex:805-814`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L805-L814)) monitors the pid if not already present
and puts it in `state.subscribers`. It does nothing else - no backfill, no
catch-up, no snapshot. `unsubscribe/2` (`:519-521`, handler `:816-825`) pops
and demonitors with `[:flush]`. A subscriber that dies is dropped on its own
`:DOWN` in the general clause at [`lib/statifier/session.ex:910-921`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L910-L921), checked
after the parent clause (`:906-908`) and after `Invocations.pop_by_pid/2`.

`notify/2` ([`lib/statifier/session.ex:1589-1594`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1589-L1594)):

```elixir
defp notify(state, message) do
  payload = {:statifier, state.session_id, message}
  Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, payload) end)
  :ok
end
```

Three call sites: `{:effect, effect}` from both `{:notify, _}` clauses of
`perform_instruction/3` ([`lib/statifier/session.ex:1085-1095`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1085-L1095)),
`{:unroutable, effect}` (`:1207`), and `{:halted, reason}` (`:1216`).

### What the initialize batch actually contains

`Statifier.Session.Effects.plan/2`
([`lib/statifier/session/effects.ex:111-114`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/effects.ex#L111-L114)) flat-maps `plan_one/2` over the
core's effect list, preserving core order. **Every** effect yields a
`{:notify, effect}` instruction in its original list position; effects that
also mean something operationally to the session append a further instruction
after it ([`lib/statifier/session/effects.ex:8-12`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/effects.ex#L8-L12), `:117-152`). `:log`,
`:datamodel_change`, `:datamodel_init`, and `:trace` plan to nothing beyond
their own `{:notify, _}`.

So the effects a from-start subscriber sees during initialize, and a late one
does not, are whatever `Interpreter.initialize/2` returned: at minimum
`{:datamodel_init, _}`, and under `trace: true` the `Trace.EntrySet`,
`Trace.ContentExecuted`, `Trace.InvokePass`, and `Trace.MacrostepStable` the
bead enumerates, plus any `:log`, `:send`, `:invoke`, or `:datamodel_change` a
`<onentry>` produced, plus `{:done, _}` and `{:halted, :done}` for a chart that
terminates during initialize (a case `start_link/2`'s own `@doc` calls
"corpus-normal", [`lib/statifier/session.ex:365-369`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L365-L369)).

### The effect vocabulary and how a new effect type is added

`Statifier.Effect` (`lib/statifier/effect.ex`) is the single `@type t()` union
and the trace gate. Its moduledoc holds the authoritative vocabulary table
(one row per tag, naming the producing module) and states the two invariants a
new effect has to satisfy:

- **Every effect is `{tag, payload_struct}`** - "There are no positional tuples
  with four or five elements anywhere in this vocabulary."
- **Every effect carries `macrostep`/`microstep`/`round`** (constraint 4,
  ADR-0046); trace payloads additionally carry constraint-3 *identities* - a
  state index, a `t_index`, a `c_index` - never a `%Machine.State{}`,
  `%Machine.Transition{}`, or a compiled content-node struct.

Each trace payload module is the same shape - see
`lib/statifier/effect/trace/entry_set.ex`,
`lib/statifier/effect/trace/macrostep_stable.ex`,
`lib/statifier/effect/trace/invoke_pass.ex`: a moduledoc citing the
`docs/observability.md` constraint-2 row it implements, `@enforce_keys` listing
its own fields plus the three counters, a `defstruct`, a `@type t`, and a
`new/2` that stamps the counters off the `%MachineState{}`:

```elixir
def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
  struct!(__MODULE__, Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round))
end
```

`Effect.trace/3` (`lib/statifier/effect.ex`, the `defmacro`) is the emission
gate: single evaluation of the `machine_state` argument, and full laziness of
`fields` when `machine_state.trace` is false.

Places that must change together when a tag joins the vocabulary:

- `lib/statifier/effect.ex` - the moduledoc table, the `core()`/`trace()`
  typedocs, the `@type` unions, and `trace?/1`.
- `test/statifier/effect_test.exs` - the table-driven `@core_effects` /
  trace lists (`:30-60+`) that make `trace?/1` exhaustive by test rather than
  by compiler.
- `lib/statifier/session/effects.ex` - a `plan_one/2` clause; the planner has
  no catch-all, and `test/statifier/session/effects_test.exs` is table-driven
  over the whole vocabulary (`@vocabulary`, `:37+`) so a missing clause raises
  `FunctionClauseError` rather than planning nothing.
- `lib/statifier/session/telemetry.ex` - `core_shape/2` or `trace_shape/2` plus
  `trace_kind/1` (`:643-652`), and the moduledoc's own event tables
  (`:114-170`). ADR-0040 (`:449-455`) says any field added to, removed from, or
  renamed on any `Effect.*` struct reopens that ADR, because "the raw struct
  rides verbatim in every core/trace event's `effect` metadata key".
- `lib/statifier/replay.ex` - whatever the replay fold must do to reproduce it,
  since `result().stream` is asserted equal to the live stream.

### Ordering: ADR-0044 and ADR-0046

ADR-0044 decision 1 is the subscriber-stream contract: delivery in
non-decreasing `(macrostep, round)` order, "the same order `Statifier.Replay`
produces for the same run". It is achieved by the `deferred` FIFO rather than
by sorting - `perform/3` ([`lib/statifier/session.ex:1048-1053`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1048-L1053)) runs
`perform_batch/3` then `drain_deferred/1`, and `deliver_internal/6` appends
its returned effects to `state.deferred` instead of performing them inline
([`lib/statifier/session.ex:1540-1562`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1540-L1562), the append at `:1555`).

ADR-0044 decision 2 makes `{:halted, reason}` end-of-stream. Decision 3 makes
`Trace.MacrostepStable` unique per `(macrostep, round)` rather than per
macrostep. Decision 4 deferred stamping `round` onto core effects; ADR-0046
did that work, leaving no exemptions.

ADR-0046's rejected alternative is the one most directly load-bearing here: a
session-side wrapper attaching `round` at delivery was rejected because it
"fails on replay: ADR-0034's `Statifier.Replay` re-derives effects from the
core with no session behind it, so a session-applied stamp would exist in live
streams and not in replayed ones, breaking the stream equality".

The moduledoc of `Statifier.Session` restates the whole contract for
subscribers at [`lib/statifier/session.ex:59-102`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L59-L102), including the caveat that the
order guarantee is about *delivery*, not something re-derivable from the
structs (a note now partly superseded by ADR-0046, which is why
`test/support/stream_order.ex` treats a `macrostep`-without-`round` payload as
a defect rather than an exemption).

### What identifies a session and its document today

**Session identity.** `MachineState.generate_session_id/0`
([`lib/statifier/machine_state.ex:503-508`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/machine_state.ex#L503-L508)) mints `"sess_" <>` Crockford base32
of a 48-bit millisecond timestamp plus 80 bits of CSPRNG output (ADR-0008 as
amended). It is public specifically so `Session.init/1` can resolve the id
before `Interpreter.initialize/2` runs ([`lib/statifier/session.ex:545`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L545),
comment at `:533-542`). `MachineState.new/2`
([`lib/statifier/machine_state.ex:448-473`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/machine_state.ex#L448-L473)) merges
`SystemVariables.initial(machine, session_id)` over the caller's `:datamodel`,
so `_sessionid` always wins; `SystemVariables.initial/2`
([`lib/statifier/evaluator/system_variables.ex:74-84`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/evaluator/system_variables.ex#L74-L84)) writes `_sessionid`,
`_name` (from `machine.name`), `_event`, and `_ioprocessors` (whose `location`
is `SystemVariables.scxml_location/1`, `"#_scxml_" <> session_id`).
`Session.session_id/1` ([`lib/statifier/session.ex:404-406`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L404-L406)) is documented as
"`datamodel[\"_sessionid\"]`, held apart for routing".

**Document identity.** `%Statifier.Machine{}`
([`lib/statifier/machine.ex:111-158`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/machine.ex#L111-L158)) carries `states`, `id_to_index`,
`transitions`, `contents`, `data_elements`, `name` (`String.t() | nil`, the
`<scxml name>` attribute), `datamodel` (the datamodel *type* string),
`binding` (`:early | :late`), `location` (`Parser.Location.t()` of the
`<scxml>` element), `global_scripts`, `warnings`. There is **no source path,
no filename, and no source text** on it; `Parser.Location`
(`lib/statifier/parser/location.ex`) is line/column/byte-offset only.

`%Statifier.Document{}` ([`lib/statifier/document.ex:111-146`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/document.ex#L111-L146)) is richer -
it alone carries `version`, `xmlns`, `namespace`, `initial`,
`datamodel_element`, `scripts`, and `attribute_locations` - but the compiler
threads only `name: document.name` onto the Machine
([`lib/statifier/compiler.ex:291`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/compiler.ex#L291)). A session never holds a `%Document{}`; it
holds `machine_state.machine`.

**The closest thing to a header today** is the telemetry init event.
`Telemetry.init/4` ([`lib/statifier/session/telemetry.ex:275-293`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/telemetry.ex#L275-L293)) emits
`[:statifier, :session, :init]` with measurement `system_time` and metadata
`session_id`, `machine_name` (`machine.name`), `trace` (boolean), and
`invoked_by` (`{parent_pid, invoke_id}` or `nil`). That is the entire
document-describing payload: one nilable string. Per ADR-0040, telemetry is
"one more interpreter of that stream, not a new channel", it always carries
`session_id` in metadata, and `Statifier.Replay` fires nothing.

**The closest structural precedent for an opening effect** is
`Statifier.Effect.DatamodelInit` (`lib/statifier/effect/datamodel_init.ex`),
emitted once per `Interpreter.initialize/2`, unconditionally, even for a chart
with no `<datamodel>`. Its own design record
(`docs/plans/260817-st-1xwh-initial-datamodel-binding-effect.md`, decision 6)
kept machine facts (`binding`, `env_ids`, declared ids) *off* it on
`docs/observability.md` constraint 3's grounds. `round: 0` is the stamp
ADR-0020 gives pre-fold-begin effects, so an initialize-time effect sorts
before every real round.

### Recording and replay: why they do not answer this

`Statifier.Session.Recording` ([`lib/statifier/session/recording.ex:92-109`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/recording.ex#L92-L109)) is
`{machine, opts, entries}`. `opts` is normalized to exactly `[:session_id,
:trace, :datamodel, :max_macrostep_rounds, :routes]` and sorted (`:111`,
`:128-140`). The `entry()` union (`:96-105`) has six kinds - `:event`,
`:invoked_event`, `:cancel`, `:timer`, `:interpret`, `:internal` - each with a
trailing `Send.Routes.t() | nil` snapshot (ADR-0048 decision 3). The only
effects it holds are the `{:interpret, [Effect.t()], routes}` batches, which
are inputs a caller supplied, not effects the core emitted. It records no
wall-clock time; ordering is purely ordinal.

The session's own moduledoc states the split plainly
([`lib/statifier/session.ex:265-276`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L265-L276)): "Recording taps the input clauses, never
the inbox ... which is why the tap sits on the input side and not on the effect
stream `notify/2` fans out." [`docs/observability.md:199-203`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/docs/observability.md#L199-L203) gives the reason:
the recorder "cannot be a subscriber, because the effect stream does not
distinguish core-derived effects (replay re-derives them) from
`interpret/2`-injected ones (replay re-injects them)".

`Statifier.Replay` (`lib/statifier/replay.ex`) re-drives the pure core with no
process and no timer (ADR-0034), appending subscriber-shaped messages to
`state.stream` (`:499`) instead of `send/2`-ing them, and returning
`%{machine_state:, stream:, status:}` (`:164-168`) where `message()` is
`{:effect, Effect.t()} | {:unroutable, Effect.t()} | {:halted, halt_reason()}`
(`:159-161`). `Replay.run/1` is called from no module under `lib/`; its only
call sites are [`test/statifier/replay_round_trip_test.exs:108`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/replay_round_trip_test.exs#L108),
`test/statifier/replay_test.exs`, and
`test/statifier/session/invoke_cancel_test.exs`.

That round-trip helper ([`test/statifier/replay_round_trip_test.exs:97-113`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/replay_round_trip_test.exs#L97-L113)) is
the gate any change here must pass:

```elixir
defp round_trip(machine, opts, drive) do
  session_opts = Keyword.merge([record: true, trace: true, subscribers: [self()]], opts)
  {:ok, session} = Session.start_link(machine, session_opts)
  ...
  assert {:ok, result} = Replay.run(recording)
  assert result.stream == stream
  assert result.machine_state == snapshot
```

Note that the live side always uses `subscribers: [self()]` at start, so the
live stream it compares against is a from-start stream.

### Where the tests live

- `test/statifier/session_test.exs` (1483 lines) is the canonical suite.
  `describe "subscribers"` at `:165-241`; `describe "identity"` at `:104-143`
  covers `session_id/1`, a supplied `:session_id`, and `_name` from
  `machine.name`. Roughly fifteen tests across the file pass
  `subscribers: [self()]` at start.
- [`test/statifier/session_test.exs:171-183`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/session_test.exs#L171-L183) is the one test that calls
  `subscribe/2` today. It spawns a `late` sink pid, subscribes it, then asserts
  only against `self()` - the from-start subscriber. Nothing currently asserts
  what a `subscribe/2`-attached pid receives.
- `test/support/stream_order.ex` (`Statifier.StreamOrder`) is the shared
  harness: `drain/2` (`:46-52`, 100 ms quiet window, arrival order preserved),
  `assert_monotone/1` (`:67-82`), `assert_stable_unique/1` (`:124-142`),
  `assert_halted_last/1` (`:148-161`). Used at `session_test.exs:761-764`,
  `:815-819`, `:1117-1123`.
- `test/statifier/replay_round_trip_test.exs` keeps its own private
  `drain_stream/2` (`:85-91`), which `stream_order.ex` was modelled on.
- `test/statifier/session/effects_test.exs` is table-driven over the whole
  vocabulary; `test/statifier/session/recording_test.exs` and
  `test/statifier/replay_test.exs` are pure struct-level;
  `test/statifier/session/telemetry_test.exs` is `async: false` and attaches
  via `:telemetry_test.attach_event_handlers/2` (`:28-32`).
- [`test/statifier/session_test.exs:1163-1457`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/session_test.exs#L1163-L1457) is the `describe "recording"`
  block, including a live-session round-trip through `Replay.run/1` at
  `:1431-1456`.
- No test calls `Session.unsubscribe/2`, and no test drains a live
  `{:unroutable, _}` subscriber message (that shape is covered at the telemetry
  layer, [`test/statifier/session/telemetry_test.exs:1046-1075`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/session/telemetry_test.exs#L1046-L1075)).

The sabotage convention in these files is a comment directly above the `test`
line naming the concrete mutation, the observable consequence after `->`, and
"Reverted and confirmed green"; `# sabotage: n/a - <reason>` for harness
plumbing ([`test/support/stream_order.ex:1`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/support/stream_order.ex#L1),
[`test/statifier/session_test.exs:221-224`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/session_test.exs#L221-L224)).

### Guards that will see a change here

`Mix.Statifier.AdrGuard` holds `@effect_interpreter_paths`
([`lib/mix/statifier/adr_guard.ex:87-91`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/mix/statifier/adr_guard.ex#L87-L91)) as exactly
`["lib/statifier/session.ex", "lib/statifier/supervisor.ex",
"lib/statifier/session/telemetry.ex"]`. Any I/O in a fourth module under
`lib/statifier/` fails the ADR-0003 check; the moduledoc of `session.ex`
(`:8-14`) says so from the other side: "A different path or module name fails
the gate."

`.quality.exs:33` disables the `adr_judge` stage by default and `:41`
re-enables it under the `merge` profile, which `.claude/wurk/mr.md` runs
unconditionally before every push - so a new ADR, or an amendment to an
existing one, is judged at MR time and not on the bare gate.

## Code References

- [`lib/statifier/session.ex:59-102`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L59-L102) - the moduledoc's subscriber-stream contract
- [`lib/statifier/session.ex:265-276`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L265-L276) - "Recording taps the input clauses, never the inbox"
- [`lib/statifier/session.ex:289-341`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L289-L341) - `%State{}`, including `deferred` and `done_effect`
- [`lib/statifier/session.ex:363-397`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L363-L397) - `start_link/2`'s `@doc`, the option list
- [`lib/statifier/session.ex:544-598`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L544-L598) - `init/1`: initialize at `:558`, subscribers at `:560-563`, continue at `:597`
- [`lib/statifier/session.ex:723-737`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L723-L737) - `handle_continue({:initialize, ...}, _)`, where the batch is performed
- [`lib/statifier/session.ex:805-825`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L805-L825) - `subscribe`/`unsubscribe` handlers
- [`lib/statifier/session.ex:1048-1078`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1048-L1078) - `perform/3`, `perform_batch/3`, `drain_deferred/1`
- [`lib/statifier/session.ex:1085-1095`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1085-L1095) - the two `{:notify, _}` clauses
- [`lib/statifier/session.ex:1540-1562`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1540-L1562) - `deliver_internal/6` and the `deferred` append
- [`lib/statifier/session.ex:1589-1594`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1589-L1594) - `notify/2`
- [`lib/statifier/session/effects.ex:8-12`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/effects.ex#L8-L12) - every effect plans a `{:notify, _}` first
- [`lib/statifier/session/effects.ex:90-114`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/effects.ex#L90-L114) - `instruction()` union and `plan/2`
- [`lib/statifier/session/recording.ex:92-109`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/recording.ex#L92-L109) - the recording struct and `entry()` union
- [`lib/statifier/session/telemetry.ex:275-293`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/telemetry.ex#L275-L293) - `Telemetry.init/4`, the nearest thing to a header
- [`lib/statifier/session/telemetry.ex:426-451`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session/telemetry.ex#L426-L451) - `Telemetry.effect/3`
- `lib/statifier/effect.ex` - the vocabulary table, `trace?/1`, and the `trace/3` gate
- `lib/statifier/effect/trace/entry_set.ex` - the canonical trace-payload shape
- `lib/statifier/effect/datamodel_init.ex` - the existing once-per-initialize opening effect
- [`lib/statifier/machine.ex:111-158`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/machine.ex#L111-L158) - `%Machine{}` fields
- [`lib/statifier/document.ex:111-146`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/document.ex#L111-L146) - `%Document{}` fields
- [`lib/statifier/machine_state.ex:503-508`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/machine_state.ex#L503-L508) - `generate_session_id/0`
- [`lib/statifier/evaluator/system_variables.ex:74-84`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/evaluator/system_variables.ex#L74-L84) - `_sessionid`, `_name`, `_ioprocessors`
- [`lib/statifier/replay.ex:159-168`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/replay.ex#L159-L168) - `message()` and `result()`
- [`lib/mix/statifier/adr_guard.ex:87-91`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/mix/statifier/adr_guard.ex#L87-L91) - `@effect_interpreter_paths`
- [`test/statifier/session_test.exs:165-241`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/session_test.exs#L165-L241) - `describe "subscribers"`
- [`test/statifier/session_test.exs:171-183`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/session_test.exs#L171-L183) - the only `subscribe/2` test
- [`test/support/stream_order.ex:46-161`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/support/stream_order.ex#L46-L161) - `drain/2` and the three stream assertions
- [`test/statifier/replay_round_trip_test.exs:97-113`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/replay_round_trip_test.exs#L97-L113) - `round_trip/3`, `result.stream == stream`
- [`test/statifier/session/effects_test.exs:37`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/session/effects_test.exs#L37) - the table-driven vocabulary

## Architecture Documentation

- **ADR-0003** - the pure core returns `{state, [effect]}`; `Statifier.Session`
  is the one production effect interpreter; "No pids, adapters, or log buffers
  live in core state"; "Embedders can supply their own effect interpreter".
- **ADR-0008** (amended) - `sess_` ids are minted outside the core, once per
  session, immutable. Ids minted *inside* the core are deterministic
  `%MachineState{}` counters, since the core may read neither clock nor CSPRNG.
- **ADR-0012** - trace is part of the effect vocabulary, not a core hook;
  debuggers are effect interpreters; step counters give every trace an
  ordering key.
- **ADR-0020** - `round` joins the counters; resets per macrostep;
  `(macrostep, round)` orders lexicographically; `round: 0` is the
  pre-fold-begin stamp.
- **ADR-0027** - registration happens inside `init/1`, keyed by session id; a
  session is `restart: :temporary` because a restart mints a fresh id and is
  therefore a different session.
- **ADR-0029** - `interpret/2` stays public; the replay recording widens to
  four inputs; the recorder cannot be a subscriber.
- **ADR-0034** - replay is a pure fold over a recording, never a live session;
  it appends `{:notify, _}` results to its own return value; the recording
  carries ordinal order only.
- **ADR-0040** - the telemetry contract; every event carries `session_id` in
  metadata; core effect events fire regardless of `trace`, trace events only
  under `trace: true`; replay fires nothing; a field added to or removed from
  any `Effect.*` struct reopens the ADR.
- **ADR-0044** - decision 1, monotone `(macrostep, round)` arrival is the
  subscriber-stream contract, matching what `Statifier.Replay` produces;
  decision 2, `{:halted, _}` is end-of-stream; decision 3,
  `Trace.MacrostepStable` is unique per `(macrostep, round)`.
- **ADR-0046** - `round` on every core effect, no exemptions; and the rejected
  session-side stamp, on stream-equality grounds.
- **ADR-0048** - route snapshots are stamped per drive and recorded per entry;
  this is why `init/1` resolves the session id and registers before
  `initialize/2` runs.
- **`docs/observability.md` constraint 2** - trace effects are ordinary list
  members; the ordering guarantee holds across batches; every effect carries
  the counter triple so a captured stream can be sorted offline.
- **`docs/observability.md` constraint 3** - trace payloads carry identities
  (indexes), never structs; tooling resolves them through `Machine.at/2`,
  `transition/2`, `content/2`.
- **`docs/observability.md` constraint 6** - observe and record at the
  boundary; the subscriber envelope is `{:statifier, session_id, {:effect,
  effect}}`; the recorder cannot be a subscriber.
- **`docs/observability.md` non-goals** - no stepper API, no wire format, no
  trace persistence or rotation story: "trace effects are handed to the effect
  interpreter and are its problem."
- **`docs/architecture.md`** - `Statifier.Session` owns the fan-out of the
  effect stream to subscribers; the generated-identifier split at the core
  boundary.

## Historical Context

- `docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md` -
  the research behind the session itself, including the "one subscriber
  stream, no `:owner`" shape.
- `docs/research/260815-st-dtm-replay-recorder-session-boundary.md` - the
  research that settled the recorder on the input side.
- `docs/research/260816-st-cmq.1-session-telemetry-effect-trace-streams.md` -
  the telemetry/trace stream research behind ADR-0040.
- `docs/research/260817-st-r6l9-invoke-effect-order-reentry.md` - the ordering
  research behind ADR-0044. `:110` records `notify/2` as "an unconditional
  `send/2` per subscriber - no buffering, no reordering, no batching.
  Subscriber arrival order is fold order." `:445-449` records that
  statifier-ui had *inferred* the `{:halted, _}` end-of-stream promise from
  behavior because nothing in `docs/` stated it, which ADR-0044 decision 2 then
  fixed.
- [`docs/research/260816-st-oef3-assign-datamodel-change-effect.md:420-431`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/docs/research/260816-st-oef3-assign-datamodel-change-effect.md#L420-L431) and
  `docs/plans/260817-st-1xwh-initial-datamodel-binding-effect.md` - the
  origin and design of `Effect.DatamodelInit`, the existing opening effect.
- The upstream discovery is
  `docs/research/260816-sui-t36.1-trace-coverage-spike.md` in statifier-ui,
  GAP 6. It states half (a) and half (b) in the same words the bead carries,
  and its setup section (`:117-123`) records the empirical finding: "passing
  `:subscribers` at start is the only way to see it".
- Sibling beads filed from the same spike, all `mirrors: sui-t36.1`: `st-nbmj`
  (round on core effects, closed, superseded by ADR-0046 via st-xb2b),
  `st-r6l9` (effect order, landed as ADR-0044), `st-fd7n` (P1, open - exposes
  a session's active invocations; its half (b) is "children inherit the
  parent's `:trace` and `:subscribers`", and its note records the deciding
  fact that "a post-hoc attach can never observe a child's initialize burst"),
  `st-ntf5` (P2, open - configuration on the microstep trace effects).
  `st-fd7n` is the sibling closest to this one: whatever is decided here about
  a post-hoc attach applies transitively to a child session's own burst.

## Open Questions

1. **statifier-ui may no longer need half (b) from this repo.**
   `statifier_ui/lib/statifier_ui/trace/subscriber.ex` already builds a
   `session.start` manifest itself, at its own subscription boundary, holding
   the `%Machine{}`: it learns the session id from the first
   `{:statifier, session_id, _}` message rather than calling into the session
   (deliberately, to avoid the st-xbaz start-time deadlock), then emits the
   manifest as `seq: 0`. statifier-ui's ADR-0005 states outright that "the
   producer is statifier-ui code at the subscription boundary holding the
   `%Machine{}` ... so GAP 6 / st-uqo4 is not a precondition for it". The
   sui-t36.1 follow-up also records "Wire format ... was never open ...
   Recording it as open was our error." Under ADR-0025's authority table this
   repo owns the decision about its own files either way, but the stated
   downstream need for half (b) is weaker than the bead's description implies,
   and the mirrored bead sui-t36.1 is closed. This deserves a fresh
   `mirrors:` reconciliation note before anything is scheduled against it.

2. **How a header effect coexists with `result.stream == stream`.** ADR-0046
   rejected a session-side stamp because replay would not reproduce it.
   A header effect minted by the session (which is where `session_id` is
   known - the core may not read a clock or CSPRNG, ADR-0008) faces the same
   objection at [`test/statifier/replay_round_trip_test.exs:109`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/test/statifier/replay_round_trip_test.exs#L109). An effect
   emitted by `Interpreter.initialize/2` would replay naturally, but the core
   cannot mint the session id - though it does already *hold* it, in
   `machine_state.datamodel["_sessionid"]`, written by `SystemVariables` before
   any effect is emitted. Which side emits it, and whether replay reproduces
   it or is exempted, is unresolved by anything currently written down.

3. **What "obtain the effects it missed" means mechanically.** The acceptance
   criterion says a late subscriber "can obtain the effects emitted before it
   attached". Nothing in the repo retains those effects, and ADR-0003 says
   "No pids, adapters, or log buffers live in core state" (that sentence is
   about the *core*, and the session is explicitly the module allowed to hold
   process state - but no ADR sanctions an unbounded retained effect log
   either). Whether the answer is a retained buffer on `%State{}`, a bounded
   one, a `record: true`-gated one, a re-derivation through `Replay.run/1` on
   the session's own recording, or a synthesized catch-up from the current
   `%MachineState{}` rather than the literal historical effects, is open.
   Note that a `Replay`-based answer is only available when the session was
   started with `record: true`, and that replay re-derives rather than
   reproduces `interpret/2`-injected effects verbatim.

4. **Interaction with `st-fd7n` half (b).** If children are to inherit
   `:trace`/`:subscribers`, and if a post-hoc attach can never see a child's
   initialize burst, then whatever mechanism answers half (a) here likely has
   to answer it for child sessions too, or the two beads have to agree on
   which one owns that case. Neither bead currently says.

5. **Does a header effect belong in the vocabulary at all, or is it a new
   message shape?** The subscriber envelope already carries `session_id`
   ([`lib/statifier/session.ex:1591`](https://github.com/riddler/statifier-ex/blob/909682a8349544b52b805b468c6e2f1f0b56b6a8/lib/statifier/session.ex#L1591)), and the existing non-effect message
   shapes are `{:unroutable, _}` and `{:halted, _}`. A `{:hello, _}`-style
   envelope sibling would avoid the `Effect.t()` union, `Effects.plan/2`,
   `Telemetry.effect/3`, `trace?/1`, and the replay stream entirely - at the
   cost of not being a first-class effect for tooling that pattern-matches the
   vocabulary. Nothing written down favors either shape.

6. **`docs/observability.md`'s non-goals list may need re-reading, not
   amending.** It currently disclaims "no trace persistence/rotation story -
   trace effects are handed to the effect interpreter and are its problem." A
   retained buffer inside `Statifier.Session` is arguably exactly the
   persistence story that sentence declines, or arguably not, since the
   session *is* the effect interpreter it names. Whichever reading is taken
   should be stated rather than assumed.
