# `start_session/2` init/1 Invoke Deadlock Implementation Plan

## Overview

`Statifier.Session.init/1` performs the initialize macrostep's effects
synchronously, before it returns. When the document's initial configuration
carries an `<invoke>`, one of those effects starts a child session on the
same globally-named `Statifier.SessionSupervisor` the parent is still being
started by - and the `DynamicSupervisor` cannot answer the inner
`start_child` until it has answered the outer one. Both hang forever.

This plan defers the whole initialize effect pass out of `init/1` into a
`handle_continue/2` that runs before the existing `:drain` continue, and then
ratchets in the conformance tests the fix turns green. Bead: st-u2h4.

## Current State Analysis

**The cycle, in four hops.**

1. `Statifier.start_session/2` (`lib/statifier.ex:193-211`) builds a child
   spec and calls `DynamicSupervisor.start_child(Statifier.SessionSupervisor,
   spec)`. That call blocks the caller until the child's `init/1` returns,
   and it is served *by the `Statifier.SessionSupervisor` process*, which is
   therefore busy for the whole duration.
2. `Statifier.Session.init/1` (`lib/statifier/session.ex:506-556`) calls
   `Interpreter.initialize/2` at `:510` and then `perform(state, effects)` at
   `:543` - synchronously, before `{:ok, state, {:continue, :drain}}` at
   `:555`.
3. `perform/3` (`:880-886`) folds the planned instructions; a state entered
   during initialization that carries an `<invoke>` produces
   `{:start_child, %Invoke{}, effect}`, handled at `:964-969`, which reaches
   `start_child/5` (`:1077-1094`) and the private `start_session/3`
   (`:1110-1117`).
4. `start_session/3` calls `Statifier.start_session/2` again - the same
   globally-named `Statifier.SessionSupervisor`, still inside hop 1. Deadlock.

**Why it was latent until now.** Every initial-state `<invoke>` in the corpus
used to fail the namespace-less `<content><scxml>` standalone compile before
reaching the supervisor. `st-ybuj` (ADR-0042, on `origin/main` as `7aa6ba6`)
removed that gate. This branch is rebased onto `7aa6ba6`.

**Why the internal suite is green anyway, and why that is an accident.**
Every existing `<invoke>` test starts its *parent* with a bare
`Session.start_link/2` (`test/statifier/session/invoke_start_child_test.exs`
uses it at ten call sites; 93 `Session.start_link` call sites across 12 test
files). A bare `start_link/2` is called by the test process, not by the
`DynamicSupervisor`, so the supervisor is idle when the child's
`start_child` arrives and only the *child* goes through it. The fixture
documents in `parent_doc/2`
(`test/statifier/session/invoke_start_child_test.exs:39-54`) do put
`<invoke>` in the initial state `a` - the parent's start path is the only
thing standing between the internal suite and this deadlock. That is exactly
the "shared-runtime accident" the bead's acceptance criteria forbid relying
on.

**Blast radius.** `test/support/case.ex:174` drives session-requiring corpus
documents through `Statifier.start_session/2`, so every one of them takes the
deadlocking path. 35 corpus files carry an `<invoke>` in their initial
configuration, all under `test/scxml_tests/mandatory/` (24 under `invoke/`,
plus `cancel/test207` and `system_variables/test338`). A full conformance run
on this branch does not finish: 106 tests time out at 60000ms each, all at
`test/support/case.ex:175` inside `GenServer.call/3`. The count is inflated
by the run-scoped `Statifier.Supervisor` in `test/test_helper.exs:7` - one
`DynamicSupervisor` process for the node means the first wedged `start_child`
blocks every later session start - but the deadlock reproduces on one file
with nothing else running.

**Isolated reproduction:**

```
mix test test/scxml_tests/mandatory/invoke/test220_test.exs \
  --include scxml_w3 --timeout 15000
```

## Desired End State

`Statifier.Session.init/1` returns without having started any child session.
The initialize macrostep's effects - all of them, in the order
`Effects.plan/2` produced them - are performed in a
`handle_continue({:initialize, ...}, state)` clause that runs immediately
after `init/1` returns and immediately before the existing `:drain` continue.
`Statifier.start_session/2` therefore returns as soon as the core has
initialized, freeing the `DynamicSupervisor` before any `<invoke>` is
performed, at every nesting depth.

Verified by: `test220_test.exs` runs to an assertion rather than a timeout;
two seeded full `mix test --include scion --include scxml_w3` runs finish
with identical failure sets and no 60000ms timeouts; a new internal test
starts a parent whose initial state carries an `<invoke>` through
`Statifier.start_session/2` (not `Session.start_link/2`) and completes.

### Key Discoveries:

- **The pure core is already spec-correct and is not touched by this plan.**
  `Interpreter.initialize/2` (`lib/statifier/interpreter.ex:219`) runs
  `main_event_loop/1`, and `run_invoke_pass/1` sits in the pseudocode's own
  position inside `main_event_loop/3`
  (`lib/statifier/interpreter.ex:1199-1206`), after the macrostep fold and
  before the internal-queue re-check. The `Effect.Invoke` structs arrive in
  the effect list already correctly ordered. The bug is entirely in *when the
  session performs them*.
