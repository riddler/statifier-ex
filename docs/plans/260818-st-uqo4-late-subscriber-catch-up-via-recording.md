# Late subscriber catch-up via the recording - Implementation Plan

## Overview

Give a pid that subscribes after `Statifier.Session.start_link/2` a way to
obtain the effects it missed, by adding
`Statifier.Session.subscribe(server, pid, catch_up: true)`: one `handle_call`
that atomically snapshots the session's `Statifier.Session.Recording.t()` and
adds the pid, so the caller re-derives the missed prefix with
`Statifier.Replay.run/1` and reads the suffix out of its own mailbox. Bead:
st-uqo4. Governing decision:
`docs/adr/0049-late-subscriber-catch-up-via-recording.md` (accepted
2026-08-18). This plan implements ADR-0049; it does not re-argue it.

## Current State Analysis

**A late subscriber has already missed the initialize burst, structurally.**
`init/1` calls `Interpreter.initialize/2` inline
(`lib/statifier/session.ex:558`) and the resulting effects ride a
`{:continue, {:initialize, effects, start_time, span_ref}}` term
(`lib/statifier/session.ex:597`) performed in
`handle_continue/2` (`lib/statifier/session.ex:723-737`). A `handle_continue`
runs before any message reaches the process, and `subscribe/2` is a
`GenServer.call` (`lib/statifier/session.ex:517`), so a `subscribe/2` issued
the instant `start_link/2` returns is still strictly after the whole
initialize batch was notified. There is no window; only the `:subscribers`
start option sees that burst.

**Nothing retains an emitted effect.** `notify/2`
(`lib/statifier/session.ex:1589-1594`) is an unconditional `send/2` per
subscriber with no copy kept. `%State{}`
(`lib/statifier/session.ex:289-341`) holds exactly two effect-shaped fields
and neither is a history: `deferred` is a within-`perform/3` work queue,
documented always `[]` between callbacks; `done_effect` is a single retained
`%Effect.Done{}` for the halted `configuration` projection.

**The one artifact that reproduces an emitted stream already exists.**
`Statifier.Session.Recording` (`lib/statifier/session/recording.ex:92-109`)
stores the ADR-0029 inputs, and `Statifier.Replay.run/1`
(`lib/statifier/replay.ex:170-183`) is a pure fold whose `result.stream`
(`lib/statifier/replay.ex:159-168`) is exactly the subscriber messages with
the `{:statifier, session_id, _}` envelope stripped, and whose `status` is
`:running` for a recording that has not halted - `run/1` does not require a
finished run. `Session.recording/1` (`lib/statifier/session.ex:418-419`)
already reads the recording back as a `GenServer.call`, returning
`{:error, :not_recording}` for a session without `record: true`.

**The subscribe handler today does nothing but add the pid.**
`handle_call({:subscribe, pid}, _from, state)`
(`lib/statifier/session.ex:805-813`) monitors the pid if absent and puts it
in `state.subscribers`. No backfill, no snapshot.

**What is missing** is the arity-3 head, the `catch_up` handler clause, the
tests, and three documentation edits ADR-0049 decision 6 directs.

## Desired End State

After this plan:

- `Statifier.Session.subscribe(server, pid)` is unchanged: `:ok`, adds the
  pid, delivers from now on. Its `@spec` still says `:: :ok`.
- `Statifier.Session.subscribe(server, pid, opts)` accepts
  `catch_up: boolean()` (default `false`). With `catch_up: false` (or an
  empty list) it behaves exactly as `subscribe/2` and returns `:ok`. With
  `catch_up: true` it returns `{:ok, recording}` - the session's current
  `Statifier.Session.Recording.t()`, snapshotted in the same `handle_call`
  that adds the pid - or `{:error, :not_recorded}` for a session not started
  with `record: true`, in which case **the pid is not added**.
- `Statifier.Replay.run(recording).stream` is the missed prefix, computed by
  the caller, never inside the session; `prefix ++ mailbox_suffix` is one
  uniform, gapless, duplicate-free stream in ADR-0044 decision 1's
  non-decreasing `(macrostep, round)` order.
- Tests assert the ADR's invariant **mid-run**, not only at end-of-run:
  between GenServer callbacks, `Replay.run/1` over the session's current
  recording produces exactly the messages notified so far.
- `Statifier.Session`'s moduledoc "One subscriber stream" section documents
  the new contract; `docs/observability.md` constraint 6 gains a sentence
  naming the catch-up recipe and the between-callbacks invariant (its
  non-goals list is untouched, ADR-0049 decision 4);
  `Statifier.Replay.run/1`'s `@doc` gains the mid-run use case.
- `changelog.d/st-uqo4.md` exists with an `### Added` entry.

Verified by: a full `mix quality` green, plus the four named tests below
passing.

### Key Discoveries:

- `lib/statifier/session.ex:805-813` - the subscribe handler to extend; the
  monitor-if-absent branch is what the new clause must share, not duplicate.
- `lib/statifier/session.ex:797-802` - the `:recording` handler is the exact
  precedent for a "recording or error" reply, and its error atom is
  `:not_recording`. ADR-0049 names the new one `:not_recorded`; see Open
  Questions.
