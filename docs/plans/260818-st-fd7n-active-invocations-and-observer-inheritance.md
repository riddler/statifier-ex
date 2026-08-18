# Active Invocations and Observer Inheritance Implementation Plan

## Overview

`Statifier.Session` holds its invocation table privately, and a child session
started for an `<invoke>` gets neither the parent's `:trace` setting nor the
parent's subscribers. An observer of a parent therefore sees `Effect.Invoke`,
`Trace.InvokePass`, and later `done.invoke.<id>`, but nothing the child itself
did, and it cannot even name the child: the child's `session_id` is recoverable
only by scraping `origin: "#_scxml_sess_..."` off an event the child happened to
send back.

This plan lands both halves the bead asks for: a public accessor naming a
session's live invocations, and a documented, opt-in, transitively inherited
start option that starts each invoked child with the parent's `:trace` and
subscriber set. It also records the inheritance decision as ADR-0049 and folds
the invoke tree into `docs/observability.md` constraint 6, which today describes
observation at a single session boundary only. Bead: st-fd7n.

## Current State Analysis

**The table exists and is already pure.** `Statifier.Session.Invocations`
(`lib/statifier/session/invocations.ex`) is an opaque struct holding
`invoke_id => %{session_id, pid, monitor_ref, autoforward}` plus a `pid =>
invoke_id` reverse index. It already exposes `entries/1`
(`lib/statifier/session/invocations.ex:127`), `invoke_ids/1`
(`lib/statifier/session/invocations.ex:123`), `fetch/2`, `count/1`, `live?/2`,
`pop/2`, and `pop_by_pid/2`. It is deliberately a pure map transformation with
no process calls, which is what keeps `Mix.Statifier.AdrGuard`'s
`@effect_interpreter_paths` at its short list.

**Nothing reads it from outside the session.** `%Session.State{}` carries
`invocations: Invocations.new()` (`lib/statifier/session.ex:305`), and every
read is internal: `{:forward, _, _}`, `{:stop_child, _}`, `#_<invokeid>`
routing, and the drain-time discard. `Statifier.Session`'s client section
(`lib/statifier/session.ex:405-537`) has `session_id/1`, `recording/1`,
`snapshot/1`, `status/1`, `subscribe/2`, `unsubscribe/2`, `stop/2` - no
invocation accessor. The existing tests reach the table through
`:sys.get_state(parent)` (`test/statifier/session/invoke_start_child_test.exs:95`,
`:419`), which is the shape of the gap.

**Children are started with a fixed, three-key option list.**
`start_child/5` (`lib/statifier/session.ex:1269`) seeds the child datamodel and
calls the private `start_session/3` (`lib/statifier/session.ex:1302`), which
calls `Statifier.start_session(machine, invoked_by: {self(),
invoke.invoke_id}, datamodel: datamodel)`. No `:trace`, no `:subscribers`. The
child's own `init/1` takes `:trace`, `:datamodel`, and `:max_macrostep_rounds`
into the `MachineState.new/2` option list (`lib/statifier/session.ex:551`) and
monitors each pid in `:subscribers` (`lib/statifier/session.ex:560-563`), so
both values already have a working entry point; nothing hands them down.

**A post-hoc attach cannot substitute for inheritance.**
`Session.start_link/2` runs `Interpreter.initialize/2` inside `init/1`
(`lib/statifier/session.ex:558`) and performs the resulting effects from
`handle_continue({:initialize, ...}, _)`, and the child is started from inside
the parent's own invoke pass. By the time any accessor can name the child's
pid, the child's `Trace.EntrySet`, `Trace.ContentExecuted`,
`Trace.InvokePass`, and `Trace.MacrostepStable` have already been notified to
whatever subscribers it had at start. That empirical fact - recorded on the
bead's 2026-08-16 note as input from statifier-ui's sui-t36.1 follow-up - is
why both halves land and neither replaces the other.

**The parent's own trace flag is readable.** `%MachineState{}` carries `trace`
as a plain boolean set in `new/2` and read-only thereafter
(`lib/statifier/machine_state.ex:355`, `:416`, `:469`), so
`state.machine_state.trace` is the parent's setting with no new field.

**Subscribers are a monitored map.** `%Session.State{}.subscribers` is
`%{pid() => reference()}` (`lib/statifier/session.ex:302`), added at start from
`:subscribers` and maintained by `subscribe/2`/`unsubscribe/2`
(`lib/statifier/session.ex:805-825`). `notify/2`
(`lib/statifier/session.ex:1590`) sends `{:statifier, session_id, message}` to
each. The `session_id` in that envelope is what demultiplexes a mixed
parent-and-child stream - `Statifier.StreamOrder.drain/1`
(`test/support/stream_order.ex:47`) already pins it.