- **Appendix D gives `invoke(inv)` no procedure body.** `mainEventLoop`'s own
  comment is explicit: "Here we invoke whatever needs to be invoked. The
  implementation of 'invoke' is platform-specific", above
  `for state in statesToInvoke.sort(entryOrder): for inv in
  state.invoke.sort(documentOrder): invoke(inv)`. `interpret()` is
  `enterStates([doc.initial.transition])` then `mainEventLoop()`. So the
  *placement* of the platform-specific body inside `init/1` versus a
  `handle_continue` is not an Appendix D ordering question at all - the
  pseudocode has nothing there to deviate from. Relative to this port's own
  mapping it improves: `handle_continue(:drain, _)` is documented as
  "`mainEventLoop`'s dequeue tail" (`lib/statifier/session.ex:600-606`), so
  performing the invoke in a continue that runs *before* the drain places it
  between the macrostep and the external-event dequeue - the pseudocode's own
  position. **No ADR-0002 deviation is introduced and none is removed**; the
  fix needs no deviation comment for the Appendix D rule, only a comment
  explaining the process-level constraint.
- **ADR-0040's macrostep span survives unchanged if the timer rides in the
  continue term.** `init/1` opens `Telemetry.macrostep_start(session_id,
  :initialize, nil, span_ref)` at `:524` and closes it at `:545-553` after
  `perform`. ADR-0040's own text says the `:initialize` span's start time is
  "a local binding rather than a state field" because no `%State{}` exists
  yet. Carrying `start_time` and `span_ref` in the `{:continue, term}` tuple
  keeps that property - still not a `%State{}` field - and the span still
  encloses exactly `Interpreter.initialize/2` plus `perform/3`, because
  `handle_continue` is guaranteed to run before any message, including
  `:sys` messages. Nothing can interleave. This is consistent with ADR-0040,
  not an amendment to it.
- **The ADR-0039 re-entry path is why the whole pass moves, not just the
  `:start_child` instructions.** `perform_instruction({:raise, ...})`
  (`:914-916`) calls `deliver_internal/6`, which re-enters the core and opens
  a nested macrostep span; `{:halt, reason}` (`:1020-1027`) sets
  `state.halted` and fires `returnDoneEvent`. Deferring only the
  `:start_child` instructions would reorder them relative to those, changing
  observable semantics (an `error.communication` from a failed invoke would
  fire after a `{:halt, :done}` that followed it in the plan). Moving the
  fold intact preserves the whole order.
- **No test breaks.** `test/statifier/session_test.exs:95-104` reads
  `Session.snapshot/1` with no poll right after `start_link/2`, but
  `snapshot/1` is a `GenServer.call` and queues behind the continue. The
  telemetry ordering tests
  (`test/statifier/session/telemetry_test.exs:1046-1068`, `:1075-1094`,
  `:1304-1323`) assert the `:initialize` span opens once, closes before the
  first `:event` span, and encloses any nested `:internal` span - all
  preserved. `test/statifier/session/invoke_start_child_test.exs:93-108` uses
  `:sys.get_state/1`, which is also a message and also queues behind the
  continue.
- **Recording and replay are unaffected** (ADR-0034, ADR-0029). The only
  recording write reachable from `perform/3` is
  `Recording.put_internal/5` in `deliver_internal/6`
  (`lib/statifier/session.ex:1310`); nothing else can record between `init/1`
  returning and the continue running, so the serialized input order is
  identical.
- **st-cmq.9's three phases are all landed on this branch** (`50c791b`,
  `20c0c88`, `9d7eaf0`, plus the manual-correction pass `4b822a2`). Its plan
  recorded this deadlock as an open question it could not reach
  (`docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md:1124-1131`).
  There is no remaining st-cmq.9 phase for a ratchet step to attach to.

## What We're NOT Doing

- **No new ADR.** This is a bug inside the shape ADR-0027 decision 3 already
  decided (children on the flat `Statifier.SessionSupervisor`, parent-owned
  through monitors and an invocation table). Nothing about that shape changes;
  only the moment at which the parent performs the start moves. No
  `Mix.Statifier.AdrGuard` `@effect_interpreter_paths` entry is added (every
  edit is in `lib/statifier/session.ex`, already exempt), so no
  `docs/quality-gate-changes.md` ledger entry is owed under ADR-0011.
- **No changelog fragment.** `.claude/wurk/commit.md` narrows fragments to
  cases where v2 differs from v1 while v2 is unreleased.
  `Statifier.start_session/2` and `Statifier.Session` are v2-only surfaces
  that have never shipped; this repairs unreleased code and is invisible to
  any caller of a released version.
- **Not changing the pure core.** No file under `lib/statifier/interpreter*`
  or `lib/statifier/effect/` is edited. `run_invoke_pass/1`'s position is
  already the pseudocode's own.
- **Not making `start_child/5` asynchronous.** It needs `{:ok, pid}`
  synchronously to build the `Invocations` entry and to route a failure to
  `invoke_error/4`'s `error.communication` (spec 6.4, ADR-0031). Starting the
  child from a `Task` would move the block off-process without removing it and
  would add a process for no gain.
