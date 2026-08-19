---
date: 2026-08-19
planner: Claude
git_commit: 2255d9d7079c1aa9f5068738c1b4209e96e56f06
branch: st-5yhl-resume-from-machine-state
repository: statifier-ex
beads_issue: st-5yhl
topic: "Resuming a Statifier.Session from a persisted position"
status: ready
---

# Resume a Session from a Persisted Position Implementation Plan

## Overview

Give `Statifier.Session.start_link/2` a `:resume` option that boots a session
at a position saved by `Statifier.Position.to_binary/1`, instead of running
`Statifier.Interpreter.initialize/2`; document the pure-core rehydration path
a host that drives `Statifier.Interpreter` directly already has; define what a
resume does *not* restore (in-flight delayed sends, live invoked children, the
external inbox); and make `record: true` plus ADR-0049 subscriber catch-up
compose correctly with a resumed session by anchoring the recording at the
resumed position rather than at the chart's initial configuration.

Beads issue: st-5yhl. The data half shipped with st-m5c3 (`Statifier.Position`,
`Statifier.Chart`, `Statifier.Machine.Identity`); this bead is the API half.

## Current State Analysis

Established by `docs/research/260819-st-5yhl-resume-from-persisted-machine-state.md`,
re-verified against the tree at `2255d9d`:

- **The position contract is complete.** `Statifier.Position.to_binary/1` /
  `from_binary/2` are a format-version-2 pair with an identity check on every
  load, and `export/1` / `import/2` are the string-id migration escape hatch.
  Nothing in the library feeds any of their outputs into a `Session`.
- **`Session.start_link/2` has eleven options, none of them a position**
  (`lib/statifier/session.ex:440-493`). `init/1`
  (`lib/statifier/session.ex:746-813`) unconditionally calls
  `Interpreter.initialize(machine, machine_opts)` at
  `lib/statifier/session.ex:771`. Every other `%State{}` field is an option
  value or a freshly empty value (`Inbox.new()`, `Timers.new()`,
  `Invocations.new()`, `timer_refs: %{}`, `deferred: []`, `halted: nil`).
- **The pure core needs no new function.** Every advance entry
  (`handle_event/2`, `deliver_internal/5`, `cancel/1`, `microstep/1`,
  `macrostep/1`, `main_event_loop/1`) takes a `MachineState.t()` and trusts it
  structurally; the Interpreter holds no state outside the threaded struct.
  What it does *not* have is a public way to re-stamp `invoke_types`:
  `MachineState` exposes `put_routes/2` (`lib/statifier/machine_state.ex:801`)
  and `put_event/2` and nothing else.
- **Recording and catch-up are anchored at the chart's initial
  configuration.** `Recording.new/2`
  (`lib/statifier/session/recording.ex:197-212`) is `%Recording{machine, opts,
  entries: []}` with an implicit initialization, and `Replay.run/1`
  (`lib/statifier/replay.ex:204-205`) unconditionally begins at
  `Interpreter.initialize(Recording.machine(r), Recording.opts(r))`. A
  recording made by a resumed session would therefore replay to the wrong
  starting configuration, which breaks ADR-0049's catch-up invariant for that
  session rather than merely shortening its prefix.
- **Timers and invoked children are provably non-restorable.** `delay_ms` is
  relative and no scheduling instant is stored anywhere; timer handles are
  BEAM refs (`lib/statifier/session.ex:1435-1450` is the library's only
  `Process.send_after/3`); invocation pids and monitor refs live only in
  `Session.Invocations` (`lib/statifier/session/invocations.ex:70-76`).
  ADR-0034/0054/0055/0059 already assign durable scheduling to the host.
- **`{:stop_child, invoke_id}` already tolerates an unknown id silently**
  (`lib/statifier/session.ex:1510-1523`, `Invocations.pop/2` returning `{nil,
  invocations}`), which is what makes carrying `active_invocations` forward
  across a resume safe rather than crash-prone.
- **`%State{}.session_id == machine_state.datamodel["_sessionid"]` is a live
  invariant**, stated by `Session.session_id/1`'s own doc ("This session's
  `sess_` id - `datamodel[\"_sessionid\"]`, held apart for routing") and relied
  on by ADR-0048 route snapshots (`lib/statifier/session.ex:873-900`),
  telemetry (`lib/statifier/session/telemetry.ex:282-293`), and
  `Recording.new/2`'s `opts[:session_id]` contract.
- **Next free ADR number is 0060** (`docs/adr/` ends at
  `0059-per-execution-ordinal-on-durable-timer-effects.md`). ADR-0058's
  `adr-0058-readme-index` check requires the new file and a
  `docs/adr/README.md` table row to land together.

## Desired End State

```elixir
{:ok, machine}      = Statifier.Chart.from_binary(chart_blob)
{:ok, pid}          = Statifier.start_session(machine, resume: position_blob, record: true)
{:ok, recording}    = Statifier.Session.subscribe(pid, self(), catch_up: true)
{:ok, %{stream: s}} = Statifier.Replay.run(recording)
```

- The session comes up at the persisted configuration, datamodel, history
  values, `entered_states`, `states_to_invoke`, `active_invocations`, and all
  six counters, with no `Interpreter.initialize/2` call and no re-entry of the
  chart's initial states.
- `s` is exactly the message prefix that session notified, computed by
  replaying from the anchored position rather than from the chart's initial
  configuration.
- A blob from a different chart revision, an unidentified `Machine`, a
  non-quiescent position, or a terminated position each produce a loud
  `{:error, {:resume, reason}}` from `start_link/2` rather than a
  silently-wrong session.
- `docs/persistence.md` carries the host-facing "Resuming a session" narrative
  including the non-restoration list, and ADR-0060 carries the decisions.

