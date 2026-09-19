defmodule Statifier.Send.Types do
  @moduledoc """
  A caller-declared, point-in-time claim about which `<send type>` values
  this deployment's Event I/O Processors implement beyond the built-in SCXML
  processor (ADR-0069 decision 2) - the `<send>` counterpart of
  `Statifier.Invoke.Types`, in the same shape and the same posture.

  This is a claim, not an observation: it is stamped once per session via
  `Statifier.MachineState.new/2`'s `:send_types` option (or
  `Statifier.MachineState.put_send_types/2` after a resume), fixed for the
  session's lifetime, and carries no obligation to track anything between
  writes.

  The module holds the three things ADR-0069 asks to exist exactly once:

    - `from_send_types/1`, the one constructor, deriving the registered set
      from a `:send_types` map's own keys;
    - `classify/2`, the one classifier. `Statifier.Machine.Content.Send`'s
      static check answers through it, and so do
      `check_registration/1` and `unsupported_sends/2` below. Built-in
      membership keeps delegating to
      `Statifier.Send.Target.supported_type?/1`, so 6.2.5's short-form and
      URI reasoning stays in one place;
    - `check_registration/1`, the refusal of a map that names a built-in
      spelling, which `Statifier.Session.start_link/2` runs before a session
      boots.

  `unsupported_sends/2` is the pure pre-start check of ADR-0069 decision 3.
  It lives here rather than in `Statifier.Validator`, because
  `Statifier.Validator.validate/3` judges a document against the spec and
  takes no deployment state, while this check is a question about a
  deployment's registered set.
  """

  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.Parser.Location
  alias Statifier.Send.Target

  defstruct types: MapSet.new()

  @type t :: %__MODULE__{types: MapSet.t(String.t())}

  @typedoc """
  What `classify/2` answers for one resolved `<send type>`:

    - `:built_in` - absent, `"scxml"`, or the SCXML Event I/O Processor URI;
      the target is C.1's vocabulary and the library delivers it.
    - `:registered` - a type in the declared set; the target is the
      processor's opaque route string and is never parsed.
    - `:unsupported` - anything else; 6.2.5's `error.execution`.
  """
  @type class :: :built_in | :registered | :unsupported

  @typedoc "One `<send>` the pre-start check reports: its literal `type` and its element location."
  @type unsupported_send :: %{type: String.t(), location: Location.t()}

  @doc """
  Builds the registered set from a `:send_types` map
  (`%{type_string => module}`), derived from the map's own keys rather than
  declared beside it - the `<send>` counterpart of
  `Statifier.Invoke.Types.from_handlers/1`.

  An empty map returns `nil`, "no declaration": `classify/2` answers the
  same for `nil` and for an empty set, and `nil` is what a session started
  without `:send_types` has always carried, so a host that registers nothing
  sees nothing change.

  This is the only derivation of a registered send-type set in the library.
  It does not refuse a built-in spelling; `check_registration/1` does, at
  session start, and `classify/2` answers `:built_in` for a built-in
  spelling whatever the set holds.
  """
  @spec from_send_types(send_types :: %{optional(String.t()) => module()}) :: t() | nil
  def from_send_types(send_types) when is_map(send_types) and map_size(send_types) == 0,
    do: nil

  def from_send_types(send_types) when is_map(send_types),
    do: %__MODULE__{types: send_types |> Map.keys() |> MapSet.new()}

  @doc """
  Refuses a `:send_types` map that names a built-in spelling - `nil`,
  `"scxml"`, or the SCXML Event I/O Processor URI (ADR-0069 decision 1), so
  a built-in send can never be redirected to a host processor.

  Returns `{:error, {:built_in_types, types}}` with every offending key,
  sorted, so a host learns the whole set in one round trip.
  """
  @spec check_registration(send_types :: map()) :: :ok | {:error, {:built_in_types, [term()]}}
  def check_registration(send_types) when is_map(send_types) do
    case send_types |> Map.keys() |> Enum.filter(&(classify(nil, &1) == :built_in)) do
      [] -> :ok
      built_ins -> {:error, {:built_in_types, Enum.sort(built_ins)}}
    end
  end

  @doc """
  Classifies a resolved `<send type>` against `types` (see `t:class/0`).

  A built-in spelling is `:built_in` whatever `types` holds, so the built-in
  processor keeps its targets. `nil` for `types` means "no declaration": the
  built-in set only, which is 6.2.5's closed set as it stood before
  ADR-0069 - every non-built-in type is `:unsupported`.
  """
  @spec classify(types :: t() | nil, type :: term()) :: class()
  def classify(types, type) do
    cond do
      Target.supported_type?(type) -> :built_in
      declared?(types, type) -> :registered
      true -> :unsupported
    end
  end

  @spec declared?(types :: t() | nil, type :: term()) :: boolean()
  defp declared?(nil, _type), do: false

  defp declared?(%__MODULE__{types: types}, type),
    do: is_binary(type) and MapSet.member?(types, type)

  @doc """
  The pre-start check of ADR-0069 decision 3: every `<send>` in `machine`
  whose literal `type` attribute `classify/2` answers `:unsupported` for
  against `types`, with the `<send>` element's location, in `c_index`
  order.

  Pure and total. A host calls it with a compiled chart and the set it will
  start the chart with (`from_send_types/1` of its `:send_types` map), and
  may refuse to start or activate a chart that names a processor it never
  registered. It cannot see a `typeexpr`: a type resolved at evaluation
  time is judged by the core's own check alone, which stays the backstop
  for both.
  """
  @spec unsupported_sends(machine :: Machine.t(), types :: t() | nil) :: [unsupported_send()]
  def unsupported_sends(%Machine{contents: contents}, types) do
    for %Content.Send{type: {:static, type}, location: location} <- Tuple.to_list(contents),
        classify(types, type) == :unsupported do
      %{type: type, location: location}
    end
  end
end
