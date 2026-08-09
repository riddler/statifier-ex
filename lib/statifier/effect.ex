defmodule Statifier.Effect do
  @moduledoc """
  The effect vocabulary (ADR-0003) plus the seven trace effects
  (`docs/observability.md` constraint 2) - one `@type t()` union, in this
  one module, that every interpreter bead (st-wju.3 through st-wju.6) emits
  from and every consumer (st-wju.7's API boundary, eventually st-cmq's
  session) pattern-matches against. This module defines the vocabulary and
  the trace gate; it never emits an effect itself (`## What We're NOT
  Doing`, plan Phase 3).

  ## Every effect is `{tag, payload_struct}` (Decision 3)

  An effect is always a two-element tuple: a vocabulary tag, and a struct
  carrying its named fields. The tag keeps `case effect do {:log, log} ->
  ...` reading the way ADR-0003 writes it and makes "is this a trace
  effect?" a single match (`trace?/1`); the struct payload gives named
  fields, dialyzer coverage, and room for st-cmq to add fields without
  changing any arity. There are no positional tuples with four or five
  elements anywhere in this vocabulary.

  ## The vocabulary

  | Tag | Payload | Produced by (today / eventually) |
  |---|---|---|
  | `:send` | `Statifier.Effect.Send` | st-cmq (`<send>`, immediate) |
  | `:send_delayed` | `Statifier.Effect.SendDelayed` | st-cmq (`<send>` with `delay`) |
  | `:cancel` | `Statifier.Effect.Cancel` | st-cmq (`<cancel>`) |
  | `:invoke` | `Statifier.Effect.Invoke` | st-cmq (`<invoke>`) |
  | `:done` | `Statifier.Effect.Done` | st-wju.6 (`exit_interpreter`) |
  | `:log` | `Statifier.Effect.Log` | st-wju.5 (`<log>`) |
  | `:trace` | `Statifier.Effect.Trace.EventDequeued` | st-wju.6 (event dequeued) |
  | `:trace` | `Statifier.Effect.Trace.TransitionsSelected` | st-wju.3 (`select_transitions` returns) |
  | `:trace` | `Statifier.Effect.Trace.ExitSet` | st-wju.4 (`compute_exit_set` result) |
  | `:trace` | `Statifier.Effect.Trace.ContentExecuted` | st-wju.5 (a content block ran) |
  | `:trace` | `Statifier.Effect.Trace.EntrySet` | st-wju.4 (`compute_entry_set` result) |
  | `:trace` | `Statifier.Effect.Trace.MacrostepStable` | st-wju.6 (configuration reached quiescence) |
  | `:trace` | `Statifier.Effect.Trace.Done` | st-wju.6 (top-level final entry / `exit_interpreter`) |

  The core-engine epic (st-wju) only ever produces `:log` and `:done`
  itself; `:send`/`:send_delayed`/`:cancel`/`:invoke` are defined and
  unproduced until st-cmq gives them a caller - that is the point of this
  bead (Decision 14).

  ## Trace effects carry indexes and counters, never structs

  Every trace payload carries `macrostep`/`microstep` (constraint 4) and,
  wherever it names an entity, a constraint-3 *identity* - a state index, a
  `t_index`, a `c_index` - never a `%Statifier.Machine.State{}`,
  `%Statifier.Machine.Transition{}`, or `%Statifier.Machine.Content{}`.
  Tooling resolves an identity back to its node through
  `Statifier.Machine.at/2`, `transition/2`, or `content/2`
  (`docs/observability.md:73-74`).

  ## Trace effects are ordinary list members, never a side channel

  A trace effect is just another element of the same `[effect]` list a
  microstep returns, in the same order, delivered the same way. There is no
  separate trace stream to keep in sync (`docs/observability.md:75-76`).

  ## The gate: `trace/3` (Decision 4)

      require Statifier.Effect, as: Effect

      Effect.trace(machine_state, Effect.Trace.EntrySet, indexes: entry_order)

  expands to

      if machine_state.trace do
        [{:trace, Statifier.Effect.Trace.EntrySet.new(machine_state, indexes: entry_order)}]
      else
        []
      end

  Two properties make this the gate the untraced hot path needs:

  - **Single evaluation.** The `machine_state` argument is bound to a
    variable inside the quoted block *before* the `if`, so a call site
    passing an expression (`Effect.trace(begin_microstep(ms), ...)`)
    evaluates it exactly once. Writing `unquote(machine_state)` twice -
    once for `.trace`, once as `new/2`'s argument - would double-evaluate
    it; that is the bug this shape exists to avoid.
  - **Laziness.** `fields` is spliced only inside the `if`'s `do` branch.
    When `machine_state.trace` is `false`, the gate is one boolean field
    read and an empty list: no payload struct is built, and the `fields`
    expression is never evaluated at all - not even for its side effects.

  Every trace payload module defines `new/2`, taking the machine_state (from
  which it stamps `macrostep`/`microstep`) and a keyword list of its own
  fields, so no call site ever repeats the counters and no call site can
  forget them.
  """

  alias Statifier.Effect.Cancel
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace

  @typedoc "The six core effects (Decision 14) - the ADR-0003 set, no more."
  @type core ::
          {:send, Send.t()}
          | {:send_delayed, SendDelayed.t()}
          | {:cancel, Cancel.t()}
          | {:invoke, Invoke.t()}
          | {:done, Done.t()}
          | {:log, Log.t()}

  @typedoc "The seven trace effects (Decision 13), one per `docs/observability.md` constraint-2 row."
  @type trace ::
          {:trace, Trace.EventDequeued.t()}
          | {:trace, Trace.TransitionsSelected.t()}
          | {:trace, Trace.ExitSet.t()}
          | {:trace, Trace.ContentExecuted.t()}
          | {:trace, Trace.EntrySet.t()}
          | {:trace, Trace.MacrostepStable.t()}
          | {:trace, Trace.Done.t()}

  @typedoc "Every effect this interpreter can emit - the single source of truth for the vocabulary."
  @type t :: core() | trace()

  @doc """
  Whether `effect` is a trace effect - a single match on the `:trace` tag
  (Decision 3). Table-driven over the whole vocabulary at the call site
  (`test/statifier/effect_test.exs`), so a trace point added without a
  matching case here fails that test rather than silently miscounting.
  """
  @spec trace?(effect :: t()) :: boolean()
  def trace?({:trace, _payload}), do: true
  def trace?(_effect), do: false

  @doc """
  The trace emission gate (Decision 4). `payload_module` is one of the
  `Statifier.Effect.Trace.*` modules; `fields` is the keyword list passed to
  its `new/2` (the counters are stamped automatically, never repeated at the
  call site).

  Expands to a one-element list holding `{:trace, payload}` when
  `machine_state.trace` is true, or `[]` with `fields` never evaluated when
  it is false. `machine_state` is evaluated exactly once regardless of which
  branch is taken - see the moduledoc's "Single evaluation" note.
  """
  @spec trace(machine_state :: Macro.t(), payload_module :: Macro.t(), fields :: Macro.t()) ::
          Macro.t()
  defmacro trace(machine_state, payload_module, fields) do
    quote do
      machine_state = unquote(machine_state)

      if machine_state.trace do
        [{:trace, unquote(payload_module).new(machine_state, unquote(fields))}]
      else
        []
      end
    end
  end
end