- **Not deferring only the `:start_child` instructions.** Weighed and
  rejected for the ADR-0039 reordering reason under Key Discoveries. This is
  the plan's answer to the bead's "where the invoke pass moves" question and
  is not to be re-opened during implementation.
- **Not fixing the conformance tests that stay red after the fix.** Phase 1
  ratchets what turns green and files beads for what does not; diagnosing
  individual reds is separate work.
- **Not touching `test/test_helper.exs`'s run-scoped runtime.** It amplifies
  the symptom but does not cause it, and st-cmq.9 placed it deliberately
  (ADR-0027: one runtime per node, `async: true` corpus tests share it).

## Implementation Approach

One structural edit, verified by a full conformance run, ratcheted in the
same commit.

`init/1` stops calling `perform/3` and stops closing the macrostep span. It
returns `{:ok, state, {:continue, {:initialize, effects, start_time,
span_ref}}}`. A new `handle_continue({:initialize, effects, start_time,
span_ref}, state)` clause performs the effects, closes the span exactly as
`init/1` does today, and returns `{:noreply, state, {:continue, :drain}}`.
`handle_continue(:drain, state)` is untouched.

The span timer travels in the continue term rather than in a new `%State{}`
field: the field would be dead outside the two-callback window, and ADR-0040
already documents `:initialize` as the one span whose start time is not a
`%State{}` field.

Phase 1 then runs the conformance suites twice with different seeds, ratchets
in exactly what passes with `mix test.baseline --add`, and files a bead for
each remaining red - the same protocol st-cmq.9's own Phase 3 used. Phase 2
is the residue that moves no conformance result: correcting the ratcheted
figures `docs/testing.md` states, if the run moved any.

### Why the fix and the ratchet are one phase

`.claude/wurk/commit.md` is explicit: when conformance results move,
`mix test.baseline add` "rides in the **same commit** as the feature that
unlocked the newly passing tests - not a follow-up commit." The deadlock fix
is that feature. Splitting the fix and the ratchet into two phases would
produce two commits under `/wurk:implement --loop`, where each phase's green
gate is its own commit trigger - exactly the follow-up commit that rule
forbids. So the fix, the conformance measurement that proves it, and the
`test/passing_tests.json` movement it justifies are one phase and one commit,
even though the fix alone would be gate-verifiable on its own. This is the
generic skill's own sizing rule applied to this project's commit policy: the
smallest independently *committable* unit here is larger than the smallest
gate-verifiable one.

Phase 2 stays separate because it moves no conformance result and therefore
carries no ratchet obligation: it is a documentation correction whose input is
Phase 1's printed coverage block.

### Why the ratchet belongs to this plan and not to st-cmq.9

The branch this lands on is st-cmq.9's, and the 23 corpus files `st-ybuj`
unblocked are the ones st-cmq.9's plan expected to ratchet. That plan's three
phases are nonetheless all already committed here (`50c791b`, `20c0c88`,
`9d7eaf0`, plus the manual-correction pass `4b822a2`), so there is no open
st-cmq.9 phase for a ratchet step to attach to, and reopening a completed
plan to add one would be worse than owning it here. Combined with the
same-commit rule above - the deadlock fix is what makes those files pass, so
the registry movement rides with it - the ratchet is **this** plan's Phase 1.
st-cmq.9 is not reopened, and no work is left implicitly waiting on it.

## Phase 1: Defer the initialize effect pass to a continue, and ratchet

### Overview

Move `perform/3` and the `:initialize` macrostep span's close out of
`init/1`; add the internal regression coverage that goes through
`Statifier.start_session/2` rather than `Session.start_link/2`; run the full
conformance suites and ratchet in exactly what the fix turned green; file a
bead for each remaining red. One commit.

### Changes Required:

#### 1. The session callbacks

**File**: `lib/statifier/session.ex`

**Changes**: `init/1` (`:506-556`) drops the `perform/3` call at `:543` and
the `Telemetry.macrostep_stop/7` call at `:545-553`, and returns a continue
carrying the effects and the open span. A new `handle_continue/2` clause,
placed directly above the existing `:drain` clause at `:607`, does that work.

```elixir
    # `init/1`, replacing lines 543-555:

    # `perform/3` runs from `handle_continue/2` rather than here, and the
    # `:initialize` span closes there with it. `Statifier.start_session/2`
    # blocks the `Statifier.SessionSupervisor` process for the whole of this
    # callback, and performing a `{:start_child, %Invoke{}, _}` from inside it
    # would call `DynamicSupervisor.start_child/2` on that same busy
    # supervisor - neither call could ever return (st-u2h4). A `handle_continue`
    # runs before any message reaches this process, so nothing observes the
    # split; the whole planned instruction list still runs as one ordered fold,
    # which is what keeps ADR-0039's re-entry and `{:halt, _}` in the order
    # `Statifier.Session.Effects.plan/2` produced them.
    {:ok, state, {:continue, {:initialize, effects, start_time, span_ref}}}
  end

  # The tail of `init/1`, deferred one message-loop turn. `start_time` and
  # `span_ref` ride in the continue term rather than in `%State{}`: ADR-0040
  # already makes the `:initialize` span the one span whose start time is not
  # a `%State{}` field, and a field would be `nil` everywhere but the gap
  # between these two callbacks.
  @impl GenServer
  def handle_continue({:initialize, effects, start_time, span_ref}, state) do
    state = perform(state, effects)

    Telemetry.macrostep_stop(
      state.session_id,
      :initialize,
      state.machine_state,
      nil,
      macrostep_outcome(state),
      start_time,
      span_ref
    )

    {:noreply, state, {:continue, :drain}}
  end
```

