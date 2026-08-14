defmodule Workload do
  @moduledoc """
  Shared workload builder for `bench/context_build.exs` and
  `bench/macrostep.exs`, loaded by each with `Code.require_file/2`.

  Builds the two datamodel shapes D2's four measurements need (a `nil`-bearing
  one for the real `Evaluator.context/1` path, and a `nil`-free twin for the
  `T_new` measurement, which is defined to skip `undefine_nils/1`), a real
  `%Statifier.MachineState{}` to run them through, and the named size points
  `bench/context_build.exs` sweeps over.
  """

  alias Statifier.Machine
  alias Statifier.MachineState

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
      <state id="s1">
          <transition event="go" target="s2"/>
      </state>
      <state id="s2"/>
  </scxml>
  """

  @doc """
  Builds a datamodel of `roots` top-level keys, each a tree `depth` levels
  deep with `breadth` children per level. Every third leaf is `nil`, so
  `Statifier.Evaluator.undefine_nils/1` (and, in `T_new`'s scenario, its
  absence) always has real work to do rather than measuring a no-op walk.
  """
  @spec datamodel(roots :: non_neg_integer(), depth :: non_neg_integer(), breadth :: pos_integer()) ::
          map()
  def datamodel(roots, depth, breadth) do
    for i <- 1..roots, into: %{} do
      {"root#{i}", branch(depth, breadth, i)}
    end
  end

  defp branch(0, _breadth, seed), do: leaf(seed)

  defp branch(depth, breadth, seed) do
    for j <- 1..breadth, into: %{} do
      {"child#{j}", branch(depth - 1, breadth, seed * 31 + j)}
    end
  end

  defp leaf(seed) when rem(seed, 3) == 0, do: nil
  defp leaf(seed), do: seed

  @doc """
  The `nil`-free twin of a `datamodel/3` tree, for the `T_new` scenario:
  `Predicator.Context.new/2` over data that already has no `nil`s to
  normalize, isolating predicator's own `normalize_value/1` from
  `Statifier.Evaluator.undefine_nils/1`'s deep walk.
  """
  @spec clean(map()) :: map()
  def clean(data), do: scrub(data)

  defp scrub(nil), do: 0
  defp scrub(map) when is_map(map) and not is_struct(map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)
  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  defp scrub(other), do: other

  @doc """
  A real `%Statifier.MachineState{}` on the real path: compiled from
  `@document` through `Statifier.compile/1` and `Statifier.initialize/2`,
  then `datamodel` swapped in and `s1` made the active configuration, so
  `Statifier.Evaluator.context/1`'s `In/1` closure captures a real machine
  and a real (non-empty) configuration, exactly as it would mid-run.
  """
  @spec machine_state(datamodel :: map()) :: MachineState.t()
  def machine_state(datamodel) do
    {:ok, machine} = Statifier.compile(@document)
    {machine_state, _effects} = Statifier.initialize(machine)
    {:ok, s1_index} = Machine.index(machine, "s1")

    %{machine_state | datamodel: datamodel, configuration: MapSet.new([s1_index])}
  end

  @doc """
  The same `functions:` map `Statifier.Evaluator.context/1` builds, for the
  `T_new`/`T_fixed`/`T_bind` scenarios that call `Predicator.Context.new/2`
  or `bind/3` directly rather than through `Evaluator.context/1`, so every
  scenario resolves the same `In/1` provider cost.
  """
  @spec functions(machine_state :: MachineState.t()) :: map()
  def functions(%MachineState{machine: machine, configuration: configuration}) do
    %{
      "In" =>
        {1,
         fn [state_id], _predicator_context ->
           case Machine.index(machine, state_id) do
             {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
             :error -> {:ok, false}
           end
         end}
    }
  end

  @doc """
  Named size points, keyed for `benchee`'s `inputs:` option. Each value is
  the map the scenario functions in `bench/context_build.exs` destructure:
  `ms` (the dirty machine_state, `nil`s included), `clean` (the `nil`-free
  datamodel), `fns` (the resolved `functions:` map), `ctx` (a prebuilt
  context to `bind/3` against), `root` and `val` (the single-root write
  `T_bind` and the block-level A/B both exercise).

  `:corpus` is the realistic point (D1): derived from scanning the actual
  corpus, not guessed. `mise run` is not required to reproduce the scan -
  the two commands below were run directly against this worktree:

      grep -rho '<data [^>]*>' test/scxml_tests/ test/scion_tests/ | wc -l
      #=> 169 <data> declarations total, across both corpora

      grep -rc '<data ' test/scxml_tests/ test/scion_tests/ | sort -t: -k2 -rn | head
      #=> test/scxml_tests/mandatory/selecting_transitions/test504_test.exs:5
      #=> test/scxml_tests/mandatory/foreach/test152_test.exs:5
      #=> test/scion_tests/foreach/test1_test.exs:5
      #=> test/scxml_tests/mandatory/system_variables/test329_test.exs:4
      #=> test/scxml_tests/mandatory/selecting_transitions/test533_test.exs:4
      #=> ... (all remaining files score 4 or fewer)

  The observed maximum is 5 roots (three files tie), matching D1's own
  citation of `test504_test.exs`, `test152_test.exs`, and scion
  `foreach/test1_test.exs`. `:corpus` is set to that maximum, not the mean,
  per D1: the realistic point is the corpus's worst case. Declarations are
  overwhelmingly flat scalars, so `:corpus` uses `depth: 1, breadth: 2` - a
  couple of nested values per root, not a deep tree - which is the shape D1
  describes rather than a guess.

  `:stress` sweeps roots, depth, and breadth independently and far past
  anything the corpus contains, so the realistic point's position on the
  curve is visible rather than asserted.
  """
  @spec size_points() :: %{atom() => map()}
  def size_points do
    %{
      corpus: point(5, 1, 2),
      stress_small: point(10, 2, 3),
      stress_medium: point(50, 3, 4),
      stress_large: point(200, 3, 5)
    }
  end

  defp point(roots, depth, breadth) do
    dirty = datamodel(roots, depth, breadth)
    clean = clean(dirty)
    ms = machine_state(dirty)
    fns = functions(ms)
    ctx = Predicator.Context.new(clean, functions: fns, on_unbound: :error)

    %{
      ms: ms,
      clean: clean,
      fns: fns,
      ctx: ctx,
      root: "root1",
      val: %{"child1" => 1, "child2" => nil}
    }
  end
end