- `lib/statifier/session.ex:516-521` - `subscribe/2`/`unsubscribe/2` and
  their `@spec`s; `Recording` is already aliased at
  `lib/statifier/session.ex:286`.
- `lib/statifier/replay.ex:159-168, 170-183` - `message()`, `result()`, and
  `run/1`'s contract, including its `{:error, {:unscheduled_timer_firing, _}}`
  return that a catch-up caller must still match on.
- `test/statifier/replay_round_trip_test.exs:97-113` - `round_trip/3` and the
  literal `assert result.stream == stream`. ADR-0046 rejected a session-side
  effect stamp precisely to keep that equality true; ADR-0049 makes it
  load-bearing for a public feature, so nothing here may weaken it.
- `test/support/stream_order.ex:46-52` - `Statifier.StreamOrder.drain/2`,
  already aliased in `test/statifier/session_test.exs:6`, is the drain to
  reuse rather than re-write.
- `test/statifier/session_test.exs:165-241` - `describe "subscribers"`, and
  at `:171-183` the only existing `subscribe/2` test, which asserts nothing
  about what the late pid receives.
- `test/statifier/session_test.exs:1163-1457` - `describe "recording"`,
  including a live round-trip through `Replay.run/1` at `:1431-1456`.
- ADR-0044 decision 1 (monotone `(macrostep, round)` arrival), ADR-0046
  (no session-side stamp), ADR-0029 / ADR-0034 (the recording and the pure
  fold), ADR-0040 (replay fires no telemetry) all bound this work and are
  settled - cite, do not re-argue.
- `lib/mix/statifier/adr_guard.ex:87-91` - `lib/statifier/session.ex` is
  already in `@effect_interpreter_paths`, so no new module gains I/O and the
  ADR-0003 guard is unaffected.

## What We're NOT Doing

- **No header effect and no new envelope shape.** ADR-0049 decision 3
  declines half (b) of the bead outright, on four grounds; the stream already
  opens with `{:datamodel_init, _}` carrying `_sessionid` and `_name`, and
  statifier-ui builds its own `session.start` message at its own subscription
  boundary (sui-t36.1, closed). No new `Effect` struct, no `{:hello, _}`
  sibling, no change to `lib/statifier/effect.ex`'s vocabulary or `trace?/1`.
- **No retained buffer of notified messages on `%State{}`**, bounded or
  unbounded. ADR-0049 decisions 1 and 4 reject both; a buffer is the trace
  persistence story `docs/observability.md`'s non-goals decline.
- **No session-side backfill.** The session never sends the replayed prefix
  itself: it would either block `handle_call` for an O(run) re-derivation or
  break ADR-0044 decision 1's ordering by sending from a second pid.
- **No convenience wrapper** returning the derived prefix instead of the
  recording. ADR-0049's Consequences defer it until a consumer asks; the
  two-line recipe serves Elixir callers.
- **No change to `:record` inheritance down the invoke tree.** ADR-0049
  decision 5 leaves that to st-fd7n; this mechanism is session-shape-agnostic
  and works for a child session that records.
- **No edit to `docs/observability.md`'s non-goals list.** ADR-0049 decision 4
  reads it, states the reading, and leaves it unedited on purpose. Editing it
  here would contradict the record.
- **No changes to** `notify/2`, `%State{}`'s fields,
  `lib/statifier/session/effects.ex`, `lib/statifier/session/telemetry.ex`,
  `lib/statifier/session/recording.ex`, or `lib/statifier/replay.ex`'s code
  (its `@doc` only). ADR-0049's Consequences names each of these as untouched;
  a diff that touches one is a signal to stop and re-read the record.
- **No corpus or ratchet movement.** See Corpus/Ratchet Notes.

## Implementation Approach

Two phases, split so each is independently committable with a green full
gate, and so each maps onto one of the bead's two live acceptance criteria.

