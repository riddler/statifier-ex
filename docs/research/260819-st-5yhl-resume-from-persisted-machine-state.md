---
date: 2026-08-19T10:47:31-0600
researcher: Claude
git_commit: 2255d9d7079c1aa9f5068738c1b4209e96e56f06
branch: st-5yhl-resume-from-machine-state
repository: statifier-ex
beads_issue: st-5yhl
topic: "Booting a Statifier.Session from a persisted MachineState (resume API)"
tags: [research, codebase, session, interpreter, persistence]
status: complete
last_updated: 2026-08-19
last_updated_by: Claude
---

# Research: Booting a Session from a persisted MachineState (resume API)

**Date**: 2026-08-19T10:47:31-0600
**Git Commit**: 2255d9d7079c1aa9f5068738c1b4209e96e56f06
**Branch**: st-5yhl-resume-from-machine-state
**Bead**: st-5yhl

## Research Question

st-5yhl asks for a `machine_state:` (or `resume:`) option on
`Session.start_link/2` that boots a session at a saved position, a documented
pure-core rehydration path, defined non-restoration semantics for in-flight
delayed sends and live invoked children, and defined composition with
`record: true` and ADR-0049/0050 subscriber catch-up. This document maps what
exists today across all of those surfaces.

## Summary

The data half of resume already exists and is complete; only the API half is
missing, exactly as the bead states.

- **The position contract shipped with st-m5c3.** `Statifier.Position`
  (`lib/statifier/position.ex`) is a full `to_binary/1` / `from_binary/2` pair
  at format version 2, with a chart-identity check on every load, plus an
  `export/1` / `import/2` string-id migration vocabulary. `Statifier.Chart`
  and `Statifier.Machine.Identity` complete it. Nothing in the library feeds
  any of their outputs into a `Session`.
- **`Session.start_link/2` accepts eleven options today, none of which is a
  position.** `init/1` unconditionally calls `Interpreter.initialize/2`, which
  is Appendix D's `interpret(doc)`: it builds a fresh `MachineState.new/2`
  (every counter zero, empty configuration), seeds the datamodel, runs global
  `<script>`, and enters the initial configuration. There is no branch that
  skips that call.
- **The pure core needs no new entry point to be resumed, only a documented
  one.** Every advance-style function (`handle_event/2`, `deliver_internal/5`,
  `cancel/1`, `microstep/1`, `macrostep/1`, `main_event_loop/1`) already takes
  a `MachineState.t()` and trusts it structurally. The Interpreter holds no
  state outside the struct it threads - no process dictionary, no ETS, no
  closures.
- **`%MachineState{}` is genuinely closure-free and complete for the position,
  but not for the driver.** It carries configuration, datamodel, history,
  `entered_states`, `states_to_invoke`, `active_invocations`, the three
  counters (`macrostep`/`microstep`/`round`), the three id counters
  (`invoke_counter`/`send_counter`/`timer_counter`), `running`/`status`, and
  the internal queue. It deliberately carries no pid, no ref, no wall-clock
  reading. What it therefore cannot carry: the external inbox, live timer
  refs, invocation pids/monitors, `routes`, and `invoke_types` (the last two
  are per-drive snapshots a driver re-stamps).
- **Recording and catch-up are both anchored at the chart's initial
  configuration today.** `Recording.new/2` starts with `entries: []` and an
  implicit initialization: replay always begins with
  `Interpreter.initialize(Recording.machine(r), Recording.opts(r))`. There is
  no field on a `Recording` that names a starting position other than the
  chart's own.
- **Timers and invocations are provably non-restorable from a position.**
  `delay_ms` is relative and no scheduling instant is ever stored; timer
  handles are BEAM refs; invocation pids and monitor refs live only in
  `Session.State`. ADR-0054/0055/0059 already assign durable scheduling to the
  host and name st-m5c3 as the dependency this bead consumes.
- **Identity gating has an exact, existing shape to reuse.**
  `Position.from_binary/2` already returns `{:error, {:identity_mismatch,
  expected, actual}}` and `{:error, :unidentified_chart}`. A resume option
  that takes a blob gets the check for free; a resume option that takes an
  already-decoded `%MachineState{}` does not, because that struct carries its
  own `machine` reference and nothing compares it to anything.

## Detailed Findings

### 1. `Session.start_link/2` as it stands

`start_link/2` ([`lib/statifier/session.ex:489-493`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L489-L493)) splits `:name` off for
`GenServer.start_link/3` and passes `{machine, opts}` to `init/1`. Its first
positional argument is pattern-matched `%Machine{}`, so a position cannot be
passed positionally without changing the head.

The complete option set, documented at [`lib/statifier/session.ex:440-487`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L440-L487):

| Option | Default | Read at | Effect |
|---|---|---|---|
| `:name` | - | [`lib/statifier/session.ex:491`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L491) | Passed to `GenServer.start_link/3` |
| `:session_id` | minted | [`lib/statifier/session.ex:747`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L747) | Overrides the `sess_` id |
| `:trace` | `false` | [`lib/statifier/session.ex:755`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L755) | Into `MachineState.new/2` |
| `:datamodel` | `%{}` | [`lib/statifier/session.ex:755`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L755) | Author datamodel, merged under system variables |
| `:max_macrostep_rounds` | `10_000` | [`lib/statifier/session.ex:755`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L755) | ADR-0019 round budget |
| `:subscribers` | `[]` | [`lib/statifier/session.ex:773-777`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L773-L777) | Monitored pids in the effect stream |
| `:record` | `false` | [`lib/statifier/session.ex:783-786`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L783-L786) | Builds a `Recording` |
| `:invoke_source` | `nil` | [`lib/statifier/session.ex:796`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L796) | ADR-0038 `src` resolver |
| `:invoke_handlers` | `%{}` | `lib/statifier/session.ex:751,767,797` | ADR-0051 dispatch map; also derives `invoke_types` |
| `:invoked_by` | `nil` | `lib/statifier/session.ex:750,798` | `{parent_pid, invoke_id}`, set only by the library |
| `:inherit_observers` | `false` | [`lib/statifier/session.ex:799`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L799) | ADR-0050 observation inheritance |

