defmodule Statifier.Publish do
  @moduledoc """
  The one publish-time function a host calls over a compiled chart:
  `findings/2` runs every publish-time check this package holds and
  returns what they found, each finding naming its row of
  `docs/publish-time-checks.md` (ADR-0073).

  A host's publish step is the gate between an edited chart and its first
  execution. It calls `findings/2` with the chart and a *declaration* of
  the deployment the chart will run in - the send types and invoke types
  the host registers, and the event names it says the chart accepts - and
  decides what to refuse on. The function reports and refuses nothing:
  which rows a host refuses a publish on is the host's decision, and an
  editor runs the same function at edit time to show the same findings.

  ## What a check is

  Every check inside `findings/2` is the publish-time twin of one runtime
  refusal, and the table in `docs/publish-time-checks.md` names the row.
  The checks that already exist as public functions are composed in, never
  moved: `Statifier.Send.Types.unsupported_sends/2` (row S1) and
  `Statifier.Chart.check_accepts/2` (row S15). The rows the table lists as
  NONE land here one at a time, each as one private clause of `check/3`
  and one entry in the row list, never as a module or a public function of
  its own. `Statifier.Validator` and `Statifier.compile/2` are untouched:
  a chart that compiles today compiles tomorrow, whatever this function
  reports.

  ## What a finding is

  A finding is a plain map with four keys:

    - `row` - the row's id in `docs/publish-time-checks.md`, a string such
      as `"S1"`.
    - `kind` - which finding of that row this is, an atom the row's clause
      defines, so one row can report more than one kind.
    - `location` - the `Statifier.Parser.Location.t()` of the element the
      finding is about, or `nil` when the finding has no element (a
      declared name the chart never selects on has none).
    - `data` - the row's own detail, a map whose keys the row's clause
      defines.

  Findings are ordered by row, in the row list's order, and inside a row
  in the composed check's own order.

  ## The declaration

  The second argument is a keyword list. Every key is optional, and an
  absent key is `nil`, which each check reads as "not declared" in the
  sense its composed function gives it:

    - `send_types:` - a `Statifier.Send.Types.t()`, the set a host builds
      with `Statifier.Send.Types.from_send_types/1` from the `:send_types`
      map it will start the chart with. `nil` is no declaration: the
      built-in set only, so every non-built-in `<send type>` is reported.
    - `invoke_types:` - a `Statifier.Invoke.Types.t()`, the set a host
      builds with `Statifier.Invoke.Types.from_handlers/1` from its
      `:invoke_handlers` map. Read by row S6's check when it lands; until
      then accepted and unread.
    - `accepts:` - the event names the host declares the chart accepts, a
      list of strings. `nil` is no declaration: the computed vocabulary
      is the contract and row S15 reports nothing.

  A key outside these three, or a value of the wrong shape, raises
  `ArgumentError`: it is a caller's programming error, not data.

  Pure and total over a `%Statifier.Machine{}` and a declaration: the
  function reads the compiled machine and runs nothing, so the same chart
  and declaration always give the same findings.
  """

  alias Statifier.{Chart, Machine}
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Machine.Content.{Foreach, Script}
  alias Statifier.Parser.Location
  alias Statifier.Send.Types, as: SendTypes

  @typedoc """
  One finding: its row of `docs/publish-time-checks.md`, which finding of
  that row it is, the element's location when it has one, and the row's
  own detail.
  """
  @type finding :: %{
          row: String.t(),
          kind: atom(),
          location: Location.t() | nil,
          data: map()
        }

  @typedoc """
  What the host declares about the deployment: the registered send types,
  the registered invoke types, and the accepted event names. Every key is
  optional.
  """
  @type declaration :: [
          send_types: SendTypes.t() | nil,
          invoke_types: InvokeTypes.t() | nil,
          accepts: [String.t()] | nil
        ]

  @declaration_keys [:send_types, :invoke_types, :accepts]

  # The rows this function holds, in the order their findings are
  # returned. A row lands by adding its id here and one `check/3` clause
  # below.
  @rows ["S1", "S15", "S17", "S18"]

  # Row S17: the bare-variable-name shape a `<foreach>` `item` or `index`
  # must have, the same one the runtime refusal reads.
  @foreach_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc """
  Every finding of every publish-time check this package holds, over
  `machine` and the host's `declaration`, ordered by row.

  Row S1 composes `Statifier.Send.Types.unsupported_sends/2`: one finding
  of kind `:unsupported_send_type` per `<send>` whose literal `type` the
  declared `send_types:` does not register, at the `<send>`'s location,
  with `data: %{type: type}`.

  Row S15 composes `Statifier.Chart.check_accepts/2`: one finding of kind
  `:unreachable_name` per declared name no descriptor in the chart's
  vocabulary matches, with `data: %{name: name}`, then one of kind
  `:undeclared_descriptor` per descriptor the declaration does not state,
  with `data: %{descriptor: descriptor}`; neither has a location. With no
  `accepts:` the row reports nothing.

  Row S17 reads every `<foreach>`'s literal `item` and `index` names, the
  rule the runtime applies before the loop runs: a name that begins with
  `_` is a finding of kind `:system_variable`; any other name that is not a
  bare variable name (a letter or `_`, then letters, digits or `_`) is
  `:illegal_item_name` or `:illegal_index_name`. Each finding is at the
  attribute's location, with `data: %{attribute: :item | :index, name:
  name}`, in document order, `item` before `index`; an absent `index` is
  not judged. It needs no declaration.

  Row S18 reads every `<script>` body's assignment targets, the rule the
  runtime applies when the script runs: an assignment whose target's root
  begins with `_` is a finding of kind `:system_variable`, with
  `data: %{root: root}`, once per root per script, an assignment inside an
  `if` or `while` body included. Top-level scripts come first, in document
  order, with no location (the compiled chart keeps none for them); then
  every `<script>` in executable content, in document order, at the
  `<script>`'s location. A read of a system variable is not a finding, and
  a body that did not compile is not judged by this row. It needs no
  declaration.

  See the moduledoc for the finding shape and the declaration's keys.
  """
  @spec findings(machine :: Machine.t(), declaration :: declaration()) :: [finding()]
  def findings(%Machine{} = machine, declaration \\ []) do
    declaration = declaration!(declaration)
    Enum.flat_map(@rows, &check(&1, machine, declaration))
  end

  @spec check(row :: String.t(), machine :: Machine.t(), declaration :: declaration()) ::
          [finding()]
  defp check("S1", machine, declaration) do
    for %{type: type, location: location} <-
          SendTypes.unsupported_sends(machine, declaration[:send_types]) do
      finding("S1", :unsupported_send_type, location, %{type: type})
    end
  end

  defp check("S15", machine, declaration) do
    %{unreachable: unreachable, undeclared: undeclared} =
      Chart.check_accepts(machine, declaration[:accepts])

    Enum.map(unreachable, &finding("S15", :unreachable_name, nil, %{name: &1})) ++
      Enum.map(undeclared, &finding("S15", :undeclared_descriptor, nil, %{descriptor: &1}))
  end

  # The rule `Statifier.Machine.Content.Foreach`'s `execute/2` applies to
  # `item` and `index` before the loop runs: a `_` prefix is a system
  # variable, checked first, then the bare-variable-name shape.
  defp check("S17", %Machine{contents: contents}, _declaration) do
    for %Foreach{} = node <- Tuple.to_list(contents),
        {attribute, name, location, illegal} <- [
          {:item, node.item, node.item_location, :illegal_item_name},
          {:index, node.index, node.index_location, :illegal_index_name}
        ],
        is_binary(name),
        kind = foreach_name_kind(name, illegal),
        kind != :ok do
      finding("S17", kind, location, %{attribute: attribute, name: name})
    end
  end

  # The rule `Statifier.Evaluator.run_program/2` applies to a program's
  # writes: a root beginning with `_` is a system variable, refused as
  # `{:system_variable, root}`. The targets are read from the program's own
  # source, which the compiled machine keeps beside its instructions.
  defp check("S18", %Machine{global_scripts: global, contents: contents}, _declaration) do
    top_level = for {:program, _compiled, source} <- global, do: {source, nil}

    in_content =
      for %Script{program: {:program, _compiled, source}, node_location: location} <-
            Tuple.to_list(contents),
          do: {source, location}

    for {source, location} <- top_level ++ in_content,
        root <- system_roots_written(source) do
      finding("S18", :system_variable, location, %{root: root})
    end
  end

  @spec foreach_name_kind(name :: String.t(), illegal :: atom()) :: :ok | atom()
  defp foreach_name_kind(name, illegal) do
    cond do
      String.starts_with?(name, "_") -> :system_variable
      Regex.match?(@foreach_name, name) -> :ok
      true -> illegal
    end
  end

  @spec system_roots_written(source :: String.t()) :: [String.t()]
  defp system_roots_written(source) do
    case Predicator.parse_program(source) do
      {:ok, {:program, statements, _position}} ->
        statements
        |> Enum.flat_map(&written_roots/1)
        |> Enum.filter(&String.starts_with?(&1, "_"))
        |> Enum.uniq()

      _error ->
        []
    end
  end

  @spec written_roots(statement :: term()) :: [String.t()]
  defp written_roots({:assignment, target, _value, _position}), do: [location_root(target)]

  defp written_roots({:if, _condition, then_block, else_block, _position}),
    do: written_roots(then_block) ++ written_roots(else_block)

  defp written_roots({:while, _condition, body, _position}), do: written_roots(body)

  defp written_roots({:block, statements, _position}),
    do: Enum.flat_map(statements, &written_roots/1)

  defp written_roots(_expression_or_nil), do: []

  @spec location_root(target :: term()) :: String.t()
  defp location_root({:identifier, name, _position}), do: name
  defp location_root({:property_access, inner, _property, _position}), do: location_root(inner)
  defp location_root({:bracket_access, inner, _key, _position}), do: location_root(inner)

  @spec finding(row :: String.t(), kind :: atom(), location :: Location.t() | nil, data :: map()) ::
          finding()
  defp finding(row, kind, location, data),
    do: %{row: row, kind: kind, location: location, data: data}

  @spec declaration!(declaration :: term()) :: declaration()
  defp declaration!(declaration) when is_list(declaration) do
    unless Keyword.keyword?(declaration) do
      raise ArgumentError, "the declaration must be a keyword list, got: #{inspect(declaration)}"
    end

    Enum.each(declaration, fn
      {:send_types, value} when is_nil(value) or is_struct(value, SendTypes) -> :ok
      {:invoke_types, value} when is_nil(value) or is_struct(value, InvokeTypes) -> :ok
      {:accepts, value} when is_nil(value) or is_list(value) -> :ok
      {key, value} when key in @declaration_keys -> raise_value(key, value)
      {key, _value} -> raise_key(key)
    end)

    declaration
  end

  defp declaration!(declaration) do
    raise ArgumentError, "the declaration must be a keyword list, got: #{inspect(declaration)}"
  end

  @spec raise_key(key :: term()) :: no_return()
  defp raise_key(key) do
    raise ArgumentError,
          "unknown declaration key #{inspect(key)}; the keys are #{inspect(@declaration_keys)}"
  end

  @spec raise_value(key :: atom(), value :: term()) :: no_return()
  defp raise_value(key, value) do
    raise ArgumentError,
          "the declaration's #{inspect(key)} has the wrong shape: #{inspect(value)}"
  end
end
