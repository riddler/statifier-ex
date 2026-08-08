defmodule Statifier.Validator.Error do
  @moduledoc """
  The validator's own error shape: never raised, always collected into a
  list. Mirrors `Statifier.Lowering.Error`'s shape (`reason`, `message`,
  `location`) with character-identical field names, so a future common
  diagnostic protocol can adopt both without either layer's reason union
  leaking into the other's (`docs/plans/260808-st-l5k.5-document-validator.md`
  Decision 3). The two layers' error lists are never observed together -
  `Statifier.Validator.validate/2` only ever receives a document lowering
  already accepted - so sharing the *shape* rather than the type is enough.

  `reason` is a closed tagged-tuple union, declared once in full here even
  though Phase 1 only produces `:duplicate_id`. Later phases add a
  constructor per reason rather than reopening the type, following
  `Statifier.Lowering.Error`'s own precedent.

  `code/1` returns the reason tuple's tag atom - the stable error code the
  bead's acceptance criteria ask for - while `reason` itself keeps carrying
  the offending ids as data, the way the rest of the repo does.
  """

  alias Statifier.Parser.Location

  @typedoc """
  Which slot a shared transition-shape violation (`:transition_count`,
  `:transition_missing_target`, `:transition_forbidden_attribute`) came
  from: a state's `<initial>` element, or a `:history` state's own default
  transition. The id is `nil` exactly when the owning state's own `id` is.
  """
  @type owner :: {:initial, String.t() | nil} | {:history, String.t() | nil}

  @type reason ::
          {:duplicate_id, id :: binary()}
          | {:unresolved_target, id :: binary()}
          | {:unresolved_initial, id :: binary()}
          | {:initial_not_descendant, id :: binary(), parent_id :: binary()}
          | {:initial_not_top_level, id :: binary()}
          | {:initial_on_atomic_state, id :: binary()}
          | {:initial_attribute_and_element, id :: binary()}
          | {:transition_count, owner :: owner(), count :: non_neg_integer()}
          | {:transition_missing_target, owner :: owner()}
          | {:transition_forbidden_attribute, owner :: owner(), attr :: :event | :cond}
          | {:history_bad_parent, id :: binary(), parent_kind :: atom()}
          | {:history_bad_type, raw :: binary()}
          | {:final_has_states, id :: binary()}
          | {:default_entry_not_enterable, id :: binary(), child_kind :: atom()}
          | {:donedata_not_on_final, id :: binary()}
          | {:bad_namespace, uri :: binary() | nil}
          | {:bad_version, version :: binary() | nil}

  @enforce_keys [:reason, :message, :location]
  defstruct [:reason, :message, :location]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t()
        }

  @doc """
  The reason tuple's tag - the stable error code.
  """
  @spec code(reason :: reason()) :: atom()
  def code(reason) when is_tuple(reason), do: elem(reason, 0)

  @doc """
  Check 1 (spec 3.14): `id` names more than one state in the document. The
  location is the offending (non-first) occurrence's own span, never the
  canonical one.
  """
  @spec duplicate_id(id :: binary(), location :: Location.t()) :: t()
  def duplicate_id(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:duplicate_id, id},
      message: "duplicate state id #{inspect(id)}",
      location: location
    }
  end
end