`init/1` ([`lib/statifier/session.ex:746-813`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L746-L813)) runs in this order: resolve the
session id ([`lib/statifier/session.ex:747`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L747)), register it in
`Statifier.Registry` before the first drive so the ADR-0048 route snapshot can
name it ([`lib/statifier/session.ex:748`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L748), rationale at
[`lib/statifier/session.ex:830-856`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L830-L856)), assemble `machine_opts`
([`lib/statifier/session.ex:753-767`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L753-L767)), open the `:initialize` telemetry span,
call `Interpreter.initialize(machine, machine_opts)`
([`lib/statifier/session.ex:771`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L771)), monitor subscribers and the parent, build
the `Recording` if opted in, construct `%State{}`
([`lib/statifier/session.ex:788-800`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L788-L800)), and return a `{:continue, {:initialize,
effects, ...}}` so effects are performed outside `init/1`
([`lib/statifier/session.ex:812`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L812); the deadlock rationale is at
[`lib/statifier/session.ex:802-811`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L802-L811)).

Every field of `%State{}` ([`lib/statifier/session.ex:333-358`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L333-L358)) that is not
`machine_state` is either an option value or a freshly empty value:
`Inbox.new()` ([`lib/statifier/session.ex:791`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L791)), `Timers.new()`
([`lib/statifier/session.ex:792`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L792)), `Invocations.new()`
([`lib/statifier/session.ex:795`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L795)), `timer_refs: %{}`, `deferred: []`,
`halted: nil`, `done_effect: nil`.

The session id is minted by `MachineState.generate_session_id/0`
([`lib/statifier/machine_state.ex:536-550`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L536-L550)) - 48 bits of millisecond timestamp
plus 80 bits of CSPRNG, Crockford base32, ADR-0008. It is stored in three
places: `datamodel["_sessionid"]` (via `SystemVariables.initial/2` in
`MachineState.new/2`, [`lib/statifier/machine_state.ex:504`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L504)), `%State{}.session_id`
([`lib/statifier/session.ex:790`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L790)), and the `Statifier.Registry` key
([`lib/statifier/session.ex:858`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L858)). There is no `session_id` field on
`%MachineState{}`.

**Consequence for resume**: a position carries its own `_sessionid` inside
`datamodel`, minted by the run that produced it. A resumed session that mints
a fresh id would disagree with its own datamodel; a resumed session that reads
the id back out of the position would re-register a previously-used id. Both
behaviors are consistent with existing code; neither is chosen anywhere today.
Note also `%State{}.invoked_by` and `Registry` registration together mean a
resumed session's `routes` snapshot has to be re-stamped, since
`Position.import/2` sets `routes: nil` by design.

### 2. Interpreter entry points and the rehydration path

`Statifier.Interpreter` has one start-from-scratch entry and several
advance-an-existing-position entries.

- `initialize/2` ([`lib/statifier/interpreter.ex:208-278`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L208-L278)) - takes a
  `Machine.t()` plus `MachineState.new/2`'s options, returns
  `{MachineState.t(), [Effect.t()]}`. Cannot fail.
- `handle_event/2` ([`lib/statifier/interpreter.ex:426-451`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L426-L451)) -
  `{:ok, ms, effects} | {:error, :not_running}`.
- `deliver_internal/5` ([`lib/statifier/interpreter.ex:477-496`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L477-L496)) - the ADR-0039
  re-entry seam.
- `cancel/1` ([`lib/statifier/interpreter.ex:859-869`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L859-L869)).
- `microstep/2` ([`lib/statifier/interpreter.ex:879-890`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L879-L890)), `microstep/1`
  ([`lib/statifier/interpreter.ex:940-965`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L940-L965)), `macrostep/1`
  ([`lib/statifier/interpreter.ex:1004-1016`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L1004-L1016)), `main_event_loop/1`
  ([`lib/statifier/interpreter.ex:1210-1213`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L1210-L1213)), `exit_interpreter/1`
  ([`lib/statifier/interpreter.ex:1739-1799`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L1739-L1799)).

What `initialize/2` does that no advance entry does, and that a resumed
position must therefore already reflect rather than redo:

1. Builds the `MachineState` itself - `MachineState.new/2` then
   `begin_macrostep/1` then `begin_microstep/1`
   ([`lib/statifier/interpreter.ex:211-215`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L211-L215)).
2. `Datamodel.initialize/1` ([`lib/statifier/interpreter.ex:240`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L240)) - seeds every
   declared `<data>` id, binds early, or binds only the root's under `late`.
3. `run_global_scripts/2` ([`lib/statifier/interpreter.ex:270`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L270)) - top-level
   `<script>`, spec 5.8, ADR-0026.
4. `enter_states/2` on the synthesized initial transition
   ([`lib/statifier/interpreter.ex:272-273`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L272-L273), `initial_transition/1` at
   [`lib/statifier/interpreter.ex:287-305`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L287-L305)).

