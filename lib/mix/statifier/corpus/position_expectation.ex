defmodule Mix.Statifier.Corpus.PositionExpectation do
  @moduledoc """
  The position a corpus step's `expect_position` states (ADR-0076): what
  `Statifier.Position.export/1` answers for the chart's state after that
  step, with the fields a conforming implementation need not share left
  out, rendered as the JSON value a case writes.

  The rendering is a map with string keys and exactly these seven members:

  - `configuration`, `entered_states` and `states_to_invoke`: each set of
    state ids as an array sorted ascending.
  - `history_values`: an object from each history state's id to its
    recorded state ids, as an array sorted ascending.
  - `active_invocations`: one object per active invocation, `state` (the id
    of the state that owns the `<invoke>`) and `index` (the `<invoke>`'s
    ordinal among that state's own), sorted by `state` and then by `index`;
    the invocation's id is left out.
  - `running`: the export's boolean as it is.
  - `datamodel`: the export's datamodel with `_event`, `_ioprocessors` and
    `_sessionid` removed, and `_name` removed as well unless the document's
    `<scxml>` element carries a `name` attribute: spec 5.10 binds `_name`
    to that attribute's value, so every conforming implementation holds the
    same one, while an unset `_name` is each implementation's own spelling.
    A string, a number, a boolean and `nil` are written as they are,
    `:undefined` as `nil` (JSON `null`), a list as an array and a map with
    string keys as an object, member by member; any other value has no JSON
    form and is refused, naming its variable.

  The export's other members (`identity`, `invoke_counter`, `send_counter`,
  `timer_counter`, `status`, `macrostep`, `microstep`, `round`, `trace` and
  `max_macrostep_rounds`) are not rendered. ADR-0076 gives the reason for
  each.

  A case that carries an `expect_position` on any step needs every state of
  its document to carry an id (`named/1`), because the export refuses a
  position that holds a state it cannot name.
  """

  alias Statifier.{Machine, MachineState, Position}

  @left_out_variables ~w(_event _ioprocessors _sessionid)

  @doc """
  Whether any of `corpus_case`'s steps carries an `expect_position`.
  """
  @spec expected?(corpus_case :: map()) :: boolean()
  def expected?(%{"steps" => steps}), do: Enum.any?(steps, &Map.has_key?(&1, "expect_position"))

  @doc """
  Answers `:ok` when every state of `machine` but the root carries an id,
  and a disagreement naming the count of states without one otherwise.
  """
  @spec named(machine :: Machine.t()) :: :ok | {:disagree, String.t()}
  def named(%Machine{states: states} = machine) do
    case Enum.count(1..(tuple_size(states) - 1)//1, &is_nil(Machine.id(machine, &1))) do
      0 ->
        :ok

      unnamed ->
        {:disagree,
         "a case that expects a position needs every state to carry an id, " <>
           "and #{unnamed} state(s) of this document have none"}
    end
  end

  @doc """
  Renders `machine_state`'s exported position in the expectation's JSON
  form, or answers why it cannot: the export's own refusal, or a datamodel
  value with no JSON form.
  """
  @spec render(machine_state :: MachineState.t()) :: {:ok, map()} | {:error, String.t()}
  def render(%MachineState{} = machine_state) do
    with {:ok, exported} <- export(machine_state),
         {:ok, datamodel} <- datamodel(exported.datamodel, machine_state.machine.name) do
      {:ok,
       %{
         "configuration" => ids(exported.configuration),
         "entered_states" => ids(exported.entered_states),
         "states_to_invoke" => ids(exported.states_to_invoke),
         "history_values" => Map.new(exported.history_values, fn {id, set} -> {id, ids(set)} end),
         "active_invocations" => invocations(exported.active_invocations),
         "running" => exported.running,
         "datamodel" => datamodel
       }}
    end
  end

  @doc """
  Compares `expected`, a step's `expect_position`, with the rendering of
  `machine_state`. `step` names the step in a disagreement: its one-based
  number and its event's name. Each member that differs is named, with
  both values as JSON.

  Values compare as JSON values: two numbers agree when they are equal
  in value, so a float `2.0` the chart holds agrees with an expected
  `2`; an array compares element by element in order, an object member
  by member; a string, a boolean and `null` agree only with themselves.
  """
  @spec compare(
          expected :: map(),
          machine_state :: MachineState.t(),
          step :: {pos_integer(), String.t()}
        ) :: :ok | {:disagree, String.t()}
  def compare(expected, %MachineState{} = machine_state, {number, event}) do
    label = "after step #{number} (#{event}), expect_position"

    case render(machine_state) do
      {:ok, actual} ->
        (Map.keys(expected) ++ Map.keys(actual))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.reject(&same?(Map.get(expected, &1, :absent), Map.get(actual, &1, :absent)))
        |> differs(expected, actual, label)

      {:error, reason} ->
        {:disagree, "#{label} cannot be compared: #{reason}"}
    end
  end

  defp differs([], _expected, _actual, _label), do: :ok

  defp differs(keys, expected, actual, label) do
    differing =
      Enum.map_join(keys, "; ", fn key ->
        "#{key}: expected #{encode(Map.get(expected, key))}, " <>
          "but got #{encode(Map.get(actual, key))}"
      end)

    {:disagree, "#{label} differs: #{differing}"}
  end

  # Equality of two JSON values: numbers by value, arrays in order,
  # objects by their members, anything else only with itself.
  defp same?(left, right) when is_number(left) and is_number(right), do: left == right

  defp same?(left, right) when is_list(left) and is_list(right),
    do:
      length(left) == length(right) and
        Enum.all?(Enum.zip(left, right), fn {l, r} -> same?(l, r) end)

  defp same?(left, right) when is_map(left) and is_map(right),
    do:
      map_size(left) == map_size(right) and
        Enum.all?(left, fn {key, value} ->
          Map.has_key?(right, key) and same?(value, Map.fetch!(right, key))
        end)

  defp same?(left, right), do: left === right

  defp export(machine_state) do
    case Position.export(machine_state) do
      {:ok, exported} -> {:ok, exported}
      {:error, reason} -> {:error, "the export refused the position: #{inspect(reason)}"}
    end
  end

  defp ids(set), do: Enum.sort(set)

  defp invocations(active_invocations) do
    active_invocations
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn {state, index} -> %{"state" => state, "index" => index} end)
  end

  # `document_name` is the `<scxml>` element's `name` attribute, nil without one.
  defp datamodel(datamodel, document_name) do
    datamodel
    |> Map.drop(@left_out_variables)
    |> drop_unset_name(document_name)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case value(value) do
        {:ok, json} ->
          {:cont, {:ok, Map.put(acc, name, json)}}

        :error ->
          {:halt,
           {:error,
            "the datamodel's #{name} holds #{inspect(value)}, which has no JSON form here"}}
      end
    end)
  end

  defp drop_unset_name(datamodel, name) when is_binary(name), do: datamodel
  defp drop_unset_name(datamodel, _name), do: Map.delete(datamodel, "_name")

  defp value(:undefined), do: {:ok, nil}

  defp value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp value(list) when is_list(list), do: collect(list, [], &value/1)

  defp value(map) when is_map(map) and not is_struct(map) do
    if Enum.all?(Map.keys(map), &is_binary/1),
      do: map |> Enum.sort() |> collect([], &member/1) |> to_object(),
      else: :error
  end

  defp value(_other), do: :error

  defp member({key, value}) do
    case value(value) do
      {:ok, json} -> {:ok, {key, json}}
      :error -> :error
    end
  end

  defp to_object({:ok, members}), do: {:ok, Map.new(members)}
  defp to_object(:error), do: :error

  defp collect([], acc, _fun), do: {:ok, Enum.reverse(acc)}

  defp collect([head | tail], acc, fun) do
    case fun.(head) do
      {:ok, json} -> collect(tail, [json | acc], fun)
      :error -> :error
    end
  end

  defp encode(nil), do: "nothing"
  defp encode(value), do: JSON.encode!(value)
end