**Documents that must move.** `docs/observability.md` constraint 6's
Observation bullet (`docs/observability.md:177-186`) describes observation at
one session boundary and says nothing about the invoke tree;
`docs/architecture.md:140-147` describes exactly the child-start call this plan
extends. ADR-0027 decision 3 (`docs/adr/0027-embedder-placed-session-runtime.md:116-142`)
established the invocation table and the monitor topology but says nothing
about what a child inherits or about `Statifier.Session`'s public surface.

## Desired End State

`Statifier.Session.invocations/1` returns this session's live invocations as a
list of `%{invoke_id: String.t(), session_id: String.t(), pid: pid()}`, sorted
by `invoke_id`. `Statifier.Session.start_link/2` (and therefore
`Statifier.start_session/2`) accepts `:inherit_observers`, default `false`;
when `true`, every child this session starts for an `<invoke>` is started with
this session's `:trace` value, this session's current subscriber pids, and
`inherit_observers: true` of its own, so the inheritance runs the whole depth of
the invoke tree. With the option absent or `false`, every observable behavior is
byte-for-byte what it is today.

Verified by: `mix quality` green; the new tests in
`test/statifier/session/invocations_test.exs`,
`test/statifier/session/invoke_start_child_test.exs`, and a new
`test/statifier/session/invoke_observer_inheritance_test.exs`; and by hand, a
parent started with `trace: true, subscribers: [self()], inherit_observers:
true` over a document whose `<invoke>` starts a child that itself invokes a
grandchild, where the caller's mailbox holds `Trace.EntrySet` under all three
session ids.

### Key Discoveries:

- `Invocations` already exposes `entries/1` and `invoke_ids/1`
  (`lib/statifier/session/invocations.ex:123-127`), so the accessor needs one
  more pure projection there and one `handle_call` clause in the session - no
  change to the table's shape or to who writes it.
- The child-start option list is built in exactly one place, the private
  `start_session/3` (`lib/statifier/session.ex:1302`), so inheritance has a
  single insertion point.
- `Interpreter.initialize/2` runs inside `init/1`
  (`lib/statifier/session.ex:558`), so a child's initialize burst is
  unrecoverable by any later attach - the reason half (b) is not redundant
  with half (a).
- ADR-0012 and `docs/observability.md` constraint 6 make observation a binding
  seam, and `mix adr.judge` (merge profile only) judges `lib/statifier` against
  ADR-0012, so the observability document must move with the code rather than
  after it.
- `Mix.Statifier.AdrGuard`'s `adr-0018-bead-id` check flags a bead id added in
  any comment, `@doc`, `@moduledoc`, `@typedoc`, or `test "..."` description
  under `lib/` or `test/`, and clears only on the literal marker
  `ADR-0018-exempt`. No phase below may write `st-fd7n` into code or tests.
- The sibling worktree `st-uqo4-late-subscriber-trace` is live on the same
  `area:interpreter` label and edits `lib/statifier/session.ex` too; both
  branches are off the same `origin/main` commit today.

## What We're NOT Doing

- **Not propagating `subscribe/2`/`unsubscribe/2` down the tree.** Inheritance
  is a snapshot taken when the child starts. A pid that subscribes to the
  parent afterwards is not added to already-running children, and one that
  unsubscribes is not removed from them. A live link would need the parent to
  hold and fan out over its whole descendant set on every subscription change,
  which is a distributed-subscription mechanism this bead has no caller for;
  the accessor is the supported way to reach an already-running child and
  `subscribe/2` it directly.