Verified by: the new test modules named per phase, a full green `mix quality`,
and `mix gate.verify`.

### Key Discoveries

- `lib/statifier/session.ex:771` is the single branch point - everything else
  in `init/1` is shared between a fresh start and a resume.
- `lib/statifier/replay.ex:204-205` is the single branch point for anchored
  replay; `Replay`'s entry fold and its `stamp/2` re-stamping
  (`lib/statifier/replay.ex:296-302`) are unchanged by anchoring.
- `Statifier.Position.from_binary/2` *is* the identity gate. A resume that
  takes a blob gets ADR-0052's whole hazard check for free and adds no second
  mechanism.
- `Statifier.start_session/2` (`lib/statifier.ex:220-240`) passes `opts`
  through unchanged, so `resume:` reaches the supervised path with no edit
  there.
- ADR-0002/0003 bound the core: nothing in this plan adds a side effect below
  `session.ex`, and no Appendix D procedure is edited at all. **There is no
  Appendix D deviation in this plan** - `initialize/2` and every advance entry
  keep their pseudocode structure byte for byte; the resume path *skips*
  `interpret(doc)` from outside the core rather than altering it.
- ADR-0005's interned indexes are the reason identity gating is mandatory
  rather than advisory (`docs/persistence.md:9-30`).

## Decisions on the Research Document's Open Questions

The research stage recorded seven open questions and no human was available at
plan time either. Each is answered here, with its grounding. Where an answer
could not be settled from the code and the record, the conservative option
(refuse rather than silently do the surprising thing) is taken and said so.

**OQ-1 - argument shape.** `Session.start_link/2` keeps its `%Machine{}`
positional head and gains one option, `:resume`, accepting **either** a
position blob (`binary()`) or an already-decoded `%MachineState{}`.

- The blob form calls `Position.from_binary(blob, machine)` and inherits the
  full ADR-0052 gate.
