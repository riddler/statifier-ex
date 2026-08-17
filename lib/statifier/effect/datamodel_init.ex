defmodule Statifier.Effect.DatamodelInit do
  @moduledoc """
  Payload for `{:datamodel_init, %__MODULE__{}}` - the datamodel's starting
  map, emitted once per `Statifier.Interpreter.initialize/2`, before the
  first `<data>` value is evaluated (plan decision 1).

  `datamodel` is `machine_state.datamodel` as it stands after spec 5.3.3's
  unconditional `<data>` creation (`Statifier.Interpreter.Datamodel.seed/2`)
  and before the binding fold that follows it. That ordering is what makes
  this payload carry exactly the three contributions no
  `{:datamodel_change, _}` effect can ever describe: `MachineState.new/2`'s
  `:datamodel` option, `SystemVariables.initial/2`'s four spec 5.10 system
  variables, and the `:undefined` seed (ADR-0037's spelling) for every
  declared id. Taking the baseline after binding would restate values the
  per-`<data>` binding effects already carry (decision 1).

  Emitted unconditionally, once, even for a chart with no `<datamodel>` at
  all (decision 2) - the four system variables mean the map is never empty,
  so a consumer always has a starting point with nothing to special-case.

  Deliberately carries no `binding`, `env_ids`, or declared-id list: those
  are facts about the `%Statifier.Machine{}`, and
  `docs/observability.md:94-115` constraint 3's model is that tooling
  resolves machine facts through the machine, not through an effect payload
  (decision 6). What this payload carries instead is *values*, which exist
  nowhere else - the environment's `:datamodel` option and the session's
  `_sessionid` are not recoverable from the machine alone.

  `datamodel` is a term reference, not a deep copy - Elixir maps are
  immutable, so this struct costs one word, once per session, not O(datamodel
  size). Neither `datamodel` nor the `:undefined` atom inside it commits to a
  wire format: `docs/observability.md:173-179` names "no wire format" as an
  explicit non-goal for this repo, and per ADR-0025 serialization is
  statifier-ui's own half of the mirror.
  """

  @enforce_keys [:datamodel, :macrostep, :microstep]
  defstruct [:datamodel, :macrostep, :microstep]

  @type t :: %__MODULE__{
          datamodel: map(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