- **Not inheriting `:record`, `:invoke_source`, `:max_macrostep_rounds`, or
  `:datamodel`.** `:record` builds a per-session recording whose replay
  contract (ADR-0029, ADR-0034) is defined for one session's inputs, not a
  tree's; `:datamodel` is already governed by 6.4.3's name-matched seeding;
  `:invoke_source` not descending is a real gap (a grandchild's `<invoke
  src="...">` cannot resolve today) but it is an ADR-0038 question about who
  resolves sources, not an observability one, and it belongs on its own bead.
- **Not backfilling missed effects to a late subscriber.** That is st-uqo4's
  half (a), in a live sibling worktree. This plan neither depends on it nor
  forecloses it.
- **Not exposing `monitor_ref` or `autoforward`** on the accessor. The monitor
  ref is the parent's own handle on a process it owns and hands a caller
  nothing it can act on safely; `autoforward` is an `<invoke>` attribute
  already readable off `Effect.Invoke` on the effect stream. The accessor
  answers "which sessions are running under me, and what are they called",
  which is the session-tree question the bead names.
- **Not adding a telemetry event** for either half. ADR-0040 defines the
  `[:statifier, :session, ...]` contract over effects and lifecycle; a
  synchronous read of a table emits nothing, and an inherited child already
  emits its own `[:statifier, :session, :init]` event.
- **Not renaming or re-typing `Invocations.entry/0`.** The internal entry keeps
  `monitor_ref` and `autoforward`; the public projection is a separate,
  narrower map.

## Implementation Approach

Three phases, ordered decision-then-code, each independently committable and
each green on a full `mix quality` on its own.

Phase 1 is documents only: ADR-0049 records the inheritance decision and its
`docs/adr/README.md` row. Writing it first is what this repo's workflow asks for
(`docs/workflow.md`: ADRs are drafted or reviewed at the direction level, and
there is no `proposed` state - the human gate is the review of the branch the
ADR lands on), and it means the two code phases cite a number rather than
re-arguing a decision inside a moduledoc.

Phase 2 lands half (a) - a pure projection on `Invocations` plus one client
function and one `handle_call` clause - together with the
`docs/observability.md` seam-table row it earns. It is purely additive; nothing
existing changes behavior.

Phase 3 lands half (b) - one `%State{}` field, one `init/1` read, and an
inherited option list at the single child-start site - together with the
`start_link/2` `@doc`, the session moduledoc paragraph, and the prose edits to
`docs/observability.md` constraint 6 and `docs/architecture.md`.

Both code phases touch `lib/statifier/session.ex`, which the live
`st-uqo4-late-subscriber-trace` worktree also edits. That is a rebase concern at
`/wurk:mr` time, not a design one: neither half of this bead reads or writes the
subscriber *delivery* path, only the set's membership at child start.

The Appendix D rule (ADR-0002) is satisfied vacuously here: no phase touches an
Appendix D procedure. `Interpreter.initialize/2`, `microstep/1`, and the invoke
pass are untouched; every change is in `Statifier.Session`, the effect
interpreter, and in a pure table module the spec has no counterpart for. There
is no deviation to declare.

## Phase 1: Record the inheritance decision as ADR-0049

### Overview

Write the ADR that both code phases cite, and its README row. Documents only -
no Elixir changes, so nothing in the gate can move.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0049-invoked-children-inherit-observation-by-opt-in.md`
**Changes**: New record, in the three-section format
(`## Context`, `## Decision`, `## Consequences`), `# ADR-0049: ...` on line 1
and `Status: accepted (2026-08-18)` on line 3.

`## Context` states the gap - a child's effects reach only the child's own
subscribers, so a parent's observer sees `Effect.Invoke`, `Trace.InvokePass`,
and `done.invoke.<id>` and nothing else about the child - and the deciding
empirical fact: `Session.start_link/2` runs `Interpreter.initialize/2` to
quiescence inside `init/1` (`lib/statifier/session.ex:558`) with the child
started from inside the parent's invoke pass, so an attach performed after the
child's pid is knowable can never observe that child's initialize burst. Cite
ADR-0027 decision 3 for the table and monitor topology this builds on,
ADR-0012 and `docs/observability.md` constraint 6 for the seam being widened,
and ADR-0029 for why `:record` is not in the inherited set.

`## Decision`, six numbered points:

1. **The accessor is public and narrow.** `Statifier.Session.invocations/1`
   returns `[%{invoke_id, session_id, pid}]` sorted by `invoke_id`. Not
   `monitor_ref` (the parent's own handle on a process it owns), not
   `autoforward` (an `<invoke>` attribute already on `Effect.Invoke`). Sorted
   rather than "in no particular order", because the caller is a session-tree
   pane and an order that reshuffles between reads is a defect in that use.
2. **Inheritance is opt-in and defaults to off.** `:inherit_observers` on
   `start_link/2`, default `false`. A default-on inheritance would start
   sending a parent's existing subscribers a second session's stream on an
   upgrade, which is a behavior change no caller asked for; today's behavior is
   preserved exactly.
3. **What is inherited is `:trace` and the subscriber set, and nothing else.**
   Not `:record` (its replay contract, ADR-0029/ADR-0034, is defined per
   session), not `:invoke_source` (an ADR-0038 question about who resolves
   sources), not `:max_macrostep_rounds`, not `:datamodel` (6.4.3 governs it).
4. **Inheritance is transitive.** The child is started with
   `inherit_observers: true` in its own options, so the flag descends the whole
   invoke tree from one opt-in at the root.
5. **Inheritance is a snapshot at child start, not a live link.** The child
   gets the parent's subscriber pids as of the moment `{:start_child, _, _}` is
   performed. Later `subscribe/2`/`unsubscribe/2` on the parent do not
   propagate; reaching an already-running child is decision 1's accessor plus
   `subscribe/2` on the child.
6. **The accessor and the option are not substitutes.** Point 5's escape hatch
   is not equivalent to inheritance, by the Context's empirical fact: an attach
   through the accessor is necessarily after the child has initialized. Both
   ship.

`## Consequences` covers: a subscriber of an inheriting parent now receives
messages under session ids it did not subscribe to and must demultiplex on the
envelope's `session_id` (which statifier-ui's own ADR-0005 already designs for);
`{:halted, _}` remains end-of-stream *per session id* rather than for the
mailbox as a whole, so ADR-0044 decision 2 is unchanged but is now read
per-stream; `mix adr.judge`'s ADR-0012 scope covers the changed files, and
`docs/observability.md` constraint 6 grows the invoke-tree sentence in Phase 3;
and the reopen trigger is a caller that genuinely needs live subscription
propagation, which would supersede decision 5 rather than amend it.

#### 2. The index row

**File**: `docs/adr/README.md`
**Changes**: One table row after 0048.

```
| [0049](0049-invoked-children-inherit-observation-by-opt-in.md) | Invoked children inherit the parent's observers by opt-in; the invocation table gets a public accessor | accepted |
```

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating,
      but a loop-profile green never satisfies this phase).
