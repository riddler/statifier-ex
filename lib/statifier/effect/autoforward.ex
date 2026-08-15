defmodule Statifier.Effect.Autoforward do
  @moduledoc """
  Payload for `{:autoforward, %__MODULE__{}}` - spec 6.4's `autoforward`
  attribute, Appendix D's `if inv.autoforward: send(inv.id, externalEvent)`
  in `mainEventLoop`'s finalize/autoforward pass (`:152-158`). `invoke_id`
  names the invocation to forward to; `state_index` is the constraint-3
  identity of the invoking state; `event` is the external event that
  triggered the pass, carried verbatim; `macrostep`/`microstep` are the
  counters as they stood at the moment of the pass.

  ## Not `Statifier.Effect.Send` to `"#_" <> invoke_id`

  `Effect.Send` describes an event to be *built* from a `<send>` element's
  own attributes (`event`, `eventexpr`, `<param>`/namelist) - it has no way
  to carry an existing `Statifier.Event.t()` through unchanged. Spec 6.4 is
  explicit that autoforwarding needs exactly that: "All the fields specified
  in 5.10.1 (event name, data etc.) MUST have the same values in the
  forwarded copy of the event". Routing the pseudocode's `send(inv.id,
  externalEvent)` through `Effect.Send` would lose `sendid`, `origin`, and
  `invokeid` on the way through - the same fields `Statifier.Event`'s own
  moduledoc says a caller of this pass is the first reader of - so this
  effect carries `event` whole instead of decomposing it into `Effect.Send`'s
  build-from-attributes shape.

  ## One effect per autoforwarding invocation

  Every other effect this vocabulary produces is one-per-action
  (`Effect.Invoke` is one-per-`<invoke>`, `Effect.CancelInvoke` is
  one-per-cancelled invocation); a state with two autoforwarding invocations
  therefore emits two `Autoforward` effects, never one carrying a list.

  ## No `round` field

  No core effect carries `round` - only the seven trace payloads do
  (`Statifier.Effect`'s own moduledoc, "Trace effects carry indexes and
  counters, never structs"). This payload keeps that split.
  """

  alias Statifier.Event

  @enforce_keys [:invoke_id, :state_index, :event, :macrostep, :microstep]
  defstruct [:invoke_id, :state_index, :event, :macrostep, :microstep]

  @type t :: %__MODULE__{
          invoke_id: String.t(),
          state_index: non_neg_integer(),
          event: Event.t(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
