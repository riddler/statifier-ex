defmodule Statifier.Invoke.Types do
  @moduledoc """
  A caller-declared, point-in-time claim about which `<invoke type>` values
  this deployment implements beyond the built-in `scxml` handler (ADR-0051
  decision 2) - a plain value in `Statifier.Invoke`'s namespace, mirroring
  `Statifier.Send.Routes`'s own shape and moduledoc posture.

  This is a claim, not an observation: it is stamped once per session via
  `Statifier.MachineState.new/2`'s `:invoke_types` option (not per drive -
  the registered set is fixed for the session's lifetime, unlike
  `Statifier.Send.Routes`) and carries no obligation to track anything
  between writes.

  `registered?/2` is the single shared classifier ADR-0047 decision 4 and
  ADR-0051 decision 3 require: both `Statifier.Interpreter`'s
  `maybe_record_active_invocation/5` and
  `Statifier.Session.Effects.plan_invoke` answer "is this type registered"
  by calling it, so the two sites cannot drift. Built-in membership -
  `nil`, `"scxml"`, and the bare `http://www.w3.org/TR/scxml/` URI - keeps
  delegating to `Statifier.Send.Target.supported_invoke_type?/1` rather than
  being reimplemented here, so 6.4's short-form and long-URI reasoning stays
  in exactly one place.
  """

  alias Statifier.Send.Target

  defstruct types: MapSet.new()

  @type t :: %__MODULE__{types: MapSet.t(String.t())}

  @doc """
  Builds a snapshot from `opts`: `:types` (default empty, a `MapSet` or any
  `Enum` of registered `<invoke type>` strings - `MapSet.new/1` accepts
  either).
  """
  @spec new(opts :: keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{types: opts |> Keyword.get(:types, MapSet.new()) |> MapSet.new()}
  end

  @doc """
  Builds the snapshot ADR-0051 decision 3's "one constructor" describes:
  the registered set derived from an `:invoke_handlers` map's own keys,
  rather than declared beside it.

  `Statifier.Session` stamps the core with this at both of its boot arms
  (fresh and resumed), so the set the pure core classifies against and the
  dispatch map `Statifier.Session.Effects` routes on cannot diverge - they
  are one map read two ways. A host assembling that map from
  `Statifier.Invoke.SyncHandler` modules closes the same loop one step
  further out: `Statifier.Invoke.SyncHandler.Adapter.invoke_handlers/2`
  builds the map from the one union its `invoke_types/1` computes.

  This is the only derivation of a registered-type set from a handler map in
  the library. A second one written inline somewhere else would be the exact
  drift decision 3 exists to rule out.
  """
  @spec from_handlers(invoke_handlers :: %{String.t() => module()}) :: t()
  def from_handlers(invoke_handlers) when is_map(invoke_handlers) do
    new(types: Map.keys(invoke_handlers))
  end

  @doc """
  Whether `type` is registered against `types`.

  `types` may be `nil` - "no declaration made", the same meaning `nil`
  carries on `%Statifier.MachineState{}.invoke_types` itself - in which case
  this answers exactly what `Statifier.Send.Target.supported_invoke_type?/1`
  answers today: `true` for `nil`, `"scxml"`, and the bare
  `http://www.w3.org/TR/scxml/` URI; `false` for everything else, including
  the `#SCXMLEventProcessor` URI.

  A non-`nil` snapshot answers `true` for the built-in set unioned with the
  declared set - declaring types adds to the built-ins, it never replaces
  them.
  """
  @spec registered?(types :: t() | nil, type :: String.t() | nil) :: boolean()
  def registered?(nil, type), do: Target.supported_invoke_type?(type)

  def registered?(%__MODULE__{types: types}, type) do
    Target.supported_invoke_type?(type) or (is_binary(type) and MapSet.member?(types, type))
  end
end