- [x] `docs/adr/0049-invoked-children-inherit-observation-by-opt-in.md` exists,
      line 1 is `# ADR-0049: ...`, line 3 begins `Status: accepted (`, and it
      contains exactly the headings `## Context`, `## Decision`,
      `## Consequences`.
- [x] `docs/adr/README.md` contains a row linking
      `0049-invoked-children-inherit-observation-by-opt-in.md`.
- [x] `git diff --name-only origin/main` for this phase names no path under
      `lib/` or `test/`.

#### Manual Verification:

- [x] The six decision points read as decisions with reasons, not as a
      restatement of the plan, and each rejected alternative names why it was
      rejected rather than only that it was.
- [ ] (outstanding - human/direction gate) The ADR is reviewed at the direction level per `docs/workflow.md` before
      the branch is opened for merge.
- [x] No regressions in related features: nothing outside `docs/` changed.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: A public accessor for live invocations

### Overview

Half (a). Add a pure public projection to `Statifier.Session.Invocations`, the
client function and `handle_call` clause on `Statifier.Session`, and the
`docs/observability.md` seam-table row.

### Changes Required:

#### 1. The pure projection

**File**: `lib/statifier/session/invocations.ex`
**Changes**: One `@typedoc`'d public type and one function, beside the existing
`invoke_ids/1`/`entries/1` pair. Keeping the projection here rather than in
`Statifier.Session` is what lets the struct stay `@opaque`: the session already
reads this table only through its API.

```elixir
@typedoc """
The public projection of one live invocation - `invoke_id` plus the child's
own session id and pid, and deliberately not the parent's `monitor_ref` or
the `<invoke autoforward>` flag (ADR-0049 decision 1).
"""
@type public_entry :: %{invoke_id: String.t(), session_id: String.t(), pid: pid()}

@doc """
Every live invocation as its public projection, sorted by `invoke_id` - a
stable order across reads, which `invoke_ids/1`'s map-key order is not
(ADR-0049 decision 1).
"""
@spec list(invocations :: t()) :: [public_entry()]
def list(%__MODULE__{entries: entries}) do
  entries
  |> Enum.map(fn {invoke_id, %{session_id: session_id, pid: pid}} ->
    %{invoke_id: invoke_id, session_id: session_id, pid: pid}
  end)
  |> Enum.sort_by(& &1.invoke_id)
end
```

#### 2. The client function and callback

**File**: `lib/statifier/session.ex`
**Changes**: A `@type invocation` beside the existing `@type status`
(`lib/statifier/session.ex:346-359`), a client function beside `status/1`
(`lib/statifier/session.ex:510`), and a `handle_call` clause beside the
`:status` one (`lib/statifier/session.ex:795`).

```elixir
@typedoc """
One live invocation, as `invocations/1` reports it: the author-or-core
`invoke_id` this session knows the invocation by, the child's own `sess_`
id, and its pid.
"""
@type invocation :: Statifier.Session.Invocations.public_entry()

@doc """
This session's live invocations - one entry per `<invoke>` whose child
session is still running under it, sorted by `invoke_id`, and `[]` for a
session with none. The counterpart to `status/1` for the invoke tree: an
observer holding a parent can name each child and `subscribe/2` to it, or
recurse with `invocations/1` again for a grandchild.

An entry is present from the moment the child is started until the
invocation is cancelled or the child exits - the same liveness
`#_<invokeid>` routing is judged against. A caller reading this against a
running session is reading a value that may already have changed; it is a
snapshot, not a subscription.

