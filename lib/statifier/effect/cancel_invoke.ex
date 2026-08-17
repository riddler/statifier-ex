defmodule Statifier.Effect.CancelInvoke do
  @moduledoc """
  Payload for `{:cancel_invoke, %__MODULE__{}}` - the cancellation Appendix
  D's `exitStates` and `exitInterpreter` both perform with `for inv in
  s.invoke: cancelInvoke(inv)` when a state carrying live invocations
  exits. `invoke_id` names the invocation to cancel; `state_index` is the
  constraint-3 identity of the state that owned it. `macrostep`/`microstep`/
  `round` are the counters as they stood at the moment of the cancel.

  ## Not `Statifier.Effect.Cancel`

  `Effect.Cancel` is spec 6.3's `<cancel sendid>` - an authored element that
  cancels a *delayed send*, resolved against `Statifier.Session.Timers` by
  `send_id`. This effect has no `<cancel>` element behind it at all: it is
  the interpreter's own reaction to a state exiting while one of its
  `<invoke>`s is still live, and it has no notion of a delayed send to look
  up. The two share no session-side machinery, which is why they are two
  structs rather than one with an optional field.

  ## One effect per invocation, not one per state

  Appendix D's loop is `for inv in s.invoke: cancelInvoke(inv)` - one call
  per invocation - and every other effect this vocabulary produces is
  one-per-action (`Effect.Invoke` is one-per-`<invoke>`, `Effect.Log` is
  one-per-`<log>`). A state with two live invocations therefore emits two
  `CancelInvoke` effects, never one carrying a list.
  """

  @enforce_keys [:invoke_id, :state_index, :macrostep, :microstep, :round]
  defstruct [:invoke_id, :state_index, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          invoke_id: String.t(),
          state_index: non_neg_integer(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }
end
