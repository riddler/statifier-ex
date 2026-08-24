defmodule Statifier.Effect.DatamodelChange do
  @moduledoc """
  Payload for `{:datamodel_change, %__MODULE__{}}` - one successful datamodel
  write, carrying enough to reconstruct the datamodel from the effect stream
  alone, without ever calling `Session.snapshot/1` (plan decision 1).
  Emitted for every successful write `write_location/4` performs (decision
  2); a failed write emits nothing, since the datamodel did not change and
  the failure is already observable on the error channel (decision 9). One
  exception: a `<send>`'s `idlocation` write that ADR-0047 goes on to reject
  (an invalid target or unsupported type, classified after the write lands)
  emits no effect either, because the composite error return that carries
  the rejection has no effects slot. The write is in the datamodel
  regardless - a consumer reading it back through `_event.sendid` sees it -
  and live and replay agree because both derive from the core.

  `location_path` is `Predicator.ContextLocation.location_path()` - the
  resolved `[binary() | integer()]` path, the only shape a consumer can
  apply to reconstruct `items[i]` without the pre-assignment datamodel it
  does not have. `location_source` is the raw author string that produced
  it, kept alongside under a distinct name so neither is mistaken for the
  other (decision 7).

  `new_value` and `prior_value` are ordinary predicator values, or the atom
  `:undefined` when nothing stood at the path before the write - ADR-0037's
  single spelling for an unbound value. Neither field commits to a wire
  format: `docs/observability.md:175` names "no wire format" as an explicit
  non-goal for this repo, and per ADR-0025 serialization is statifier-ui's
  own half of the mirror (decision 8).

  `c_index` identifies the content node that performed the write
  (constraint 3), `nil` for the two runner-side writes - the empty-`<finalize>`
  auto-assign and `<invoke idlocation>` - that write outside any content
  block; `owner` names which construct performed it (decision 3).
  `macrostep`/`microstep`/`round` are the counters as they stood when the
  write ran.

  `d_index` and `c_index` are mutually exclusive identities on this payload
  (decision 3): a non-nil `d_index` means the write was a `<data>`
  binding performed by `Statifier.Interpreter.Datamodel.bind_value`, which
  belongs to no content block and therefore always carries `owner: nil`. A
  `<data>` element is not executable content, so `Machine.content/2` could
  never resolve it - `Statifier.Machine.data/2` is its resolver instead, the
  same relationship `c_index` has to `Machine.content/2`.
  """

  alias Statifier.Machine.Content

  @typedoc "Which construct performed the write - `Machine.Content.owner/0` widened with the `<invoke idlocation>` case, which belongs to no content block (see `Trace.ContentExecuted`'s owner typedoc for the same widening-at-the-payload precedent)."
  @type owner :: Content.owner() | {:invoke, non_neg_integer(), non_neg_integer()}

  @enforce_keys [
    :location_path,
    :location_source,
    :new_value,
    :prior_value,
    :macrostep,
    :microstep,
    :round
  ]
  defstruct [
    :location_path,
    :location_source,
    :new_value,
    :prior_value,
    :d_index,
    :c_index,
    :owner,
    :macrostep,
    :microstep,
    :round
  ]

  @type t :: %__MODULE__{
          location_path: Predicator.ContextLocation.location_path(),
          location_source: String.t(),
          new_value: term(),
          prior_value: term(),
          d_index: non_neg_integer() | nil,
          c_index: non_neg_integer() | nil,
          owner: owner() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }
end