- The struct form is the migration path: `Position.import/2` returns a
  `%MachineState{}` whose `machine` *is* the target `Machine`, deliberately
  unchecked (that is what crossing a revision on purpose means,
  `docs/persistence.md` migration story B). The struct form therefore checks
  only that `machine_state.machine` is identified and that its identity
  matches the supplied `machine`'s (`Identity.matches?/2`) - which an
  `import/2` result satisfies by construction, and which a hand-built or
  foreign struct does not. This keeps one rule ("resume runs on an identified
  chart, and the position agrees with it") without re-litigating migration
  story B's deliberate lack of a check.
- Name: `:resume`, not `:machine_state`. The option accepts two shapes, only
  one of which is a `MachineState`, and `machine_state:` would read as the
  struct form only.

**OQ-2 - the resumed session's `sess_` id.** The resumed session **reuses the
position's `datamodel["_sessionid"]`** by default. `:session_id` may be passed
alongside `:resume` to override it, and when it is, the resumed position's
`datamodel["_sessionid"]` is rewritten to agree.

Rationale: `%State{}.session_id == datamodel["_sessionid"]` is an existing,
load-bearing invariant (see Current State), read independently by ADR-0048
route stamping, telemetry, and `Recording.new/2`. Breaking it is strictly
worse than re-registering an id whose previous holder is dead - which is the
normal case for a resume, and which `Statifier.Registry` handles the same way
it handles every other registration outcome (`register_session/1` at
`lib/statifier/session.ex:856-870` rescues and ignores every failure, leaving
the session merely unregistered). Id continuity is also what keeps
`#_scxml_<sessionid>` addressing working across a deploy, which is the whole
point of resuming rather than restarting. ADR-0027 decision 4's "generates a
fresh `sess_` id" is about *restarts* and does not govern this.

**OQ-3 - `record: true` on a resumed session.** In scope, and solved by
anchoring: `Recording` gains an `anchor` field holding a **position blob**
(never a struct, never a `Machine`), and `Replay.run/1` gains a start-here
branch. `Recording.format_version` goes 1 -> 2. Grounding: the bead's
acceptance criteria require resume to compose with `record: true` and catch-up,
so refusing the combination is not available; the blob shape means
`Recording.to_binary/1` needs no new refusal (it already refuses an
unidentified chart) and no compiled `Machine` is written twice; and
`Replay.run/1`'s anchored branch gets the identity check for free by calling
`Position.from_binary(anchor, Recording.machine(recording))`. ADR-0049's
invariant then holds *literally* for a resumed session: a resumed session emits
no initialization effects at all, so its notified prefix is exactly what
anchored replay reproduces.

**OQ-4 - does resume refuse an unidentified `Machine`?** **Yes.** Every
persistence codec in the library refuses `identity: nil`, and the resume path
exists to enforce the ADR-0052 hazard gate; an unverifiable resume is precisely
the silently-wrong-configuration failure `docs/persistence.md:9-30` describes.
The blob form already refuses via `from_binary/2`; making the struct form
refuse identically keeps one rule instead of two. Accepted consequence: a
`Machine` from `Compiler.compile/1` or from an `:invoke_source` resolver is not
resumable. That is correct - an `:invoke_source` child is started by the
library, never resumed by a host, and a host that wants a resumable chart uses
`Statifier.compile/2`. This is the first identity refusal in the session API,
and ADR-0060 records it as such.

**OQ-5 - `active_invocations` on resume.** **Carried forward verbatim**, with
the divergence documented rather than papered over. Clearing it would change
position semantics and break the `invoke_id` stability `docs/extending.md:152-160`
already promises across a persist/reload cycle, and would leave
`active_invocations` disagreeing with `states_to_invoke` and `configuration`.
The divergence is safe today: `{:stop_child, invoke_id}` already treats an
unknown id as a silent no-op (`lib/statifier/session.ex:1510-1523`), so a
`<cancel>` or exit sweep over a not-yet-re-established invocation stops
nothing and crashes nothing. Re-establishing live children is st-cmq.8's
handler-registry path and is out of scope here; the host's obligation is
documented in `docs/persistence.md` and ADR-0060.

**OQ-6 - a non-quiescent position.** **Refused**: `{:error, {:resume,
:position_not_quiescent}}` when `MachineState.internal_queue_empty?/1` is
false. Grounding: `Position.export/1` already refuses one for the same reason,
and the session boot path has no legitimate way to drain a mid-macrostep queue
- draining would produce effects outside any input boundary, and ADR-0048
requires a route snapshot taken *at* an input boundary for every drive. The
driver being stricter than the codec is deliberate and consistent:
`from_binary/2` decodes, `:resume` drives. A host drains to quiescence before
persisting, the same instruction `docs/persistence.md` already gives for
`export/1`. This is a conservative choice; the alternative (drain on boot) is
recorded under "What We're NOT Doing".

**OQ-7 - is `Session.interpret/2` affected?** **No, and this plan proves it
rather than assuming it.** `interpret/2` re-enters through
`Interpreter.deliver_internal/5`, which reads and increments the counters
relatively and compares none of them against zero. Phase 2 adds a pure-core
test driving `deliver_internal/5` on a rehydrated position with non-zero
`macrostep`/`microstep`/`round`/`send_counter`, and Phase 4 adds the
session-level `interpret/2` equivalent, asserting the emitted effects' counter
stamps continue from the resumed values instead of restarting.

**One question the research did not raise, answered the same way**: a position
with `running: false` / `status: :done` is **refused**
(`{:error, {:resume, :position_not_running}}`). Booting a GenServer that is
already terminated, has notified nobody, and has `halted: nil` is the
surprising thing; a host that wants to inspect a finished position does so with
`Position.from_binary/2` and `Statifier.active_leaf_states/1`, no session
needed.

## What We're NOT Doing

- **Not restoring in-flight delayed sends.** No deadline is recoverable from a
  position (ADR-0034 decision 2 is why no clock is read); durable scheduling is
  the host's, consuming the public `SendDelayed`/`Cancel` effect vocabulary
  (ADR-0054/0055/0059). A resumed session starts with `Timers.new()` and an
  empty `timer_refs`.
- **Not restoring live invoked children.** Pids, monitor refs, and child
  session ids are not in a position and cannot be; re-establishment through the
  invoke handler registry is st-cmq.8.
- **Not restoring the external inbox.** `Session.Inbox` is outside
  `%MachineState{}` by ADR-0002's mechanical reason
  (`lib/statifier/machine_state.ex:21-31`); anything queued but not dequeued at
  persist time is lost with the process, and this plan does not change that.
- **Not draining a non-quiescent position on boot** (OQ-6). Considered and
  rejected: it would drive the core outside an input boundary with no ADR-0048
  route snapshot and no recording entry. If a host later needs it, it is a
  follow-on bead with its own record, not a quiet widening of `:resume`.
- **Not adding a `Statifier.resume/2` facade function.** The pure-core
  rehydration path is `Position.from_binary/2` plus any existing advance entry;
  the research established no new core function is needed, and adding a facade
  wrapper for a two-line composition is surface for its own sake. The
  *documentation* of that path is a deliverable (Phase 2); a function is not.
- **Not touching Appendix D.** No interpreter procedure is edited. See "Key
  Discoveries".
- **Not changing `Position`'s own format version.** Nothing about the position
  blob changes; only `Recording`'s envelope gains a field.
- **Not making children resumable.** ADR-0050 children never record and are
  started by the library; `:resume` on an `:invoked_by` session is refused as
  part of the option-conflict check.

## Implementation Approach

Five phases, ordered so no phase leaves dead structure behind: the record
first, then the pure-core half, then the recording anchor (exercised by its own
replay tests without needing the session option), then the session option that
consumes both, then the host-facing narrative and changelog.

Each phase's own moduledoc and `@doc` updates land with that phase's code; only
the cross-cutting host narrative in `docs/persistence.md` is deferred to
Phase 5.

Every new test that asserts `lib/` behavior carries the sabotage line this
project requires (CLAUDE.md, `docs/testing.md`): break the covered code,
confirm red, revert, and record the mutation in a one-line comment above the
test.

---

## Phase 1: ADR-0060, the resume semantics record

### Overview

Record the decisions above before any code cites them, so `mix adr.check` and
the `merge`-profile ADR judge see a decision rather than an assertion.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0060-resuming-a-session-from-a-persisted-position.md`
**Changes**: New ADR, in this repo's existing ADR shape (Context / Decision /
Consequences), recording, as numbered decisions:

1. `Session.start_link/2` gains one `:resume` option accepting a position blob
   or a `%MachineState{}`; the `%Machine{}` stays positional (OQ-1).
2. Resume requires an identified chart and refuses `identity: nil` on either
   side - the first identity refusal in the session API (OQ-4).
3. A resumed session keeps the position's `_sessionid`; `%State{}.session_id`
   and `datamodel["_sessionid"]` stay equal, with `:session_id` rewriting both
   (OQ-2).
4. Resume refuses a non-quiescent position and a terminated position (OQ-6 and
   the unraised sibling question).
5. `active_invocations` is carried verbatim; the process table starts empty;
   re-establishment is the host's via st-cmq.8 (OQ-5).
6. A recording made by a resumed session is anchored at the resumed position -
   `Recording` carries a position blob and `Replay.run/1` starts there -
   which is what keeps ADR-0049's catch-up invariant true (OQ-3).
7. Timers, invoked children, and the external inbox are not restored, and why
   each cannot be (ADR-0034/0054/0055/0059, ADR-0051, ADR-0002).

Consequences must name: `Recording.format_version` 1 -> 2; `:invoke_source`
Machines becoming non-resumable; and that the driver is deliberately stricter
than `Position.from_binary/2`.

#### 2. Dated pointers on the records ADR-0060 amends

**Files**: `docs/adr/0057-recording-identity-and-serialization.md`,
`docs/adr/0049-*.md`
**Changes**: This project's established convention (visible on ADR-0052's and
ADR-0054's status lines, which carry dated pointers to ADR-0057, ADR-0055, and
ADR-0059) is that a record whose decision a new ADR revises gains a dated
pointer on its **status line**, on the same branch that writes the new record -
not deferred until the code lands.

- ADR-0057 decision 4 owns `Recording`'s envelope shape and states that any
  future widening is a format-version decision. ADR-0060 decision 6 is exactly
  that widening, so ADR-0057's status line gains: decision 4's format-version
  door walked through by ADR-0060 (2026-08-19: the envelope gains an `anchor`
  position blob, format version 1 -> 2, version 1 still decodes).
- ADR-0049's catch-up invariant is stated over `Replay.run/1` starting at
  `Interpreter.initialize/2`. ADR-0060 decision 6 preserves the invariant by
  moving where replay starts, so ADR-0049's status line gains a pointer saying
  the invariant now holds over an anchored recording for a resumed session.

Neither record is superseded; both are extended, and the pointers say so.

#### 3. The ADR index

**File**: `docs/adr/README.md`
**Changes**: One table row for ADR-0060, keeping the directory/table bijection
`adr-0058-readme-index` checks.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` is fully green (this phase's gate).
- [x] `mix quality --profile loop` used between edits, never as the phase gate.
- [x] `mix quality --format json --report -` is clean, for a looped runner to
      route on.
- [x] `mix adr.check` reports no `adr-0058-duplicate-number` and no
      `adr-0058-readme-index` finding.
- [x] `mix adr.check` reports no `adr-0058-readme-index` finding after the
      ADR-0057 and ADR-0049 status-line edits (a status-line edit must not
      disturb the README table bijection).
- [x] `mix quality --profile merge` (which re-enables the ADR judge that
      `.quality.exs:23` disables for bare runs) accepts ADR-0060.

#### Manual Verification:
- [ ] Each of the seven decisions is stated as a decision with its own
      rationale, not as a restatement of the plan.
- [ ] No decision contradicts ADR-0002, 0003, 0005, 0012, 0027, 0034, 0048,
      0049, 0050, 0051, 0052, 0054, 0055, 0057, or 0059; each superseded or
      extended record is cited by number.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The pure-core rehydration path

### Overview

Give the driver the one setter it is missing, and document (and test) the
rehydration path a host driving `Statifier.Interpreter` directly already has.
No new core entry point - the research established none is needed.

### Changes Required:

#### 1. `invoke_types` re-stamping

**File**: `lib/statifier/machine_state.ex`
**Changes**: Add `put_invoke_types/2`, an exact sibling of the existing
`put_routes/2` at `lib/statifier/machine_state.ex:801-802`, with a `@spec`, a
`@doc` citing ADR-0051, and the same "per-session snapshot the driver stamps"
framing `put_routes/2` uses for ADR-0048.

```elixir
@doc """
Stamps `invoke_types` onto `machine_state` - ADR-0051's registered-type
snapshot, re-supplied by the driver rather than carried as durable position
state (`Statifier.Position.import/2` sets it `nil` for exactly this reason).
"""
@spec put_invoke_types(machine_state :: t(), invoke_types :: invoke_types()) :: t()
def put_invoke_types(%__MODULE__{} = machine_state, invoke_types),
  do: %{machine_state | invoke_types: invoke_types}
```

#### 2. The documented rehydration path

**File**: `lib/statifier/interpreter.ex`
**Changes**: Extend the moduledoc's existing resume note
(`lib/statifier/interpreter.ex:23-41`, which today mentions `term_to_binary`)
into a named "Rehydrating a position" section stating: use
`Statifier.Position.to_binary/1` / `from_binary/2` rather than raw
`term_to_binary` (the identity check is the point); re-stamp `routes`
(`MachineState.put_routes/2`) and `invoke_types`
(`MachineState.put_invoke_types/2`) before the first drive; then call any
advance entry. Name the four things `initialize/2` does that a resumed position
must already reflect rather than redo (`MachineState.new/2`,
`Datamodel.initialize/1`, `run_global_scripts/2`, `enter_states/2` on the
initial transition), and state that resume skips all four.

#### 3. Tests

**File**: `test/statifier/interpreter_rehydration_test.exs` (new)
**Changes**: Drive a chart to a non-trivial position (history recorded,
counters advanced, datamodel written), `Position.to_binary/1` it,
`from_binary/2` it back against a freshly compiled `Machine` from the same
source, re-stamp routes and invoke_types, and assert:

- `handle_event/2` on the rehydrated position produces the same configuration
  and the same effect stamps as the same event on the un-round-tripped one;
- `deliver_internal/5` at non-zero `macrostep`/`microstep`/`round`/`send_counter`
  emits effects whose counter stamps *continue* rather than restart, and whose
  `send_<counter>` ids do not collide with ids already minted (OQ-7);
- history values survive the round trip and a subsequent history transition
  restores the persisted set, not the initial one.

**File**: `test/statifier/machine_state_test.exs`
**Changes**: A `put_invoke_types/2` test mirroring the existing `put_routes/2`
one.

Every one of these tests carries its sabotage line.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` is fully green (this phase's gate); coverage does not drop.
- [x] `mix quality --profile loop` used between edits, never as the phase gate.
- [x] `mix quality --format json --report -` is clean, for a looped runner to
      route on.
- [x] `mix test test/statifier/interpreter_rehydration_test.exs` passes.
- [x] `mix adr.check` clean - no `Process.`/`:ets.`/clock call is added under
      `lib/statifier/` (ADR-0003).
- [x] Each new test's sabotage line is present and names a real mutation
      (`mix quality`'s sabotage stage checks presence; the mutation itself is
      the manual item below).

#### Manual Verification:
- [ ] **Spec conformance**: the touched functions match the W3C Appendix D
      pseudocode line for line - `put_invoke_types/2` is a driver seam and no
      Appendix D procedure is edited, so the check is that nothing in
      `interpreter.ex` changed except the moduledoc.
- [ ] Each sabotage line was actually performed: the covered code was broken,
      the test went red, and the change was reverted.
- [ ] The moduledoc's rehydration section reads correctly to a host who has not
      read this plan.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: Anchoring a Recording at a position

### Overview

Let a `Recording` say it starts somewhere other than the chart's initial
configuration, and let `Replay.run/1` start there. Fully exercisable on its own:
a test takes a position out of an ordinary session, builds an anchored
recording by hand, and asserts replay reproduces the stream from that position.

### Changes Required:

#### 1. The anchor field

**File**: `lib/statifier/session/recording.ex`
**Changes**:

- Add `anchor` to the struct and to `t()`: `binary() | nil`, a
  `Statifier.Position.to_binary/1` blob. Never a `%MachineState{}` and never a
  `%Machine{}` - the blob keeps the "no compiled term is ever serialized" rule
  (ADR-0052 decision 3) true by construction and needs no new refusal in
  `to_binary/1`.
- `new/2` becomes `new(machine, opts, anchor \\ nil)`; `new/2` callers are
  unaffected.
- Add `anchor/1`, the reader `Replay` uses.
- `@format_version` 1 -> 2; `to_binary/1` writes the anchor into the envelope;
  `from_binary/1` accepts version 2 and reads a version-1 envelope as
  `anchor: nil` (the same read-the-old-version courtesy `Position.from_binary/2`
  extends to its own version 1, ADR-0059 decision 4).
- Moduledoc: an "Anchored recordings" section stating that a recording made by
  a resumed session begins at the anchor, that the anchor is identity-checked
  on replay by `Position.from_binary/2`, and that an anchored recording's
  stream contains no initialization effects because a resumed session performs
  no initialization.

#### 2. Anchored replay

**File**: `lib/statifier/replay.ex`
**Changes**: Split the opening of `run/1` (`lib/statifier/replay.ex:204-205`)
on `Recording.anchor/1`:

```elixir
# nil anchor: today's path, unchanged.
# blob anchor: start at the persisted position instead of interpret(doc).
defp start_state(recording) do
  case Recording.anchor(recording) do
    nil ->
      {machine_state, effects} =
        Interpreter.initialize(Recording.machine(recording), Recording.opts(recording))

      {:ok, machine_state, effects}

    blob ->
      with {:ok, machine_state} <- Position.from_binary(blob, Recording.machine(recording)) do
        {:ok, MachineState.put_invoke_types(machine_state, invoke_types(recording)), []}
      end
  end
end
```

`run/1`'s return type gains the anchor's error arm, propagated unflattened as
`{:error, {:anchor, reason}}` so a caller can tell an anchor identity mismatch
from an `{:unscheduled_timer_firing, _}`. The entry fold, `stamp/2`
(`lib/statifier/replay.ex:296-302`), and the timer-credit bookkeeping are
untouched: an anchored run re-stamps each entry's recorded route snapshot
exactly as an unanchored one does.

Note the anchored branch performs no effects and does not drain before the
first entry - the anchor is quiescent by Phase 4's refusal, and a resumed
session likewise drives nothing before its first input.

#### 3. Tests

**File**: `test/statifier/session/recording_test.exs`
**Changes**: `new/3` carries the anchor; `anchor/1` reads it; `to_binary/1` /
`from_binary/1` round-trip it; a hand-built version-1 envelope decodes with
`anchor: nil`; `format_version/0` is 2.

**File**: `test/statifier/replay_test.exs`
**Changes**: Run an ordinary session part-way, take `Position.to_binary/1` of
its `machine_state`, build `Recording.new(machine, opts, anchor)` and append
entries for the events that follow, then assert `Replay.run/1`'s
`result.stream` and final configuration match what the live session actually
notified from that point - and specifically that the stream does **not** begin
with the chart's initial-configuration entry effects. Plus: an anchor whose
identity does not match the recording's machine returns
`{:error, {:anchor, {:identity_mismatch, _, _}}}`.

All new tests carry sabotage lines.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` is fully green (this phase's gate); coverage does not drop.
- [x] `mix quality --profile loop` used between edits, never as the phase gate.
- [x] `mix quality --format json --report -` is clean, for a looped runner to
      route on.
- [x] `mix test test/statifier/replay_test.exs test/statifier/session/recording_test.exs`
      passes.
- [x] `Recording.format_version/0` returns `2` and a version-1 envelope still
      decodes - asserted by test, not by inspection.
- [x] No new `@tag :skip`, no `test/passing_tests.json` shrink, no
      `.quality.exs` / `.credo.exs` / `coveralls.json` / `.sobelow-conf` /
      `.doctor.exs` edit (so `mix gate.check` needs no
      `docs/quality-gate-changes.md` entry).

#### Manual Verification:
- [ ] **Spec conformance**: no Appendix D procedure is touched; `Replay`'s
      entry fold still drives the core through the same advance entries in the
      same order a live session does.
- [ ] Each sabotage line was actually performed.
- [ ] An anchored recording's blob is inspected once by hand and confirmed to
      contain no compiled `%Machine{}` term (ADR-0052 decision 3).
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 4: The `:resume` option on `Session.start_link/2`

### Overview

The API half. `init/1` branches once, on `:resume`, between
`Interpreter.initialize/2` and a rehydrate-and-stamp path; everything else in
`init/1` is shared.

### Changes Required:

#### 1. Option resolution and refusals

**File**: `lib/statifier/session.ex`
**Changes**: In `init/1`, before the `machine_opts` assembly, resolve `:resume`
into either `:fresh` or `{:resumed, machine_state}`. Refusals return
`{:stop, {:error, {:resume, reason}}}`, so `start_link/2` answers
`{:error, {:resume, reason}}`. The `reason` vocabulary, in check order:

| reason | when |
|---|---|
| `{:conflicting_options, opts}` | `:resume` passed with any of `:trace`, `:datamodel`, `:max_macrostep_rounds` (these are `MachineState.new/2` options and `new/2` is not called on this path, so silently ignoring them is the surprising thing), or with `:invoked_by` (children are library-started, never resumed) |
| `:not_a_statifier_blob` / `{:unsupported_format_version, v}` / `{:identity_mismatch, e, a}` / `:unidentified_chart` | propagated from `Position.from_binary/2` unflattened |
| `:unidentified_chart` | struct form, either side unidentified |
| `{:identity_mismatch, e, a}` | struct form, `Identity.matches?/2` false between `machine_state.machine` and `machine` |
| `:position_not_quiescent` | `MachineState.internal_queue_empty?/1` false (OQ-6) |
| `:position_not_running` | `running: false` or `status: :done` |

Order matters and is documented inline: decode/identity before shape, so a
wrong-revision blob reports the revision rather than a confusing quiescence
error.

#### 2. The resumed boot path

**File**: `lib/statifier/session.ex`
**Changes**: With `{:resumed, machine_state}`:

- `session_id` resolves to `Keyword.get(opts, :session_id)` or
  `machine_state.datamodel["_sessionid"]` (OQ-2); when `:session_id` was
  supplied, rewrite `datamodel["_sessionid"]` to it so the invariant holds.
  `MachineState.generate_session_id/0` is not called on this path.
- `register_session(session_id)` runs exactly as today, before the first drive.
- Instead of `Interpreter.initialize(machine, machine_opts)`:
  `machine_state |> MachineState.put_routes(init_routes(session_id, invoked_by))
  |> MachineState.put_invoke_types(InvokeTypes.new(types: Map.keys(invoke_handlers)))`,
  with `effects = []`. The position's `machine` is replaced by the supplied
  `machine` for the blob form already (that is what `from_binary/2` does); for
  the struct form it is already identity-equal, and is rebound to the supplied
  `machine` so one `Machine` term is shared.
- `Telemetry.init/4` gains a `resumed: boolean()` metadatum (additive; existing
  handlers ignore an extra key), and the macrostep span opened at
  `lib/statifier/session.ex:781` passes trigger `:resume` rather than
  `:initialize` on this path. `Telemetry.macrostep_start/4` and
  `macrostep_stop/*` both spec `trigger :: :initialize | :event | :cancel |
  :internal` (`lib/statifier/session/telemetry.ex:350` and `:380`); both
  typespecs gain `| :resume`, and `Statifier.Session.Telemetry`'s own
  moduledoc (which is where the trigger vocabulary is enumerated -
  `docs/observability.md` does not list trigger values) gains the value.
- `Recording.new/3` is called with the anchor `Position.to_binary!`-equivalent
  of the resumed position. Because Phase 4 refuses an unidentified chart,
  `to_binary/1` cannot fail here; match `{:ok, blob}` and let a `MatchError` be
  the impossible case rather than inventing a third refusal.
- `%State{}` is built exactly as today: `Inbox.new()`, `Timers.new()`,
  `Invocations.new()`, `timer_refs: %{}`, `deferred: []`, `halted: nil`. This
  is the non-restoration, expressed in code.
- The `{:continue, {:initialize, [], start_time, span_ref}}` return is
  unchanged in shape; performing an empty effect list is already a no-op fold.

#### 3. Documentation on the option

**File**: `lib/statifier/session.ex`
**Changes**: `start_link/2`'s `@doc` gains the `:resume` entry - both accepted
shapes, the refusal vocabulary, the `_sessionid` rule, the "what is not
restored" list (timers, invoked children, the inbox) with its ADR citations,
and the note that `active_invocations` is carried forward while the process
table starts empty (OQ-5). Cite ADR-0060.

#### 4. Tests

**File**: `test/statifier/session/resume_test.exs` (new)
**Changes**:

- **Continuity**: run a session to a mid-chart position with history recorded,
  a datamodel write, and advanced counters; persist it with
  `Session.snapshot/1` plus `Position.to_binary/1`; resume on a freshly
  compiled `Machine`; assert configuration (via `Session.status/1`'s
  string-id `configuration`), datamodel, history restoration on a subsequent
  history transition, and all six counters continue rather than restart.
  Note `Session` exposes no `active_leaf_states/1` of its own -
  `Statifier.active_leaf_states/1` over `Session.snapshot/1` is the leaf view.
- **No re-initialization**: the resumed session emits no entry effects for the
  chart's initial states, and a top-level `<script>` that increments a
  datamodel counter has *not* run a second time.
- **Session id**: default resume keeps `datamodel["_sessionid"]` and
  `Session.session_id/1` agrees with it; `:session_id` override rewrites both.
- **Each refusal** in the table above, one test apiece.
- **`interpret/2` after resume** (OQ-7): effect counter stamps continue.
- **`active_invocations`** (OQ-5): a position with a live invocation resumes;
  a transition that exits the invoking state produces no crash and the session
  stays healthy.
- **Timers**: a position persisted with an outstanding delayed send resumes
  with `Timers.new()`; the send never fires; `pending_timers` is 0.
- **`record: true` + catch-up**: resume with `record: true`, drive some events,
  `subscribe(pid, self(), catch_up: true)`, `Replay.run/1` the returned
  recording, and assert the replayed prefix equals the messages a subscriber
  attached at resume time actually received - the ADR-0049 invariant, now over
  an anchored recording.
- **`Statifier.start_session/2`** passes `:resume` through to the supervised
  path unchanged.

All new tests carry sabotage lines.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` is fully green (this phase's gate); coverage does not drop.
- [x] `mix quality --profile loop` used between edits, never as the phase gate.
- [x] `mix quality --format json --report -` is clean, for a looped runner to
      route on.
- [x] `mix test test/statifier/session/resume_test.exs` passes.
- [x] `mix adr.check` clean: the only added I/O is inside `session.ex`, the one
      module ADR-0003 permits it in.
- [x] `mix gate.check` needs no `docs/quality-gate-changes.md` entry (no
      guarded file edited, no `@tag :skip` added, no ratchet shrink).

#### Manual Verification:
- [ ] **Spec conformance**: the touched functions match the W3C Appendix D
      pseudocode line for line - no Appendix D procedure is edited here either;
      `init/1` chooses whether to call `interpret(doc)`, and never alters it.
- [ ] Each sabotage line was actually performed.
- [ ] A resumed session addressed by `#_scxml_<sessionid>` from a second live
      session is reachable at its pre-resume id (exercised by hand once).
- [ ] The refusal messages read as actionable instructions to a host, not as
      internal atoms.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 5: Host-facing narrative and changelog

### Overview

`docs/persistence.md` is the host-facing home for all of this; the acceptance
criteria's "timer and invoke non-restoration semantics are documented" is
satisfied here rather than only in a moduledoc.

### Changes Required:

#### 1. The resume narrative

**File**: `docs/persistence.md`
**Changes**: A new "Resuming a session" section, after "What a host must
persist" and before "Persisting a recording", covering:

- The three-line recipe (`Chart.from_binary/1`, then
  `Session.start_link(machine, resume: blob)`, or the pure-core equivalent for
  a host driving `Interpreter` directly).
- **What resume does not restore**, as its own subsection with a reason per
  item: in-flight delayed sends (no deadline is recoverable; ADR-0034 decision
  2, ADR-0054/0055/0059 assign durable scheduling to the host and name the
  effect vocabulary to consume), live invoked children (pids and monitor refs
  are not position state; `invoke_id` *is* stable across the cycle per
  `docs/extending.md:152-160`, and re-establishment goes through the handler
  registry), and the external inbox (outside `%MachineState{}` by ADR-0002's
  mechanical reason; anything queued but not dequeued is lost).
- The `active_invocations` divergence and the host's obligation (OQ-5).
- The refusal vocabulary as a table, with the fix for each.
- The `_sessionid` rule and why continuity matters for `#_scxml_<sessionid>`
  addressing.
- Resume plus `record: true`: the recording is anchored, `Replay.run/1` starts
  there, catch-up is unchanged for the caller, and an anchored recording's
  stream carries no initialization effects.
- A pointer to ADR-0060.

**File**: `docs/observability.md`
**Changes**: One sentence in the catch-up description noting that a resumed
session's catch-up prefix begins at the resumed position, pointing at
`docs/persistence.md`.

#### 2. Changelog fragment

**File**: `changelog.d/st-5yhl.md` (new)
**Changes**: A user-facing entry - `Session.start_link/2` gains `:resume`;
`Recording` blobs are format version 2 and version 1 still decodes; the
non-restoration list in one line with a pointer to `docs/persistence.md`. This
is a capability v1 never had, so it qualifies under `changelog.d/README.md`'s
"while v2 is unreleased" rule.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` is fully green (this phase's gate). A docs-and-fragment
      change runs the gate anyway; the ADR guard and doc stages are the ones
      with something to say.
- [x] `mix quality --format json --report -` is clean, for a looped runner to
      route on.
- [x] `changelog.d/st-5yhl.md` exists and `CHANGELOG.md` is untouched.
- [x] No `docs/adr/` renumbering: `mix adr.check` still reports no
      `adr-0058-readme-index` finding.

#### Manual Verification:
- [ ] A host who has read only `docs/persistence.md` could resume a session,
      and would know which of their own obligations (timers, children,
      unacknowledged inbox events) they still own.
- [ ] Every non-restoration item names *why* it cannot be restored, not just
      that it is not.
- [ ] The house style of `docs/persistence.md` is matched (its existing
      hyphenation and heading conventions), not converted.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/machine_state_test.exs` - `put_invoke_types/2`, mirroring the
  existing `put_routes/2` test.
- `test/statifier/interpreter_rehydration_test.exs` (new) - the pure-core
  round trip: `handle_event/2` and `deliver_internal/5` on a rehydrated
  position, counter continuation, history survival, and the OQ-7 non-zero-counter
  case.
- `test/statifier/session/recording_test.exs` - anchor carry, codec round trip,
  version-1 backward decode, `format_version/0` is 2.
- `test/statifier/replay_test.exs` - anchored `run/1` reproduces the
  from-the-anchor stream and not the initial-configuration one; anchor identity
  mismatch is `{:error, {:anchor, {:identity_mismatch, _, _}}}`.
- `test/statifier/session/resume_test.exs` (new) - the whole option surface:
  continuity, no re-initialization, session-id rule, every refusal, `interpret/2`
  after resume, `active_invocations` divergence, timer non-restoration, and
  `record: true` plus catch-up.

Key edge cases: a position at `macrostep`/`round` near `max_macrostep_rounds`;
a position whose `history_values` reference a state that is not currently
active; a chart with a top-level `<script>` (must not re-run); a position
carrying a `send_counter` above zero (minted ids must not collide); a resumed
session that immediately receives `cancel/1` (exit sweep over the resumed
configuration).

Every one of these tests carries its sabotage line in the format
`docs/testing.md:190` fixes - `# sabotage: <what was broken> -> red`, one line,
present tense, above the test - and the mutation is actually performed
(break the covered code, confirm red, revert), per CLAUDE.md and
`docs/testing.md:169-196`. Note `mix quality`'s sabotage scan only checks the
note exists (`docs/testing.md:209-210`), so performing the mutation is the
manual criterion each phase carries, not something the gate can decide. No corpus test is
touched, so `test/passing_tests.json` does not move.

### Manual Testing Steps:

1. Compile a chart with `Statifier.compile/2`, start a session, drive it to a
   mid-chart configuration, take `Statifier.Session.snapshot/1` and
   `Position.to_binary/1` it, stop the session.
2. In a fresh IEx, `Statifier.Chart.from_binary/1` the chart blob and
   `Statifier.start_session(machine, resume: position_blob)`; confirm
   `Statifier.Session.status/1`'s `configuration` matches the pre-persist
   configuration and that no `<onentry>` side effect of the initial states
   re-ran.
3. Recompile the chart with one state added, and confirm the same resume now
   returns `{:error, {:resume, {:identity_mismatch, _, _}}}` rather than a
   running session.
4. Resume with `record: true`, drive three events, `subscribe(pid, self(),
   catch_up: true)` from a second process, and confirm
   `Replay.run(recording).stream` starts at the resumed configuration.
5. Persist a position with an outstanding `<send delay="...">` and confirm the
   resumed session's `pending_timers` is 0 and the event never arrives.
6. From a second live session, `<send target="#_scxml_<id>">` to the resumed
   session's pre-resume id and confirm delivery.

## Corpus/Ratchet Notes

This plan touches no conformance fixture and changes no SCXML semantics, so
`test/passing_tests.json` does not move and `mise run corpus` is not run. If a
phase unexpectedly changes a conformance result, that is a defect in that
phase, not a ratchet update: `mix test.regression` must stay green without
`mix test.baseline add`.

## References

- Source document: `docs/research/260819-st-5yhl-resume-from-persisted-machine-state.md`
- Related ADRs: `docs/adr/0002-*`, `0003-*`, `0005-*`, `0012-*`, `0027-*`,
  `0034-*`, `0048-*`, `0049-*`, `0050-*`, `0051-*`, `0052-*`, `0054-*`,
  `0055-*`, `0057-*`, `0059-*`; new: `docs/adr/0060-resuming-a-session-from-a-persisted-position.md`
- Host narrative: `docs/persistence.md`, `docs/extending.md:152-160`
- Similar implementation: `lib/statifier/replay.ex:184-228` (driving the core
  outside a session), `lib/statifier/session.ex:746-813` (`init/1`)
- Prior plan that scoped this bead out: `docs/plans/260818-st-m5c3-machine-identity-and-position-serialization.md:206-207`
- Bead: st-5yhl (depends on st-m5c3, blocks st-q6xl and st-ewd7)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Each of the seven decisions is stated as a decision with its own
      rationale, not as a restatement of the plan.
- [ ] No decision contradicts ADR-0002, 0003, 0005, 0012, 0027, 0034, 0048,
      0049, 0050, 0051, 0052, 0054, 0055, 0057, or 0059; each superseded or
      extended record is cited by number.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [ ] **Spec conformance**: the touched functions match the W3C Appendix D
      pseudocode line for line - `put_invoke_types/2` is a driver seam and no
      Appendix D procedure is edited, so the check is that nothing in
      `interpreter.ex` changed except the moduledoc.
- [ ] Each sabotage line was actually performed: the covered code was broken,
      the test went red, and the change was reverted.
- [ ] The moduledoc's rehydration section reads correctly to a host who has not
      read this plan.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 3

- [ ] **Spec conformance**: no Appendix D procedure is touched; `Replay`'s
      entry fold still drives the core through the same advance entries in the
      same order a live session does.
- [ ] Each sabotage line was actually performed.
- [ ] An anchored recording's blob is inspected once by hand and confirmed to
      contain no compiled `%Machine{}` term (ADR-0052 decision 3).
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 4

- [ ] **Spec conformance**: the touched functions match the W3C Appendix D
      pseudocode line for line - no Appendix D procedure is edited here either;
      `init/1` chooses whether to call `interpret(doc)`, and never alters it.
- [ ] Each sabotage line was actually performed.
- [ ] A resumed session addressed by `#_scxml_<sessionid>` from a second live
      session is reachable at its pre-resume id (exercised by hand once).
- [ ] The refusal messages read as actionable instructions to a host, not as
      internal atoms.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 5

- [ ] A host who has read only `docs/persistence.md` could resume a session,
      and would know which of their own obligations (timers, children,
      unacknowledged inbox events) they still own.
- [ ] Every non-restoration item names *why* it cannot be restored, not just
      that it is not.
- [ ] The house style of `docs/persistence.md` is matched (its existing
      hyphenation and heading conventions), not converted.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---