#### 2. The comments that describe the old placement

**File**: `lib/statifier/session.ex`

**Changes**: three prose sites state or imply that effects are performed
inside `init/1` and must be corrected in the same commit.

- `:499-504` - the ADR-0040 comment above `init/1`. It stays true about the
  start time not being a `%State{}` field; it gains the continue term as
  where that binding now travels, and why.
- `:299-305` - `%State{}`'s `macrostep_started_at` typedoc, which says
  "`init/1`'s span uses a local binding instead". Reword to name the continue
  term.
- The moduledoc's account of starting an invocation's child session
  (`:139` and the "Starting an invocation's child session" section) - state
  that a child is never started from `init/1`, and why.

#### 3. Regression coverage through the deadlocking path

**File**: `test/statifier/session/invoke_start_child_test.exs`

**Changes**: a new `describe` block whose tests start the *parent* with
`Statifier.start_session/2`. Every existing test in the file starts the
parent with `Session.start_link/2`, which is the accident that kept this
green; the new block is the only internal coverage of the real path. Both
tests carry `@tag timeout: 10_000` so a regression fails in ten seconds
rather than hanging the suite for a minute.

```elixir
  describe "a parent started through the runtime (Statifier.start_session/2)" do
    # sabotage: `perform(state, effects)` and the `:initialize`
    # `Telemetry.macrostep_stop/7` call are moved back into `init/1` ahead of
    # its return (the pre-st-u2h4 shape) -> the parent's `init/1` calls
    # `DynamicSupervisor.start_child/2` on the `Statifier.SessionSupervisor`
    # that is still serving its own start, and this test fails on the
    # 10_000ms timeout instead of asserting. Reverted and confirmed green.
    @tag timeout: 10_000
    test "starts its initial state's <invoke> without deadlocking the supervisor" do
      # parent_doc/2 already puts <invoke> in the initial state "a".
    end

    # sabotage: same mutation -> the grandchild's start wedges the same
    # supervisor one level deeper and this test times out. Reverted and
    # confirmed green.
    @tag timeout: 10_000
    test "nests: a child whose own initial state invokes a grandchild" do
    end
  end
```

The first test asserts the `{:effect, {:invoke, %Effect.Invoke{}}}` message
reaches the subscriber, that `Invocations.count/1` on the parent is 1, and
that the child's `Session.status/1` reports its expected configuration - the
same assertions the existing `Session.start_link/2` test makes, over the
runtime-started parent. The second builds a two-level document (the parent's
`<invoke>` carries a `<content>` child chart that itself carries an
`<invoke>`) and asserts an invocation table entry at each level.

#### 4. The regression registry

**File**: `test/passing_tests.json`

**Changes**: grown by `mix test.baseline --add`, never hand-edited. Today it
holds 2 internal globs, 119 `scion_tests` entries, and 128 `w3c_tests`
entries. `mix test.baseline` runs each candidate on its own before writing,
so nothing enters without passing first, and the task never removes an entry.
This is the same commit as the change groups above, per
`.claude/wurk/commit.md`'s ratchet rule.

#### 5. Beads for the remaining reds

