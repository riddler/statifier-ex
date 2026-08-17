defmodule Statifier.Interpreter.Datamodel.Write do
  @moduledoc """
  What `Statifier.Interpreter.Datamodel.write_location/4` wrote - a report of
  a write that already happened, never an instruction to perform one. `path`
  is the resolved `Predicator.ContextLocation.location_path()`, `new_value` is
  what was written, and `prior_value` is what stood at that full path
  immediately before the write - `:undefined` when nothing did, per
  ADR-0037's single spelling for an unbound value. This does conflate "the
  path was absent" with "the path held `:undefined`" already; that is
  accepted, since `prior_value` exists for diffing and undo, never for
  reconstruction.
  """

  @enforce_keys [:path, :prior_value, :new_value]
  defstruct [:path, :prior_value, :new_value]

  @type t :: %__MODULE__{
          path: Predicator.ContextLocation.location_path(),
          prior_value: term(),
          new_value: term()
        }
end
