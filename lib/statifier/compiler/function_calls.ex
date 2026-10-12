defmodule Statifier.Compiler.FunctionCalls do
  @moduledoc """
  The compile-time check that every function a chart's expressions call is
  one the chart can be evaluated with: `In/1`, a predicator builtin, or a
  function the host registers through `Statifier.compile/2`'s
  `:function_providers` option.

  It reads the compiled `Statifier.Machine` rather than the document: every
  `cond`, `expr`, `<script>` and other predicator source has already been
  compiled to a `%Predicator.Compiled{}` by then, and a call is one
  top-level `["call", name, arity]` instruction in it. A name outside the known set
  becomes one `Statifier.Compiler.Error` with reason
  `{:unknown_function, name, source}`, reported at the location of the
  element whose expression makes the call.

  Only the name is checked, not the arity: a call with the wrong number of
  arguments to a known function still compiles and fails at evaluation, as
  it always has.
  """

  alias Statifier.Compiler.Error
  alias Statifier.Machine
  alias Statifier.Parser.Location

  @doc """
  One error per distinct `{name, location}` pair whose `name` is not in
  `known`, ordered by location. `[]` when every call names a known
  function, which is always true of a chart that calls none.
  """
  @spec check(machine :: Machine.t(), known :: MapSet.t(String.t())) :: [Error.t()]
  def check(%Machine{location: location} = machine, %MapSet{} = known) do
    machine
    |> Map.take([:states, :transitions, :contents, :data_elements, :global_scripts])
    |> walk(location, [])
    |> Enum.reject(fn {name, _source, _location} -> MapSet.member?(known, name) end)
    |> Enum.uniq_by(fn {name, _source, location} -> {name, location} end)
    |> Enum.sort_by(fn {name, _source, location} -> {location.start_offset, name} end)
    |> Enum.map(fn {name, source, location} -> Error.unknown_function(name, source, location) end)
  end

  # Collects `{name, source, location}` for every call instruction under
  # `term`, carrying the innermost enclosing struct's `location` down so
  # each call is reported at the element that holds it.
  @spec walk(term :: term(), location :: Location.t(), acc :: list()) :: list()
  defp walk({tag, %Predicator.Compiled{instructions: instructions}, source}, location, acc)
       when tag in [:compiled, :program] and is_binary(source) do
    instructions
    |> calls([])
    |> Enum.reduce(acc, fn name, acc -> [{name, source, location} | acc] end)
  end

  defp walk(%Location{}, _location, acc), do: acc

  defp walk(%{__struct__: _module} = struct, location, acc) do
    location =
      case Map.get(struct, :location) do
        %Location{} = own -> own
        _none -> location
      end

    struct |> Map.from_struct() |> walk(location, acc)
  end

  defp walk(map, location, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {_key, value}, acc -> walk(value, location, acc) end)

  defp walk(list, location, acc) when is_list(list),
    do: Enum.reduce(list, acc, &walk(&1, location, &2))

  defp walk(tuple, location, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk(location, acc)

  defp walk(_other, _location, acc), do: acc

  # A call is one top-level `["call", name, arity]` instruction. The
  # instruction list is flat - no opcode carries a nested instruction list
  # (`Predicator.Instructions.opcodes/0`) - so only the top level is read: an
  # operand is data, and a literal list that happens to look like a call
  # (`["lit", ["call", "x", 1]]`) is not one.
  @spec calls(instructions :: list(), acc :: [String.t()]) :: [String.t()]
  defp calls(instructions, acc) do
    Enum.reduce(instructions, acc, fn
      ["call", name, arity], acc when is_binary(name) and is_integer(arity) -> [name | acc]
      _instruction, acc -> acc
    end)
  end
end