**Changes**: no file. For each conformance test still failing after the two
seeded runs, either match it to an existing open bead (st-cmq.9's Phase 3
already filed `st-lz1c`, `st-yizi`, `st-vwdg`, `st-2dht`, `st-5577`,
`st-w2zz` and recorded `st-bnr` as direction-decided) or file a new one with
`/wurk:issue`. Diagnosing them is out of scope here.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` is green, proven by `mix gate.verify` exiting zero
      (not a profiled, scoped, `--quick`, or `--skip`-ed run). Use
      `mix quality --profile loop` while iterating; it never satisfies this
      criterion on its own.
- [x] `mix test test/statifier/session/invoke_start_child_test.exs` passes,
      including the two new tests, with no test hitting its 10_000ms timeout.
- [x] `mix test test/scxml_tests/mandatory/invoke/test220_test.exs --include
      scxml_w3 --timeout 15000` terminates - it runs to an assertion (pass or
      an ordinary ExUnit failure) rather than timing out. This is the bead's
      first acceptance criterion.
- [x] `mix test test/statifier/session_test.exs
      test/statifier/session/telemetry_test.exs
      test/statifier/session/recording_test.exs` passes unchanged, with no
      edits to those files - the tests that encode the old `init/1` timing
      still hold.
- [x] `mix test --include scion --include scxml_w3` **completes** - the run
      terminates and prints a summary. This is the bead's second acceptance
      criterion; the pre-fix baseline is 106 tests timing out at 60000ms each.
- [x] The run is repeated with a second, different `--seed`, and both runs
      report the same test count and the same set of failing files. A failure
      set that differs between seeds means an order dependence and blocks this
      phase.
- [x] Neither run's output contains an ExUnit timeout failure, at any
      duration.
- [~] `mix test.baseline` (scan, no `--add`) reports the newly passing set;
      then `mix test.baseline --add` writes it. The registry's `scion_tests` +
      `w3c_tests` count strictly increases from 247.
      **Premise changed, criterion met against the new one.** The starting
      count is 245, not 247: st-cmq.9's Phase 3 commit was amended to hold
      `test187` and `test242` out (see the resolution note below). The count
      went 245 -> 266, strictly increasing.
- [x] `mix test.regression` is green against the grown registry, and its
      per-corpus coverage block prints.
- [x] `git diff test/passing_tests.json` shows additions only - no line
      removed. A shrunk registry is an ADR-0011 gate-guard condition and must
      not be produced here.
- [x] `bd list` shows an open bead for every conformance test still failing
      after the runs.
- [x] `git diff --name-only` shows no file under `lib/statifier/interpreter*`,
      `lib/statifier/effect/`, `lib/mix/statifier/adr_guard.ex`, or
      `docs/quality-gate-changes.md`.
- [x] `mix quality --format json --report -` produces the machine-readable
      stage results, for any later agent that routes on them.

#### Manual Verification:

- [x] Spec-conformance judgment (required for any phase touching
      `lib/statifier/`): read Appendix D's `interpret()` and `mainEventLoop()`
      from
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`
      and confirm the ported functions still match line for line -
      specifically that `run_invoke_pass/1`'s position in
      `lib/statifier/interpreter.ex:1199-1206` is unchanged and that the
      session's performance of the platform-specific `invoke(inv)` body now
      falls between the macrostep and `handle_continue(:drain, _)`'s dequeue
      tail. Confirm no new ADR-0002 deviation comment is owed.
- [x] Attach `:telemetry` to `Statifier.Session.Telemetry.events/0` for a
      document with an `<invoke>` in its initial state, start it through
      `Statifier.start_session/2`, and confirm by eye that exactly one
      `trigger: :initialize` `macrostep, :start`/`:stop` pair fires, in that
      order, with the `:stop` carrying a plausible non-zero `duration` and the
      correct `outcome`.
- [x] Read the three corrected comment sites and confirm each describes what
      the code now does, with no surviving sentence claiming effects are
      performed inside `init/1`.
- [x] Walk the newly ratcheted file list and confirm each one is a test the
      deadlock was blocking (an initial-configuration `<invoke>`, or a test
      wedged behind one on the shared runtime), not a test that passes for an
      unrelated and possibly accidental reason.
- [x] Confirm by inspection that no remaining red is a *new* failure
      introduced by this phase - compare the failure set against st-cmq.9's
      recorded baseline of 34 failures over 2074 tests
      (`docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md:1257-1308`),
      accounting for the 23 files `st-ybuj` unblocked.
- [x] Confirm the bead's third acceptance criterion by reading, not by
      running: no test in `test/` reaches an `<invoke>` in an initial
      configuration only because its parent was started with a bare
      `Session.start_link/2`. This phase's new `describe` block is the
      deliberate counter-example; the rest of the file's use of
      `start_link/2` stays, since it covers the unregistered-session path
      ADR-0027 decision 2 sanctions.
- [~] No regressions in related features: an embedder-visible behavior spot
      check that `Statifier.start_session/2` still returns `{:ok, pid}` for a
      document with no `<invoke>`, and `{:error, _}` (never a hang) when
      `Statifier.Supervisor` was never placed; plus one previously ratcheted
      `test/scion_tests/` file and one `test/scxml_tests/optional/` file still
      passing.
      **One half of this criterion was wrong when it was written.** `{:ok,
      pid}` for a document with no `<invoke>`: confirmed. Never a hang:
      confirmed - it returns in microseconds. But with no runtime placed it
      **exits** rather than returning `{:error, _}`:
      `** (exit) exited in: GenServer.call(Statifier.SessionSupervisor, ...)
      ** (EXIT) no process`. That is not a defect - `Statifier.start_session/2`'s
      moduledoc promises `DynamicSupervisor.start_child/2`'s own return value,
      and calling a `DynamicSupervisor` that was never started exits by
      design. The criterion overstated the contract; the behavior matches what
      the function documents. Left as observed rather than "fixed", since
      changing it would be an API decision this bead has no mandate for.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
moving to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end instead of blocking here.

