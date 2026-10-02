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

  The module holds the two things ADR-0069 asks to exist exactly once:

    - `from_send_types/1`, the one constructor, deriving the registered set
      from a `:send_types` map's own keys;
    - `classify/2`, the one classifier. `Statifier.Machine.Content.Send`'s
      static check answers through it, and so do `unsupported_sends/2`
      below and `Statifier.Session.start_link/2`'s refusal of a map that
      names a built-in spelling. Built-in membership keeps delegating to
      `Statifier.Send.Target.supported_type?/1`, so 6.2.5's short-form and
      URI reasoning stays in one place.

  Beside the set, a registered set carries each type's `_ioprocessors`
  entry (spec 5.10), the value its processor supplies through the optional
  `c:Statifier.Send.Processor.ioprocessors_entry/1` callback, and each
  type's module and registration options, so
  `Statifier.MachineState.new/2` can write the entries from the same
  stamp it classifies against, asking a processor that implements the
  optional `c:Statifier.Send.Processor.ioprocessors_entry/2` once the
  session id is known (ADR-0075 decision 3).

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

  defstruct types: MapSet.new(), entries: %{}, processors: %{}

  @typedoc """
  One `:send_types` value (ADR-0075 decision 8, point b): a bare
  `Statifier.Send.Processor` module, or the module with its registration
  options. The options reach the processor's
  `c:Statifier.Send.Processor.ioprocessors_entry/2` context and, for a
  `{module, opts}` registration only, the plan context its callbacks
  receive, under `:opts`.
  """
  @type registration :: module() | {module(), keyword()}

  @typedoc """
  The registered set. `types` is the set `classify/2` answers against;
  `entries` holds each type's `_ioprocessors` value as
  `c:Statifier.Send.Processor.ioprocessors_entry/1` returned it (or an
  empty map); `processors` holds each type's module and options, a bare
  module's options being `[]`.
  """
  @type t :: %__MODULE__{
          types: MapSet.t(String.t()),
          entries: %{String.t() => map()},
          processors: %{String.t() => {module(), keyword()}}
        }

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
  (`%{type_string => registration}`, a `t:registration/0` being a module
  or `{module, opts}`), derived from the map's own keys rather than
  declared beside it - the `<send>` counterpart of
  `Statifier.Invoke.Types.from_handlers/1`.

  An empty map returns `nil`, "no declaration": `classify/2` answers the
  same for `nil` and for an empty set, and `nil` is what a session started
  without `:send_types` has always carried, so a host that registers nothing
  sees nothing change.

  This is the only derivation of a registered send-type set in the library.
  It does not refuse a built-in spelling; `Statifier.Session.start_link/2`
  does, and `classify/2` answers `:built_in` for a built-in spelling
  whatever the set holds.

  `entries` holds each type's `_ioprocessors` value: what the type's module
  returns from `c:Statifier.Send.Processor.ioprocessors_entry/1`, or an
  empty map when the module does not export it. Raises `ArgumentError`
  when a returned value is not a map, or holds an atom key other than
  `true` or `false` at any level, because every datamodel key is a string.
  `processors` keeps each type's module and options (ADR-0075 decision 3),
  so `Statifier.Evaluator.SystemVariables.initial/3` can ask a module that
  exports `c:Statifier.Send.Processor.ioprocessors_entry/2` for its entry
  once the session id is known; that function says when the entries are
  written and how they read after a resume.
  """
  @spec from_send_types(send_types :: %{optional(String.t()) => registration()}) :: t() | nil
  def from_send_types(send_types) when is_map(send_types) and map_size(send_types) == 0,
    do: nil

  def from_send_types(send_types) when is_map(send_types) do
    processors = Map.new(send_types, fn {type, registration} -> {type, split(registration)} end)

    %__MODULE__{
      types: send_types |> Map.keys() |> MapSet.new(),
      entries:
        Map.new(processors, fn {type, {module, _opts}} -> {type, entry!(module, type)} end),
      processors: processors
    }
  end

  # The module and options of one `t:registration/0`: a bare module's
  # options are `[]`. Callable across the library's own modules (the
  # planner reads registrations through it) but not part of its public API,
  # hence `@doc false`.
  @doc false
  @spec split(registration :: registration()) :: {module(), keyword()}
  def split({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  def split(module) when is_atom(module), do: {module, []}

  # Whether `split/1` accepts `registration`'s shape, by the same guards,
  # without calling it. Internal: `Statifier.Session.start_link/2` leaves a
  # map holding any other shape to `init/1`, hence `@doc false`.
  @doc false
  @spec registration?(registration :: term()) :: boolean()
  def registration?({module, opts}) when is_atom(module) and is_list(opts), do: true
  def registration?(module) when is_atom(module), do: true
  def registration?(_other), do: false

  # The first registration of a `:send_types` map, in the order of its type
  # strings, whose module exports the optional
  # `c:Statifier.Send.Processor.check_registration/2` and answers
  # `{:error, reason}`, as `{type, reason}`; `nil` when none does. Every
  # exporting module is asked before any answer is used, and when one of
  # them raises, throws, exits or answers anything other than `:ok` or
  # `{:error, reason}`, the answer is `nil` too, so the caller leaves the
  # start to `Statifier.Session`'s `init/1` as if nothing were asked. A
  # module that does not export the callback is not asked. Internal:
  # `Statifier.Session`'s fresh start is its caller, hence `@doc false`.
  @doc false
  @spec rejected_registration(send_types :: %{optional(String.t()) => registration()}) ::
          {String.t(), term()} | nil
  def rejected_registration(send_types) when is_map(send_types) do
    answers =
      send_types
      |> Enum.sort_by(fn {type, _registration} -> type end)
      |> Enum.map(fn {type, registration} -> {type, answer(type, split(registration))} end)

    if Enum.any?(answers, &match?({_type, :unanswered}, &1)),
      do: nil,
      else: Enum.find_value(answers, &rejection/1)
  end

  @spec rejection({type :: String.t(), answer :: :ok | {:error, term()}}) ::
          {String.t(), term()} | nil
  defp rejection({type, {:error, reason}}), do: {type, reason}
  defp rejection({_type, :ok}), do: nil

  # One module's answer to `check_registration/2`, `:ok` for a module that
  # does not export it, and `:unanswered` for a check that does not keep the
  # callback's contract, whatever it does instead.
  @spec answer(type :: String.t(), processor :: {module(), keyword()}) ::
          :ok | {:error, term()} | :unanswered
  defp answer(type, {module, opts}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :check_registration, 2) do
      ask(module, type, opts)
    else
      :ok
    end
  end

  @spec ask(module :: module(), type :: String.t(), opts :: keyword()) ::
          :ok | {:error, term()} | :unanswered
  defp ask(module, type, opts) do
    case module.check_registration(type, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> :unanswered
    end
  rescue
    _exception -> :unanswered
  catch
    _kind, _value -> :unanswered
  end

  # The value `module` returns from `ioprocessors_entry/2` for `type` and
  # `context`, checked as `from_send_types/1` checks a `/1` entry.
  # Internal: `Statifier.Evaluator.SystemVariables.initial/3` is its one
  # caller (ADR-0075 decision 3), hence `@doc false`.
  @doc false
  @spec session_entry!(module :: module(), type :: String.t(), context :: map()) :: map()
  def session_entry!(module, type, context),
    do: checked!(module.ioprocessors_entry(type, context), module, type)

  # The processor's own `_ioprocessors` value for `type`, checked at the one
  # constructor so a value that reaches the datamodel is string-keyed by
  # construction, as `Statifier.MachineState`'s datamodel invariant needs.
  @spec entry!(module :: module(), type :: String.t()) :: map()
  defp entry!(module, type) do
    entry =
      if Code.ensure_loaded?(module) and function_exported?(module, :ioprocessors_entry, 1),
        do: module.ioprocessors_entry(type),
        else: %{}

    checked!(entry, module, type)
  end

  @spec checked!(entry :: term(), module :: module(), type :: String.t()) :: map()
  defp checked!(entry, module, type) do
    unless is_map(entry) and string_keyed?(entry) do
      raise ArgumentError,
            "#{inspect(module)}.ioprocessors_entry(#{inspect(type)}) must return a map " <>
              "string-keyed at every level, got: #{inspect(entry)}"
    end

    entry
  end

  @spec string_keyed?(value :: term()) :: boolean()
  defp string_keyed?(%_struct{}), do: true
  defp string_keyed?(list) when is_list(list), do: Enum.all?(list, &string_keyed?/1)

  defp string_keyed?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      not (is_atom(key) and not is_boolean(key)) and string_keyed?(value)
    end)
  end

  defp string_keyed?(_scalar), do: true

  @doc """
  Classifies a resolved `<send type>` against `types` (see
  `t:Statifier.Send.Types.class/0`).

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