Then it calls `main_event_loop/1` ([`lib/statifier/interpreter.ex:275`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L275)), which
is the same tail `handle_event/2` calls at [`lib/statifier/interpreter.ex:448`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L448).

**A rehydration path calls no new function.** The moduledoc already documents
the shape at [`lib/statifier/interpreter.ex:23-41`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L23-L41): keep an earlier
`machine_state`, or "round-trip one through `:erlang.term_to_binary/1` to
resume in another process", then call `microstep/1` on it. What the advance
entries assume of the position they receive, read off their bodies:

- `running`/`status` are meaningful - `false` short-circuits to
  `{:error, :not_running}` in `handle_event/2`, `deliver_internal/5`, and
  `cancel/1`.
- `configuration` is a valid, already-entered full configuration of
  `machine_state.machine` - `cancel/1` reaches `exit_interpreter/1`, which
  walks `Machine.exit_order/2` over it ([`lib/statifier/interpreter.ex:1742`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L1742))
  and resolves each index with `Machine.at/2`
  ([`lib/statifier/interpreter.ex:1765`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L1765)).
- `active_invocations` correctly names what needs cancelling and finalizing -
  `apply_invoke_passes/2` ([`lib/statifier/interpreter.ex:526-544`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L526-L544)) reads it on
  every external event.
- The counters are internally consistent, since every `Trace.*` effect and
  every `Cause` is stamped from them.