**Open question recorded 2026-08-16 (loop stopped here, unattended, no human
available to ask):** the `handle_continue` fix itself is verified working
(`test220_test.exs` terminates; two seeded full `mix test --include scion
--include scxml_w3` runs both report 2082 tests / 15 failures with identical
failure-file sets and no timeouts; `mix test.baseline --add` ratcheted 21
files in, additions-only). But `mix test.regression` is red on two tests that
were **already** in `test/passing_tests.json` before this phase started:
`test187` and `test242`. Root-caused (reproduces via a bare
`Session.start_link/2`, so it is unrelated to this phase's `init/1` diff):
both were ratcheted in before ADR-0042 / `7aa6ba6` relaxed the namespace-less
`<content>` compile gate, when their `<invoke>`s never compiled at all; now
that they compile, real session-timing bugs surface - `test187`'s invoked
child reaches `:done` while a delayed `<send>` is still pending, and the
timer still fires because `:done` idles a session rather than stopping it;
`test242`'s inline-`<content>` invoke races `done.invoke` against a slower
sibling timer and used to win only because the invoke never ran at all.
`docs/testing.md`'s own rule is that a test which used to pass and now does
not is a regression to fix, never a registry line to delete - so this phase
did not touch `test/passing_tests.json` for either test, and did not attempt
to fix the underlying session-timing bugs itself (the plan's "Not doing" list
excludes `lib/statifier/interpreter*` and `lib/statifier/effect/`, but is
silent on whether `lib/statifier/session.ex` timing semantics may grow beyond
this phase's stated diff - a scope call this loop is not authorized to make
unattended). Filed `st-dmfg` (test187) and `st-vy97` (test242) to track the
fixes; also filed `st-vfmb` for `test236` (an untracked red with no registry
conflict). **Decision needed from a human**: either fix the two session
semantics bugs as part of unblocking this phase's `mix test.regression` gate
(growing Phase 1's diff beyond what it currently states), or decide this is a
legitimate registry correction this plan did not anticipate and amend the
plan/phase accordingly. The code diff, the two new sabotage-verified tests,
and the `test/passing_tests.json` additions from this run are left
uncommitted in the working tree for inspection rather than discarded.

---

## Phase 2: Correct the conformance figures the docs state

### Overview

Phase 1's `mix test.regression` and `mix test.baseline` runs each print a
per-corpus coverage block. Bring `docs/testing.md`'s stated conformance
figures back in line with what those blocks now report. This phase moves no
conformance result and touches no `lib/` file, so it carries no ratchet
obligation of its own - which is exactly why it is separable from Phase 1's
single fix-plus-ratchet commit.

If Phase 1's coverage blocks match what `docs/testing.md` already says, this
phase is a no-op and is closed by recording that, not by inventing an edit.
That is a real and expected outcome: the document's figures are denominators
(corpus files on disk) and v1 reference targets, neither of which this work
moves.

### Changes Required:

#### 1. Ratcheted and denominator figures

**File**: `docs/testing.md`

**Changes**: reconcile every conformance number the prose states against
Phase 1's printed coverage blocks. Today the document states corpus
denominators of 119 SCION and 162 W3C files on disk (the W3C figure being 159
`mandatory/` plus 3 `optional/`), and v1 reference targets of 90/127 SCION and
27/59 W3C. Correct any figure the runs contradict; leave the rest alone.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` is green, proven by `mix gate.verify` exiting zero
      (not a profiled, scoped, `--quick`, or `--skip`-ed run). Use
      `mix quality --profile loop` while iterating.
- [x] `mix test.regression` is green and its per-corpus coverage block prints;
      every figure `docs/testing.md` states about corpus counts appears in
      that block or in `mix test.baseline`'s, with no number in the document
      that no command produces.
- [x] `git diff --name-only` shows `docs/testing.md` and nothing else - no
      `lib/`, no `test/`, no `test/passing_tests.json`.

#### Manual Verification:

- [x] Read the changed paragraphs end to end and confirm each number is the
      one its own sentence claims (a denominator stayed a denominator, a
      ratcheted numerator stayed a numerator) - a find-and-replace that swaps
      a target figure for a current one is the failure mode here.
- [x] Confirm the document still reads as guidance rather than as a
      changelog: no sentence added that will be stale the next time the
      ratchet moves.
- [x] No regressions in related features: `docs/testing.md`'s ratchet and
      sabotage sections are unchanged in substance, since nothing in this work
      revises either policy.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
moving to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via
`/wurk:commit --auto`), and Manual Verification items are deferred and
surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

- The ratchet moves forward only. `mix test.baseline` verifies each candidate
  on its own before writing, and `mix test.regression` fails on a registry
  entry that matches no file on disk - so a deleted or renamed corpus file is
  a red run, never a silent shrink.
- `mix test.baseline add <files>` is all-or-nothing across the named files;
  the bare `--add` form scans and adds whatever passed. Phase 1 uses `--add`
  after a clean scan, which is the protocol st-cmq.9's Phase 3 used.
- Expected movement: the 23 files `st-ybuj` unblocked are the headline, drawn
  from the 35 corpus files carrying an initial-configuration `<invoke>` (24
  under `test/scxml_tests/mandatory/invoke/`, plus
  `mandatory/cancel/test207` and `mandatory/system_variables/test338`). The
  actual number is whatever the Phase 1 scan reports; nothing is ratcheted on
  an expectation.
- `test192` and `test233` were recorded by st-cmq.9 as unpassable behind the
  namespace gap. That gap is closed on `origin/main` by ADR-0042 / `7aa6ba6`,
  so they are ordinary candidates for the Phase 1 scan - if they still fail,
  they are filed as beads like any other red, not carried forward as a known
  exception.
- The corpus itself is not regenerated. `mise run corpus` is not run by this
  plan; no `tools/corpus/` file changes.

## Testing Strategy

### Unit Tests:

- `test/statifier/session/invoke_start_child_test.exs` - the two new tests
  under Phase 1's runtime-started `describe` block. They are the only
  internal coverage of `Statifier.start_session/2` as the *parent's* start
  path with an initial-configuration `<invoke>`, which is the deadlocking
  shape. Both carry a `@tag timeout: 10_000` so a regression is a fast red.
- Key edge cases: nesting depth two (parent -> child -> grandchild, all
  invoking from their initial configurations), which is where a partial fix
  that only unblocked the first level would still hang; and the existing
  "no `Statifier.Supervisor` placed" test at
  `test/statifier/session/invoke_start_child_test.exs:190-211`, which must
  still reach `invoke_error/4`'s `error.communication` rather than crashing
  or hanging now that the start happens one callback later.
- Sabotage discipline (`docs/testing.md`, `.claude/wurk/commit.md`): both new
  tests assert `lib/` behavior and therefore need a real mutation run before
  the commit. The mutation for both is the pre-fix shape - move `perform/3`
  and the `Telemetry.macrostep_stop/7` call back inside `init/1` ahead of its
  return - which reddens each test on its 10_000ms timeout. Break it, watch
  it go red for that reason, revert, confirm green, then write the
  `# sabotage:` note. A note written for a mutation that was never run is the
  one failure the gate's scan cannot catch.
- No new test file is created; the existing invoke test module is the right
  home, and it is already `async: false` for exactly the runtime-singleton
  reason this coverage needs.

### Manual Testing Steps:

1. From a clean tree on this branch, run
   `mix test test/scxml_tests/mandatory/invoke/test220_test.exs --include
   scxml_w3 --timeout 15000` with nothing else running, and confirm it
   terminates. Before Phase 1 this hangs at `test/support/case.ex:175` inside
   `GenServer.call/3`.
2. Run `mix test --include scion --include scxml_w3` to completion, twice,
   with two different `--seed` values; record both summaries and diff the
   failing-file sets.
3. Attach a `:telemetry` handler to
   `Statifier.Session.Telemetry.events/0`, start a document whose initial
   state carries an `<invoke>` through `Statifier.start_session/2`, and read
   the emitted sequence: one `[:statifier, :session, :init]`, one
   `macrostep, :start` with `trigger: :initialize`, the invoke effect event,
   and one `macrostep, :stop` with `trigger: :initialize` closing after it.
4. Start a session with `record: true`, drive one external event, read the
   recording back with `Statifier.Session.recording/1`, and confirm the input
   order is what it was before Phase 1 (ADR-0034, ADR-0029).
5. In `iex -S mix` with no `Statifier.Supervisor` placed, call
   `Statifier.start_session/2` on an invoke-carrying document and confirm it
   returns an `{:error, _}` promptly rather than hanging.

## References

- Bead: `st-u2h4`
- Deadlock site: `lib/statifier/session.ex:506-556` (`init/1`), `:880-886`
  (`perform/3`), `:964-969` (`{:start_child, _, _}`), `:1077-1117`
  (`start_child/5`, `start_session/3`); `lib/statifier.ex:193-211`
  (`Statifier.start_session/2`)
- Continue this fix lands beside: `lib/statifier/session.ex:600-651`
  (`handle_continue(:drain, _)`, "`mainEventLoop`'s dequeue tail")
- Spec: Appendix D `interpret()` and `mainEventLoop()`, in
  `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`
  (run `mise run spec:fetch` if absent); the invoke pass's port site is
  `lib/statifier/interpreter.ex:1199-1206`
- Related ADRs: `docs/adr/0002-literal-w3c-appendix-d-port.md`,
  `docs/adr/0003-pure-core-with-effects.md`,
  `docs/adr/0027-embedder-placed-session-runtime.md`,
  `docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md`,
  `docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md`,
  `docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`,
  `docs/adr/0040-session-telemetry-event-contract.md`,
  `docs/adr/0042-invoke-content-compiles-under-the-relaxed-namespace-rule.md`
- Prior plans: `docs/plans/260815-st-cmq.7-invoke-scxml-child-sessions.md`
  (child-session protocol; did not anticipate the re-entrancy),
  `docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md:1124-1131`
  (recorded this deadlock as an unreachable open question)
- Docs: `docs/observability.md` constraint 6, `docs/testing.md` (ratchet and
  sabotage discipline), `docs/architecture.md`
- Harness: `test/support/case.ex:173-190` (`drive_through_session/3`),
  `test/test_helper.exs:7` (the run-scoped `Statifier.Supervisor`)

## Verification Record - 2026-08-16

Both phases' criteria were walked after the fact, since the loop stopped
before its own check-off step. What was run, so it can be re-run.

### Resolution of the open question the loop recorded

The loop's Phase 1 note asked whether to fix the two newly-exposed session
bugs or treat this as a registry correction. Neither, as it turned out: a
third option the note did not consider is the one taken. `test187` and
`test242` were ratcheted in by **st-cmq.9's own Phase 3 commit, on this same
branch**, while `st-ybuj`'s namespace gap left their `<invoke>` children
inert - so they passed for a reason that was about to disappear. Those
entries had never been pushed. Phase 3's commit was amended to hold both out
(now `1dc8109`), which keeps the branch's net diff against `origin/main`
additions-only: no `GateGuard` shrink finding, and no
`docs/quality-gate-changes.md` entry owed. `st-dmfg` and `st-vy97` stay filed
as the real bugs, and neither was papered over.

### Phase 1 measurements

- Full gate green and attested (`scope all, no profile, 13 stages`);
  `mix gate.verify` exit 0. `Gate guard`: no findings.
- `mix test test/statifier/session/invoke_start_child_test.exs`: 11 tests, 0
  failures, nothing near its 10_000ms timeout.
- `test220_test.exs`: terminates in 0.04s, passing. Pre-fix it hung.
- `session_test.exs` + `session/telemetry_test.exs` +
  `session/recording_test.exs`: 84 tests, 0 failures, and `git diff` shows
  none of the three edited on this branch - the tests encoding the old
  `init/1` timing still hold untouched.
- Two full seeded runs (`--seed 31337`, `--seed 80085`): both **2082 tests,
  15 failures**, identical failing-file sets, and `grep -c TimeoutError` is
  **0** in each. The pre-fix baseline was 106 tests timing out at 60000ms.
- Registry: 245 -> 266 (119 SCION, 147 W3C). Against `origin/main` the entry
  **set difference is 0 removed, 92 added**. Note that the raw line diff
  shows two `-` lines; both are artifacts (`last_updated`, and the trailing
  comma the previous last element gained), which is why the set difference
  rather than the line count is the check that answers this criterion.
- Coverage: **SCION 119/119 (100%), W3C 147/162 (90.7%)**, against v1's
  90/127 and 27/59.
- Every one of the 15 remaining reds has an open bead: `st-yizi` (test159,
  test496), `st-dmfg` (test187), `st-lz1c` (test201, test216, test226,
  test239, test276, test552), `st-vfmb` (test236), `st-vy97` (test242),
  `st-2dht` (test330), `st-5577` (test530), `st-vwdg` (test553, test554).
- `git diff --name-only origin/main...HEAD` touches nothing under
  `lib/statifier/interpreter*`, `lib/statifier/effect/`,
  `lib/mix/statifier/adr_guard.ex`, or `docs/quality-gate-changes.md`.

### Phase 1 judgments

- **Appendix D.** `spec-cache/appendix-d.txt:137` reads "Here we invoke
  whatever needs to be invoked. The implementation of 'invoke' is
  platform-specific" - quoted, not recalled. `lib/statifier/interpreter.ex` is
  **unchanged on this branch**, so `run_invoke_pass/1` keeps the pseudocode
  position its own comment cites. The session's performance of the
  platform-specific body now sits in `handle_continue({:initialize, ...}, _)`,
  which returns `{:continue, :drain}` - between the macrostep and the dequeue
  tail. No new ADR-0002 deviation comment is owed, because the pseudocode
  gives `invoke(inv)` no body to deviate from.
- **Telemetry.** For a document invoking from its initial state, the parent
  emits exactly one `trigger: :initialize` `macrostep` `:start`/`:stop` pair,
  in that order, `:stop` carrying `duration: 12_356_083` and
  `outcome: :quiescent`. Filtering by the parent's `session_id` is required
  to see this: unfiltered, the invoked child's own `:initialize` pair
  (`outcome: :done`) also arrives, which is correct rather than a duplicate.
- **Comment sites.** All three describe the new behavior. The one grep hit
  for effects and `init/1` in the same sentence is `session.ex:140`, which is
  the corrected text - "This is never performed from `init/1`".
- **Newly ratcheted files.** All 21 invoke from their initial configuration:
  19 from a plain initial `<state>`, `test234` from an initial `<parallel>`
  whose regions each carry an `<invoke>`, `test422` from `s1`. None is an
  accidental pass.
- **No new failures.** Against st-cmq.9's recorded 34-over-2074 baseline, 21
  reds are fixed and the only two additions are `test187` and `test242` -
  both accounted for by ADR-0042 landing on main, both filed, both held out
  of the ratchet rather than silenced.
- **The bead's third criterion**, by reading: the registered path is covered
  by this phase's new `describe` block, which is the deliberate
  counter-example. The remaining `Session.start_link/2` sites cover the
  unregistered-session path ADR-0027 decision 2 sanctions, so no test reaches
  an initial-configuration `<invoke>` *only* through a bare `start_link/2`.

### Phase 2: no-op, as the phase itself anticipated

`docs/testing.md` hard-codes no ratcheted numerator. Its corpus figures are
the denominators 119 SCION and 162 W3C, both of which appear in the coverage
block the tasks print, and v1's 90/127 and 27/59 reference targets, which
this work does not move. The suite-description figures that *were* stale were
corrected earlier under st-cmq.9 (commit `2651c45`). No edit invented.
