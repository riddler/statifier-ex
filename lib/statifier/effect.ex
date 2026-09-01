defmodule Statifier.Effect do
  @moduledoc """
  The effect vocabulary (ADR-0003) plus the ten trace effects
  (`docs/observability.md` constraint 2) - one `@type t()` union, in this
  one module, that every interpreter function emits from and every
  consumer pattern-matches against, including `Statifier.Session`, which
  drives `<send>`/`<cancel>`/`<invoke>`. This module defines the
  vocabulary and the trace gate; it never emits an effect itself.

  ## Every effect is `{tag, payload_struct}`

  An effect is always a two-element tuple: a vocabulary tag, and a struct
  carrying its named fields. The tag keeps `case effect do {:log, log} ->
  ...` reading the way ADR-0003 writes it and makes "is this a trace
  effect?" a single match (`trace?/1`); the struct payload gives named
  fields, dialyzer coverage, and room to grow the `<send>`/`<send_delayed>`/
  `<cancel>`/`<invoke>` payloads without changing any arity. There are no
  positional tuples with four or five elements anywhere in this
  vocabulary.

  ## The vocabulary

  | Tag | Payload | Produced by |
  |---|---|---|
  | `:send` | `Statifier.Effect.Send` | `Statifier.Machine.Content.Send`'s `execute/2`, when no delay resolves (`<send>`, immediate, spec 6.2) |
  | `:send_delayed` | `Statifier.Effect.SendDelayed` | `Statifier.Machine.Content.Send`'s `execute/2`, when a delay resolves (`<send>` with `delay`, spec 6.2) |
  | `:cancel` | `Statifier.Effect.Cancel` | `Statifier.Machine.Content.Cancel`'s `execute/2` (`<cancel>`, spec 6.3) |
  | `:invoke` | `Statifier.Effect.Invoke` | `Statifier.Interpreter`'s invoke pass (`main_event_loop/3`'s `run_invoke_pass/1`, spec 6.4) |
  | `:cancel_invoke` | `Statifier.Effect.CancelInvoke` | `Statifier.Interpreter.ExitEntry.cancel_invocations_for_state/2`, called from both `depart/2` and `Statifier.Interpreter.exit_interpreter/1` (spec 6.4) |
  | `:autoforward` | `Statifier.Effect.Autoforward` | `Statifier.Interpreter.handle_event/2`'s finalize/autoforward pass (`apply_invoke_passes/2`, spec 6.4) |
  | `:budget_exhausted` | `Statifier.Effect.BudgetExhausted` | `Statifier.Interpreter.macrostep/1` |
  | `:done` | `Statifier.Effect.Done` | `Statifier.Interpreter.exit_interpreter/1` |
  | `:log` | `Statifier.Effect.Log` | `Statifier.Machine.Content.Log`'s `execute/2` (`<log>`) |
  | `:datamodel_change` | `Statifier.Effect.DatamodelChange` | `Statifier.Interpreter.Datamodel.write_location/4`'s four call sites - `Statifier.Machine.Content.Assign`'s `execute/2` (`<assign>`), `Statifier.Machine.Content.Send`'s `execute/2` (`<send idlocation>`), `Statifier.Interpreter`'s `write_finalize_target/6` (the empty-`<finalize>` auto-assign), and `Statifier.Interpreter`'s `invoke_one/6` (`<invoke idlocation>`) - plus `Statifier.Interpreter.Datamodel.bind_value`, reached from both `initialize/1` and `enter_state/2`, for a `<data>` binding |
  | `:datamodel_init` | `Statifier.Effect.DatamodelInit` | `Statifier.Interpreter.Datamodel.initialize/1` |
  | `:trace` | `Statifier.Effect.Trace.EventDequeued` | `Statifier.Interpreter.handle_event/2` and `internal_round/1` |
  | `:trace` | `Statifier.Effect.Trace.CondsEvaluated` | `Statifier.Interpreter.Selection.select_transitions/2` and `select_eventless_transitions/1`, when the round evaluated at least one written `cond` |
  | `:trace` | `Statifier.Effect.Trace.TransitionsSelected` | `Statifier.Interpreter.run_selected` |
  | `:trace` | `Statifier.Effect.Trace.ExitSet` | `exit_states/2` (`compute_exit_set` result) |
  | `:trace` | `Statifier.Effect.Trace.ContentExecuted` | `execute_block/3` (a content block ran) and `Statifier.Interpreter.run_global_script` (a top-level `<script>` ran at load time) |
  | `:trace` | `Statifier.Effect.Trace.EntrySet` | `enter_states/2` (`compute_entry_set` result) |
  | `:trace` | `Statifier.Effect.Trace.MacrostepStable` | `Statifier.Interpreter.macrostep/1` |
  | `:trace` | `Statifier.Effect.Trace.Done` | `Statifier.Interpreter.exit_interpreter/1` |
  | `:trace` | `Statifier.Effect.Trace.InvokePass` | `Statifier.Interpreter`'s invoke pass (`run_invoke_pass/1`, spec 6.4) |
  | `:trace` | `Statifier.Effect.Trace.FinalizeAutoforward` | `Statifier.Interpreter.handle_event/2`'s finalize/autoforward pass (`apply_invoke_passes/2`, spec 6.4/6.5) |

  Every tag in this vocabulary is produced today: `:log`, `:done`,
  `:budget_exhausted`, `:invoke`, `:cancel_invoke`, `:autoforward`,
  `:datamodel_change`, `:datamodel_init`, `:send`, `:send_delayed`,
  `:cancel`, and all ten trace effects.

  ## Trace effects carry indexes and counters, never structs

  Every effect in this vocabulary, core and trace alike, carries
  `macrostep`/`microstep`/`round` (constraint 4, ADR-0046); trace payloads
  additionally carry, wherever one names an entity, a constraint-3
  *identity* - a state index, a `t_index`, a `c_index` - never a
  `%Statifier.Machine.State{}`, `%Statifier.Machine.Transition{}`, or a
  compiled content-node struct.
  Tooling resolves an identity back to its node through
  `Statifier.Machine.at/2`, `transition/2`, or `content/2`
  (`docs/observability.md:73-74`). `round` is the only one of the three that
  advances in a round that runs no microstep at all - a livelocked or
  eventless round still stamps a fresh `round` on everything it emits, which
  is what keeps such a trace ordered (ADR-0020).

  ## Trace effects are ordinary list members, never a side channel

  A trace effect is just another element of the same `[effect]` list a
  microstep returns, in the same order, delivered the same way. There is no
  separate trace stream to keep in sync (`docs/observability.md:75-76`).

  ## The gate: `trace/3`

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
  which it stamps `macrostep`/`microstep`/`round`) and a keyword list of its
  own fields, so no call site ever repeats the counters and no call site can
  forget them.
  """

  alias Statifier.Effect.{
    Autoforward,
    BudgetExhausted,
    Cancel,
    CancelInvoke,
    DatamodelChange,
    DatamodelInit,
    Done,
    Invoke,
    Log,
    Send,
    SendDelayed,
    Trace
  }

  @typedoc "The eleven core effects - the ADR-0003 set plus ADR-0019's `:budget_exhausted`, `:cancel_invoke`/`:autoforward`, and the two datamodel effects: `:datamodel_change` (a write) and `:datamodel_init` (the starting baseline)."
  @type core ::
          {:send, Send.t()}
          | {:send_delayed, SendDelayed.t()}
          | {:cancel, Cancel.t()}
          | {:invoke, Invoke.t()}
          | {:cancel_invoke, CancelInvoke.t()}
          | {:autoforward, Autoforward.t()}
          | {:budget_exhausted, BudgetExhausted.t()}
          | {:done, Done.t()}
          | {:log, Log.t()}
          | {:datamodel_change, DatamodelChange.t()}
          | {:datamodel_init, DatamodelInit.t()}

  @typedoc "The ten trace effects - the seven `docs/observability.md` constraint-2 rows, plus `InvokePass`/`FinalizeAutoforward` for the two Appendix-D-named phase boundaries `<invoke>` added, plus `CondsEvaluated` for the `conditionMatch` guard seam."
  @type trace ::
          {:trace, Trace.EventDequeued.t()}
          | {:trace, Trace.CondsEvaluated.t()}
          | {:trace, Trace.TransitionsSelected.t()}
          | {:trace, Trace.ExitSet.t()}
          | {:trace, Trace.ContentExecuted.t()}
          | {:trace, Trace.EntrySet.t()}
          | {:trace, Trace.MacrostepStable.t()}
          | {:trace, Trace.Done.t()}
          | {:trace, Trace.InvokePass.t()}
          | {:trace, Trace.FinalizeAutoforward.t()}

  @typedoc "Every effect this interpreter can emit - the single source of truth for the vocabulary."
  @type t :: core() | trace()

  @doc """
  Whether `effect` is a trace effect - a single match on the `:trace` tag.
  Table-driven over the whole vocabulary at the call site
  (`test/statifier/effect_test.exs`), so a trace point added without a
  matching case here fails that test rather than silently miscounting.
  """
  @spec trace?(effect :: t()) :: boolean()
  def trace?({:trace, _payload}), do: true
  def trace?(_effect), do: false

  @doc """
  The trace emission gate. `payload_module` is one of the
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