None of these functions validates that the position resulted from a legal run.
They trust it and proceed structurally. That is what makes an unguarded resume
the silent-wrong-configuration hazard [`docs/persistence.md:9-30`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/persistence.md#L9-L30) describes.

The Interpreter holds no state outside the threaded struct: no `Process.`,
`:ets.`, `Agent.`, or `Application.get_env` call appears in
`lib/statifier/interpreter.ex`. The one entropy site in the whole core is
`MachineState.generate_session_id/0`
([`lib/statifier/machine_state.ex:529-534`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L529-L534)), inside `new/2`, whose output lands
in the returned struct's `datamodel`.

`Statifier.Replay` (ADR-0034) is the existing precedent for driving the core
outside a session, and it deliberately does **not** rehydrate: `run/1`
([`lib/statifier/replay.ex:184-228`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/replay.ex#L184-L228)) always starts with
`Interpreter.initialize(Recording.machine(recording), Recording.opts(recording))`
([`lib/statifier/replay.ex:204-205`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/replay.ex#L204-L205)) and folds the recording's entries through
`handle_event/2` / `cancel/1` / `deliver_internal/5`. It never constructs a
`%MachineState{}` literal. Before each drive it re-stamps the recorded route
snapshot with `MachineState.put_routes/2`
([`lib/statifier/replay.ex:296-302`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/replay.ex#L296-L302)) - the same re-stamping a resumed session
would owe, since `Position.import/2` leaves `routes: nil`.

### 3. What `MachineState` holds, and whether it is complete

`%MachineState{}` (`lib/statifier/machine_state.ex`) has 21 fields:

- `machine` - the compiled chart this position walks.
- `configuration` - full configuration, ancestors included (ADR-0005); leaf
  states are the derived `active_leaf_states/1`, never a second field.
- `internal_queue` - `:queue.queue(Event.t())`. The **external** queue is
  deliberately absent ([`lib/statifier/machine_state.ex:21-31`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L21-L31)): the core takes
  one external event per call, and the session owns the waiting ones.
- `history_values` - `%{state_index => MapSet.t(state_index)}`.
- `entered_states` - `s.isFirstEntry` moved off the immutable state
  ([`lib/statifier/machine_state.ex:94-126`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L94-L126)), populated unconditionally
  precisely so that a position is complete regardless of the document.
- `states_to_invoke` - Appendix D's `statesToInvoke`
  ([`lib/statifier/machine_state.ex:33-58`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L33-L58)).
- `active_invocations` - `%{{state_index, invoke_index} => invoke_id}`, and
  explicitly **not** the session's pid table
  ([`lib/statifier/machine_state.ex:82-87`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L82-L87): "no pid, no monitor ref, no child
  session id").
- `invoke_counter`, `send_counter`, `timer_counter` - the three session-global
  id sequences (ADR-0008 amendment, ADR-0035, ADR-0059). Each is a pure
  counter specifically so a recorded run and its replay do not diverge
  ([`lib/statifier/machine_state.ex:144-155`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L144-L155)).
- `datamodel` - a map, holding `_sessionid` and the other system variables.
- `running`, `status` - `:running | :done`.
- `macrostep`, `microstep`, `round` - the step counters (ADR-0020, ADR-0046),
  each with exactly one writer ([`lib/statifier/machine_state.ex:242-287`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L242-L287)).
- `trace`, `max_macrostep_rounds` - drive configuration.
- `routes`, `invoke_types` - per-drive/per-session snapshots (ADR-0048,
  ADR-0051), re-stamped by the driver rather than durable position state.

Closure-freedom is a design claim with a test behind it: ADR-0012 item 1
states the struct "fully reifies the between-microsteps position", and
[`docs/observability.md:34-38`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/observability.md#L34-L38) restates it as "any machine_state value is a
complete, inspectable, resumable position". `Statifier.Position.to_binary/1`
relies on that being true - it `term_to_binary`s the struct minus `:machine`
with no scrubbing pass.

**What it is complete for, and what it is not.** It is complete for the
Appendix D position. It is not, and does not claim to be, complete for the
driver: the external inbox (`lib/statifier/session/inbox.ex`), live timers
(`lib/statifier/session/timers.ex` plus `%State{}.timer_refs`), the invocation
table (`lib/statifier/session/invocations.ex`), `invoke_source`,
`invoke_handlers`, subscribers, and the recording all live in
`%Statifier.Session.State{}` ([`lib/statifier/session.ex:333-358`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L333-L358)) and are
outside the struct by design.

`Statifier.Position` sharpens this into a written contract
(`lib/statifier/position.ex`, moduledoc): the exported map omits
`internal_queue`, `routes`, `invoke_types`, and `machine`, and `import/2`
always sets `internal_queue` to a fresh empty queue and `routes`/`invoke_types`
to `nil`, "leaving both for the driver to re-stamp". `export/1` further refuses
a non-empty internal queue outright (`{:error, :internal_queue_not_empty}`),
so the string-id migration path is quiescence-only. `to_binary/1` has no such
restriction and does carry `internal_queue` verbatim.

### 4. Recording and subscriber catch-up

`record: true` is read at [`lib/statifier/session.ex:783-786`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L783-L786) and builds
`Recording.new(machine, machine_opts)`. The struct is
`%Recording{machine, opts, entries: []}`
([`lib/statifier/session/recording.ex:136`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/recording.ex#L136)), where `opts` is a normalized,
sorted subset (`@normalized_opts`,
[`lib/statifier/session/recording.ex:154-162`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/recording.ex#L154-L162), `new/2` at
[`lib/statifier/session/recording.ex:197-212`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/recording.ex#L197-L212)) and `entries` is the session's
serialized input order (six entry shapes,
[`lib/statifier/session/recording.ex:139-146`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/recording.ex#L139-L146), each carrying an ADR-0048 route
snapshot).

Entries are appended by the five input clauses, each before its effects are
planned: [`lib/statifier/session.ex:1050`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1050) (event),
[`lib/statifier/session.ex:1077`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1077) (cancel), [`lib/statifier/session.ex:1083`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1083)
(`interpret/2` batch), [`lib/statifier/session.ex:1102`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1102) (fired timer),
[`lib/statifier/session.ex:1607-1609`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1607-L1609) (invoked event), and
[`lib/statifier/session.ex:1929-1931`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1929-L1931) (internal delivery), all through
`record/2` ([`lib/statifier/session.ex:1994-2003`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1994-L2003)), a no-op when `recording` is
`nil`.

**Initialization is never an entry.** `Interpreter.initialize/2` runs at
[`lib/statifier/session.ex:771`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L771), before `Recording.new/2` is even called, and
produces no `put_*`. The recording's moduledoc states the model directly
([`lib/statifier/session/recording.ex:16-20`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/recording.ex#L16-L20)): `machine` plus "the first
entry's implicit initialization" plus `entries` are the whole of what a run
needs. `Replay.run/1` reconstructs that initialization by calling
`Interpreter.initialize/2` itself. There is no field on `Recording` that could
name a non-initial starting position, and `opts` is `MachineState.new/2`'s
option set, which builds a zeroed position by construction.

Catch-up (ADR-0049) is `subscribe/3` with `catch_up: true`
([`lib/statifier/session.ex:685-718`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L685-L718)). On a recording session it returns
`{:ok, recording}` and adds the pid in the *same* `handle_call`
([`lib/statifier/session.ex:1024-1030`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1024-L1030)); the caller computes the missed prefix
with `Replay.run(recording)` and concatenates the live suffix. On a
non-recording session it returns `{:error, :not_recorded}` and does not add
the pid. There is no cursor, sequence number, or stored buffer: the "position"
in the stream is the callback boundary itself, and the invariant
([`lib/statifier/session.ex:109-117`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L109-L117)) is that replaying the recording taken
inside a callback reproduces exactly the messages notified so far.

**What "anchored at the resumed position" would have to mean, per surface:**

- *Recording*: a recording made by a resumed session cannot be replayed by
  `Replay.run/1` as it stands, because `run/1` begins at
  `Interpreter.initialize/2` and would therefore reproduce the chart's initial
  configuration rather than the resumed one. A recording anchored at a resumed
  position needs the position itself in the recording (or in its blob) and a
  `Replay` entry that starts there.
- *Catch-up*: ADR-0049's invariant is stated in terms of `Replay.run/1` over
  the session's recording. It holds for a resumed session only if the above
  holds - the prefix a late subscriber derives would otherwise be the wrong
  prefix, not a short one.
- *Telemetry*: nothing needs anchoring. Every event carries `session_id` plus
  `macrostep`/`microstep`/`round` read off `%MachineState{}`
  ([`lib/statifier/session/telemetry.ex:642-645`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/telemetry.ex#L642-L645)), and a resumed position
  carries those counters forward, so the stream continues from where it left
  off rather than restarting at zero. Spans are correlated by `make_ref/0`,
  not by `(session_id, macrostep)`
  ([`lib/statifier/session/telemetry.ex:33-63`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/telemetry.ex#L33-L63)), which is what keeps that true
  across a discontinuity.
- *Invoked children* (ADR-0050): `inherit_observers` propagates `:trace` and a
  snapshot of subscriber pids to children
  ([`lib/statifier/session.ex:1685-1694`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1685-L1694)), and deliberately never propagates
  `:record`. A child is therefore never recording, and
  `subscribe(child, pid, catch_up: true)` always answers
  `{:error, :not_recorded}`. Resume does not change this, but it does mean a
  resumed parent's children have no observation history of their own.

### 5. Delayed sends and invoked children: why they cannot be restored

**Delayed sends.** The core emits `{:send_delayed, %Effect.SendDelayed{}}`
([`lib/statifier/effect/send_delayed.ex:25-64`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/effect/send_delayed.ex#L25-L64)), carrying `delay_ms` (relative
milliseconds), `send_id`, the counter triple, and the ADR-0059 `ordinal` minted
from `timer_counter`. `Session.Effects.plan_send_delayed/3`
([`lib/statifier/session/effects.ex:268-288`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/effects.ex#L268-L288)) resolves the route at plan time
and emits the opaque `{:schedule, ...}` instruction.
`perform_instruction({:schedule, ...})` ([`lib/statifier/session.ex:1435-1450`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1435-L1450))
is the library's only `Process.send_after/3` call: it mints a correlation
`make_ref()`, embeds it in the message, stores it in `Timers.put/3`, and stores
the real cancellable timer ref in `%State{}.timer_refs` keyed by the same
correlation ref. `<cancel>` resolves through `Timers.take/2`
([`lib/statifier/session.ex:1452-1456`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1452-L1456)), which reads only this session's own
table - ADR-0035's cross-session collision wall. `terminate/2`
([`lib/statifier/session.ex:1182-1201`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1182-L1201)) cancels every live ref, satisfying spec
6.2's discard-on-termination.

Of all that, only `send_counter` and `timer_counter` are in `%MachineState{}`.
Not restorable from a position, and why:

- **Timer handles** - `reference()` values from `make_ref/0` and
  `Process.send_after/3` are BEAM-local and meaningless in a new process.
- **Deadlines** - `delay_ms` is relative to the scheduling instant, and no
  scheduling instant is recorded anywhere. `%MachineState{}` reads no clock
  (ADR-0034 decision 2 is why), so a position cannot say how much of a delay
  had elapsed.
- **The pending set itself** - `Session.Timers`' `by_id`/`live` maps and
  `%State{}.timer_refs` are GenServer-only.

ADR-0054/0055/0059 already assign this: a durable host consumes the public
effect vocabulary (`SendDelayed`, `Cancel`), keys rows by a cancellation key
`{session scope, send_id}` and an eight-part dedup key ending in `ordinal`,
supplies its own session scope because `send_counter` restarts at 0 per
position, and performs a liveness check at fire time rather than a
cancel-on-shutdown hook. ADR-0055 makes non-self routes (`#_parent`,
`#_invokeid`, `#_internal`) permanently out of scope for durable timers and
defers the external-session route. ADR-0054's Consequences name st-m5c3 as the
dependency for the process-less case - that dependency is now satisfied, and
this bead is where it is consumed.

**Invoked children.** `%MachineState{}.active_invocations` holds only
`{state_index, invoke_index} => invoke_id`. The live table is
`Session.Invocations` ([`lib/statifier/session/invocations.ex:70-76`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/invocations.ex#L70-L76)):
`%{invoke_id => %{type, session_id, pid, monitor_ref, autoforward}}` plus a
`by_pid` reverse index. Entries are written by
`perform_instruction({:start_child, ...})`
([`lib/statifier/session.ex:1466-1471`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1466-L1471) into `start_child/5`), which calls
`Statifier.start_session/2` and `Process.monitor/1`; removed by
`{:stop_child, ...}` ([`lib/statifier/session.ex:1510-1523`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1510-L1523), which casts
`cancel/1` rather than `stop/2` so the child runs its `<onexit>` walk per
6.4.3) and by the `:DOWN` clause ([`lib/statifier/session.ex:1138-1149`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1138-L1149)).
Handler-backed invocations (ADR-0051) have `pid: nil` and are removed through a
`{:pop_invocation, invoke_id}` self-message instead
([`lib/statifier/session.ex:1165-1168`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1165-L1168)).

Not restorable: pids, monitor refs, the child session ids, and the child
processes themselves - each child is a separate `Session` with its own
position. `invoke_source` and `invoke_handlers` are `start_link/2` values (a
closure and a module map), supplied at boot rather than carried. What *is*
carried is the `invoke_id`, deterministically, which is why
[`docs/extending.md:152-160`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/extending.md#L152-L160) already promises that `invoke_id` "stays stable
across a persist/reload cycle" and that handlers must be idempotent on it. The
handler-registry re-establishment path is st-cmq.8's, per the bead.

**The inbox.** `Session.Inbox` ([`lib/statifier/session/inbox.ex:19-39`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/inbox.ex#L19-L39)) holds
waiting external events, invoked events, and the cancel marker, in
`%State{}.inbox`. It is outside `%MachineState{}` for the ADR-0002 mechanical
reason recorded at [`lib/statifier/machine_state.ex:21-31`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L21-L31). Anything queued but
not yet dequeued at persist time is therefore lost with the process, distinct
from `internal_queue`, which is carried.

### 6. Identity gating a resume against a mismatched chart

[`docs/persistence.md:9-30`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/persistence.md#L9-L30) states the hazard exactly: configuration,
`entered_states`, `states_to_invoke`, and history values are MapSets of
interned integer indexes assigned by compiler layout, stable within one
`Machine` build and meaningless across two. A position loaded against a
renumbered chart "still decodes into a valid-looking `MachineState` - they just
name different states than they did yesterday. The machine does not crash; it
silently resumes the wrong configuration."

The existing mechanism, all shipped:

- `Statifier.Machine.Identity` (`lib/statifier/machine/identity.ex`) -
  `%Identity{content_hash, name, version}`, `content_hash` a SHA-256 of the
  **source bytes** (`of_source/2`), with `matches?/2` as the only sanctioned
  comparison and `nil` on either side always `false`. `Statifier.compile/2`
  stamps it, along with `source` and an allowlisted `compile_opts`
  ([`lib/statifier.ex:49`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier.ex#L49): `:invoke_content_markup`, `:chart_name`,
  `:chart_version`), onto every `Machine` it produces. A `Machine` from
  `Compiler.compile/1` directly, or from an `:invoke_source` resolver, carries
  `identity: nil`.
- `Statifier.Position.to_binary/1` refuses `{:error, :unidentified_chart}` for
  an unidentified chart, so no unverifiable position blob can exist.
- `Statifier.Position.from_binary/2` checks, in order: safe decode, envelope
  tag, format version (2, with version 1 upgraded by defaulting
  `timer_counter: 0` per ADR-0059 decision 4), then identity, then rebuilds.
  Errors: `:not_a_statifier_blob`, `{:unsupported_format_version, v}`,
  `{:identity_mismatch, expected, actual}`, `:unidentified_chart`.
- `Statifier.Chart.to_binary/1` / `from_binary/1` bundle source, compile opts,
  and identity, recompiling on load - the two-line composition
  [`docs/persistence.md:153-159`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/persistence.md#L153-L159) models.
- `Statifier.Position.export/1` / `import/2` are the deliberate escape hatch:
  string-id keyed, **no identity check at all**, refusing a non-quiescent
  position and any unnameable state.

**What this implies for the resume API's shape.** The gate is free if resume
takes a blob plus a `Machine`, because `from_binary/2` is that gate. It is
absent if resume takes an already-decoded `%MachineState{}`: that struct
carries its own `machine`, and nothing today compares `machine_state.machine`
against a separately supplied `Machine` or asserts either is identified. A
resume option accepting a bare `%MachineState{}` would let a host that built one
via `import/2` (which is unchecked by design) boot a session on it, which is
either the intended migration flow or the hazard, depending on whether the host
meant it. [`docs/persistence.md:58-71`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/persistence.md#L58-L71) names migration story A - drain on the
old revision - as the default recommendation, which is a resume-adjacent
statement: the recommended way to handle a revision bump is to keep resuming
old positions on the old compiled chart, not to migrate them.

Note one asymmetry worth carrying into the design: `Session.start_link/2` today
accepts any `%Machine{}`, identified or not, and identity is only ever consulted
by the persistence codecs. A resume path is the first place in the session API
where `identity: nil` could become a refusal.

### 7. Prior art in the repo for the API shape

- `Statifier.start_session/2` ([`lib/statifier.ex:220-240`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier.ex#L220-L240)) is the
  runtime-placed alternative to a bare `start_link/2`, building the child spec
  by hand precisely because `Session.start_link/2` is arity-2 positional. Any
  resume entry point that is not an option on `start_link/2` would need the
  same treatment here.
- `Statifier.initialize/2` ([`lib/statifier.ex:149-152`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier.ex#L149-L152)) is the facade's
  pass-through to `Interpreter.initialize/2` and is where a documented
  pure-core rehydration counterpart would naturally sit alongside.
- ADR-0027 decision 4 (`restart: :temporary`) already records that "recovery
  that preserves identity is replay ... and belongs to the embedder or a later
  replay bead, not to a restart flag" - the clearest existing statement that
  session recovery is deliberately not an OTP restart concern.
- ADR-0052's Context (`:16-20`) names this bead's family directly: before
  st-m5c3, "any persistence story built on top of `%MachineState{}` - a resume
  API, the `statifier_persistence` charter - was unsafe by construction."

## Code References

- [`lib/statifier/session.ex:440-493`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L440-L493) - `start_link/2` doc and body; the full option set
- [`lib/statifier/session.ex:746-813`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L746-L813) - `init/1`, the whole boot path
- [`lib/statifier/session.ex:333-358`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L333-L358) - `%Session.State{}`, every runtime-only field
- [`lib/statifier/session.ex:938-1005`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L938-L1005) - `handle_continue` `:initialize` then `:drain`
- [`lib/statifier/session.ex:1024-1034`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1024-L1034) - `subscribe` with and without catch-up
- [`lib/statifier/session.ex:1435-1456`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1435-L1456) - `{:schedule, ...}` and `{:cancel_timers, ...}`
- [`lib/statifier/session.ex:1685-1694`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1685-L1694) - `inherited_observer_opts/1` (ADR-0050)
- [`lib/statifier/session.ex:1994-2003`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session.ex#L1994-L2003) - `record/2`, the recording no-op gate
- [`lib/statifier/interpreter.ex:208-278`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L208-L278) - `initialize/2`, the four initialize-only steps
- [`lib/statifier/interpreter.ex:426-451`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L426-L451) - `handle_event/2`, the advance entry
- [`lib/statifier/interpreter.ex:23-41`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/interpreter.ex#L23-L41) - the moduledoc's term_to_binary resume note
- [`lib/statifier/machine_state.ex:466-515`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L466-L515) - `new/2`, every field's fresh-start value
- [`lib/statifier/machine_state.ex:21-31`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L21-L31) - why the external queue is absent
- [`lib/statifier/machine_state.ex:82-87`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L82-L87) - `active_invocations` is not the session table
- [`lib/statifier/machine_state.ex:536-550`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine_state.ex#L536-L550) - `generate_session_id/0`
- `lib/statifier/position.ex` - the whole position contract: `to_binary/1`, `from_binary/2`, `export/1`, `import/2`
- `lib/statifier/machine/identity.ex` - `of_source/2`, `matches?/2`, the binary envelope
- [`lib/statifier/machine.ex:107-135`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/machine.ex#L107-L135) - `identity`/`source`/`compile_opts` on the Machine
- [`lib/statifier/chart.ex:79-160`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/chart.ex#L79-L160) - the source-plus-identity envelope and its recompile
- [`lib/statifier/replay.ex:184-228`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/replay.ex#L184-L228) - `run/1`, which always starts at `initialize/2`
- [`lib/statifier/session/recording.ex:136-212`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/recording.ex#L136-L212) - the struct, entry shapes, `new/2`
- `lib/statifier/session/timers.ex` - the pure timer table; performs no `Process.*`
- [`lib/statifier/session/invocations.ex:70-76`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/invocations.ex#L70-L76) - the pid/monitor table
- [`lib/statifier/session/inbox.ex:19-39`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/session/inbox.ex#L19-L39) - the external queue that lives outside the core
- [`lib/statifier/effect/send_delayed.ex:25-64`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier/effect/send_delayed.ex#L25-L64) - the durable-timer effect payload
- [`lib/statifier.ex:49`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier.ex#L49) - `@persisted_compile_opts`
- [`lib/statifier.ex:220-240`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/lib/statifier.ex#L220-L240) - `start_session/2`'s hand-built child spec

## Architecture Documentation

- **ADR-0003 / ADR-0012** - the pure core returns `{state, [effect]}` and the
  position is a value. This is the premise the whole bead rests on:
  [`docs/observability.md:34-38`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/observability.md#L34-L38) asserts a `%MachineState{}` is a "complete,
  inspectable, resumable position", and several fields
  (`entered_states`, `states_to_invoke`) are populated unconditionally rather
  than conditionally *because* of that constraint.
- **ADR-0005** - full configuration, interned indexes. The reason a resume
  needs an identity gate at all.
- **ADR-0052** - chart identity (source hash) and position serialization,
  version-then-identity check order, compiled Machine never serialized. The
  st-i7y7 amendment adds `Statifier.Chart`.
- **ADR-0027** - embedder-placed runtime, `restart: :temporary`, recovery is
  replay and not a restart flag.
- **ADR-0034** - replay re-drives the core, never a live session; reads no
  clock.
- **ADR-0035 / ADR-0008 amendment / ADR-0059** - `send_counter`,
  `invoke_counter`, `timer_counter` are pure `%MachineState{}` counters
  precisely so a persisted position replays identically. ADR-0059 bumped
  `Position.format_version` 1 -> 2 for `timer_counter`.
- **ADR-0048 / ADR-0051** - `routes` and `invoke_types` are per-drive snapshots
  the driver stamps. `Position.import/2` nulls both by design.
- **ADR-0049 / ADR-0050 / ADR-0057** - catch-up is transient re-derivation
  from a recording rather than a retained buffer; children inherit trace and
  subscribers by opt-in but never `record`; recordings have their own
  identity-checked codec nesting a chart blob.
- **ADR-0054 / ADR-0055** - durable timer scheduling is the host's, consuming
  the public effect vocabulary; only self-routed delayed sends are durably
  schedulable, and the other routes are permanently or conditionally out of
  scope.

## Historical Context

- [`docs/research/260818-st-m5c3-machine-identity-and-serialization.md:433-437`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/research/260818-st-m5c3-machine-identity-and-serialization.md#L433-L437)
  scopes this bead in advance, naming the `machine_state:`/`resume:` option,
  the two non-restoration classes, and the `record:`/catch-up composition -
  the same four items the bead description carries.
- [`docs/plans/260818-st-m5c3-machine-identity-and-position-serialization.md:206-207`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/plans/260818-st-m5c3-machine-identity-and-position-serialization.md#L206-L207)
  explicitly excludes the resume option from that bead: "`Session.start_link/2`
  gains no `:machine_state` or `:resume` option here - that is st-5yhl, which
  this bead blocks."
- `docs/persistence.md` is the host-facing narrative for all of the above and
  is the natural home for the "what resume does not restore" prose the
  acceptance criteria ask for.
- [`docs/extending.md:152-160`](https://github.com/riddler/statifier-ex/blob/2255d9d7079c1aa9f5068738c1b4209e96e56f06/docs/extending.md#L152-L160) already documents the persist/reload guarantee
  for `invoke_id` and the at-least-once idempotency obligation on handlers -
  prior text a resume section would extend rather than contradict.

## Related Research

- `docs/research/260818-st-m5c3-machine-identity-and-serialization.md` - the
  pre-implementation research for the position/identity contract this bead
  consumes.
- `docs/research/260819-st-rsyx-statifier-oban-charter-durable-timers.md` - the
  durable-scheduler charter that owns the timer half of the non-restoration
  story.
- `docs/research/260818-st-cmq.8-handler-registry-invoke.md` - the invoke
  handler registry the invoked-children half defers to.
- `docs/research/260818-st-uqo4-late-subscriber-trace-and-session-header.md` -
  the ADR-0049 catch-up mechanism resume must compose with.
- `docs/research/260815-st-dtm-replay-recorder-session-boundary.md` - the
  recorder/session boundary a resumed recording would sit on.

## Open Questions

Recorded here rather than resolved; no human was available during this
research stage.

1. **Which argument shape does resume take?** Three are consistent with the
   codebase as it stands: a position blob plus the `Machine`
   (identity-gated for free by `Position.from_binary/2`), an already-decoded
   `%MachineState{}` (no gate exists, and its embedded `machine` is unchecked
   against anything), or both forms. The bead names `machine_state:` or
   `resume:` without deciding. Note `start_link/2`'s head pattern-matches
   `%Machine{}` positionally, so the `Machine` stays a positional argument in
   every shape.

   **Settled (2026-08-19):** both shapes, via one `:resume` option - ADR-0060
   decision 1. A blob goes through `Position.from_binary/2` (identity-gated
   for free); a `%MachineState{}` is checked against the positional
   `%Machine{}` by the same rule, so there is one identity rule rather than
   two. Named `:resume` rather than `machine_state:` because it accepts
   either shape. No `Statifier.resume/2` facade was added.
2. **What is a resumed session's `sess_` id?** The position's `datamodel`
   already carries `_sessionid` from the run that produced it. Reading it back
   re-registers a previously-live id in `Statifier.Registry`; minting a fresh
   one makes `%State{}.session_id` disagree with `datamodel["_sessionid"]`,
   which several surfaces read independently (routes, telemetry, recording's
   `new/2`). ADR-0027 decision 4's "generates a fresh `sess_` id and loses
   every bit of the crashed session's state" is about restarts, not resumes,
   and does not settle it.

   **Settled (2026-08-19):** the position's own `_sessionid` is reused -
   ADR-0060 decision 3. Id continuity is what keeps `#_scxml_<sessionid>`
   addressing working across the deploy or crash that made the resume
   necessary; `register_session/1` already rescues every registration
   failure, so re-registering an id whose holder is dead costs nothing.
   `:session_id` may override it, and doing so rewrites
   `datamodel["_sessionid"]` to agree.
3. **Does a resumed session with `record: true` produce a replayable
   recording?** `Replay.run/1` begins unconditionally at
   `Interpreter.initialize/2`, so a recording made by a resumed session replays
   to the wrong starting configuration unless `Recording` gains the resumed
   position (or its blob) and `Replay` gains a start-here entry. If it does
   not, ADR-0049's catch-up invariant does not hold for a resumed session and
   `catch_up: true` would be answering with a recording whose replay is wrong
   rather than short. Whether that is in scope for this bead or is a follow-on
   is undecided.

   **Settled (2026-08-19):** yes - `Recording` gained an `anchor` field and
   `Replay.run/1` a start-here branch (ADR-0060 decision 6, format version
   1 -> 2, version-1 blobs still decode). Anchoring rather than refusing the
   combination was required by the bead's acceptance criteria. In scope for
   this bead, not a follow-on.
4. **Does resume refuse an unidentified `Machine`?** Every persistence codec
   refuses `identity: nil` with `{:error, :unidentified_chart}`, but
   `Session.start_link/2` accepts any `%Machine{}` today. If resume refuses,
   it is the first session-API refusal on identity, and it makes an
   `:invoke_source`-returned Machine (which is `identity: nil` by
   construction) non-resumable.

   **Settled (2026-08-19):** yes, it refuses - ADR-0060 decision 2, the first
   identity refusal in the session API. Accepted consequence: an
   `:invoke_source`-resolved or `Compiler.compile/1`-built `%Machine{}` is
   not resumable, and a host that wants a resumable chart compiles through
   `Statifier.compile/2`.
5. **What happens to `active_invocations` on resume?** The position says
   invocations are live; the session's `Invocations` table is empty. Options
   visible in the code: leave the divergence (a subsequent `<cancel>` or exit
   sweep finds nothing to stop, silently), clear `active_invocations` on
   resume (which would change position semantics and break `invoke_id`
   stability), or require the host to re-establish through the handler
   registry before the first drive. The bead points at st-cmq.8 for the
   re-establishment path but does not say what the resumed core's own map
   should contain in the meantime.

   **Settled (2026-08-19):** carried forward verbatim; the live process table
   starts empty - ADR-0060 decision 5. Clearing it would change what the
   position means and break `invoke_id` stability. The divergence is safe
   because `{:stop_child, _}` already no-ops on an unknown id, and is
   documented in `docs/persistence.md` rather than left silent.
   Re-establishing the processes stays the host's job (st-cmq.8).
6. **Does resume accept a non-quiescent position?** `Position.to_binary/1`
   carries `internal_queue` verbatim, while `export/1` refuses a non-empty one.
   A resume that accepts a mid-macrostep position needs the counters and the
   queue to drive correctly on the first call; a resume that refuses one is
   stricter than `from_binary/2` currently is.

   **Settled (2026-08-19):** it refuses, with `:position_not_quiescent` -
   ADR-0060 decision 4. Booting mid-macrostep would produce effects with no
   ADR-0048 input boundary behind them. `:resume` is deliberately no more
   lenient than `Position.export/1`. Draining on boot is recorded in the
   plan's "What We're NOT Doing" as a follow-on rather than a quiet
   widening.
7. **Is `Session.interpret/2` (ADR-0029) affected?** It is one of the five
   recordable input paths and re-enters the core directly. Nothing suggests it
   behaves differently after a resume, but it has not been examined against a
   position whose counters did not start at zero.

   **Settled (2026-08-19):** no - ADR-0060's plan proved it rather than
   assuming it. `interpret/2` re-enters through `deliver_internal/5`, which
   increments counters relatively and compares none against zero; a pure-core
   test and a session-level test both assert the effect counter stamps
   continue from the resumed values instead of restarting.