A child started before this session opted into `:inherit_observers` (or
one under a session that never did) has its own subscriber set, so
attaching to it here observes it only from the moment of the
`subscribe/2` - see `start_link/2`'s `:inherit_observers` for the reason
that is not equivalent to inheriting from the start (ADR-0049).
"""
@spec invocations(server :: server()) :: [invocation()]
def invocations(server), do: GenServer.call(server, :invocations)
```

```elixir
def handle_call(:invocations, _from, state) do
  {:reply, Invocations.list(state.invocations), state}
end
```

#### 3. The observability seam row

**File**: `docs/observability.md`
**Changes**: One row in the "Where the seams live" table
(`docs/observability.md:218-231`).

```
| the session's live invocations are nameable from outside it, so an observer can walk the invoke tree | `Statifier.Session.invocations/1`, `Statifier.Session.Invocations.list/1` |
```

#### 4. Changelog fragment

**File**: `changelog.d/st-fd7n.md`
**Changes**: New file, `### Added` section, one bullet for the accessor.
(A fragment filename is a path, not a code comment, so the ADR-0018 bead-id
check does not apply to it.)

#### 5. Tests

**File**: `test/statifier/session/invocations_test.exs`
**Changes**: A `describe "list/1"` block covering the pure projection - empty
table returns `[]`; a table with three entries returns exactly the three keys
`:invoke_id`, `:session_id`, `:pid` per entry and neither `:monitor_ref` nor
`:autoforward`; the result is sorted by `invoke_id` regardless of insertion
order. Each test carries its sabotage line.

**File**: `test/statifier/session/invoke_start_child_test.exs`
**Changes**: One test asserting `Session.invocations(parent)` names the same
`invoke_id`, `session_id`, and `pid` that `:sys.get_state(parent)` shows, and
one asserting the entry disappears after the invocation is cancelled. Model it
on the existing `"starts a real child session, monitored, with one table
entry"` test (`test/statifier/session/invoke_start_child_test.exs:87`) and the
cancellation tests in `test/statifier/session/invoke_cancel_test.exs`, reusing
each module's own `compile!/1`, `content_body/0`, and `wait_for_status/3`.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating;
      a loop-profile green does not satisfy this phase).
- [x] `mix test test/statifier/session/invocations_test.exs
      test/statifier/session/invoke_start_child_test.exs
      test/statifier/session/invoke_cancel_test.exs` passes.
- [x] Every new `test "..."` added in this phase has a `# sabotage:` line above
      it, and the mutation described was actually run and confirmed red.
- [x] `changelog.d/st-fd7n.md` exists.
- [x] `mix adr.check` reports no finding (in particular no `adr-0018-bead-id`
      finding - the string `st-fd7n` appears in no file under `lib/` or
      `test/`).

#### Manual Verification:

- [x] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously here, since this phase touches no Appendix D procedure; confirm
      by reading the diff that `lib/statifier/interpreter*` is untouched.
- [x] In IEx over a document with two `<invoke>`s, `Session.invocations/1`
      returns both entries sorted, each `pid` is alive, and
      `Session.session_id/1` on each pid equals the reported `session_id`.
- [x] `Session.invocations/1` on a session with no `<invoke>` returns `[]`
      rather than raising, and on a halted session returns `[]` once
      `terminate/2`-adjacent cancellation has emptied the table.
- [x] No regressions in related features: `#_<invokeid>` routing, autoforward,
      and cancellation behave as before.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: `:inherit_observers` hands `:trace` and subscribers down the tree

### Overview

Half (b). One `%State{}` field, one `init/1` read, an inherited option list at
the single child-start site, and the documentation that makes it a promise
rather than an implementation detail.

### Changes Required:

#### 1. The state field

**File**: `lib/statifier/session.ex`
**Changes**: `%State{}` gains `inherit_observers: false` in its `defstruct`
(`lib/statifier/session.ex:292-308`) and `inherit_observers: boolean()` in its
`@type t` (`lib/statifier/session.ex:310-343`), with a short comment citing
ADR-0049 decisions 2 and 4.

#### 2. Reading the option

**File**: `lib/statifier/session.ex`
**Changes**: In `init/1`'s `%State{}` construction
(`lib/statifier/session.ex:575-585`), add
`inherit_observers: Keyword.get(opts, :inherit_observers, false)`. It stays out
of the `Keyword.take([:trace, :datamodel, :max_macrostep_rounds])` list at
`lib/statifier/session.ex:551`, so it never reaches `MachineState.new/2`.

#### 3. The inherited option list

**File**: `lib/statifier/session.ex`
**Changes**: `start_child/5` (`lib/statifier/session.ex:1269`) passes `state`
into the child-start call, and the private `start_session/3`
(`lib/statifier/session.ex:1302`) becomes `start_session/4`, merging the
inherited options onto the three it already builds. The new private helper is
the whole of the decision.

```elixir
# ADR-0049 decisions 2-5: off by default, so a session that never opted in
# starts its children exactly as before. When on, the child gets this
# session's `trace` (read off `%MachineState{}`, where `new/2` fixed it) and
# this session's subscriber pids *as of now* - a snapshot, not a live link -
# plus the flag itself, which is what carries the opt-in the rest of the way
# down the invoke tree.
@spec inherited_observer_opts(state :: State.t()) :: keyword()
defp inherited_observer_opts(%State{inherit_observers: false}), do: []

defp inherited_observer_opts(%State{} = state) do
  [
    trace: state.machine_state.trace,
    subscribers: Map.keys(state.subscribers),
    inherit_observers: true
  ]
end
```

```elixir
defp start_session(machine, invoke, datamodel, state) do
  Statifier.start_session(
    machine,
    [invoked_by: {self(), invoke.invoke_id}, datamodel: datamodel] ++
      inherited_observer_opts(state)
  )
catch
  :exit, reason -> {:error, reason}
end
```

#### 4. The option's documentation

**File**: `lib/statifier/session.ex`
**Changes**: A `:inherit_observers` bullet in `start_link/2`'s `opts` list
(after `:invoke_source`, `lib/statifier/session.ex:387-392`), and a paragraph
in the moduledoc's "Starting an invocation's child session" section
(`lib/statifier/session.ex:161-190`).

The `@doc` bullet says: `:inherit_observers` - when `true`, every child session
this session starts for an `<invoke>` is started with this session's `:trace`
setting, this session's subscriber pids as of the moment the child starts, and
`inherit_observers: true` of its own, so one opt-in at the root traces the whole
invoke tree (ADR-0049). Default `false`, which starts children exactly as
before. Each inherited subscriber receives the child's messages under the
child's own `session_id` in the `{:statifier, session_id, message}` envelope, so
a mixed stream demultiplexes on that field; `{:halted, _}` is still
end-of-stream per session id (ADR-0044 decision 2), not for the mailbox as a
whole. It is a snapshot: `subscribe/2` and `unsubscribe/2` after a child has
started do not reach that child, and `invocations/1` plus `subscribe/2` on the
child is how an already-running child is attached to.

The moduledoc paragraph adds why an attach cannot substitute: `start_link/2`
runs `Interpreter.initialize/2` to quiescence, and the child is started from
inside the parent's invoke pass, so a subscriber added after the child's pid is
knowable has already missed that child's `Trace.EntrySet`,
`Trace.ContentExecuted`, `Trace.InvokePass`, and `Trace.MacrostepStable`.

#### 5. The prose documents

**File**: `docs/observability.md`
**Changes**: Constraint 6's Observation bullet (`docs/observability.md:177-186`)
gains a sentence: observation is per session, and an invoke tree is a tree of
sessions - `Statifier.Session.start_link/2`'s `:inherit_observers` (ADR-0049)
starts each invoked child with the parent's `:trace` and subscribers so one
attach at the root covers the tree, with each session's messages carrying its
own `session_id` in the envelope; `Statifier.Session.invocations/1` names the
live children for an observer attaching to a tree already running, which
necessarily misses each child's initialize burst.

**File**: `docs/architecture.md`
**Changes**: The "Sessions and invoke" `{:invoke, _}` paragraph
(`docs/architecture.md:140-147`) gains one sentence naming `:inherit_observers`
and `invocations/1` beside the existing `invoked_by:` sentence, linking
ADR-0049.

#### 6. Changelog fragment

**File**: `changelog.d/st-fd7n.md`
**Changes**: Add a bullet under the existing `### Added` for the start option,
naming the default and the transitivity.

#### 7. Tests

**File**: `test/statifier/session/invoke_observer_inheritance_test.exs`
**Changes**: New module, `use ExUnit.Case, async: false` with the same header
comment the other real-child modules carry
(`test/statifier/session/invoke_start_child_test.exs:2-12`), reusing that
module's `compile!/1`, `content_body/0`, `parent_doc/2`, and `wait_for_status/3`
shapes. A child document that itself carries an `<invoke>` with a CDATA
`<content>` grandchild is what makes transitivity testable; the nesting
technique already exists verbatim in
`test/statifier/session/invoke_start_child_test.exs:380-401` (the
`"nests: a child whose own initial state invokes a grandchild"` test,
including the `]]]]><![CDATA[>` CDATA-splitting escape and its
`@tag timeout: 10_000`), and should be reused rather than re-derived. Tests, each with its
own sabotage line:

- Default off: a parent started `trace: true, subscribers: [self()]` and *no*
  `:inherit_observers` produces no message under the child's session id -
  `Statifier.StreamOrder.drain(child_session_id)` returns `[]`, with
  `child_session_id` read from `Session.invocations(parent)`.
- On, one level: with `inherit_observers: true`, `StreamOrder.drain/1` under
  the child's session id contains a `%Effect.Trace.EntrySet{}`, and
  `StreamOrder.assert_monotone/1` holds over that child's own stream.
- Transitive: the grandchild's session id, read through
  `Session.invocations/1` on the child pid, also yields a `Trace.EntrySet` in
  the parent's subscriber mailbox.
- Trace descends independently of subscribers: a parent with
  `trace: true, inherit_observers: true` and `subscribers: []`, with a pid
  subscribed to the *child* through `invocations/1` afterwards, still receives
  the child's later trace effects - which is what shows `:trace` was inherited
  rather than the subscriber list alone.
- Snapshot, not a live link: a pid that `subscribe/2`s to the parent after the
  child has started receives nothing under the child's session id.

**File**: `test/statifier/session_test.exs`
**Changes**: One test that an uninvoked session started with
`inherit_observers: true` behaves exactly as one started without it - the flag
is inert with no `<invoke>` - so the option cannot be read as changing this
session's own stream.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating;
      a loop-profile green does not satisfy this phase).
- [x] `mix test test/statifier/session/` passes, including the new
      `invoke_observer_inheritance_test.exs`.
- [x] `mix test` (the default internal suite) passes with no change to any
      pre-existing test - the option defaulting to `false` means no existing
      expectation about a child's stream may move.
- [x] Every new `test "..."` has a `# sabotage:` line above it, with the
      mutation actually run and confirmed red.
- [x] `mix adr.check` reports no finding.
- [x] `mix quality --profile merge` passes, so the ADR judge (ADR-0012 scope,
      `lib/statifier`) runs against this branch at least once before the
      request is opened.
- [x] `changelog.d/st-fd7n.md` names both the accessor and the option.

#### Manual Verification:

- [x] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously here, since this phase touches no Appendix D procedure; confirm
      from the diff that `lib/statifier/interpreter*` is untouched and that the
      change is confined to `Statifier.Session`'s effect-performing half.
- [x] In IEx, a three-level document (parent invokes child invokes grandchild)
      started `trace: true, subscribers: [self()], inherit_observers: true`
      fills the mailbox with `{:statifier, sid, {:effect, _}}` under all three
      session ids, and `Session.invocations/1` walks from the root to the leaf.
- [x] The same document started without the option produces messages under the
      root's session id only.
- [x] `{:halted, _}` arrives last within each session id's own stream.
- [x] No regressions in related features: cancelling an invocation still stops
      the child and the parent's subscribers stop receiving that child's
      messages; a killed subscriber does not take a child down.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/session/invocations_test.exs` - `list/1` as a pure map
  transformation: empty, populated, key set exactly
  `[:invoke_id, :pid, :session_id]`, sorted by `invoke_id` independent of
  insertion order. No process needed, matching the module's existing tests.
- `test/statifier/session/invoke_start_child_test.exs` - the accessor against a
  real child: agreement with `:sys.get_state/1`, and the entry's disappearance
  on cancellation.
- `test/statifier/session/invoke_observer_inheritance_test.exs` - the option's
  five behaviors: default-off, one level on, transitive to a grandchild, trace
  inherited independently of the subscriber list, and snapshot-not-live-link.
- `test/statifier/session_test.exs` - the option is inert on a session with no
  `<invoke>`.

Key edge cases: a parent with `inherit_observers: true` and an empty subscriber
set (trace still descends, nobody hears it); a subscriber that dies between the
parent's start and the child's (the child's own `Process.monitor/1` on a dead
pid fires immediately and the existing subscriber-`:DOWN` clause drops it, so
no special handling is added); a second `<invoke>` re-entering the same
author-written `id` (the table overwrites, so `list/1` still reports one entry
for that id); and a cancelled invocation, which must vanish from `list/1` at the
pop, not at the child's eventual exit.

One criterion is deliberately only half command-checkable: the sabotage bullet
in each code phase asks both that the `# sabotage:` line be present (grep can
decide that) and that the mutation it describes was actually run and confirmed
red (no gate stage can decide that after the fact). It stays under Automated
Verification because that is where this repo has always put it - see
`docs/plans/260817-st-xb2b-round-on-core-effects.md` - and splitting it here
alone would make this plan the odd one out rather than raise the bar.

Every new test asserting `lib/` behavior carries a `# sabotage:` line naming the
mutation, the assertion it reddens, and that it was reverted and confirmed
green, per `docs/testing.md`. No test description or code comment may contain
the bead id, per `Mix.Statifier.AdrGuard`'s `adr-0018-bead-id` check.

Conformance impact: none expected. No SCXML element, attribute, or interpreter
procedure changes behavior, so `test/passing_tests.json` should not move and no
ratchet step is planned; if a full `mix test --include scion --include scxml_w3`
does move, that is a finding to stop on rather than to ratchet.

### Manual Testing Steps:

1. Compile a three-level document - a parent whose `<invoke>` carries a CDATA
   `<content>` child that itself carries an `<invoke>` with a CDATA
   `<content>` grandchild - and start
   `Statifier.Supervisor.start_link([])` in IEx.
2. `Statifier.start_session(machine, trace: true, subscribers: [self()])` and
   confirm the mailbox holds messages under the root session id only.
3. Repeat with `inherit_observers: true` and confirm messages arrive under all
   three session ids, each stream ending in `{:halted, _}`.
4. `Statifier.Session.invocations/1` on the parent, then on the returned child
   pid, and confirm the walk reaches the grandchild and that each reported
   `session_id` equals `Statifier.Session.session_id/1` on the reported pid.
5. Send the parent an event that exits the invoking state, then re-read
   `invocations/1` and confirm the entry is gone.

## References

- Source document: bead `st-fd7n` (`bd show st-fd7n`), and its 2026-08-16 note
  recording statifier-ui's sui-t36.1 input on half (b)
- Upstream discovery: `docs/research/260816-sui-t36.1-trace-coverage-spike.md`
  in the statifier-ui repo, GAP 3
- Related ADRs: `docs/adr/0027-embedder-placed-session-runtime.md` (decision 3,
  the invocation table and monitor topology),
  `docs/adr/0012-debuggability-designed-into-the-core.md` (the binding
  observability constraints),
  `docs/adr/0044-re-entry-effects-defer-to-the-outer-batch.md` (decision 2,
  `{:halted, _}` as end-of-stream, now read per session id),
  `docs/adr/0029-session-interpret-stays-public.md` and
  `docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md` (why
  `:record` is not inherited),
  `docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md` (why
  `:invoke_source` inheritance is a separate question),
  `docs/adr/0002-literal-w3c-appendix-d-port.md` (no Appendix D procedure is
  touched, so no deviation is declared), and the new
  `docs/adr/0049-invoked-children-inherit-observation-by-opt-in.md`
- Related documents: `docs/observability.md` constraint 6,
  `docs/architecture.md` "Sessions and invoke", `docs/testing.md` (sabotage)
- Similar implementation: `lib/statifier/session.ex:510` (`status/1`, the
  existing small projection accessor), `lib/statifier/session.ex:795` (its
  `handle_call` clause), `lib/statifier/session.ex:1302` (the single
  child-start option list), `lib/statifier/session/invocations.ex:123-127`
  (`invoke_ids/1` and `entries/1`, the projection's neighbours),
  `test/statifier/session/invoke_start_child_test.exs:87-105` (the real-child
  test shape), `test/support/stream_order.ex:47`
  (`drain/1`'s session-id demultiplexing)
- Coordination: the live sibling worktree `st-uqo4-late-subscriber-trace`
  (bead st-uqo4) also edits `lib/statifier/session.ex`; expect a rebase at
  `/wurk:mr` time, not a design conflict
- Bead: `st-fd7n`

## Deferred Manual Verification

**Verified 2026-08-18.** Every item below was exercised against a running
runtime and is ticked, with two clarifications worth carrying forward:

- "cancelling an invocation still stops the child" means the child reaches
  `:cancelled` with its `<onexit>` walk run and emits nothing further on its
  stream; the child *process* deliberately stays alive, since
  `{:stop_child, _}` calls `Session.cancel/1` rather than `GenServer.stop/2`
  (`lib/statifier/session.ex:1247-1259`). A check asserting process death is
  asserting the wrong thing.
- The one item left unticked is the direction-level ADR review, which is a
  human gate rather than something this branch can satisfy for itself.

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [x] The six decision points read as decisions with reasons, not as a
      restatement of the plan, and each rejected alternative names why it was
      rejected rather than only that it was.
- [ ] (outstanding - human/direction gate) The ADR is reviewed at the direction level per `docs/workflow.md` before
      the branch is opened for merge.
- [x] No regressions in related features: nothing outside `docs/` changed.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [x] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously here, since this phase touches no Appendix D procedure; confirm
      by reading the diff that `lib/statifier/interpreter*` is untouched.
- [x] In IEx over a document with two `<invoke>`s, `Session.invocations/1`
      returns both entries sorted, each `pid` is alive, and
      `Session.session_id/1` on each pid equals the reported `session_id`.
- [x] `Session.invocations/1` on a session with no `<invoke>` returns `[]`
      rather than raising, and on a halted session returns `[]` once
      `terminate/2`-adjacent cancellation has emptied the table.
- [x] No regressions in related features: `#_<invokeid>` routing, autoforward,
      and cancellation behave as before.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

### Phase 3

- [x] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously here, since this phase touches no Appendix D procedure; confirm
      from the diff that `lib/statifier/interpreter*` is untouched and that the
      change is confined to `Statifier.Session`'s effect-performing half.
- [x] In IEx, a three-level document (parent invokes child invokes grandchild)
      started `trace: true, subscribers: [self()], inherit_observers: true`
      fills the mailbox with `{:statifier, sid, {:effect, _}}` under all three
      session ids, and `Session.invocations/1` walks from the root to the leaf.
- [x] The same document started without the option produces messages under the
      root's session id only.
- [x] `{:halted, _}` arrives last within each session id's own stream.
- [x] No regressions in related features: cancelling an invocation still stops
      the child and the parent's subscribers stop receiving that child's
      messages; a killed subscriber does not take a child down.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---
