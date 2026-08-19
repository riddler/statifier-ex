defmodule Statifier.Session do
  @moduledoc """
  The GenServer effect interpreter (ADR-0003): the outer `while running`
  loop, the waiting external events, the delayed-send timers, and the
  fan-out of the effect stream to subscribers. The pure core decides; this
  module performs.

  This is the one module under `lib/statifier/` allowed to do I/O
  (`lib/mix/statifier/adr_guard.ex`'s `@effect_interpreter_paths`), which is
  why the deciding half lives in `Statifier.Session.Inbox`,
  `Statifier.Session.Timers`, and `Statifier.Session.Effects` - pure values
  and a pure function, testable with no process at all - and only the
  performing half lives here. A different path or module name fails the
  gate.

  ## A bare `start_link/2` stays legal; the runtime is opt-in

  `start_link/2` and the `use GenServer`-generated `child_spec/1` still work
  exactly as before: an embedder can place a session directly
  in their own supervision tree, and `:name` is passed to
  `GenServer.start_link/3` unchanged, so an embedder-owned
  `{:via, Registry, _}` works with no code here. A session started this way
  is legal and unregistered - ADR-0027 decision 2 sanctions this outright,
  since C.1 leaves "accessible to a given SCXML Processor" platform-defined,
  and an unregistered session is an inaccessible one to every *other*
  session (decision 10 below is the one exception, and it is about
  self-addressing, not registration).

  `Statifier.start_session/2` is the alternative that registers: it starts
  the session on `Statifier.SessionSupervisor` under `Statifier.Supervisor`
  (ADR-0027), and `init/1` below registers under `Statifier.Registry` when
  that registry is running - never fatal to the session when it is not, so
  a bare `start_link/2` embedder pays nothing for a runtime it never placed.

  `use GenServer, restart: :temporary` (ADR-0027 decision 4) is written
  explicitly, both because the generated `child_spec/1` otherwise defaults
  to `restart: :permanent` - which would have a supervisor restart a
  session that halted normally, the opposite of the next section - and
  because `:temporary` itself is a decision: a supervisor restart re-runs
  `start_link/2`, which generates a *fresh* `sess_` id and loses every
  bit of the crashed session's state, so restarting is actively wrong, not
  merely useless. Recovery that preserves identity is replay, not a
  restart flag.

  ## `:done` idles the session; it does not stop it

  The process stays alive with the terminal `%MachineState{}` and the
  retained `%Effect.Done{}` in hand, so `snapshot/1` and `status/1` still
  answer after termination. Stopping is the caller's move (`stop/2`), or the
  supervisor's. Further events are queued but never drained. The same is
  true, with a narrower meaning, for `:cancelled` (`cancel/1` reached the
  same `exit_interpreter/1` path) and for `:budget_exhausted` (ADR-0019):
  the session neither retries with a larger budget nor stops itself, and
  `cancel/1` still works from a budget-halted session, since the
  underlying `%MachineState{}` is still `running` and the inbox's cancel
  entry is checked before any drive of the core - a queued ordinary event
  is not.

  ## One subscriber stream

  There is no `:owner` concept. Subscribers are a monitored set;
  `start_link/2` takes `:subscribers` (default `[]`), and
  `subscribe/2`/`unsubscribe/2` manage it afterward. Every message a
  subscriber receives is `{:statifier, session_id, message}`, where
  `message` is one of:

    - `{:effect, effect}` - every effect the core (or an `interpret/2`
      caller) hands this session, trace effects included, in
      non-decreasing `(macrostep, round)` order - the same order
      `Statifier.Replay` produces for the same recording (ADR-0044
      decision 1). An ADR-0039 re-entry crosses the seam at its own
      instruction's position but its effects are queued and drained after
      the batch that triggered it, so a subscriber never sees a later
      round ahead of an earlier one. Trace effects are ordinary list
      members here too, never a side channel.

      This is a guarantee about **delivery order**, not one a subscriber
      can re-derive from the structs: `round` is carried only by the
      `Statifier.Effect.Trace.*` payloads and by
      `Statifier.Effect.BudgetExhausted` today, so a mixed stream cannot
      be sorted back into this order after the fact (ADR-0044 decision 4
      leaves stamping `round` onto the rest as follow-on work). Take the
      order as it arrives.

      A macrostep may carry more than one `Trace.MacrostepStable` - one
      per core drive that reached quiescence - and there is exactly one
      per `(macrostep, round)` (ADR-0044 decision 3). Within a macrostep
      the last one is that macrostep's last *quiescent* point, which is
      not always where the macrostep ends: a macrostep that halts ends
      with `Trace.Done` instead, either after its final
      `Trace.MacrostepStable` or - when the halting drive is the only one
      - with no `Trace.MacrostepStable` of its own at all.
    - `{:unroutable, effect}` - reserved for an effect this session cannot
      route; every `:send`/`:send_delayed`/`:invoke`/`:cancel_invoke`/
      `:autoforward` effect now routes (see `Statifier.Session.Effects`'s
      own moduledoc), so no message currently reaches a subscriber this way.
    - `{:halted, :done | :cancelled | :budget_exhausted}` - one lifecycle
      message, following the effects that caused it, and the **last**
      message this session sends its subscribers for the run (ADR-0044
      decision 2).

  A late subscriber catches up by replaying the recording, not from any
  buffer this session retains (ADR-0049). `subscribe/3` with
  `catch_up: true` returns `{:ok, recording}` - the session's current
  `Statifier.Session.Recording.t()`, snapshotted in the *same* `handle_call`
  that adds the pid - or `{:error, :not_recorded}` without adding it, for a
  session not started with `record: true`.

  The invariant that makes the split exact: **between GenServer callbacks,
  `Statifier.Replay.run/1` over this session's current recording produces
  exactly the messages this session has notified so far.** Each callback is
  atomic in the effects' terms - it records its input and notifies every
  resulting effect, including ADR-0044's deferred re-entry batches drained
  before the callback returns, which is why `deferred` is documented always
  `[]` between callbacks - so a `subscribe` call, serialized between
  callbacks, observes a recording whose replay is precisely the notified
  prefix.

  The consumption recipe, as it will actually be written:

  ```elixir
  {:ok, recording} = Statifier.Session.subscribe(session, self(), catch_up: true)
  {:ok, %{stream: prefix}} = Statifier.Replay.run(recording)
  # every subsequent {:statifier, session_id, message} is the suffix
  ```

  ADR-0044 decision 1's monotone-arrival contract holds across the seam: the
  prefix is replay's own order and the suffix continues it. A halted session
  composes for free - the recording is complete, the replayed stream ends
  `{:halted, reason}`, the live suffix is empty, and `Replay.run/1`'s
  `status` says so, so post-mortem attachment is the same call as late
  attachment. A subscriber wanting only the current picture keeps using
  `snapshot/1`/`status/1` with a plain `subscribe/2`; nothing here replaces
  them.

  A subscriber that dies is dropped on its own `:DOWN`.

  ## A cancel is a queue entry, not an out-of-band call

  `cancel/1` enqueues the cancel marker onto this session's own external
  inbox (`Statifier.Session.Inbox.enqueue_cancel/1`), so a cancellation is
  recorded in the same ordered queue as every event
  (`docs/observability.md` constraint 6) rather than racing ahead of it
  through a side channel. Draining it runs `Statifier.Interpreter.cancel/1`
  - Appendix D's `running = false` followed by `exitInterpreter()` - and
  halts the session `:cancelled`, even though the `{:done, _}` effect that
  walk produces is still forwarded to subscribers exactly as natural
  termination's is.

  ## `<send>` routing

  A `<send>`/`<send_delayed>` with no `target` lands on this session's own
  external queue. `#_internal` and a self-addressed `#_scxml_<sessionid>`
  (decision 10: a session is always accessible to itself, registry or not)
  both resolve with no registry at all - the former through
  `Statifier.Interpreter.deliver_internal/5` (ADR-0039), the latter onto
  this session's own inbox. Every other `#_scxml_<sessionid>` resolves
  through `Registry.lookup(Statifier.Registry, sid)` (ADR-0027 decision 2):
  a hit casts the event onto that session's inbox via `send_event/2`; an
  empty lookup - the id never existed, named a bare unregistered session,
  or named a session that has since died - takes C.1's mandated
  `error.communication` path on the *sending* session's own internal queue,
  through the private `communication_error/4` resolver. `#_parent`/`_parent`
  (6.4.4/C.1's spelling disagreement, decision 8) resolves through
  `state.invoked_by`: a live invocation's child stamps `invokeid` (5.10.1)
  and delivers straight to the parent's external queue; a session that was
  never invoked has no parent and takes the same `communication_error/4`
  path as any other unreachable route. `#_<invokeid>` resolves through the
  same invocation table this module holds (`Statifier.Session.Invocations`,
  `Invocations.fetch/2`) rather than the registry: a live entry's `pid` gets
  the event delivered to its external queue directly, and an `invokeid`
  naming no live invocation - never one, or since cancelled or exited -
  takes the same `communication_error/4` path as any other unreachable
  route. An
  unsupported `type` or an unparseable `target` raises `error.execution` the
  same way, at plan time. `:cancel_invoke` plans `{:stop_child, invoke_id}`
  ("Cancelling an invocation" below). A child reaching a top-level final
  returns `done.invoke.<invokeid>` to its parent's external queue the same
  direct way ("Starting an invocation's child session" below names the
  reciprocal obligation this halt-time delivery completes). See
  `Statifier.Session.Effects` and `Statifier.Send.Target`.

  ## Autoforward delivery

  `{:autoforward, %Effect.Autoforward{}}` plans `{:forward, invoke_id,
  event}` unconditionally (`Statifier.Session.Effects`) - every external
  event the parent removes from its queue, forwarded verbatim to each
  autoforwarding invocation, at the point 6.4.2 puts it: inside
  `apply_invoke_passes/2`'s own turn, before the next `Inbox.next/1`.
  Performing it looks `invoke_id` up in `state.invocations` and
  `send_event/2`s the event unmodified; a miss - the invocation was
  cancelled or the child died between the core's pass and this instruction -
  is a silent no-op, not an error.

  ## Starting an invocation's child session

  `{:invoke, %Effect.Invoke{}}` with a supported `type` plans
  `{:start_child, invoke, effect}` (`Statifier.Session.Effects`). This is
  never performed from `init/1`: an initial configuration's own `<invoke>`
  would otherwise start the child through `Statifier.start_session/2` while
  this session's own start is still being served by the same
  `Statifier.SessionSupervisor`, and that supervisor process cannot answer
  the inner call until it has answered the outer one. Every
  planned instruction - this one included, at whatever position
  `Statifier.Session.Effects.plan/2` gave it - performs from
  `handle_continue/2`, one message-loop turn after `init/1` returns.
  Performing it resolves `invoke.content`/`invoke.src` through `Statifier.Invoke.Source`
  (`state.invoke_source`, the embedder-supplied resolver from `start_link/2`
  ADR-0038 hands off to), seeds the resolved child `Machine.t()`'s datamodel
  through `Statifier.Session.Invocations.seed_datamodel/2` (spec 6.4.3's
  name-matched `<param>`/namelist seeding), and starts it on
  `Statifier.SessionSupervisor` via `Statifier.start_session/2` with
  `invoked_by: {self(), invoke.invoke_id}`. Success monitors the child and
  records `{pid, session_id, monitor_ref, autoforward}` in
  `state.invocations`; either a resolve failure or a
  `Statifier.start_session/2` failure raises `error.communication` on this
  session's own internal queue instead (Decision 4: 3.12.2 names `<invoke>`
  outright as a communication-error source), through the private
  `invoke_error/4` resolver, and writes no table entry - "terminate the
  processing of the element without further action."

  A session started with `invoked_by: {parent_pid, invoke_id}` (an invoked
  child) monitors `parent_pid` in turn: the parent's `:DOWN` stops this
  session (a child whose parent is gone has nobody to report to), and a
  monitored child's own `:DOWN` pops its entry from `state.invocations` -
  both checked ahead of the ordinary subscriber `:DOWN` clause.

  `start_link/2`'s `:inherit_observers` starts a child with this session's
  `:trace` and subscriber pids at the moment it starts (ADR-0050), rather than
  leaving observation to a post-hoc attach, because an attach cannot
  substitute here: `start_link/2` runs `Interpreter.initialize/2` to
  quiescence, and the child is started from inside the parent's own invoke
  pass, so a subscriber added after the child's pid is knowable has already
  missed that child's `Trace.EntrySet`, `Trace.ContentExecuted`,
  `Trace.InvokePass`, and `Trace.MacrostepStable`.

  ## Cancelling an invocation

  `{:cancel_invoke, %Effect.CancelInvoke{}}` - the core's own reaction to a
  state exiting while one of its `<invoke>`s is still live - plans
  `{:stop_child, invoke_id}` unconditionally (`Statifier.Session.Effects`).
  Performing it pops `invoke_id`'s table entry *before* touching the child,
  `Process.demonitor/2`s the ref with `[:flush]`, and calls this module's own
  `cancel/1` on the child - never `stop/2`: 6.4.3 requires the cancelled
  session to "exit at the end of the next microstep" having "execute[d] the
  `<onexit>` handlers for all active states", which is `Interpreter.cancel/1`'s
  own `exit_interpreter/1` walk, and `GenServer.stop/2` would skip every one
  of them. The child is left to idle `:cancelled` exactly as any cancelled
  session does; this session is no longer monitoring it and no longer holds
  its id, so it is silent by construction. A miss - the invocation already
  popped by its own `:DOWN`, or a second cancel of the same id - is a silent
  no-op.

  Popping the entry first is what makes the drain-time discard below
  correct: any event this child already delivered is un-keyed the instant
  the pop happens, not only once the cancelled child actually halts.

  ## The discard of a cancelled invocation's queued events

  6.4.3: after cancelling, this session "MUST ignore any events it receives
  from that session. In particular it MUST NOT ... insert them into the
  external event queue of the invoking session" (the doubled "not" is
  verbatim in the REC). `handle_continue(:drain, _)` applies this at the one
  point every queued entry passes through it: an `{:invoked_event,
  invoke_id, _}` entry whose `invoke_id` is no longer a key of
  `state.invocations` is dropped and the drain continues, with no separate
  retired-id bookkeeping - the live table is already the predicate (the
  invoke child-session plan's own Decision 6), and cancelling removes the
  key, so every event from that invocation - queued before the cancel or
  arriving after it - is dropped this way.

  The predicate reads the *entry kind*, which `send_invoked_event/3` sets
  only on the child-to-parent direction, and never `event.invokeid`. 6.4.2
  requires an autoforwarded copy to preserve every 5.10.1 field, so an event
  this session forwards to one of its children arrives there still carrying
  a *sibling* invocation's `invokeid` - an id that names nothing in the
  receiving session's own table. Keying the discard on that field would drop
  exactly the copy 6.4.2 requires be delivered; keying it on where the entry
  came from is also what ADR-0027 already says ("every queued entry
  *originating from* a cancelled invokeid").

  `Statifier.Session.Inbox` still needs no keyed discard of its own: the
  predicate is applied to `Inbox.next/1`'s result, not inside the queue,
  which is what keeps `Inbox` ignorant of the invocation *table* even while
  it carries the entry's origin.

  `terminate/2` cancels every entry still in `state.invocations` alongside
  its existing timer cancellation, so an orderly stop of this session leaves
  no orphaned children; the child-side parent monitor above already covers
  the disorderly case.

  ## Two snapshot shapes

  `snapshot/1` returns the whole `%MachineState{}` - the complete, resumable
  position tooling and replay need. `status/1` returns a small projection
  for a caller polling in a loop, since `snapshot/1` copies the entire
  compiled `machine` on every call. For a halted session, the projection's
  `configuration` is read from the retained `%Effect.Done{}` rather than
  `%MachineState{}.configuration`, which `exit_interpreter/1` empties by
  construction - mirroring the restore `test/support/case.ex` performs for
  the same reason.

  ## `interpret/2` is a public seam, not a test hook

  Decided by ADR-0029; see its own `@doc` for the recording contract it
  carries.

  ## Recording taps the input clauses, never the inbox

  `:record` (`start_link/2`) builds a `Statifier.Session.Recording.t()` that
  each of the five input-handling clauses appends one entry to, before that
  entry's effects are ever planned or performed - the same "one recordable
  input path" the converging-paths comment above `handle_info/2`'s fired-timer
  clause already describes. ADR-0029 named the
  four inputs a sound recording needs; ADR-0034 decided replay re-derives core
  effects and re-injects `interpret/2` batches rather than replaying against a
  live session, which is why the tap sits on the input side and not on the
  effect stream `notify/2` fans out. `recording/1` reads the value back; see
  its own `@doc` for the ordering caveat on when it is safe to call.
  """

  use GenServer, restart: :temporary

  alias Statifier.{Effect, Event, Interpreter, Machine, MachineState, Position}
  alias Statifier.Effect.{Done, Invoke}
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event.Cause
  alias Statifier.Invoke.Source
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine.Identity
  alias Statifier.Send.{Routes, Target}
  alias Statifier.Session.{Effects, Inbox, Invocations, Recording, Telemetry, Timers}

  defmodule State do
    @moduledoc false

    @enforce_keys [:machine_state, :session_id, :inbox, :timers]
    defstruct [
      :machine_state,
      :session_id,
      :done_effect,
      :inbox,
      :timers,
      :invoke_source,
      :invoked_by,
      invoke_handlers: %{},
      timer_refs: %{},
      subscribers: %{},
      halted: nil,
      recording: nil,
      invocations: Invocations.new(),
      macrostep_started_at: nil,
      deferred: [],
      # ADR-0050 decisions 2 and 4: off by default, so a session that never
      # opted in starts its own children exactly as before. `true` carries
      # forward into every child this session starts for an `<invoke>`, which
      # is what makes the opt-in transitive down the whole invoke tree.
      inherit_observers: false
    ]

    @type t :: %__MODULE__{
            machine_state: Statifier.MachineState.t(),
            session_id: String.t(),
            done_effect: Statifier.Effect.Done.t() | nil,
            inbox: Statifier.Session.Inbox.t(),
            timers: Statifier.Session.Timers.t(),
            timer_refs: %{reference() => reference()},
            subscribers: %{pid() => reference()},
            halted: :done | :cancelled | :budget_exhausted | nil,
            recording: Statifier.Session.Recording.t() | nil,
            invocations: Statifier.Session.Invocations.t(),
            invoke_source: (String.t() -> {:ok, Machine.t()} | {:error, term()}) | nil,
            invoked_by: {pid(), String.t()} | nil,
            # ADR-0051 decision 2: the per-session `<invoke type> => module`
            # dispatch map `start_link/2`'s `:invoke_handlers` option
            # supplied, default `%{}`. `init/1` derives the `%MachineState{}`
            # `invoke_types` stamp from this same map's keys - one
            # constructor, so the stamped set and this dispatch map cannot
            # diverge (decision 3's anti-drift property).
            invoke_handlers: %{String.t() => module()},
            # The monotonic timestamp (`System.monotonic_time/0`) of the
            # currently open macrostep span - telemetry only, never recorded
            # (ADR-0040, ADR-0034). `nil` outside `drain_event/2`,
            # `drain_cancel/1`, and `deliver_internal/6`'s own spans; the
            # `:initialize` span opened in `init/1` and closed in
            # `handle_continue({:initialize, ...}, _)` uses a local binding
            # carried in the continue term instead, since no `%State{}`
            # exists yet when it opens (ADR-0040).
            macrostep_started_at: integer() | nil,
            # ADR-0044 decision 1: effects returned by a mid-batch ADR-0039
            # seam crossing, queued in crossing order with the
            # `halt_override` that was in force when they were produced, and
            # drained FIFO by the outermost `perform/3` once its own
            # instruction list is exhausted. Always `[]` outside a
            # `perform/3` call - every callback that reads `%State{}` sees
            # an empty queue.
            deferred: [{[Statifier.Effect.t()], :cancelled | nil}],
            # ADR-0050 decisions 2 and 4: whether a child this session starts
            # for an `<invoke>` inherits this session's `:trace` and
            # subscriber pids, and the flag itself, so one opt-in at the root
            # traces the whole invoke tree.
            inherit_observers: boolean()
          }
  end

  @typedoc "A `GenServer` server reference - a pid, or whatever `:name` was started with."
  @type server :: GenServer.server()

  @typedoc """
  The small status projection `status/1` returns, as the counterpart to
  `snapshot/1`'s whole `%MachineState{}`.
  """
  @type status :: %{
          session_id: String.t(),
          status: :running | :done | :cancelled | :budget_exhausted,
          configuration: MapSet.t(String.t()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer(),
          queued_events: non_neg_integer(),
          pending_timers: non_neg_integer()
        }

  @typedoc """
  One live invocation, as `invocations/1` reports it: the author-or-core
  `invoke_id` this session knows the invocation by, the child's own `sess_`
  id, and its pid.
  """
  @type invocation :: Statifier.Session.Invocations.public_entry()

  # -- client -----------------------------------------------------------------

  @doc """
  Starts a session over `machine` (already compiled - `Statifier.compile/1`),
  running `Statifier.Interpreter.initialize/2` to quiescence before
  returning. A document that reaches a stable configuration, or even
  terminates, before any external event is ever sent is corpus-normal; the
  session comes up already `:running`, `:done`, or `:budget_exhausted`
  accordingly.

  `opts`:

    - `:name` - passed to `GenServer.start_link/3` unchanged, so
      `{:via, Registry, _}` works today with no code here.
    - `:session_id`, `:trace`, `:datamodel`, `:max_macrostep_rounds` -
      `Statifier.MachineState.new/2`'s own options, passed straight
      through. The session never generates the `sess_` id itself
      (ADR-0008); it reads it back off
      `machine_state.datamodel["_sessionid"]` once `new/2` has written it,
      since there is no `session_id` field on `%MachineState{}`.
    - `:subscribers` - pids to monitor and forward the effect stream to
      from the start (default `[]`); `subscribe/2` adds more afterward.
    - `:record` - when `true` (default `false`), builds a
      `Statifier.Session.Recording.t()` that captures every delivered event,
      timer firing, cancel marker, and `interpret/2` batch this session
      handles, in input order (ADR-0029). Read it back with `recording/1`.
    - `:invoke_source` - a `(src :: String.t() -> {:ok, Machine.t()} |
      {:error, term()})` function this session hands to
      `Statifier.Invoke.Source.resolve/2` for every `<invoke src="...">` it
      starts (ADR-0038). `nil` (the default) leaves every `src`-only
      invocation unresolved, per `Statifier.Invoke.Source`'s own contract.
    - `:invoke_handlers` - a `%{type_string => module}` map of
      `Statifier.Invoke.Handler`-implementing modules this session
      dispatches a registered `<invoke type="...">` to (ADR-0051). Default
      `%{}`, which registers no type beyond the built-in `scxml`/bare-URI
      set `Statifier.Invoke.Handler.Scxml` already serves as the default
      handler for. The `%MachineState{}` `invoke_types` snapshot this
      session's core is stamped with is derived from this same map's keys,
      so the registered-type set and the dispatch map cannot diverge
      (decision 3).
    - `:invoked_by` - `{parent_pid, invoke_id}`, set by
      `Statifier.Session` itself when it starts a child for an `<invoke>`
      (never set by an ordinary caller). Makes this session monitor
      `parent_pid`, so a dead parent stops it in turn ("Starting an
      invocation's child session" above).
    - `:inherit_observers` - when `true`, every child session this session
      starts for an `<invoke>` is started with this session's `:trace`
      setting, this session's subscriber pids as of the moment the child
      starts, and `inherit_observers: true` of its own, so one opt-in at the
      root traces the whole invoke tree (ADR-0050). Default `false`, which
      starts children exactly as before. Each inherited subscriber receives
      the child's messages under the child's own `session_id` in the
      `{:statifier, session_id, message}` envelope, so a mixed stream
      demultiplexes on that field; `{:halted, _}` is still end-of-stream per
      session id (ADR-0044 decision 2), not for the mailbox as a whole. It is
      a snapshot: `subscribe/2` and `unsubscribe/2` after a child has started
      do not reach that child, and `invocations/1` plus `subscribe/2` on the
      child is how an already-running child is attached to.
    - `:resume` - boots this session at a persisted position (ADR-0060)
      instead of running `Statifier.Interpreter.initialize/2`. Accepts
      either a `Statifier.Position.to_binary/1` blob (decoded via
      `Statifier.Position.from_binary/2` against `machine`, which inherits
      the full ADR-0052 identity gate) or an already-decoded
      `%Statifier.MachineState{}` (the `Statifier.Position.import/2`
      migration path - checked instead against `machine`'s own identity via
      `Statifier.Machine.Identity.matches?/2`, one identity rule for both
      shapes). `machine` stays the positional `%Machine{}` either way; the
      position's own `machine` field is rebound to it, so one compiled
      `Machine` term is shared by the resumed state.

      A resumed session comes up with `machine_state`'s configuration,
      datamodel, history values, `entered_states`, `states_to_invoke`,
      `active_invocations`, and all six counters exactly as persisted - no
      `Interpreter.initialize/2` call, no re-entry of the chart's initial
      states, no `<script>` or `<onentry>` block run a second time.
      `:session_id` resolves to the caller's own option if supplied,
      otherwise to `machine_state.datamodel["_sessionid"]`; supplying it
      explicitly rewrites `datamodel["_sessionid"]` to agree, so the
      `session_id == datamodel["_sessionid"]` invariant always holds.
      `record: true` on a resumed session anchors the new
      `Statifier.Session.Recording.t()` at the resumed position rather than
      at the chart's initial configuration (ADR-0060 decision 6), so
      catch-up (`subscribe/3` with `catch_up: true`) and `Statifier.Replay`
      still reproduce exactly the notified prefix.

      What a resume does **not** restore, each for a reason ADR-0060
      decision 7 records: in-flight delayed-send timers (no scheduling
      deadline is ever stored - a resumed session starts with
      `Statifier.Session.Timers.new()` and an empty `timer_refs` map; a
      durable host re-arms them itself from the `SendDelayed`/`Cancel`
      effect vocabulary, ADR-0054/0055/0059); live invoked children (pids,
      monitor refs, and child session ids are process-local and were never
      part of a position - `active_invocations` carries forward verbatim as
      the record of *what* was invoked, `Statifier.Session.Invocations`
      starts empty, and re-establishing the processes behind those ids is
      the host's job through the invoke handler registry, ADR-0051); and
      the external inbox (`Statifier.Session.Inbox` lives outside
      `%MachineState{}` by ADR-0002's core/session split - anything queued
      but not yet dequeued at persist time is lost with the process that
      held it).

      Refuses with `{:error, {:resume, reason}}` rather than booting a
      silently-wrong session, for `reason` in:

        - `{:conflicting_options, opts}` - `:resume` was passed alongside
          `:trace`, `:datamodel`, or `:max_macrostep_rounds`
          (`Statifier.MachineState.new/2`'s own options, not read on this
          path) or `:invoked_by` (a child session is always library-started,
          never resumed).
        - `:not_a_statifier_blob`, `{:unsupported_format_version, v}`,
          `{:identity_mismatch, expected, actual}`, or `:unidentified_chart`
          - `Statifier.Position.from_binary/2`'s own errors (blob form), or
          the equivalent checks against `machine_state.machine`'s identity
          (struct form).
        - `:position_not_quiescent` - the position's internal event queue is
          non-empty (`Statifier.MachineState.internal_queue_empty?/1`);
          booting mid-macrostep would produce effects with no ADR-0048 input
          boundary behind them. A host drains to quiescence before
          persisting, the same instruction `Statifier.Position.export/1`
          already gives.
        - `:position_not_running` - the position has `running: false`
          (`status: :done`); booting a `GenServer` that is already
          terminated, has notified nobody, and has `halted: nil` is the
          surprising outcome. A host that wants to inspect a finished
          position uses `Statifier.Position.from_binary/2` and
          `Statifier.active_leaf_states/1` directly, no session required.

      See ADR-0060 for the full decision record.
  """
  @spec start_link(machine :: Machine.t(), opts :: keyword()) :: GenServer.on_start()
  def start_link(%Machine{} = machine, opts \\ []) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {machine, opts}, gen_opts)
  end

  @doc "This session's `sess_` id - `datamodel[\"_sessionid\"]`, held apart for routing."
  @spec session_id(server :: server()) :: String.t()
  def session_id(server), do: GenServer.call(server, :session_id)

  @doc """
  The `Statifier.Session.Recording.t()` this session has captured so far, or
  `{:error, :not_recording}` if it was not started with `record: true`.
  Note the neighbouring atom: `subscribe/3` answers the *same* condition
  with `{:error, :not_recorded}`. The two are one letter apart and are
  deliberately not unified here - each reads correctly in its own sentence
  ("this session is not recording"; "that material was not recorded") - so
  match on the one belonging to the function you called.

  Call this only after the run has quiesced relative to whatever this caller
  is waiting on - a timer firing arrives as a message with no ordering
  guarantee against this call, so a `recording/1` issued before an
  `assert_receive` on the effect it produced (or a `wait_for_status/3`-style
  poll) can race the entry it is meant to observe.

  A caller that also wants to subscribe should use `subscribe/3` with
  `catch_up: true` instead: `recording/1` followed by `subscribe/2` has a
  window between the two calls, while `subscribe/3` snapshots and adds the
  pid atomically, in the same `handle_call` (ADR-0049).
  """
  @spec recording(server :: server()) :: {:ok, Recording.t()} | {:error, :not_recording}
  def recording(server), do: GenServer.call(server, :recording)

  @doc """
  Delivers `event` to this session's external inbox (asynchronously - `:ok`
  is returned before the event is necessarily processed). A plain string is
  a convenience over `Statifier.Event.external/2` carrying no data; a
  caller that needs event data builds the `%Statifier.Event{}` directly.
  Queued behind whatever else is already waiting, and processed in that
  order.
  """
  @spec send_event(server :: server(), event :: Event.t() | String.t()) :: :ok
  def send_event(server, %Event{} = event) do
    GenServer.cast(server, {:enqueue_event, event})
  end

  def send_event(server, name) when is_binary(name), do: send_event(server, Event.external(name))

  @doc """
  Delivers `event` to `server`'s external queue as an entry originating from
  `server`'s own invocation `invoke_id` - the child-to-parent direction, and
  the only direction 6.4.3's "MUST ignore any events it receives from that
  [cancelled] session" applies to. `send_event/2` is what every other caller
  wants, autoforwarded copies included; see `Statifier.Session.Inbox`'s
  `entry` typedoc for why the two are distinct entries rather than one entry
  read two ways.
  """
  @spec send_invoked_event(server :: server(), invoke_id :: String.t(), event :: Event.t()) :: :ok
  def send_invoked_event(server, invoke_id, %Event{} = event) when is_binary(invoke_id) do
    GenServer.cast(server, {:enqueue_invoked_event, invoke_id, event})
  end

  @doc """
  The door a non-`scxml` `<invoke>` handler's host uses when its externally
  run service has finished (ADR-0051 decision 5) - the generalization of
  what a child `Statifier.Session` does for itself through
  `return_done_event/2` when *it* halts `:done`. Constructs
  `done.invoke.<invoke_id>` from `donedata` (spec 6.4's own shape: the
  service's `<donedata>`, or whatever a process-less host's own equivalent
  is - 6.4's MUST here is on the *service*, not this engine, which only
  provides the door and documents what arrives through it), stamps
  `invokeid`, and delivers it exactly as `send_invoked_event/3` would -
  through the same invocation-tagged entry, subject to the same 6.4.3
  drain-time discard if `invoke_id` is no longer live by the time it is
  dequeued (a late arrival for an invocation already cancelled). `server`
  is `invoke_id`'s own *owning* session - the one whose `<invoke>` started
  it, not a child of it, since a handler-backed invocation has no child
  session at all; the built-in `scxml` handler's own completion
  (`return_done_event/2`) calls this the same way, on its own parent.

  `invoke_id`'s table entry is popped once the delivered event has cleared
  the drain that decides whether to discard it - not synchronously here,
  which would make the very entry this call is reporting on already look
  gone to that same drain-time check (`handle_info/2`'s `{:pop_invocation,
  _}` clause below carries the full reasoning). A handler-backed
  invocation's entry (ADR-0051 decision 6) has no pid for a `:DOWN` to pop
  on its own, so this call is the only place it is ever removed; calling
  this for an invocation this session already popped (a prior cancel, or a
  second `done_invocation/3` call for the same id) is a harmless no-op both
  times - the discard drops the event, and the pop finds nothing.
  """
  @spec done_invocation(server :: server(), invoke_id :: String.t(), donedata :: term()) :: :ok
  def done_invocation(server, invoke_id, donedata \\ nil) when is_binary(invoke_id) do
    GenServer.cast(server, {:done_invocation, invoke_id, donedata})
  end

  @doc """
  Hands `effects` - any list of `Statifier.Effect.t()` values, from any
  driver of the pure core - to this session's own effect-interpretation
  path: planned through `Statifier.Session.Effects.plan/1` and performed
  exactly as the effects this session's own drive of the core produces.
  ADR-0003's "Embedders can supply their own effect interpreter", read the
  other way: an embedder that drives the core itself can still lean on this
  session for timer and routing service. It is also what makes
  `:send_delayed`/`:cancel` testable end to end before any document can
  produce them, and it funnels through the same internal cast path
  `send_event/2` uses, so it opens no side door around the inbox.

  **This widens what a recording has to contain** (ADR-0029). The
  three-input replay tuple - `(machine, initial data, external event
  log)` - reconstructs a run only when every effect this session
  interpreted came from `Statifier.Interpreter.initialize/2` or
  `handle_event/2`. An `interpret/2` call hands the session effects that no
  such call produced, so replaying a run that used it needs a fourth
  input: each `interpret/2` batch, recorded at its position in this
  session's serialized input order alongside the event log
  (`docs/observability.md` constraint 6). Calling this function does not
  void the replay guarantee - it obligates the recording. That is a
  statement about the recording's contents, not a leak in the boundary:
  the calls are still ordered, still observable, still on the one input
  path.
  """
  @spec interpret(server :: server(), effects :: [Effect.t()]) :: :ok
  def interpret(server, effects) when is_list(effects) do
    GenServer.cast(server, {:interpret, effects})
  end

  @doc """
  Enqueues the cancel marker onto this session's external inbox - a queue
  entry, not an out-of-band call, so a cancellation is recorded in the same
  ordered queue as every event: one queued behind several events is
  processed in that order, not ahead of them. Draining it runs
  `Statifier.Interpreter.cancel/1` - Appendix D's `running = false`
  followed by `exitInterpreter()` - and halts this session `:cancelled`.
  """
  @spec cancel(server :: server()) :: :ok
  def cancel(server), do: GenServer.cast(server, :enqueue_cancel)

  @doc """
  The whole `%Statifier.MachineState{}` this session currently holds - a
  complete, resumable position (`docs/observability.md` constraint 1). A
  term copy and nothing more: `MachineState` carries no pid, ref, port, or
  fun.
  """
  @spec snapshot(server :: server()) :: MachineState.t()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc """
  A small status projection - `session_id`, `status`, `configuration` (as
  string ids), the three step counters, and the queued-event and
  pending-timer counts - for a caller polling in a loop, since `snapshot/1`
  copies the entire compiled `machine` on every call. For a halted session,
  `configuration` is read from the retained `%Statifier.Effect.Done{}`
  rather than the (by-then-empty) `%MachineState{}.configuration`.
  """
  @spec status(server :: server()) :: status()
  def status(server), do: GenServer.call(server, :status)

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
  `subscribe/2`. Catch-up does not close that gap for a child: children
  are not started with `record: true`, so `subscribe/3` with
  `catch_up: true` on one answers `{:error, :not_recorded}` - see
  `start_link/2`'s `:inherit_observers` for why that is not equivalent to
  inheriting from the start (ADR-0050 decisions 3 and 6).
  """
  @spec invocations(server :: server()) :: [invocation()]
  def invocations(server), do: GenServer.call(server, :invocations)

  @doc """
  Adds `pid` to this session's monitored subscriber set. Idempotent - a
  pid already subscribed is not monitored twice.
  """
  @spec subscribe(server :: server(), pid :: pid()) :: :ok
  def subscribe(server, pid) when is_pid(pid), do: GenServer.call(server, {:subscribe, pid})

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
  acceptable falls back to `subscribe/2`. Note the neighbouring atom:
  `recording/1` answers the same condition with `{:error, :not_recording}`,
  one letter apart and deliberately not unified - match on the one belonging
  to the function you called.
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

  @doc "Removes `pid` from this session's subscriber set. A no-op if it was never in it."
  @spec unsubscribe(server :: server(), pid :: pid()) :: :ok
  def unsubscribe(server, pid) when is_pid(pid), do: GenServer.call(server, {:unsubscribe, pid})

  @doc """
  Stops the session. `terminate/2` cancels every outstanding delayed-send
  timer before the process exits (spec 6.2's discard-on-termination), so
  nothing scheduled is ever delivered after this call returns.
  """
  @spec stop(server :: server(), reason :: term()) :: :ok
  def stop(server, reason \\ :normal), do: GenServer.stop(server, reason)

  # -- callbacks ----------------------------------------------------------

  # ADR-0048 decision 2's initialization stamping needs the session's own id
  # before `Interpreter.initialize/2` runs (the snapshot names its own
  # session, mirroring `deliver/5`'s self-clause), so this callback resolves
  # `session_id` and registers under it *first* - see `register_session/1`'s
  # own comment for why registering ahead of `initialize/2` is still safe.
  # `start_time` and `span_ref` for the `:initialize` macrostep span still
  # travel in a local binding rather than `%State{}.macrostep_started_at`
  # (ADR-0040's one exception, unchanged by this reordering): no `%State{}`
  # exists yet, and the span does not close until `handle_continue/2` has
  # performed the effects this callback only plans.
  @impl GenServer
  def init({%Machine{} = machine, opts}) do
    case resolve_resume(opts, machine) do
      {:ok, resume} -> init_boot(machine, opts, resume)
      {:error, reason} -> {:stop, {:resume, reason}}
    end
  end

  # The tail of `init/1`, shared by a fresh start and a resume: `resume` has
  # already been resolved and refused what needed refusing
  # (`resolve_resume/2`), so this function only ever assembles a `%State{}`
  # and hands the `{machine_state, effects}` pair off to `handle_continue/2`
  # - `boot/6` is the one branch point (ADR-0060's "Key Discoveries": this is
  # the single spot `lib/statifier/session.ex:771` names).
  @spec init_boot(machine :: Machine.t(), opts :: keyword(), resume :: resume()) ::
          {:ok, State.t(), {:continue, tuple()}}
  defp init_boot(machine, opts, resume) do
    session_id = resolve_session_id(opts, resume)
    register_session(session_id)

    invoked_by = Keyword.get(opts, :invoked_by)
    invoke_handlers = Keyword.get(opts, :invoke_handlers, %{})

    start_time = System.monotonic_time()
    span_ref = make_ref()

    {machine_state, effects, machine_opts, trigger, anchor} =
      boot(resume, machine, opts, session_id, invoked_by, invoke_handlers)

    subscribers =
      opts
      |> Keyword.get(:subscribers, [])
      |> Enum.reduce(%{}, fn pid, acc -> Map.put(acc, pid, Process.monitor(pid)) end)

    monitor_parent(invoked_by)

    Telemetry.init(session_id, machine, machine_state, invoked_by, trigger == :resume)
    Telemetry.macrostep_start(session_id, trigger, nil, span_ref)

    recording =
      if Keyword.get(opts, :record, false) do
        Recording.new(machine, machine_opts, anchor)
      end

    state = %State{
      machine_state: machine_state,
      session_id: session_id,
      inbox: Inbox.new(),
      timers: Timers.new(),
      subscribers: subscribers,
      recording: recording,
      invocations: Invocations.new(),
      invoke_source: Keyword.get(opts, :invoke_source),
      invoke_handlers: invoke_handlers,
      invoked_by: invoked_by,
      inherit_observers: Keyword.get(opts, :inherit_observers, false)
    }

    # `perform/3` runs from `handle_continue/2` rather than here, and the
    # `:initialize`/`:resume` span closes there with it. `Statifier.start_session/2`
    # blocks the `Statifier.SessionSupervisor` process for the whole of this
    # callback, and performing a `{:start_child, %Invoke{}, _}` from inside it
    # would call `DynamicSupervisor.start_child/2` on that same busy
    # supervisor - neither call could ever return. A `handle_continue`
    # runs before any message reaches this process, so nothing observes the
    # split; the whole planned instruction list still runs as one ordered fold,
    # which is what keeps ADR-0039's re-entry and `{:halt, _}` in the order
    # `Statifier.Session.Effects.plan/2` produced them.
    {:ok, state, {:continue, {:initialize, effects, start_time, span_ref}}}
  end

  # -- ADR-0060: resolving and refusing :resume ----------------------------

  @typedoc "What `resolve_resume/2` decided: an ordinary start, or a resumed position."
  @type resume :: :fresh | {:resumed, MachineState.t()}

  # `:resume` is never one of `MachineState.new/2`'s own options, and it is
  # never set on a library-started invoked child - see `start_link/2`'s own
  # `@doc`. Passing any of these five alongside `:resume` would either be
  # silently ignored (the first three; `MachineState.new/2` is never called
  # on this path) or is nonsensical on its face (`:invoked_by`), so all five
  # are refused together rather than only some.
  @resume_conflicting_opts [:trace, :datamodel, :max_macrostep_rounds, :invoked_by]

  # Checks run in the order `start_link/2`'s own `@doc` states: conflicting
  # options first (a shape check that needs no decode), then decode/identity
  # (a wrong-revision blob reports the revision, not a confusing quiescence
  # error further down), then the two session-boot preconditions
  # (`:position_not_quiescent`, `:position_not_running`) `Statifier.Position.
  # from_binary/2` itself has no opinion on - `:resume` is deliberately
  # stricter than the codec it drives (ADR-0060 decision 4).
  @spec resolve_resume(opts :: keyword(), machine :: Machine.t()) ::
          {:ok, resume()} | {:error, term()}
  defp resolve_resume(opts, machine) do
    case Keyword.fetch(opts, :resume) do
      :error ->
        {:ok, :fresh}

      {:ok, resume} ->
        with :ok <- check_no_conflicting_resume_opts(opts),
             {:ok, machine_state} <- decode_resume(resume, machine),
             :ok <- check_position_quiescent(machine_state),
             :ok <- check_position_running(machine_state) do
          {:ok, {:resumed, machine_state}}
        end
    end
  end

  @spec check_no_conflicting_resume_opts(opts :: keyword()) ::
          :ok | {:error, {:conflicting_options, keyword()}}
  defp check_no_conflicting_resume_opts(opts) do
    case Keyword.take(opts, @resume_conflicting_opts) do
      [] -> :ok
      conflicting -> {:error, {:conflicting_options, conflicting}}
    end
  end

  # The blob form gets the whole ADR-0052 identity gate for free from
  # `Position.from_binary/2` - its error vocabulary is propagated unflattened
  # (`:not_a_statifier_blob`, `{:unsupported_format_version, _}`,
  # `{:identity_mismatch, _, _}`, `:unidentified_chart`). The struct form
  # (the `Position.import/2` migration path, ADR-0060 decision 1) is made to
  # refuse identically by hand: either side unidentified is
  # `:unidentified_chart`, and a mismatch between the two identified sides is
  # `{:identity_mismatch, expected, actual}` - one identity rule for both
  # shapes. Either form rebinds the position's `machine` to the supplied
  # positional `machine`, so one compiled `Machine` term is shared from here
  # on (the blob form already does this inside `from_binary/2`; the struct
  # form was already identity-equal, so this only makes the sharing literal).
  @spec decode_resume(resume :: binary() | MachineState.t(), machine :: Machine.t()) ::
          {:ok, MachineState.t()} | {:error, term()}
  defp decode_resume(blob, machine) when is_binary(blob) do
    Position.from_binary(blob, machine)
  end

  defp decode_resume(%MachineState{machine: %Machine{identity: nil}}, %Machine{}) do
    {:error, :unidentified_chart}
  end

  defp decode_resume(%MachineState{}, %Machine{identity: nil}) do
    {:error, :unidentified_chart}
  end

  defp decode_resume(
         %MachineState{machine: %Machine{identity: source}} = machine_state,
         %Machine{
           identity: target
         } = machine
       ) do
    if Identity.matches?(source, target) do
      {:ok, %{machine_state | machine: machine}}
    else
      {:error, {:identity_mismatch, source, target}}
    end
  end

  @spec check_position_quiescent(machine_state :: MachineState.t()) ::
          :ok | {:error, :position_not_quiescent}
  defp check_position_quiescent(machine_state) do
    if MachineState.internal_queue_empty?(machine_state) do
      :ok
    else
      {:error, :position_not_quiescent}
    end
  end

  @spec check_position_running(machine_state :: MachineState.t()) ::
          :ok | {:error, :position_not_running}
  defp check_position_running(%MachineState{running: false}), do: {:error, :position_not_running}
  defp check_position_running(%MachineState{status: :done}), do: {:error, :position_not_running}
  defp check_position_running(%MachineState{}), do: :ok

  # OQ-2: the resumed session keeps the position's own `_sessionid` unless
  # the caller supplied `:session_id`, in which case that value wins (and
  # `boot/6`'s resumed clause rewrites `datamodel["_sessionid"]` to agree,
  # below). A fresh start is unchanged: `MachineState.generate_session_id/0`
  # only ever runs here, never inside `MachineState.new/2` on this path
  # either, so the id `register_session/1` registers under is always
  # resolved before the first drive.
  @spec resolve_session_id(opts :: keyword(), resume :: resume()) :: String.t()
  defp resolve_session_id(opts, :fresh) do
    Keyword.get_lazy(opts, :session_id, &MachineState.generate_session_id/0)
  end

  defp resolve_session_id(opts, {:resumed, machine_state}) do
    Keyword.get(opts, :session_id, machine_state.datamodel["_sessionid"])
  end

  # The one branch point ADR-0060's "Key Discoveries" names: a fresh start
  # calls `Interpreter.initialize/2` exactly as before; a resume stamps
  # `routes`/`invoke_types` onto the persisted position and performs no
  # entry at all (`effects: []` - the non-restoration ADR-0060 decisions 1
  # and 4 describe, expressed in code). Both arms return the same five-tuple
  # so `init_boot/3` above has one tail regardless of which ran.
  @spec boot(
          resume :: resume(),
          machine :: Machine.t(),
          opts :: keyword(),
          session_id :: String.t(),
          invoked_by :: {pid(), String.t()} | nil,
          invoke_handlers :: %{String.t() => module()}
        ) :: {MachineState.t(), [Effect.t()], keyword(), :initialize | :resume, binary() | nil}
  defp boot(:fresh, machine, opts, session_id, invoked_by, invoke_handlers) do
    machine_opts =
      opts
      |> Keyword.take([:trace, :datamodel, :max_macrostep_rounds])
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:routes, init_routes(session_id, invoked_by))
      # ADR-0051 decision 3's "one constructor": the `invoke_types` snapshot
      # the core is stamped with is derived from `invoke_handlers`'s own
      # keys, not declared separately, so the registered-type set and the
      # dispatch map `plan_context/1` builds below cannot diverge.
      # `:invoke_handlers` itself rides along in `machine_opts` too, purely
      # so `Recording.new/3` (called with this same keyword list) can
      # normalize it into the recording (`@normalized_opts`) - `Statifier.
      # MachineState.new/2` reads no such key and ignores it.
      |> Keyword.put(:invoke_types, InvokeTypes.new(types: Map.keys(invoke_handlers)))
      |> Keyword.put(:invoke_handlers, invoke_handlers)

    {machine_state, effects} = Interpreter.initialize(machine, machine_opts)
    {machine_state, effects, machine_opts, :initialize, nil}
  end

  defp boot({:resumed, machine_state}, _machine, _opts, session_id, invoked_by, invoke_handlers) do
    machine_state =
      machine_state
      |> stamp_session_id(session_id)
      |> MachineState.put_routes(init_routes(session_id, invoked_by))
      |> MachineState.put_invoke_types(InvokeTypes.new(types: Map.keys(invoke_handlers)))

    # `resolve_resume/2` already refused a non-quiescent, unidentified, or
    # otherwise unencodable position, so `to_binary/1`'s error arm is
    # unreachable here - a `MatchError` on it would mean one of those checks
    # regressed, not a third refusal this function needs to invent.
    {:ok, anchor} = Position.to_binary(machine_state)

    machine_opts = [
      session_id: session_id,
      trace: machine_state.trace,
      datamodel: machine_state.datamodel,
      max_macrostep_rounds: machine_state.max_macrostep_rounds,
      routes: machine_state.routes,
      invoke_types: machine_state.invoke_types,
      invoke_handlers: invoke_handlers
    ]

    {machine_state, [], machine_opts, :resume, anchor}
  end

  # OQ-2's rewrite half: keeps `%State{}.session_id == datamodel["_sessionid"]`
  # true regardless of whether the caller supplied `:session_id` or the
  # position's own id was reused - a no-op write in the latter case.
  @spec stamp_session_id(machine_state :: MachineState.t(), session_id :: String.t()) ::
          MachineState.t()
  defp stamp_session_id(%MachineState{datamodel: datamodel} = machine_state, session_id) do
    %{machine_state | datamodel: Map.put(datamodel, "_sessionid", session_id)}
  end

  # `invoked_by` is `nil` for every session started as a plain document (the
  # common case) and `{parent_pid, invoke_id}` for a child `Statifier.Session`
  # starts to serve an `<invoke>` ("Starting an invocation's child session",
  # this module's own moduledoc). Monitoring the parent here, rather than
  # leaving it to the parent's own side, is what makes a brutally-killed
  # parent take its children down (ADR-0027 decision 3): the child's own
  # `:DOWN` clause below stops it the moment that monitor fires.
  @spec monitor_parent(invoked_by :: {pid(), String.t()} | nil) :: :ok
  defp monitor_parent(nil), do: :ok

  defp monitor_parent({parent_pid, _invoke_id}) do
    Process.monitor(parent_pid)
    :ok
  end

  # ADR-0027 decision 2: registration happens here, not by a caller-supplied
  # `:name`. It now runs *before* `Interpreter.initialize/2` rather than
  # after it (ADR-0048 decision 2): the initialization drive's own route
  # snapshot has to name this session's own id in its `sessions` set before
  # that drive runs, and `session_id` is resolved locally in `init/1` now
  # (`MachineState.generate_session_id/0`, made public for exactly this) -
  # there is no `Interpreter.initialize/2` result left to read it back from
  # first. Registering ahead of `init/1` returning is safe: `init/1`
  # processes no message of its own, so anything another session casts at
  # this newly registered name simply waits in the mailbox until this
  # callback (and the `handle_continue({:initialize, ...}, _)` that follows
  # it) has finished - the ordinary GenServer guarantee that a process
  # answers no message until `init/1` returns, unaffected by registering
  # one step earlier inside it. There is no separate
  # `Statifier.Registry`-running check ahead of the call: `Registry.register/3`
  # itself raises when the named registry does not exist, and that raise is
  # rescued into the same no-op every other registration failure gets, so a
  # bare `start_link/2` embedder who never placed `Statifier.Supervisor`
  # stays legal and unregistered (the "bare `start_link/2`" section above)
  # through the same path as any other failure, not a second mechanism.
  # Failure is never fatal to the session: whether `Statifier.Registry`
  # was never started, crashed mid-call, or `session_id` somehow collides,
  # the session still starts, merely unreachable by id - exactly what an
  # unregistered session already is. Registration is a one-shot call made
  # here at `init/1` time only; a session that starts before
  # `Statifier.Supervisor` exists stays unregistered even if the runtime
  # is placed later, since nothing here retries it.
  @spec register_session(session_id :: String.t()) :: :ok
  defp register_session(session_id) do
    Registry.register(Statifier.Registry, session_id, nil)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # -- ADR-0048 route snapshots -------------------------------------------

  # `init/1`'s own call: no `%State{}` exists yet (this *is* the snapshot for
  # the drive that creates one), so `routes/3` below is given the three facts
  # directly rather than reading them off a struct - a session just starting
  # has never invoked anything yet, hence the empty `invokes` set.
  @spec init_routes(session_id :: String.t(), invoked_by :: {pid(), String.t()} | nil) ::
          Routes.t()
  defp init_routes(session_id, invoked_by) do
    routes(session_id, invoked_by != nil, [])
  end

  # ADR-0048 decision 1/4: exactly what `deliver/5` below resolves - the
  # registry's keys plus this session's own id (a session is accessible to
  # itself whether or not it is registered, the mirror of `deliver/5`'s own
  # self-clause), whether a parent exists, and the live invoke ids passed in.
  # Point-in-time truth by definition (decision 5); the registry enumeration
  # is O(live sessions) per stamping, accepted in the record's consequences.
  # Takes the three facts as plain values, not a `%State{}`, since `init/1`
  # calls this before any `%State{}` exists (`init_routes/2` above) - `stamp/1`
  # below is the one caller that already holds a `%State{}` and reads them
  # off it.
  @spec routes(
          session_id :: String.t(),
          parent? :: boolean(),
          invoke_ids :: [String.t()] | MapSet.t(String.t())
        ) :: Routes.t()
  defp routes(session_id, parent?, invoke_ids) do
    Routes.new(
      sessions: MapSet.put(registry_keys(), session_id),
      parent?: parent?,
      invokes: MapSet.new(invoke_ids)
    )
  end

  # `Registry.select/2` over a `keys: :unique` registry, with the same
  # `ArgumentError` rescue `registry_lookup/1` already carries for the
  # "no runtime placed" case - a bare `start_link/2` sender is allowed to be
  # in it, and it simply declares no reachable peers.
  @spec registry_keys() :: MapSet.t(String.t())
  defp registry_keys do
    Statifier.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> MapSet.new()
  rescue
    ArgumentError -> MapSet.new()
  end

  # ADR-0048's per-drive stamping site, shared by every recordable input
  # boundary: `handle_cast`'s `{:enqueue_event, _}`,
  # `{:enqueue_invoked_event, _, _}`, `:enqueue_cancel`, `{:interpret, _}`,
  # `handle_info`'s `{:statifier_delayed_send, ...}`, and
  # `deliver_internal/6`. Each site calls this immediately before recording
  # its entry, so the recorded entry and the stamped `%MachineState{}` carry
  # the same value by construction - a derived drive inside the same drain
  # (a `:self` route's re-enqueue) reads whatever snapshot is already on
  # `%MachineState{}` rather than triggering a stamp of its own.
  @spec stamp(state :: State.t()) :: State.t()
  defp stamp(%State{} = state) do
    new_routes =
      routes(state.session_id, state.invoked_by != nil, Invocations.invoke_ids(state.invocations))

    %{state | machine_state: MachineState.put_routes(state.machine_state, new_routes)}
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

  # `mainEventLoop`'s dequeue tail (Appendix D), with `Statifier.Session.Inbox`
  # in place of the blocking `externalQueue.dequeue()`: while an entry is
  # waiting, drain it and continue; empty stops with no further work. A
  # `:cancel` entry is always drained, even while halted (a budget-halted
  # `%MachineState{}` is still `running`, so `Interpreter.cancel/1` still
  # succeeds) - an ordinary event is drained only while not halted, so it
  # stays queued rather than being silently dropped.
  @impl GenServer
  def handle_continue(:drain, state) do
    case Inbox.next(state.inbox) do
      :empty ->
        {:noreply, state}

      {:ok, :cancel, inbox} ->
        state = %{state | inbox: inbox} |> drain_cancel()
        {:noreply, state, {:continue, :drain}}

      {:ok, entry, _inbox}
      when state.halted != nil and elem(entry, 0) in [:event, :invoked_event] ->
        {:noreply, state}

      {:ok, {:invoked_event, invoke_id, event}, inbox} ->
        if Invocations.live?(state.invocations, invoke_id) do
          state = %{state | inbox: inbox} |> drain_event(event)
          {:noreply, state, {:continue, :drain}}
        else
          # 6.4.3: "MUST ignore any events it receives from that [cancelled]
          # session. In particular it MUST NOT ... insert them into the
          # external event queue of the invoking session." `Invocations`'s
          # live table is the predicate (Decision 6, `docs/plans/`): an
          # entry is discarded whenever the invocation that *delivered* it no
          # longer names a live one, whether it was queued before the cancel
          # or arrived after it - `{:stop_child, _}` below pops the entry
          # before cancelling, so nothing accumulates and nothing needs a
          # separate retired-id set (ADR-0027's own "drops, at drain time,
          # every queued entry originating from a cancelled invokeid").
          #
          # The predicate reads the *entry kind*, never `event.invokeid`:
          # 6.4.2 makes an autoforwarded copy preserve every 5.10.1 field,
          # so an event forwarded to a child arrives still carrying the
          # sibling invocation's `invokeid`, which names nothing in the
          # receiving session's own table. Keying on the field would discard
          # exactly the copy 6.4.2 requires be delivered
          # (`Statifier.Session.Inbox`'s `entry` typedoc).
          {:noreply, %{state | inbox: inbox}, {:continue, :drain}}
        end

      {:ok, {:event, event}, inbox} ->
        state = %{state | inbox: inbox} |> drain_event(event)
        {:noreply, state, {:continue, :drain}}
    end
  end

  @impl GenServer
  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}
  def handle_call(:snapshot, _from, state), do: {:reply, state.machine_state, state}
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call(:invocations, _from, state) do
    {:reply, Invocations.list(state.invocations), state}
  end

  def handle_call(:recording, _from, %State{recording: nil} = state) do
    {:reply, {:error, :not_recording}, state}
  end

  def handle_call(:recording, _from, %State{recording: recording} = state) do
    {:reply, {:ok, recording}, state}
  end

  def handle_call({:subscribe, _pid, :catch_up}, _from, %State{recording: nil} = state) do
    {:reply, {:error, :not_recorded}, state}
  end

  def handle_call({:subscribe, pid, :catch_up}, _from, %State{recording: recording} = state) do
    {:reply, {:ok, recording}, %{state | subscribers: add_subscriber(state.subscribers, pid)}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: add_subscriber(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, subscribers} ->
        {:reply, :ok, %{state | subscribers: subscribers}}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  @impl GenServer
  def handle_cast({:enqueue_event, event}, state) do
    state = stamp(state)
    state = record(state, &Recording.put_event(&1, event, state.machine_state.routes))
    {:noreply, %{state | inbox: Inbox.enqueue_event(state.inbox, event)}, {:continue, :drain}}
  end

  def handle_cast({:enqueue_invoked_event, invoke_id, event}, state) do
    {:noreply, enqueue_invoked(state, invoke_id, event), {:continue, :drain}}
  end

  # `done_invocation/3`'s own cast: `build_done_event/3` is the one
  # `done.invoke.<invoke_id>` construction site `return_done_event/2` also
  # calls through (`done_invocation/3`'s own doc). The entry pop is
  # deliberately *not* here - `send(self(), {:pop_invocation, invoke_id})`
  # queues it behind the `{:continue, :drain}}` this cast returns, which
  # fully drains (including the entry just enqueued below) before the
  # GenServer's receive loop looks at the next message; popping
  # synchronously in this same clause would make `state.invocations`, as
  # seen by that very drain, already look like `invoke_id` is not live -
  # discarding the event this call exists to deliver. See
  # `handle_info/2`'s `{:pop_invocation, _}` clause for the other half.
  def handle_cast({:done_invocation, invoke_id, donedata}, state) do
    event = build_done_event(state.session_id, invoke_id, donedata)
    send(self(), {:pop_invocation, invoke_id})
    {:noreply, enqueue_invoked(state, invoke_id, event), {:continue, :drain}}
  end

  def handle_cast(:enqueue_cancel, state) do
    state = stamp(state)
    state = record(state, &Recording.put_cancel(&1, state.machine_state.routes))
    {:noreply, %{state | inbox: Inbox.enqueue_cancel(state.inbox)}, {:continue, :drain}}
  end

  def handle_cast({:interpret, effects}, state) do
    state = stamp(state)
    state = record(state, &Recording.put_interpret(&1, effects, state.machine_state.routes))
    Telemetry.interpret(state.session_id, length(effects), state.machine_state)
    {:noreply, perform(state, effects), {:continue, :drain}}
  end

  # The fired-timer path (spec 6.2): forget the reference regardless of
  # whether this session is halted - a fired timer is gone either way - then
  # deliver by `route`, resolved now rather than at schedule time (6.2.3:
  # the route was decided when the `<send>` was *evaluated*, but a
  # cross-session target can only be *reached* once the timer actually
  # fires) - `deliver_fired/4` below. A `:self` route enqueues onto the
  # ordinary inbox exactly as `send_event/2` would, so a caller's send, a
  # self-targeted send re-enqueued from an effect, and a fired timer all
  # reach the core through the one recordable input path
  # (`docs/observability.md` constraint 6). `handle_continue/2`'s own halted
  # check decides whether it is drained now or stays queued.
  @impl GenServer
  def handle_info({:statifier_delayed_send, ref, send_id, route, event, effect}, state) do
    state = stamp(state)
    state = record(state, &Recording.put_timer(&1, send_id, event, state.machine_state.routes))

    state = %{
      state
      | timers: Timers.forget(state.timers, ref),
        timer_refs: Map.delete(state.timer_refs, ref)
    }

    # `deliver_fired/4` -> `deliver/5` can reach `deliver_internal/6`
    # (`:internal` target or an unreachable route via `communication_error/4`)
    # entirely outside any `perform/3` call - the one caller of
    # `deliver_internal/6` that is not inside a `perform/3` fold (ADR-0044's
    # change-4 seam). An unguarded deferral would strand those effects in
    # `state.deferred` forever, so drain explicitly here. `drain_deferred/1`
    # on an empty queue is a single pattern match, so the non-seam-crossing
    # routes (`:self`, a live `{:session, sid}`, `:parent`, `{:invoke, _}`)
    # pay nothing for this. Unlike the in-fold paths, `handle_info/2` opens
    # no `in_macrostep/4` span of its own, so on this path the deferred
    # batch's `{:effect, _}` notifications and effect telemetry arrive with
    # no enclosing macrostep span at all - accepted, not fixed, per ADR-0044.
    state = deliver_fired(route, event, effect, state) |> drain_deferred()

    {:noreply, state, {:continue, :drain}}
  end

  # This session's own invoking parent has gone down (`monitor_parent/1`'s
  # own comment) - a child with nobody to report to has nothing left to do.
  # Ahead of the general clause below on purpose: `pid` here is
  # `state.invoked_by`'s own parent pid, which is never also a subscriber or
  # an invocation this session started, so clause order never actually
  # picks between them for one `:DOWN` - but stating the parent case first
  # is what the moduledoc's own ordering claim documents.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{invoked_by: {pid, _id}} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Invocations.pop_by_pid(state.invocations, pid) do
      {{_invoke_id, _entry}, invocations} ->
        {:noreply, %{state | invocations: invocations}}

      {nil, _unchanged} ->
        case Map.get(state.subscribers, pid) do
          ^ref -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
          _other -> {:noreply, state}
        end
    end
  end

  # `done_invocation/3`'s own deferred half (its own doc, and
  # `handle_cast/2`'s `{:done_invocation, _, _}` clause): a handler-backed
  # invocation has no pid, so nothing ever sends this session a `:DOWN` for
  # it - this message is the only removal `done_invocation/3` gets, and it
  # is sent (`send(self(), _)`) rather than popped inline specifically so it
  # lands *after* the `{:continue, :drain}}` that same cast returns has run
  # to completion: a GenServer's `handle_continue/2` chain always finishes
  # before the next mailbox message is taken, so by the time this clause
  # runs, the done event `done_invocation/3` just enqueued has already
  # either been delivered (found `invoke_id` live) or discarded (found it
  # already popped by an intervening cancel) - never the reverse, which
  # popping synchronously in the cast would have risked. `Invocations.pop/2`
  # is idempotent on a miss, so a `invoke_id` a prior cancel already popped
  # costs nothing here.
  def handle_info({:pop_invocation, invoke_id}, state) do
    {_entry, invocations} = Invocations.pop(state.invocations, invoke_id)
    {:noreply, %{state | invocations: invocations}}
  end

  # Spec 6.2: "If the SCXML session terminates before the delay interval has
  # elapsed, the SCXML Processor MUST discard the message without
  # attempting to deliver it." Every live timer this session ever scheduled
  # is cancelled here, `Statifier.Session.Timers.refs/1` in hand.
  #
  # Every live child is cancelled alongside the timers, so an orderly parent
  # stop leaves no orphans: `Session.cancel/1` is a cast, not a call, so this
  # never blocks terminate/2 waiting on a child that is itself mid-shutdown.
  # The disorderly case (a parent that dies without running terminate/2 at
  # all - a kill, a crash) is covered instead by the child-side parent
  # monitor from Phase 2 (`monitor_parent/1`'s own comment): the child's own
  # `:DOWN` on its parent stops it without this session's help.
  @impl GenServer
  def terminate(reason, state) do
    state.timers
    |> Timers.refs()
    |> Enum.each(fn ref ->
      case Map.get(state.timer_refs, ref) do
        nil -> :ok
        timer_ref -> Process.cancel_timer(timer_ref)
      end
    end)

    state.invocations
    |> Invocations.entries()
    |> Enum.each(fn {_invoke_id, %{pid: pid}} -> cancel(pid) end)

    {status, _configuration} = status_and_configuration(state)
    Telemetry.terminate(state.session_id, reason, status, state.machine_state)

    :ok
  end

  # -- draining -------------------------------------------------------------

  @spec drain_cancel(state :: State.t()) :: State.t()
  defp drain_cancel(state) do
    in_macrostep(state, :cancel, nil, fn state ->
      case Interpreter.cancel(state.machine_state) do
        {:ok, machine_state, effects} ->
          %{state | machine_state: machine_state}
          |> perform(effects, halt_override: :cancelled)

        # A race: something else already stopped the core (e.g. natural
        # termination reached it first). No crash, no further state change.
        {:error, :not_running} ->
          state
      end
    end)
  end

  @spec drain_event(state :: State.t(), event :: Event.t()) :: State.t()
  defp drain_event(state, event) do
    in_macrostep(state, :event, event, fn state ->
      case Interpreter.handle_event(state.machine_state, event) do
        {:ok, machine_state, effects} ->
          %{state | machine_state: machine_state} |> perform(effects)

        {:error, :not_running} ->
          state
      end
    end)
  end

  # ADR-0040 Decision 2/3: opens the `[:statifier, :session, :macrostep,
  # :start]`/`[..., :stop]` span pair around `drive`'s core-driving call
  # (`Interpreter.handle_event/2`, `Interpreter.cancel/1`, or
  # `Interpreter.deliver_internal/5`, per caller) plus the effect
  # interpretation `perform/3` runs on its result - the span closes only once
  # `state.halted` has whatever value that call produced, which is what
  # `macrostep_outcome/1` reads. `state.macrostep_started_at` holds the open
  # span's start time only for the span's own duration, reset to `nil` once
  # it closes.
  @spec in_macrostep(
          state :: State.t(),
          trigger :: :event | :cancel | :internal,
          event :: Event.t() | nil,
          drive :: (State.t() -> State.t())
        ) :: State.t()
  defp in_macrostep(state, trigger, event, drive) do
    # `start_time` is captured in a local binding, not read back off
    # `state.macrostep_started_at`, once `drive.()` returns: ADR-0039's
    # re-entry path means `drive.()` can itself call `deliver_internal/6`,
    # which opens and closes its own nested `in_macrostep/4` span before
    # this (outer) one closes - the inner call's own `%{state |
    # macrostep_started_at: nil}` would otherwise clobber the outer span's
    # start time out from under it. The field still reflects the
    # innermost currently-open span at any given instant (ADR-0040); this
    # closure is what keeps each span's own duration correct regardless of
    # nesting depth. Since ADR-0044, the nested span no longer encloses the
    # *performance* of the effects the crossing produced - those are queued
    # and drained by the outermost `perform/3` after `drive.()` returns - so
    # this span's duration now measures the core drive alone.
    start_time = System.monotonic_time()
    span_ref = make_ref()
    state = %{state | macrostep_started_at: start_time}
    Telemetry.macrostep_start(state.session_id, trigger, event, span_ref)

    state = drive.(state)

    Telemetry.macrostep_stop(
      state.session_id,
      trigger,
      state.machine_state,
      event,
      macrostep_outcome(state),
      start_time,
      span_ref
    )

    %{state | macrostep_started_at: nil}
  end

  @spec macrostep_outcome(state :: State.t()) ::
          :quiescent | :done | :cancelled | :budget_exhausted
  defp macrostep_outcome(%State{halted: nil}), do: :quiescent
  defp macrostep_outcome(%State{halted: reason}), do: reason

  # -- performing (Statifier.Session.Effects plans; this performs) --------

  # ADR-0044 decision 1. `perform_batch/3` is the old body; the drain after
  # it is what makes subscriber arrival order non-decreasing in `(macrostep,
  # round)`. `deliver_internal/6` no longer calls this function at all, so
  # every call site is an outermost drive and `drain_deferred/1` never
  # nests.
  @spec perform(state :: State.t(), effects :: [Effect.t()], opts :: keyword()) :: State.t()
  defp perform(state, effects, opts \\ []) do
    state
    |> perform_batch(effects, Keyword.get(opts, :halt_override))
    |> drain_deferred()
  end

  @spec perform_batch(
          state :: State.t(),
          effects :: [Effect.t()],
          halt_override :: :cancelled | nil
        ) :: State.t()
  defp perform_batch(state, effects, halt_override) do
    effects
    |> Effects.plan(plan_context(state))
    |> Enum.reduce(state, &perform_instruction(&1, &2, halt_override))
  end

  # The plan context (`Statifier.Session.Effects.t:context/0`, ADR-0051
  # decisions 2, 4, and 6), built from the `%MachineState{}`/session state
  # this session already holds so the planner's `invoke_types` answer and
  # the core's own stamp cannot diverge, and so `invoke_handlers` is the
  # same map `init/1` derived `invoke_types` from (decision 3's "one
  # constructor"). `invocation_types` is `state.invocations`'s own live
  # snapshot (`Invocations.types/1`), re-derived on every call rather than
  # cached, exactly like `invoke_types`/`invoke_handlers` above - it always
  # reflects the table as it stood the moment this plan was built.
  @spec plan_context(state :: State.t()) :: Effects.context()
  defp plan_context(%State{} = state) do
    %{
      session_id: state.session_id,
      invoke_types: state.machine_state.invoke_types,
      invoke_handlers: state.invoke_handlers,
      invocation_types: Invocations.types(state.invocations)
    }
  end

  # FIFO, and monotone with no sorting at any nesting depth: each crossing's
  # core drive already happened at its instruction's position, so rounds
  # were stamped in the same order batches were appended, and a deferred
  # batch that crosses the seam again appends behind every batch already
  # queued.
  @spec drain_deferred(state :: State.t()) :: State.t()
  defp drain_deferred(%State{deferred: []} = state), do: state

  defp drain_deferred(%State{deferred: [{effects, override} | rest]} = state) do
    %{state | deferred: rest}
    |> perform_batch(effects, override)
    |> drain_deferred()
  end

  @spec perform_instruction(
          instruction :: Effects.instruction(),
          state :: State.t(),
          halt_override :: :cancelled | nil
        ) :: State.t()
  defp perform_instruction({:notify, {:done, %Done{}} = effect}, state, _override) do
    notify(state, {:effect, effect})
    Telemetry.effect(state.session_id, state.machine_state.machine, effect)
    %{state | done_effect: elem(effect, 1)}
  end

  # ADR-0051 decision 6: a handler-backed invocation (dispatched to a
  # non-`scxml` `Statifier.Invoke.Handler`) has no `{:start_child, _, _}`
  # instruction to record it through - `plan_invoke/3` spliced its own
  # `start/2` instructions in instead, and this session cannot tell from
  # those alone (an opaque `{:handler, module, payload}` among them, in the
  # common case) which `invoke_id` they belong to or whether `start/2` even
  # produced them for *this* effect. The `{:invoke, _}` effect's own
  # `{:notify, _}` instruction is always planned immediately ahead of
  # whatever `start/2` returned (`Effects.plan_one/2`), so it is read here
  # instead: a registered `invoke.type` (`InvokeTypes.registered?/2`, the
  # same test `plan_invoke/3` itself runs, no I/O) gets a pid-less entry
  # recording `invoke.type` - the only fact `Statifier.Session.Effects.
  # plan_one/2`'s later `:cancel_invoke`/`:autoforward` dispatch
  # (`handler_for/2`) needs to route back to the same handler. This runs for
  # a built-in `scxml` invoke too, not only a handler-backed one: `type`
  # unconditionally recorded here is what lets an `invoke_handlers` map that
  # explicitly overrides the literal `"scxml"` type still be honored on
  # cancel/forward, the same as it already is on start - and `start_child/5`
  # below overwrites this entry with the real one (pid, monitor_ref,
  # session_id) once the child actually starts, carrying `type` forward
  # rather than dropping it. An unregistered type, about to raise instead of
  # starting, is left untouched: it never becomes live at all (mirroring
  # `maybe_record_active_invocation/5`, which records `active_invocations`
  # off `type` registration alone, not off whether the session-side start
  # later succeeds).
  defp perform_instruction({:notify, {:invoke, %Invoke{} = invoke} = effect}, state, _override) do
    notify(state, {:effect, effect})
    Telemetry.effect(state.session_id, state.machine_state.machine, effect)

    if InvokeTypes.registered?(state.machine_state.invoke_types, invoke.type) do
      entry = %{
        type: invoke.type,
        session_id: nil,
        pid: nil,
        monitor_ref: nil,
        autoforward: invoke.autoforward == true
      }

      %{state | invocations: Invocations.put(state.invocations, invoke.invoke_id, entry)}
    else
      state
    end
  end

  defp perform_instruction({:notify, effect}, state, _override) do
    notify(state, {:effect, effect})
    Telemetry.effect(state.session_id, state.machine_state.machine, effect)
    state
  end

  defp perform_instruction({:enqueue_event, event}, state, _override) do
    %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
  end

  # ADR-0039's re-entry seam: enqueue on the internal queue exactly as an
  # in-loop `raise` would, then run to quiescence. `:internal`
  # (`<send target="#_internal">`, a self-targeted `error.communication`
  # never - see `deliver/5` below) and `:platform`
  # (`error.execution`/`error.communication`) share this one door.
  defp perform_instruction({:raise, kind, name, origin, opts}, state, override) do
    deliver_internal(kind, name, origin, opts, state, override)
  end

  # A `<send>` whose route resolved to something other than `:self` (which
  # plans straight to `{:enqueue_event, _}` and never reaches here).
  defp perform_instruction({:deliver, route, event, effect}, state, override) do
    deliver(route, event, effect, state, override)
  end

  # The one `Process.send_after/3` call in the library. `ref` is a
  # correlation id this session mints itself and embeds in the message, so
  # the fired message can identify which entry to `Timers.forget/2` -
  # `Process.send_after/3` has no way to embed its own return value in the
  # message it delivers, since that value does not exist until the call
  # returns. `timer_ref`, the value `Process.cancel_timer/1` actually needs,
  # is kept in `timer_refs`, keyed by that same correlation id. `route` rides
  # along in the message unresolved - see `handle_info/2`'s own comment for
  # why resolution waits for the fire.
  defp perform_instruction({:schedule, send_id, delay_ms, route, event, effect}, state, _override) do
    ref = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:statifier_delayed_send, ref, send_id, route, event, effect},
        delay_ms
      )

    %{
      state
      | timers: Timers.put(state.timers, send_id, ref),
        timer_refs: Map.put(state.timer_refs, ref, timer_ref)
    }
  end

  defp perform_instruction({:cancel_timers, send_id}, state, _override) do
    {refs, timers} = Timers.take(state.timers, send_id)
    timer_refs = Enum.reduce(refs, state.timer_refs, &cancel_ref/2)
    %{state | timers: timers, timer_refs: timer_refs}
  end

  # 6.4's own body: resolve the child's source, seed its datamodel from the
  # name-matched `<param>`/namelist map, start it, and monitor it - or, on
  # any failure along the way, raise `error.communication` (Decision 4) and
  # write no table entry ("terminate the processing of the element without
  # further action"). `Statifier.Invoke.Source.resolve/2` and
  # `Statifier.start_session/2` are the two ways this can fail; both reach
  # `invoke_error/4` the same way, so a caller reading the effect stream
  # cannot (and need not) tell them apart.
  defp perform_instruction({:start_child, %Invoke{} = invoke, effect}, state, override) do
    case Source.resolve(invoke, invoke_source: state.invoke_source) do
      {:ok, machine} -> start_child(machine, invoke, effect, state, override)
      {:error, _reason} -> invoke_error(invoke, effect, state, override)
    end
  end

  # 6.4.2's autoforward delivery: `event` is the core's own copy, unmodified
  # ("All the fields specified in 5.10.1 ... MUST have the same values in the
  # forwarded copy of the event"), so it is never rebuilt through
  # `Effect.Send`. A miss in `state.invocations`, or an entry with no `pid`
  # (ADR-0051 decision 6: a handler-backed invocation whose `forward/3`
  # chose to reuse this built-in instruction rather than routing an actual
  # delivery through its own `perform/2`), is a silent no-op, not an error:
  # for a miss, the invocation was cancelled or the child died between the
  # core's finalize/autoforward pass and this instruction, and 6.4 specifies
  # no error for forwarding to a gone child - the cancelled case is 6.4.3's
  # MUST-ignore, which is a silence requirement, not an `error.communication`
  # one.
  defp perform_instruction({:forward, invoke_id, event}, state, _override) do
    case Invocations.fetch(state.invocations, invoke_id) do
      {:ok, %{pid: pid}} when is_pid(pid) -> send_event(pid, event)
      _miss_or_pidless -> :ok
    end

    state
  end

  # 6.4.3's cancellation: pop the table entry *before* cancelling the child -
  # that ordering is what makes the drain-time discard below correct, since
  # any event this child already delivered is un-keyed the instant the entry
  # is gone, not only once the child actually halts. `Process.demonitor/2`
  # with `[:flush]` drops the queued `:DOWN` this session would otherwise see
  # for a cancel it itself initiated (the child cancelling on its own is a
  # different, still-monitored, path). `Session.cancel/1` - never
  # `GenServer.stop/2` - is deliberate: 6.4.3 requires the cancelled session
  # to run its `<onexit>` handlers for every active state before it exits,
  # which is `Interpreter.cancel/1`'s own `exit_interpreter/1` walk;
  # `GenServer.stop/2` would tear the process down with none of them run. A
  # miss (the invocation already popped by its own `:DOWN`, or a prior
  # cancel of the same id) is a silent no-op - and so, symmetrically, is a
  # popped entry with no `pid` (ADR-0051 decision 6's handler-backed entry):
  # there is no child process to demonitor or cancel, only the table entry
  # itself to drop.
  defp perform_instruction({:stop_child, invoke_id}, state, _override) do
    case Invocations.pop(state.invocations, invoke_id) do
      {nil, invocations} ->
        %{state | invocations: invocations}

      {%{pid: nil}, invocations} ->
        %{state | invocations: invocations}

      {%{pid: pid, monitor_ref: ref}, invocations} ->
        Process.demonitor(ref, [:flush])
        cancel(pid)
        %{state | invocations: invocations}
    end
  end

  # ADR-0051 decision 4's impure half: `module.perform/2` is the one call
  # site any `{:handler, module, payload}` instruction ever reaches - a
  # planning callback (`start/2`, `cancel/2`, `forward/3`) never performs
  # anything itself, it only returns this opaque instruction for an
  # executor to run. The library does not interpret `perform/2`'s return:
  # an `{:error, _}` is the handler's own concern to observe, not something
  # this session recovers from or feeds back into the core (ADR-0003), and
  # a raised exception crashes this session's process - deliberately, per
  # `Statifier.Invoke.Handler`'s own moduledoc, which asks for idempotency
  # on `invoke_id` instead of a rescue-to-default here.
  defp perform_instruction({:handler, module, payload}, state, _override) do
    module.perform(payload, plan_context(state))
    state
  end

  defp perform_instruction({:unroutable, effect}, state, _override) do
    notify(state, {:unroutable, effect})
    Telemetry.unroutable(state.session_id, state.machine_state.machine, effect)
    state
  end

  defp perform_instruction({:halt, reason}, state, override) do
    reason = override || reason
    state = %{state | halted: reason}
    return_done_event(reason, state)
    notify(state, {:halted, reason})
    Telemetry.halt(state.session_id, reason, state.machine_state)
    state
  end

  # `exitInterpreter`'s own `returnDoneEvent` (Appendix D declares it
  # platform-specific and gives it no pseudocode): 6.4.3's
  # `done.invoke.<invokeid>`, carrying the child's own `<donedata>`, reaches
  # the parent through `done_invocation/3` - the same door ADR-0051 decision
  # 5 gives a handler-backed invocation's own host, so there is one
  # `done.invoke` construction site rather than two (this clause used to
  # build the event inline through `Event.external/2` directly). Only a
  # `:done` halt with a live `invoked_by` qualifies: `:cancelled` is 6.4.3's
  # own "MUST NOT generate the done.invoke.id event" (a cancelled child
  # halts `:cancelled`, never `:done`, so this clause never matches it),
  # `:budget_exhausted` has not finished processing in 6.4.2's sense either,
  # and `invoked_by: nil` (an ordinary, uninvoked session) has no parent to
  # tell. `state.done_effect` is populated here because `{:notify, {:done,
  # %Done{}}}` always precedes `{:halt, :done}` in
  # `Statifier.Session.Effects.plan_one/2`'s own output for the `{:done, _}`
  # effect - an existing ordering guarantee this clause leans on, not a new
  # one.
  @spec return_done_event(reason :: :done | :cancelled | :budget_exhausted, state :: State.t()) ::
          :ok
  defp return_done_event(:done, %State{invoked_by: {parent_pid, invoke_id}} = state) do
    done_invocation(parent_pid, invoke_id, state.done_effect.donedata)
  end

  defp return_done_event(_reason, _state), do: :ok

  # `done.invoke.<invoke_id>`'s one construction site (ADR-0051 decision 5):
  # both `handle_cast/2`'s `{:done_invocation, _, _}` clause and, through
  # `done_invocation/3`, `return_done_event/2`'s own `:done` clause build the
  # event here rather than each inlining `Event.external/2` - the shape
  # `docs/extending.md` documents for a process-less host to match.
  @spec build_done_event(session_id :: String.t(), invoke_id :: String.t(), donedata :: term()) ::
          Event.t()
  defp build_done_event(session_id, invoke_id, donedata) do
    Event.external("done.invoke." <> invoke_id,
      data: donedata,
      invokeid: invoke_id,
      origin: SystemVariables.scxml_location(session_id),
      origintype: SystemVariables.scxml_event_processor()
    )
  end

  # `{:enqueue_invoked_event, _, _}`'s own body, factored out so
  # `handle_cast/2`'s `{:done_invocation, _, _}` clause can enqueue its own
  # constructed event the same recorded, invocation-tagged way (`stamp/1`,
  # `Recording.put_invoked_event/4`, `Inbox.enqueue_invoked_event/3`)
  # without duplicating it.
  @spec enqueue_invoked(state :: State.t(), invoke_id :: String.t(), event :: Event.t()) ::
          State.t()
  defp enqueue_invoked(state, invoke_id, event) do
    state = stamp(state)

    state =
      record(
        state,
        &Recording.put_invoked_event(&1, invoke_id, event, state.machine_state.routes)
      )

    %{state | inbox: Inbox.enqueue_invoked_event(state.inbox, invoke_id, event)}
  end

  # -- <invoke> starting -----------------------------------------------

  # `Source.resolve/2` succeeded: seed the child's datamodel (6.4.3), start
  # it on `Statifier.SessionSupervisor` with `invoked_by: {self(),
  # invoke.invoke_id}` (this module's own moduledoc, "Starting an
  # invocation's child session"), and record it in `state.invocations` on
  # success. `Statifier.start_session/2`'s own `{:error, _}` - most commonly
  # `Statifier.SessionSupervisor` not running - is Decision 4's other
  # failure path, handled identically to a `Source.resolve/2` failure.
  @spec start_child(
          machine :: Machine.t(),
          invoke :: Invoke.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp start_child(machine, invoke, effect, state, override) do
    datamodel = Invocations.seed_datamodel(invoke.params, machine)

    case start_session(machine, invoke, datamodel, state) do
      {:ok, pid} ->
        entry = %{
          type: invoke.type,
          session_id: session_id(pid),
          pid: pid,
          monitor_ref: Process.monitor(pid),
          autoforward: invoke.autoforward == true
        }

        %{state | invocations: Invocations.put(state.invocations, invoke.invoke_id, entry)}

      {:error, _reason} ->
        invoke_error(invoke, effect, state, override)
    end
  end

  # `Statifier.start_session/2`'s own moduledoc promises `DynamicSupervisor.start_child/2`'s
  # `{:ok, pid} | {:error, term}` "most commonly `Statifier.SessionSupervisor`
  # itself not being started" - but `Statifier.SessionSupervisor` unstarted is
  # an *unregistered name*, and `GenServer.call/3` to one **exits** the caller
  # rather than returning `{:error, _}` (confirmed empirically: `Registry.lookup/2`
  # raises `ArgumentError` on the same condition, which is a different failure
  # shape from a `GenServer.call` to a name nothing is registered under).
  # `registry_lookup/1` below already exists to fold exactly this kind of
  # "no runtime placed" failure into `{:error, _}` for the registry; this does
  # the same for the session-start call, so a bare parent (no
  # `Statifier.Supervisor` anywhere) reaches `invoke_error/4` above instead of
  # crashing.
  @spec start_session(
          machine :: Machine.t(),
          invoke :: Invoke.t(),
          datamodel :: map(),
          state :: State.t()
        ) :: {:ok, pid()} | {:error, term()}
  defp start_session(machine, invoke, datamodel, state) do
    Statifier.start_session(
      machine,
      [invoked_by: {self(), invoke.invoke_id}, datamodel: datamodel] ++
        inherited_observer_opts(state)
    )
  catch
    :exit, reason -> {:error, reason}
  end

  # ADR-0050 decisions 2-5: off by default, so a session that never opted in
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

  # Decision 4's `error.communication` write: the same ADR-0039
  # `deliver_internal/5` door `communication_error/4` uses, with `<invoke>`'s
  # own origin (`{:invoke, state_index, invoke_index}`, spec 3.12.2's
  # "arising from `<send>` and `<invoke>`") and no `sendid` - there is no
  # triggering `<send>` here to name one. `effect` is accepted but unused:
  # the origin is built from `invoke` alone, kept as a parameter for the same
  # symmetry `communication_error/4`'s own signature has with its caller.
  @spec invoke_error(
          invoke :: Invoke.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp invoke_error(invoke, _effect, state, override) do
    deliver_internal(
      :platform,
      "error.communication",
      {:invoke, invoke.state_index, invoke.invoke_index},
      [],
      state,
      override
    )
  end

  # -- <send> routing --------------------------------------------------

  # `:internal` resolves through the ADR-0039 seam with no registry needed at
  # all. `{:session, sid}` where `sid == state.session_id` is the clause
  # that needs no registry either: a session is accessible to itself whether
  # or not it is registered (decision 10), which narrows ADR-0027 decision
  # 2's "an unregistered session is an inaccessible one" - that sentence is
  # about reachability *by other sessions* - and is recorded as a
  # consequence in `docs/adr/0027-embedder-placed-session-runtime.md`. Every
  # other `{:session, sid}` resolves through `Statifier.Registry`
  # (`registry_lookup/1`): a hit casts onto that session's inbox, an empty
  # lookup takes C.1's mandated `error.communication` path via
  # `communication_error/4`. `:parent` resolves through `state.invoked_by`
  # below; `{:invoke, invokeid}` resolves through `state.invocations`
  # instead of the registry - the parent-held table is this session's own
  # handle on each child it created by `<invoke>`, so no registry lookup is
  # needed to reach one.
  @spec deliver(
          route :: Target.route(),
          event :: Event.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp deliver(:internal, event, effect, state, override) do
    deliver_internal(
      :internal,
      event.name,
      origin_of(effect),
      [data: event.data, sendid: event.sendid],
      state,
      override
    )
  end

  defp deliver({:session, sid}, event, _effect, %State{session_id: sid} = state, _override) do
    %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
  end

  defp deliver({:session, sid}, event, effect, state, override) do
    case registry_lookup(sid) do
      [{pid, _value}] ->
        send_event(pid, event)
        state

      [] ->
        communication_error(event, effect, state, override)
    end
  end

  # `#_parent`/`_parent` (6.4.4/C.1's disagreement, Decision 8): with
  # `invoked_by` set, this session is a live invocation's child, so the
  # event reaches its parent's external queue with `invokeid` stamped
  # (5.10.1: "If this event is generated from an invoked child process, the
  # SCXML Processor MUST set this field to the invoke id of the invocation
  # that triggered the child process") - `origin`/`origintype`/`sendid` ride
  # along unchanged, already this child's own address
  # (`Statifier.Session.Effects.delivered_event/2`). With `invoked_by: nil`,
  # this session was never invoked and has no parent - C.1's "does not exist
  # or is inaccessible", the same `communication_error/4` path as any other
  # unreachable route.
  defp deliver(
         :parent,
         event,
         _effect,
         %State{invoked_by: {parent_pid, invoke_id}} = state,
         _override
       ) do
    send_invoked_event(parent_pid, invoke_id, %{event | invokeid: invoke_id})
    state
  end

  defp deliver(:parent, event, effect, state, override) do
    communication_error(event, effect, state, override)
  end

  # C.1's `#_invokeid` route: `invokeid` names a session the sending session
  # itself created by `<invoke>`, so `state.invocations` (this session's own
  # parent-held table, `Statifier.Session.Invocations`) is resolved rather
  # than the registry - a live entry's `pid` gets the event cast onto its
  # external queue via `send_event/2`, the same mechanism `{:session, sid}`
  # above uses once it has a pid in hand. A miss - the invokeid names no
  # live invocation, whether because it was never one or because the
  # invocation has since been cancelled or exited - is C.1's "does not exist
  # or is inaccessible" and takes the same `communication_error/4` path as
  # any other unreachable route.
  defp deliver({:invoke, invoke_id}, event, effect, state, override) do
    case Invocations.fetch(state.invocations, invoke_id) do
      {:ok, %{pid: pid}} ->
        send_event(pid, event)
        state

      :error ->
        communication_error(event, effect, state, override)
    end
  end

  # A delayed send's route is resolved only once the timer actually fires
  # (`handle_info/2`'s own comment) - `:self` is the one route
  # `deliver/5` above does not carry (an immediate `:self` send plans
  # straight to `{:enqueue_event, _}` and never reaches `deliver/5` at all),
  # so it gets its own clause here; every other route reuses `deliver/5`
  # unchanged.
  @spec deliver_fired(
          route :: Target.route(),
          event :: Event.t(),
          effect :: Effect.t(),
          state :: State.t()
        ) :: State.t()
  defp deliver_fired(:self, event, _effect, state) do
    %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
  end

  defp deliver_fired(route, event, effect, state), do: deliver(route, event, effect, state, nil)

  # `Registry.lookup/2` raises `ArgumentError` when `Statifier.Registry`
  # itself is not running (no ETS table backs a registry nobody started),
  # which is exactly the "no runtime placed" case a bare `start_link/2`
  # sender is allowed to be in - so that raise is caught and folded into the
  # same empty-lookup shape a live registry returns for an unknown or dead
  # id. Both arrive at `communication_error/4` the same way; the caller
  # cannot tell "no registry" from "registry, but nothing there" apart, per
  # C.1's "does not exist or is inaccessible".
  @spec registry_lookup(sid :: String.t()) :: [{pid(), term()}]
  defp registry_lookup(sid) do
    Registry.lookup(Statifier.Registry, sid)
  rescue
    ArgumentError -> []
  end

  # C.1's mandated path for a route the ADR-0048 snapshot could not (or did
  # not) rule out at plan time - `Statifier.Machine.Content.Send`'s
  # reachability arm catches every route the *stamped* snapshot names as
  # unreachable, at the `<send>`'s own position, before this module ever sees
  # the effect; this resolver is what remains once that arm has had its say
  # (ADR-0048 decision 5), and it still has a real caseload:
  #
  #   - a **stale snapshot** - the route was live when this drive was
  #     stamped and the core let the effect through, but the session that
  #     died before delivery was actually attempted (e.g. a `<invoke>`
  #     cancelled earlier in the same macrostep's own fold, popping
  #     `state.invocations` before this effect's own `{:deliver, ...}`
  #     instruction runs).
  #   - a **`nil`-snapshot drive** - the caller stamped nothing (a hand-built
  #     `%MachineState{}`, or a replayed recording captured before this ADR
  #     landed), so the core's arm made no determination and emitted the
  #     effect exactly as it did before ADR-0048.
  #   - an **`interpret/2`-injected effect** - a caller-supplied effect never
  #     passed through `Statifier.Machine.Content.Send.execute/2` at all, so
  #     no core arm ever judged it against any snapshot.
  #   - a **delayed send's route miss at fire time** - ADR-0048 decision 6
  #     exempts every delayed send from the plan-time check outright (6.2.3
  #     governs argument evaluation, not reachability), so its route is
  #     always resolved here, at `deliver_fired/4`, regardless of whether the
  #     target was ever live.
  #
  # "a session that does not exist or is inaccessible" -> `error.communication`
  # on the *sending* session's own internal queue, carrying the failing
  # send's `sendid`. One private resolver so a later bead's registry/invocation
  # table changes this function, not the `{:deliver, ...}` clause or the
  # planner.
  @spec communication_error(
          event :: Event.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp communication_error(event, effect, state, override) do
    deliver_internal(
      :platform,
      "error.communication",
      origin_of(effect),
      [sendid: event.sendid],
      state,
      override
    )
  end

  # The one call site of `Interpreter.deliver_internal/5` - records the call
  # (ADR-0029, `docs/observability.md` constraint 6) before making it, then
  # **queues** whatever effects it returns instead of performing them here.
  # ADR-0044 decision 1: the seam is still crossed at this instruction's
  # position - the core's `%MachineState{}` advances now, the recording
  # entry is written at its true position, and this nested ADR-0040 span
  # still opens and closes around the core drive - but notifying the
  # returned effects inline is what put them ahead of the tail of the batch
  # that triggered them. The outermost `perform/3` drains the queue instead.
  #
  # One consequence to read deliberately: this nested span's `outcome`
  # (`macrostep_outcome/1`, reading `state.halted`) is now always
  # `:quiescent`, because a halt inside the deferred batch is performed
  # later, during the drain. That drain runs inside the *outermost* drive's
  # span, so the run's halt outcome is still reported - once, on the span
  # that encloses the batch that actually performed `{:halt, _}`. ADR-0044's
  # consequences record the same shift for effect-vs-span event ordering.
  # `{:error, :not_running}` is a no-op: a halted session has no queue to
  # raise onto, and nothing is queued.
  @spec deliver_internal(
          kind :: Effects.raise_kind(),
          name :: String.t(),
          origin :: Cause.origin(),
          opts :: keyword(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp deliver_internal(kind, name, origin, opts, state, override) do
    state = stamp(state)

    state =
      record(
        state,
        &Recording.put_internal(&1, kind, name, origin, opts, state.machine_state.routes)
      )

    in_macrostep(state, :internal, nil, fn state ->
      case Interpreter.deliver_internal(state.machine_state, kind, name, origin, opts) do
        {:ok, machine_state, effects} ->
          %{
            state
            | machine_state: machine_state,
              deferred: state.deferred ++ [{effects, override}]
          }

        {:error, :not_running} ->
          state
      end
    end)
  end

  # `Statifier.Effect.Send.owner/0`/`c_index` and
  # `Statifier.Effect.SendDelayed`'s own copies name the block that emitted
  # this send - the same identity `Statifier.Event.Cause.origin/0`'s
  # `{:content, c_index, owner}` arm already carries for every other
  # content-raised event.
  @spec origin_of(effect :: Effect.t()) :: Cause.origin()
  defp origin_of({:send, %Effect.Send{c_index: c_index, owner: owner}}),
    do: {:content, c_index, owner}

  defp origin_of({:send_delayed, %Effect.SendDelayed{c_index: c_index, owner: owner}}),
    do: {:content, c_index, owner}

  @spec cancel_ref(ref :: reference(), timer_refs :: %{reference() => reference()}) ::
          %{reference() => reference()}
  defp cancel_ref(ref, timer_refs) do
    case Map.pop(timer_refs, ref) do
      {nil, timer_refs} ->
        timer_refs

      {timer_ref, timer_refs} ->
        Process.cancel_timer(timer_ref)
        timer_refs
    end
  end

  @spec notify(state :: State.t(), message :: term()) :: :ok
  defp notify(state, message) do
    payload = {:statifier, state.session_id, message}
    Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, payload) end)
    :ok
  end

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

  # A session started without `record: true` carries `recording: nil` and
  # pays only its call site's closure and this one clause match per input,
  # leaving the state untouched; a recording session hands its current value
  # through `append` and keeps the result.
  @spec record(state :: State.t(), append :: (Recording.t() -> Recording.t())) :: State.t()
  defp record(%State{recording: nil} = state, _append), do: state

  defp record(%State{recording: recording} = state, append) do
    %{state | recording: append.(recording)}
  end

  # -- status/1 -------------------------------------------------------------

  @spec build_status(state :: State.t()) :: status()
  defp build_status(state) do
    {status, configuration} = status_and_configuration(state)
    machine_state = state.machine_state

    %{
      session_id: state.session_id,
      status: status,
      configuration: translate_configuration(machine_state.machine, configuration),
      macrostep: machine_state.macrostep,
      microstep: machine_state.microstep,
      round: machine_state.round,
      queued_events: Inbox.size(state.inbox),
      pending_timers: Timers.count(state.timers)
    }
  end

  # `:done` and `:cancelled` both reach exit_interpreter/1, which empties
  # `configuration` by construction - the restore
  # `test/support/case.ex:23-32` performs, mirrored here. `:budget_exhausted`
  # never touches `exit_interpreter/1`, so its `%MachineState{}.configuration`
  # is still the live, resumable position (ADR-0019).
  @spec status_and_configuration(state :: State.t()) ::
          {:running | :done | :cancelled | :budget_exhausted, MapSet.t(non_neg_integer())}
  defp status_and_configuration(%State{halted: nil, machine_state: machine_state}) do
    {:running, machine_state.configuration}
  end

  defp status_and_configuration(%State{halted: reason, done_effect: %Done{configuration: config}})
       when reason in [:done, :cancelled] do
    {reason, config}
  end

  defp status_and_configuration(%State{halted: :budget_exhausted, machine_state: machine_state}) do
    {:budget_exhausted, machine_state.configuration}
  end

  @spec translate_configuration(machine :: Machine.t(), configuration :: MapSet.t()) ::
          MapSet.t(String.t())
  defp translate_configuration(machine, configuration) do
    configuration
    |> Enum.map(&Machine.id(machine, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
