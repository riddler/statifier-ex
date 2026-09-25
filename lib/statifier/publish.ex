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
      `:invoke_handlers` map, what row S6's check reads. `nil` is no
      declaration: the built-in set only, so every non-built-in
      `<invoke type>` is reported.
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
  alias Statifier.Machine.{Block, Param, State, Transition}
  alias Statifier.Machine.Content.{Assign, Foreach, Script, Send}
  alias Statifier.Machine.Invoke, as: MachineInvoke
  alias Statifier.Parser.Location
  alias Statifier.Send.Target
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
  @rows ["S1", "S2", "S6", "S15", "S16", "S17", "S18", "S19"]

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

  Row S2 reads every `<send>` whose `type` is built-in (absent, `"scxml"`,
  or the SCXML Event I/O Processor URI) and whose `target` is a literal,
  the rule the runtime applies before the send dispatches: a target
  `Statifier.Send.Target.parse/1` cannot parse is a finding of kind
  `:invalid_target`, at the `<send>`'s location, with `data: %{target:
  target}`, in document order. A registered or unsupported `type` is not
  judged (a registered processor's target is its own route string; an
  unsupported type is S1's), and a `targetexpr` or a `typeexpr` is left to
  the runtime. It needs no declaration.

  Row S6 reads every `<invoke>` whose `type` is a literal, the rule the
  runtime applies before the invocation starts: a type
  `Statifier.Invoke.Types.registered?/2` does not register against the
  declared `invoke_types:` is one finding of kind
  `:unregistered_invoke_type`, at the `<invoke>`'s location, with
  `data: %{type: type}`, in document order. With no `invoke_types:` only
  the built-in `scxml` types are registered, as `registered?/2` answers
  for `nil`. An `<invoke>` with no `type` is the built-in `scxml` type and
  is not a finding; a `typeexpr` is resolved at run time and is not
  judged.

  Row S15 composes `Statifier.Chart.check_accepts/2`: one finding of kind
  `:unreachable_name` per declared name no descriptor in the chart's
  vocabulary matches, with `data: %{name: name}`, then one of kind
  `:undeclared_descriptor` per descriptor the declaration does not state,
  with `data: %{descriptor: descriptor}`; neither has a location. With no
  `accepts:` the row reports nothing.

  Row S16 finds every cycle of eventless transitions none of which
  carries a `cond`, the literal half of a macrostep that never reaches
  quiescence and spends the round budget. From each atomic state it
  follows the transition the engine must take with no event: the first
  eventless transition in document order of the state, then of each
  ancestor outward. When that transition has no `cond`, the state it
  leads to is decided by the chart - the state itself for a targetless
  transition, the target for an atomic one, the target's initial child,
  followed down, for a compound one - and a state reached twice closes a
  cycle. One finding of kind `:eventless_cycle` per cycle, at the
  location of the transition taken from the cycle's first state in
  document order, with `data: %{states: [id]}`, the atomic states the
  cycle passes through in the order it passes through them, starting
  there (an id is `nil` for a state that wrote none); cycles in document
  order. A `cond` ahead of or on the taken transition, a state inside a
  `<parallel>`, a transition with more than one target, and a history
  state or `<parallel>` entered along the way each leave the state to run
  time; a chain that reaches a top-level `<final>` ends the execution and
  is no cycle. It needs no declaration.

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

  Row S19 reads every literal write location - an `<assign>`'s `location`,
  a `<send>`'s or an `<invoke>`'s `idlocation`, and each target an empty
  `<finalize>` writes (a `namelist` entry, or a `<param>`'s `location`) -
  and resolves it the way the runtime write does, with every variable used
  as a bracket key standing for a valid key, since that value is the
  data's. A location that does not parse is a finding of kind
  `:parse_error`; one that names something that cannot be assigned (a
  literal, a string, a list, a function call, an operator expression) is
  `:not_assignable`; a membership test, an object literal, a cast, a
  duration or a relative date is `:invalid_node`; a bracket key that is
  neither a string, an integer nor a variable is `:computed_key`. Each
  finding is at the attribute's location (the element's when the attribute
  has none of its own), with `data: %{attribute: :location | :idlocation |
  :namelist, source: source}`: executable content first, in document
  order, then each state's `<invoke>`s in document order, `idlocation`
  before the `<finalize>` targets. A `namelist` entry that did not compile
  is row S13's, not this row's. It needs no declaration.

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

  # The target check `Statifier.Machine.Content.Send`'s `reject_reason/4`
  # applies to a send whose type classifies as built-in: a target
  # `Target.parse/1` answers `{:invalid, _}` for is refused with
  # `{:invalid_target, target}`. Only a literal type and a literal target
  # are judged here.
  defp check("S2", %Machine{contents: contents}, _declaration) do
    for %Send{target: {:static, target}, type: type, location: location} <-
          Tuple.to_list(contents),
        built_in_type?(type),
        match?({:invalid, _target}, Target.parse(target)) do
      finding("S2", :invalid_target, location, %{target: target})
    end
  end

  # The rule `Statifier.Interpreter`'s `registered_type` and
  # `Statifier.Session.Effects`' `plan_invoke` apply before an invocation
  # starts, through the one shared classifier, `InvokeTypes.registered?/2`.
  # Only a literal `type` is judged: a `typeexpr` compiles to
  # `{:compiled, ...}` and is left to the runtime.
  defp check("S6", %Machine{states: states}, declaration) do
    for %Machine.State{invoke: invokes} <- Tuple.to_list(states),
        %Machine.Invoke{type: {:static, type}, location: location} <- invokes,
        not InvokeTypes.registered?(declaration[:invoke_types], type) do
      finding("S6", :unregistered_invoke_type, location, %{type: type})
    end
  end

  defp check("S15", machine, declaration) do
    %{unreachable: unreachable, undeclared: undeclared} =
      Chart.check_accepts(machine, declaration[:accepts])

    Enum.map(unreachable, &finding("S15", :unreachable_name, nil, %{name: &1})) ++
      Enum.map(undeclared, &finding("S15", :undeclared_descriptor, nil, %{descriptor: &1}))
  end

  # The literal half of the round budget `Statifier.Interpreter`'s
  # macrostep fold spends (ADR-0019): each atomic state's eventless step,
  # the one `Statifier.Interpreter.Selection`'s
  # `select_eventless_transitions/1` must take when the step has no
  # `cond`, and every cycle those steps close. A history pseudo-state has
  # no children but is never active, so it takes no step.
  defp check("S16", %Machine{states: states} = machine, _declaration) do
    steps =
      for %State{index: index, kind: kind} <- Tuple.to_list(states),
          index != 0,
          kind != :history,
          Machine.atomic?(machine, index),
          step = eventless_step(machine, index),
          step != nil,
          into: %{},
          do: {index, step}

    steps
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce({MapSet.new(), []}, &walk_steps(&1, steps, &2))
    |> elem(1)
    |> Enum.map(&rotate_to_first/1)
    |> Enum.sort()
    |> Enum.map(fn [first | _rest] = cycle ->
      {%Transition{location: location}, _next} = Map.fetch!(steps, first)

      finding("S16", :eventless_cycle, location, %{
        states: Enum.map(cycle, &Machine.id(machine, &1))
      })
    end)
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

  # The rule `Statifier.Interpreter.Datamodel.write_location/4` applies
  # before it writes: the location resolves through
  # `Predicator.context_location/3`. Only a variable bracket key reads the
  # data, so each one is bound to `0`, a valid key; every other refusal of
  # that function is the source's alone.
  defp check("S19", %Machine{contents: contents, states: states}, _declaration) do
    in_content =
      Enum.flat_map(Tuple.to_list(contents), fn
        %Assign{location: source, location_location: at, node_location: node} ->
          [{:location, source, at || node}]

        %Send{idlocation: source, attribute_locations: attrs, location: node}
        when is_binary(source) ->
          [{:idlocation, source, Map.get(attrs, :idlocation, node)}]

        _node ->
          []
      end)

    in_invokes =
      for state <- Tuple.to_list(states),
          invoke <- state.invoke,
          target <- invoke_write_targets(invoke),
          do: target

    for {attribute, source, location} <- in_content ++ in_invokes,
        is_binary(source),
        kind = unassignable_kind(source),
        kind != :ok do
      finding("S19", kind, location, %{attribute: attribute, source: source})
    end
  end

  # An absent `type` is the SCXML Event I/O Processor (6.2.5); a
  # `typeexpr` is resolved at run time and is not judged.
  @spec built_in_type?(type :: Machine.expr() | nil) :: boolean()
  defp built_in_type?(nil), do: true
  defp built_in_type?({:static, type}), do: Target.supported_type?(type)
  defp built_in_type?(_typeexpr), do: false

  # The transition the engine takes from `index` with no event, and the
  # atomic state it leads to, when the chart alone decides both; `nil`
  # otherwise. Another region of a `<parallel>` selects in the same round,
  # so a state with a parallel ancestor is not decided here.
  @spec eventless_step(machine :: Machine.t(), index :: non_neg_integer()) ::
          {Transition.t(), non_neg_integer()} | nil
  defp eventless_step(machine, index) do
    ancestors = Machine.proper_ancestors(machine, index)

    with false <- Enum.any?(ancestors, &Machine.parallel?(machine, &1)),
         %Transition{} = transition <-
           Enum.find_value([index | ancestors], &first_eventless(machine, &1)),
         next when is_integer(next) <- next_atomic(machine, index, transition) do
      {transition, next}
    else
      _undecided -> nil
    end
  end

  # A state's first eventless transition in document order: the one the
  # engine takes when it has no `cond`, `:undecided` when the data decides,
  # `nil` when the state has none and the walk goes on outward.
  @spec first_eventless(machine :: Machine.t(), index :: non_neg_integer()) ::
          Transition.t() | :undecided | nil
  defp first_eventless(machine, index) do
    first =
      machine
      |> Machine.at(index)
      |> Map.fetch!(:transitions)
      |> Enum.map(&Machine.transition(machine, &1))
      |> Enum.find(&(&1.events == []))

    case first do
      nil -> nil
      %Transition{cond: nil} = transition -> transition
      %Transition{} -> :undecided
    end
  end

  @spec next_atomic(
          machine :: Machine.t(),
          index :: non_neg_integer(),
          transition :: Transition.t()
        ) :: non_neg_integer() | nil
  defp next_atomic(_machine, index, %Transition{targets: []}), do: index

  defp next_atomic(machine, _index, %Transition{targets: [target]}),
    do: entered_atomic(machine, target)

  defp next_atomic(_machine, _index, %Transition{}), do: nil

  # The atomic state entering `index` leaves active, followed down each
  # compound state's initial child. A history state enters what it
  # recorded at run time.
  @spec entered_atomic(machine :: Machine.t(), index :: non_neg_integer()) ::
          non_neg_integer() | nil
  defp entered_atomic(machine, index) do
    case Machine.at(machine, index) do
      %State{kind: :history} -> nil
      %State{children: []} -> index
      %State{kind: :state, initial: [initial]} -> entered_atomic(machine, initial)
      %State{} -> nil
    end
  end

  # Follows the steps from `start` until one is missing, one reaches a
  # state an earlier walk already settled, or one repeats a state of this
  # walk, which closes a cycle: the states from that one on.
  @spec walk_steps(
          start :: non_neg_integer(),
          steps :: %{non_neg_integer() => {Transition.t(), non_neg_integer()}},
          acc :: {MapSet.t(non_neg_integer()), [[non_neg_integer()]]}
        ) :: {MapSet.t(non_neg_integer()), [[non_neg_integer()]]}
  defp walk_steps(start, steps, {settled, cycles}) do
    walk_steps(start, steps, settled, cycles, [], MapSet.new())
  end

  @spec walk_steps(
          index :: non_neg_integer(),
          steps :: %{non_neg_integer() => {Transition.t(), non_neg_integer()}},
          settled :: MapSet.t(non_neg_integer()),
          cycles :: [[non_neg_integer()]],
          path :: [non_neg_integer()],
          on_path :: MapSet.t(non_neg_integer())
        ) :: {MapSet.t(non_neg_integer()), [[non_neg_integer()]]}
  defp walk_steps(index, steps, settled, cycles, path, on_path) do
    cond do
      MapSet.member?(on_path, index) ->
        cycle = path |> Enum.reverse() |> Enum.drop_while(&(&1 != index))
        {MapSet.union(settled, on_path), [cycle | cycles]}

      MapSet.member?(settled, index) or not Map.has_key?(steps, index) ->
        {MapSet.union(settled, on_path), cycles}

      true ->
        {_transition, next} = Map.fetch!(steps, index)
        walk_steps(next, steps, settled, cycles, [index | path], MapSet.put(on_path, index))
    end
  end

  # A cycle read from its first state in document order.
  @spec rotate_to_first(cycle :: [non_neg_integer()]) :: [non_neg_integer()]
  defp rotate_to_first(cycle) do
    first = Enum.min(cycle)
    {before, from_first} = Enum.split_while(cycle, &(&1 != first))
    from_first ++ before
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

  # An `<invoke>`'s `idlocation`, then - only when its `<finalize>` is
  # empty, the one case the runtime auto-assigns - every `namelist` entry
  # and `<param location>` that compiled, the targets that write reads.
  @spec invoke_write_targets(invoke :: MachineInvoke.t()) ::
          [{atom(), String.t(), Location.t() | nil}]
  defp invoke_write_targets(%MachineInvoke{} = invoke) do
    idlocation =
      if is_binary(invoke.idlocation),
        do: [
          {:idlocation, invoke.idlocation,
           Map.get(invoke.attribute_locations, :idlocation, invoke.location)}
        ],
        else: []

    finalize =
      case invoke.finalize do
        %Block{content: []} ->
          for {attribute, params} <- [namelist: invoke.namelist, location: invoke.params],
              %Param{kind: :location, expr: {:compiled, _compiled, source}} = param <- params,
              do: {attribute, source, param.expr_location || param.location}

        _absent_or_populated ->
          []
      end

    idlocation ++ finalize
  end

  @spec unassignable_kind(source :: String.t()) ::
          :ok | :parse_error | :not_assignable | :invalid_node | :computed_key
  defp unassignable_kind(source) do
    case Predicator.context_location(source, bracket_variables(source)) do
      {:ok, _path} -> :ok
      {:error, %Predicator.Errors.ParseError{}} -> :parse_error
      {:error, %Predicator.Errors.LocationError{type: type}} -> location_kind(type)
    end
  end

  @spec location_kind(type :: atom()) :: :ok | :not_assignable | :invalid_node | :computed_key
  defp location_kind(type) when type in [:not_assignable, :invalid_node, :computed_key], do: type
  defp location_kind(_type_the_data_decides), do: :ok

  # Every identifier in the source bound to `0`, so a variable bracket key
  # resolves whatever the data will hold; the other identifiers are never
  # read by the resolution.
  @spec bracket_variables(source :: String.t()) :: %{String.t() => 0}
  defp bracket_variables(source) do
    case Predicator.Lexer.tokenize(source) do
      {:ok, tokens} ->
        for {:identifier, _line, _column, _length, name} <- tokens, into: %{}, do: {name, 0}

      _error ->
        %{}
    end
  end

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