Phase 1 lands the API, its handler, the docs that state the contract at the
call site, the changelog fragment, and the tests that pin the *contract*:
the acceptance test for criterion 1 (replayed prefix plus drained live suffix
equals a from-start subscriber's full stream), the `{:error, :not_recorded}`
path leaving the pid unsubscribed, `catch_up: false` behaving as
`subscribe/2`, and a post-halt attach recovering the complete stream.

Phase 2 lands criterion 2 - the between-callbacks invariant asserted at
several mid-run quiescent points, in the round-trip suite that already owns
stream equality - and the two prose edits ADR-0049 decision 6 directs outside
`session.ex` (`docs/observability.md` constraint 6, `Replay.run/1`'s `@doc`),
which are the sentences that generalize end-of-run equality to every
quiescent point.

Phase 1 is a complete, shippable feature on its own; Phase 2 strengthens the
evidence and the prose. Neither leaves the other's gate red.

### The ordering rule every test here depends on

`subscribe/3` and `recording/1` are `GenServer.call`s, so they are serialized
*between* callbacks. Every message notified by an earlier callback was
`send/2`-ed synchronously, in-process, before that callback returned - so by
the time the call's reply arrives, the whole notified prefix is already in
the caller's mailbox. A test therefore does the call **first** and drains
**after**, never the reverse. Charts used for the mid-run assertions must
have no timers and no autonomous progress, so that "quiescent" is a real
stopping point rather than a race against a `Process.send_after/3` firing.

There is a second, stronger fact these tests can rely on rather than polling
for: every input callback returns `{:continue, :drain}`
(`lib/statifier/session.ex:736, 831, 844, 850, 857, 896`) and
`handle_continue(:drain, _)` re-continues to itself until the inbox is empty
(`lib/statifier/session.ex:747-791`). A `handle_continue` chain runs to
exhaustion before *any* message reaches the process, so a `GenServer.call`
issued after a `Session.send_event/2` cast is necessarily served after that
event's entire drive has been recorded and notified. Checkpoints that follow
an explicit `send_event/2` therefore need no `wait_for_status/3` poll to be
deterministic; the poll is needed only where a real timer is in play, which
these charts avoid.

### The Appendix D rule

No Appendix D function is touched. This work is entirely in the effect
interpreter (`lib/statifier/session.ex`'s `handle_call` layer) and its
documentation; `lib/statifier/interpreter*` is not edited, and no pseudocode
deviation is introduced or needed. ADR-0002's rule is satisfied vacuously
here, and the per-phase manual criterion below is to confirm that vacuity
against the diff rather than to re-derive pseudocode.

---

## Phase 1: `subscribe/3`, the catch-up handler, and the contract tests

### Overview

Adds the arity-3 public head, the two new `handle_call` clauses, the
moduledoc contract, the `@spec`s, the changelog fragment, and the four
contract tests.

### Changes Required:

#### 1. The public function

**File**: `lib/statifier/session.ex` (at `:516-517`, beside the existing
`subscribe/2`)

**Changes**: Leave `subscribe/2` byte-identical - same `@doc`, same
`@spec ... :: :ok`, same body - and add a separate arity-3 head below it.
Two real clauses rather than a default argument, so `subscribe/2` keeps the
narrow `:: :ok` spec instead of inheriting the union.

```elixir
@typedoc """
`subscribe/3` options. `catch_up: true` asks for the recording snapshot
alongside the subscription; the default is `false`.
"""
@type subscribe_opts :: [catch_up: boolean()]

@doc """
Adds `pid` to this session's monitored subscriber set, optionally handing
back the material the pid needs to reconstruct what it missed (ADR-0049).

With `catch_up: false` (the default) this is `subscribe/2`: `:ok`, delivery
from now on.

With `catch_up: true` on a session started with `record: true`, returns
`{:ok, recording}` - the session's current
`Statifier.Session.Recording.t()`, snapshotted in the *same* `handle_call`
that adds `pid`. The missed prefix is
`Statifier.Replay.run(recording)`'s `result.stream`, computed by the
caller; the suffix is everything `pid` receives from now on. There is no
overlap and no gap between them, and no dedup key is needed - see the
moduledoc's "One subscriber stream" section for why, and for the
`prefix ++ suffix` consumption recipe.

With `catch_up: true` on a session started *without* `record: true`,
returns `{:error, :not_recorded}` and **does not add `pid`** - there is
nothing to re-derive from, and this record adds no second retention
mechanism (ADR-0049 decision 2). A caller for whom live-only delivery is
acceptable falls back to `subscribe/2`.
"""
@spec subscribe(server :: server(), pid :: pid(), opts :: subscribe_opts()) ::
        :ok | {:ok, Recording.t()} | {:error, :not_recorded}
def subscribe(server, pid, opts) when is_pid(pid) and is_list(opts) do
  if Keyword.get(opts, :catch_up, false) do
    GenServer.call(server, {:subscribe, pid, :catch_up})
  else
    GenServer.call(server, {:subscribe, pid})
  end
end
```

#### 2. The handler clauses

**File**: `lib/statifier/session.ex` (at `:805-813`)

**Changes**: Extract the monitor-if-absent branch of the existing
`{:subscribe, pid}` clause into a private helper, then add the two
`{:subscribe, pid, :catch_up}` clauses above it. The `recording: nil` clause
must come first and must return the state untouched - the pid is not added,
which is the whole point of the error path.

```elixir
def handle_call({:subscribe, _pid, :catch_up}, _from, %State{recording: nil} = state) do
  {:reply, {:error, :not_recorded}, state}
end

def handle_call({:subscribe, pid, :catch_up}, _from, %State{recording: recording} = state) do
  {:reply, {:ok, recording}, %{state | subscribers: add_subscriber(state.subscribers, pid)}}
end

def handle_call({:subscribe, pid}, _from, state) do
  {:reply, :ok, %{state | subscribers: add_subscriber(state.subscribers, pid)}}
end
```

with, beside the other private helpers near `notify/2`
(`lib/statifier/session.ex:1589`):

```elixir
# Idempotent: a pid already subscribed is not monitored twice. Shared by
# both `{:subscribe, _}` clauses so the catch-up path cannot drift from
# the plain one.
@spec add_subscriber(subscribers :: %{pid() => reference()}, pid :: pid()) ::
        %{pid() => reference()}
defp add_subscriber(subscribers, pid) do
  if Map.has_key?(subscribers, pid) do
    subscribers
  else
    Map.put(subscribers, pid, Process.monitor(pid))
  end
end
```

No other `%State{}` field, no `notify/2` call, no telemetry event, no
recording append: a `subscribe` is not a recordable input (ADR-0029's four
inputs are unchanged), and catch-up emits no telemetry (ADR-0040).

#### 3. The moduledoc contract

**File**: `lib/statifier/session.ex`, the "One subscriber stream" section
(`:59-102`)

**Changes**: The section currently says "`subscribe/2`/`unsubscribe/2`
manage it afterward" and stops there. Add, after the `{:halted, _}` bullet
and before "A subscriber that dies is dropped on its own `:DOWN`", a
sub-section stating the new contract in the module's own voice:

- `subscribe/3` with `catch_up: true` returns `{:ok, recording}`,
  snapshotted in the same `handle_call` that adds the pid, or
  `{:error, :not_recorded}` without adding it.
- The invariant that makes the split exact: **between GenServer callbacks,
  `Statifier.Replay.run/1` over this session's current recording produces
  exactly the messages this session has notified so far.** Each callback is
  atomic in the effects' terms - it records its input and notifies every
  resulting effect, including ADR-0044's deferred re-entry batches drained
  before the callback returns, which is why `deferred` is documented always
  `[]` between callbacks - so a `subscribe` call, serialized between
  callbacks, observes a recording whose replay is precisely the notified
  prefix.
- The consumption recipe, as it will actually be written:

  ```elixir
  {:ok, recording} = Statifier.Session.subscribe(session, self(), catch_up: true)
  {:ok, %{stream: prefix}} = Statifier.Replay.run(recording)
  # every subsequent {:statifier, session_id, message} is the suffix
  ```

- That ADR-0044 decision 1's monotone-arrival contract holds across the
  seam: the prefix is replay's own order and the suffix continues it.
- That a halted session composes for free - the recording is complete, the
  replayed stream ends `{:halted, reason}`, the live suffix is empty, and
  `Replay.run/1`'s `status` says so, so post-mortem attachment is the same
  call as late attachment.
- That a subscriber wanting only the current picture keeps using
  `snapshot/1`/`status/1` with a plain `subscribe/2`; nothing here replaces
  them.

Also amend the `recording/1` `@doc` (`:408-417`) with one sentence pointing
at `subscribe/3` as the atomic alternative for a caller that wants the
snapshot *and* the subscription without a window between them - `recording/1`
followed by `subscribe/2` has such a window and is the wrong recipe for
catch-up.

#### 4. The changelog fragment

**File**: `changelog.d/st-uqo4.md` (new)

```markdown
### Added

- `Statifier.Session.subscribe/3` with `catch_up: true` returns the session's
  recording alongside the subscription, so a pid that attached after
  `start_link/2` can rebuild the effects it missed with
  `Statifier.Replay.run/1`. Requires `record: true`; otherwise returns
  `{:error, :not_recorded}` and does not subscribe.
```

Single heading, one bullet, no nested points, present tense - `changelog.d/README.md`'s
format rules. This is a public API addition and v2 has no v1 equivalent, so
it earns a fragment under the "while v2 is unreleased" rule.

#### 5. Tests

**File**: `test/statifier/session_test.exs`, a new
`describe "catch-up subscribers"` block placed immediately after the existing
`describe "subscribers"` block (its closing `end` is at `:238`).

Conventions: XML in triple-quoted heredocs at 4-space base indentation
(reuse `two_state_doc/0` and `final_on_event_doc/0` already in the file);
pattern matching in assertions over multiple bare asserts; reuse
`StreamOrder.drain/2` (already aliased) rather than a new drain; no
`@tag :tmp_dir` anywhere (nothing here needs a scratch directory, so no
`@tag :isolated_tmp_dir` either).

One private helper, harness plumbing rather than a test:

```elixir
# Spawns a subscriber process that relays every session message it receives
# to `test_pid`, tagged, in arrival order. The BEAM preserves message order
# per sender pair, so the relayed sequence is exactly this pid's own
# subscriber suffix - which is what lets one session serve both a from-start
# subscriber (the test process) and a late one.
defp relay_to(test_pid) do
  spawn(fn -> relay_loop(test_pid) end)
end

defp relay_loop(test_pid) do
  receive do
    {:statifier, _session_id, _message} = envelope -> send(test_pid, {:late, envelope})
  end

  relay_loop(test_pid)
end

defp drain_late(session_id, acc \\ []) do
  receive do
    {:late, {:statifier, ^session_id, message}} -> drain_late(session_id, [message | acc])
  after
    100 -> Enum.reverse(acc)
  end
end
```

The four tests:

1. **`"a late catch_up subscriber's replayed prefix plus its live suffix is the from-start stream"`**
   (the acceptance test for bead criterion 1). One session,
   `record: true, trace: true, subscribers: [self()]`, so `self()` collects
   the full from-start stream and no second session's `_sessionid` can differ
   inside `{:datamodel_init, _}`. Bind the late pid with
   `relay = relay_to(self())`. Drive one step
   (`Session.send_event(session, "go")`), then
   `assert {:ok, recording} = Session.subscribe(session, relay, catch_up: true)`,
   then drive the rest, then `assert {:ok, %{stream: prefix}} = Replay.run(recording)`,
   `full = StreamOrder.drain(session_id)`, `suffix = drain_late(session_id)`,
   and `assert prefix ++ suffix == full`. Also
   `StreamOrder.assert_monotone(prefix ++ suffix)` to pin ADR-0044 decision 1
   across the seam, and `assert prefix != []` so an empty-prefix regression
   cannot pass the equality vacuously.
2. **`"catch_up: true on a session without record: true returns :not_recorded and does not subscribe"`**.
   Start with `trace: true, subscribers: [self()]` and no `:record`. Assert
   `{:error, :not_recorded} = Session.subscribe(session, relay, catch_up: true)`,
   drive the chart to `{:halted, :done}` on `self()`, then
   `assert drain_late(session_id) == []` - the pid was not added. Then
   `assert :ok = Session.subscribe(session, relay)` to show the documented
   fallback still works.
3. **`"catch_up: false is subscribe/2"`**. `assert :ok = Session.subscribe(session, relay, catch_up: false)`
   and `assert :ok = Session.subscribe(session, relay, [])`, then drive and
   assert the relay received the suffix - same delivery, no recording
   returned, and idempotent (subscribing the same pid twice does not double
   its messages: assert the drained suffix has no repeated
   `{:halted, :done}`).
4. **`"a post-halt catch_up attach recovers the complete stream"`**. A
   `record: true, trace: true` session with **no** subscribers at all, driven
   to `:done` (poll with the file's existing `wait_for_status/3`). Then
   `assert {:ok, recording} = Session.subscribe(session, relay, catch_up: true)`,
   `assert {:ok, %{stream: stream, status: :done}} = Replay.run(recording)`,
   `assert List.last(stream) == {:halted, :done}`, and
   `assert drain_late(session_id) == []` - the live suffix is empty.

**Sabotage discipline** (`docs/testing.md`): each of the four tests gets a
one-line `# sabotage:` comment directly above its `test` line naming the
concrete mutation, the observable consequence after `->`, and "Reverted and
confirmed green", matching the existing style at
`test/statifier/session_test.exs:166-171`. Perform the mutation, watch it go
red, revert, confirm green - do not write the comment from reasoning alone.
Planned mutations, one per test:

1. the catch-up `handle_call` clause replies `{:ok, recording}` but drops the
   `subscribers:` update -> the relay never receives the suffix, `suffix` is
   `[]`, and `prefix ++ suffix == full` fails.
2. the `recording: nil` clause is reordered below the general catch-up clause
   (so a non-recording session replies `{:ok, nil}` and *is* subscribed) ->
   the `{:error, :not_recorded}` match fails.
3. `subscribe/3`'s `Keyword.get(opts, :catch_up, false)` default is flipped
   to `true` -> `catch_up: false` returns `{:error, :not_recorded}` on a
   non-recording session instead of `:ok`.
4. `handle_call({:subscribe, pid, :catch_up}, ...)` snapshots
   `Recording.new(...)`-fresh state instead of `state.recording` -> the
   replayed stream is empty and neither the `status: :done` match nor the
   `List.last/1` assertion holds.

The relay helper carries `# sabotage: n/a - test plumbing, no lib/ behavior
of its own`, matching `test/support/stream_order.ex:1`.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` is used between edits while iterating (not
      as the phase gate).
- [x] Full `mix quality` passes, and `mix gate.verify` confirms the run was
      unprofiled, unscoped, and not `--skip`-ed.
- [x] `mix test test/statifier/session_test.exs` passes, including the four
      new tests in `describe "catch-up subscribers"`.
- [x] `mix test test/statifier/replay_round_trip_test.exs` still passes -
      `assert result.stream == stream` at `:109` is untouched and still green.
- [x] `test -f changelog.d/st-uqo4.md` and the file contains a single
      `### Added` heading.
- [x] `git diff --name-only` lists no file outside
      `lib/statifier/session.ex`, `test/statifier/session_test.exs`, and
      `changelog.d/st-uqo4.md`.
- [x] `git diff` contains no change under `docs/quality-gate-changes.md`'s
      guarded paths (`.quality.exs`, `.credo.exs`, `coveralls.json`,
      `.sobelow-conf`, `.doctor.exs`, gate-relevant `mix.exs` lines), no new
      `@tag :skip`, and no shrink of `test/passing_tests.json` - so
      `mix gate.check` needs no ledger entry.
- [x] Every new `test` line in the diff has a `# sabotage:` comment directly
      above it (`grep -B1 'test "' ` over the new block).

#### Manual Verification:
- [ ] **Appendix D judgment**: confirm from the diff that no function named
      in Appendix D was touched and no interpreter file was edited, so
      ADR-0002's deviation rule is satisfied vacuously rather than by an
      unrecorded deviation.
- [ ] Each of the four sabotage mutations was actually applied and observed
      red before being reverted - the comments describe runs that happened.
- [ ] The moduledoc's new sub-section reads as the module's contract, not as
      a restatement of ADR-0049: it says what a caller does, and cites the
      ADR number rather than re-arguing the alternatives.
- [ ] `{:error, :not_recorded}` versus the neighbouring
      `{:error, :not_recording}` from `recording/1` is deliberate and both
      are documented in their own `@doc` (see Open Questions).
- [ ] No regressions in related features: `subscribe/2`'s existing test at
      `test/statifier/session_test.exs:171-183` still reads as before and
      still passes.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
moving to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end instead of blocking here.

---

## Phase 2: The mid-run invariant, asserted, and the prose that generalizes it

### Overview

Asserts ADR-0049's named invariant at several mid-run quiescent points rather
than only at end-of-run, in the suite that already owns stream equality, and
lands the two documentation edits outside `session.ex` that decision 6
directs.

### Changes Required:

#### 1. The mid-run invariant test

**File**: `test/statifier/replay_round_trip_test.exs`, a new
`describe "the between-callbacks invariant"` block appended after the
existing case blocks.

**Changes**: The file's existing `round_trip/3` (`:97-113`) asserts equality
once, at end of run. Add a helper that asserts it at an *arbitrary* quiescent
point, and a test that calls it repeatedly across one run.

```elixir
# ADR-0049 decision 1's invariant, checkable at any quiescent point:
# between GenServer callbacks, `Replay.run/1` over the session's current
# recording produces exactly the messages notified so far. `recording/1` is
# a GenServer.call, so it is serialized between callbacks and every message
# notified by an earlier callback is already in this process's mailbox when
# it replies - which is why the call comes first and the drain second.
# Returns the messages consumed, so a caller can accumulate across checks.
defp assert_invariant_here(session, session_id, seen) do
  {:ok, recording} = Session.recording(session)
  new = drain_stream(session_id)
  seen = seen ++ new

  assert {:ok, result} = Replay.run(recording)
  assert result.stream == seen

  seen
end
```

The test: a `record: true, trace: true, subscribers: [self()]` session over
`two_state_doc/0` - no timers, no autonomous progress, so every point between
explicit `send_event/2` calls is genuinely quiescent. Call
`assert_invariant_here/3` immediately after `start_link/2` (the initialize
burst alone, which is exactly the prefix a late subscriber misses), again
after the first `"go"`, and again after the second, threading `seen` through.
Assert at the end that `seen != []` and that `StreamOrder`-style monotonicity
holds over `seen`, so a degenerate always-empty run cannot satisfy the
equality vacuously.

Add a second, smaller test asserting the invariant holds *after halt* too:
over `final_chain_doc/0`, drive to `:done`, `assert_invariant_here/3`, and
match `result.status == :done` - the same call shape as a post-mortem
catch-up.

**Sabotage discipline**: each new test gets its `# sabotage:` line. Planned
mutations:

- for the mid-run test: `Session.handle_cast({:enqueue_event, event}, state)`'s
  `record(state, &Recording.put_event(&1, event, ...))` is dropped, so an
  event drives the core without being recorded -> the replayed stream is
  short by that event's effects and `result.stream == seen` fails at the
  *second* checkpoint while the first still passes, which is exactly the
  mid-run sensitivity the end-of-run test could report only as a single
  final mismatch.
- for the post-halt test: `Replay`'s `to_result/1` reports `status: :running`
  unconditionally -> the `status: :done` match fails.

Apply, observe red, revert, confirm green; write the comment from the run.

#### 2. `docs/observability.md` constraint 6

**File**: `docs/observability.md`, the **Observation** bullet of "Constraint
6: observe and record at the boundary" (`:174-186`)

**Changes**: Append two sentences to that bullet (the **Replay** bullet and
the **Non-goals** list below it are untouched - ADR-0049 decision 4 states
that the non-goal is read and left unedited, so an edit there would
contradict the record):

- A pid that subscribes after `Statifier.Session.start_link/2` has already
  missed the initialize burst, and catches up by asking for the recording in
  the same call that subscribes it:
  `Statifier.Session.subscribe(server, pid, catch_up: true)` returns
  `{:ok, recording}`, and `Statifier.Replay.run/1` re-derives the missed
  prefix (ADR-0049). It requires `record: true`; nothing is retained on the
  session to answer it otherwise.
- What makes prefix and suffix meet exactly: between GenServer callbacks,
  `Statifier.Replay.run/1` over the session's current recording produces
  exactly the messages the session has notified so far - which generalizes
  the end-of-run equality
  `test/statifier/replay_round_trip_test.exs` asserts to every quiescent
  point.

#### 3. `Statifier.Replay.run/1`'s `@doc`

**File**: `lib/statifier/replay.ex` (`:170-180`)

**Changes**: Add a paragraph to the existing `@doc` naming the mid-run use
case `run/1` already supports - a recording captured from a session still
running replays to `status: :running` and a `stream` that is the notified
prefix so far, which is what
`Statifier.Session.subscribe(server, pid, catch_up: true)` hands its caller
(ADR-0049). No code change in this file; `result()`, `message()`, and the
fold are untouched.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` is used between edits while iterating (not
      as the phase gate).
- [x] Full `mix quality` passes, and `mix gate.verify` confirms the run was
      unprofiled, unscoped, and not `--skip`-ed.
- [x] `mix test test/statifier/replay_round_trip_test.exs` passes, including
      the new `describe "the between-callbacks invariant"` block.
- [x] `mix test` (the default internal suite) passes with no change to the
      pre-existing tests.
- [x] `git diff --name-only` lists exactly
      `test/statifier/replay_round_trip_test.exs`, `docs/observability.md`,
      and `lib/statifier/replay.ex`.
- [x] `git diff lib/statifier/replay.ex` shows changes inside the `@doc`
      heredoc only - no line outside it, so the pure fold is provably
      untouched.
- [x] `git diff docs/observability.md` shows no line changed under the
      `## Non-goals (for now)` heading (ADR-0049 decision 4).
- [x] Every new `test` line in the diff has a `# sabotage:` comment directly
      above it.

#### Manual Verification:
- [ ] **Appendix D judgment**: confirm from the diff that no Appendix D
      function and no interpreter file was touched; the only `lib/` change is
      a docstring.
- [ ] Both sabotage mutations were applied and observed red - and, for the
      mid-run one, observed red *at the second checkpoint specifically*,
      which is the property distinguishing this test from the end-of-run
      one it sits beside.
- [ ] The `docs/observability.md` sentences read as constraint prose in that
      document's voice, not as an ADR excerpt, and cite ADR-0049 by number.
- [ ] Read `docs/adr/0049-late-subscriber-catch-up-via-recording.md` decision
      6 against the final diff and confirm all three directed edits landed:
      observability constraint 6, `Session`'s moduledoc (Phase 1), and
      `Replay.run/1`'s doc.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
moving to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/session_test.exs`, `describe "catch-up subscribers"` (Phase
  1) - the API contract: the acceptance equality
  (`prefix ++ suffix == full`), `{:error, :not_recorded}` leaving the pid
  unsubscribed, `catch_up: false`/`[]` behaving as `subscribe/2` and staying
  idempotent, and a post-halt attach recovering the complete stream ending
  `{:halted, :done}`.
- `test/statifier/replay_round_trip_test.exs`,
  `describe "the between-callbacks invariant"` (Phase 2) - the invariant at
  three mid-run quiescent points and once after halt.

Key edge cases covered: a late subscriber attaching before any event has been
sent (the initialize burst is the whole prefix); attaching after halt (empty
suffix); a non-recording session (no subscription, no partial answer);
subscribing the same pid twice; and the seam's ordering, via a monotonicity
assertion over `prefix ++ suffix` rather than over each half alone.

Edge cases deliberately **not** covered, with reasons: a session with a
delayed `<send>` in flight at catch-up time - the recording holds a pending
timer credit that has not fired, which `Replay.run/1` simply leaves unused,
so it exercises no new code path here and is already covered by the
round-trip suite's timer cases; and a child (invoked) session's catch-up,
which is st-fd7n's per ADR-0049 decision 5.

### Manual Testing Steps:

1. In `iex -S mix`, compile a two-state chart, start
   `Session.start_link(machine, record: true, trace: true)` with **no**
   subscribers, send one event, then run
   `{:ok, r} = Session.subscribe(session, self(), catch_up: true)` and
   `{:ok, %{stream: prefix}} = Replay.run(r)`. Confirm `prefix` opens with
   `{:effect, {:datamodel_init, _}}` and contains the `Trace.EntrySet` and
   `Trace.MacrostepStable` a late subscriber would otherwise have missed.
2. Send a second event and `flush()` the IEx mailbox. Confirm the flushed
   messages continue where `prefix` stopped - no repeat of any message
   already in `prefix`, and no gap.
3. Repeat step 1 against a session started **without** `record: true`.
   Confirm `{:error, :not_recorded}`, then send an event and `flush()` -
   confirm nothing arrives, i.e. the failed catch-up did not subscribe you.
4. Start a session, drive it to `:done`, then catch up. Confirm the replayed
   stream ends `{:halted, :done}`, `status` is `:done`, and `flush()` shows
   an empty mailbox.

## Corpus/Ratchet Notes

No corpus regeneration and no ratchet movement. This change adds a public
function to the effect interpreter and touches no parser, lowering,
validator, compiler, or interpreter code, so no SCION or W3C conformance
result can move. `mix test.regression` and `mix test.baseline add` are
therefore **not** phase criteria here; if a bare `mix quality` ever reports a
conformance delta on this branch, that is a signal that the diff grew beyond
what this plan describes, not a ratchet to update.

## Open Questions

Recorded rather than left blocking - each has a decision this plan acts on,
and is written here so the reason survives for whoever implements it.

1. **`:not_recorded` sits one letter from the existing `:not_recording`.**
   `Session.recording/1` already returns `{:error, :not_recording}`
   (`lib/statifier/session.ex:798`) for the same underlying condition - the
   session was not started with `record: true`. ADR-0049 decision 1 names the
   new atom `:not_recorded` explicitly, so **this plan follows the ADR** and
   does not rename either one; renaming `recording/1`'s atom would be a
   breaking change to a shipped return value, and renaming the new one would
   contradict an accepted record. The mitigation is documentary: both `@doc`s
   name their own atom, and the moduledoc's new sub-section uses
   `{:error, :not_recorded}` verbatim. If a reviewer wants them unified, that
   is a direction-level call on a follow-on bead, not a plan edit.
2. **`Replay.run/1`'s error return is part of the catch-up recipe.**
   `run/1` can return `{:error, {:unscheduled_timer_firing, send_id}}`, so
   the documented two-line recipe's `{:ok, %{stream: prefix}} = ...` match
   will raise rather than degrade on a corrupt recording. That is the right
   behavior - a recording that cannot replay is a defect, not a degraded
   catch-up - and this plan keeps the recipe in its matching form rather than
   teaching every caller a `case`. The moduledoc mentions `run/1`'s contract
   by reference rather than restating it.
3. **The plan asserts `prefix != []` and `seen != []` explicitly.** Both
   equality assertions (`prefix ++ suffix == full`, `result.stream == seen`)
   would pass vacuously if the streams were empty on both sides - a real risk
   if a future change stopped emitting effects at initialize. The
   non-emptiness assertions are deliberate belt-and-braces, not redundancy;
   do not drop them as noise.

## References

- Governing decision: `docs/adr/0049-late-subscriber-catch-up-via-recording.md`
- Source document: `docs/research/260818-st-uqo4-late-subscriber-trace-and-session-header.md`
- Related ADRs: `docs/adr/0002-*` (Appendix D fidelity), `docs/adr/0003-*`
  (pure core, one effect interpreter), `docs/adr/0029-*` (the recording's four
  inputs), `docs/adr/0034-*` (replay as a pure fold), `docs/adr/0040-*`
  (telemetry; replay fires nothing), `docs/adr/0044-*` (monotone
  `(macrostep, round)` arrival; `{:halted, _}` is end-of-stream),
  `docs/adr/0046-*` (no session-side stamp; stream equality),
  `docs/adr/0025-*` (cross-repo tracker authority, for the sui-t36.1 mirror)
- Constraint prose: `docs/observability.md` constraints 3 and 6, and its
  non-goals list
- Similar implementation: `lib/statifier/session.ex:797-802`
  (`recording/1`'s reply shape), `lib/statifier/session.ex:805-813` (the
  subscribe handler), `test/statifier/replay_round_trip_test.exs:97-113`
  (`round_trip/3`), `test/support/stream_order.ex:36-52`
  (`StreamOrder.drain/2`)
- Bead: st-uqo4 (mirrors sui-t36.1, closed)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

**Verified 2026-08-18**, all nine, in an orchestrator session with the human.
The two sabotage items were not taken on the comments' word: all six
mutations were re-applied to the working tree and re-run individually, each
observed red at the assertion its comment names - including the mid-run one
at the *second* checkpoint specifically (`replay_round_trip_test.exs:647`,
the first checkpoint passing), which is the property that distinguishes that
test from the end-of-run cases beside it. Every mutation was then reverted
and the tree confirmed clean against `HEAD`.

One fixup came out of the review rather than a clean pass: the
`:not_recorded` / `:not_recording` item asked whether the near-collision is
deliberate *and* documented. Each atom was documented in its own `@doc`, but
neither named the other, so a reader hitting one had no signal the other
existed. Both `@doc`s now carry a cross-reference saying the two are one
letter apart and deliberately not unified. Renaming stayed out of scope per
Open Question 1.

### Phase 1

- [x] **Appendix D judgment**: confirm from the diff that no function named
      in Appendix D was touched and no interpreter file was edited, so
      ADR-0002's deviation rule is satisfied vacuously rather than by an
      unrecorded deviation.
- [x] Each of the four sabotage mutations was actually applied and observed
      red before being reverted - the comments describe runs that happened.
- [x] The moduledoc's new sub-section reads as the module's contract, not as
      a restatement of ADR-0049: it says what a caller does, and cites the
      ADR number rather than re-arguing the alternatives.
- [x] `{:error, :not_recorded}` versus the neighbouring
      `{:error, :not_recording}` from `recording/1` is deliberate and both
      are documented in their own `@doc` (see Open Questions).
- [x] No regressions in related features: `subscribe/2`'s existing test at
      `test/statifier/session_test.exs:171-183` still reads as before and
      still passes.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
moving to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end instead of blocking here.

---

### Phase 2

- [x] **Appendix D judgment**: confirm from the diff that no Appendix D
      function and no interpreter file was touched; the only `lib/` change is
      a docstring.
- [x] Both sabotage mutations were applied and observed red - and, for the
      mid-run one, observed red *at the second checkpoint specifically*,
      which is the property distinguishing this test from the end-of-run
      one it sits beside.
- [x] The `docs/observability.md` sentences read as constraint prose in that
      document's voice, not as an ADR excerpt, and cite ADR-0049 by number.
- [x] Read `docs/adr/0049-late-subscriber-catch-up-via-recording.md` decision
      6 against the final diff and confirm all three directed edits landed:
      observability constraint 6, `Session`'s moduledoc (Phase 1), and
      `Replay.run/1`'s doc.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
moving to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end instead of blocking here.

---
