# The three-term decomposition (D2) plus a block-level rebuild-vs-bind/3 A/B.
#
# Run with:
#
#     mix run bench/context_build.exs
#
# See bench/README.md for why this directory is outside every gate stage,
# and docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md D2 for
# the four scenarios below and how their subtraction derives the three
# separable cost terms.

Code.require_file("support/workload.exs", __DIR__)

alias Predicator.Context
alias Statifier.Evaluator

# --- Run 1: the three-term decomposition ------------------------------
#
# T_full  = Evaluator.context/1 on a datamodel with nils - the real path.
# T_new   = Context.new/2 on the nil-free twin - skips undefine_nils/1.
# T_fixed = Context.new/2 over an empty datamodel - isolates
#           resolve_functions/1, the fixed per-call cost.
# T_bind  = Context.bind/3, one root - the alternative.

Benchee.run(
  %{
    "T_full  Evaluator.context/1" => fn %{ms: ms} -> Evaluator.context(ms) end,
    "T_new   Context.new/2, no nils" => fn %{clean: d, fns: f} ->
      Context.new(d, functions: f, on_unbound: :error)
    end,
    "T_fixed Context.new/2, empty data" => fn %{fns: f} ->
      Context.new(%{}, functions: f, on_unbound: :error)
    end,
    "T_bind  Context.bind/3 one root" => fn %{ctx: ctx, root: r, val: v} ->
      Context.bind(ctx, r, v)
    end
  },
  inputs: Workload.size_points(),
  time: 5,
  memory_time: 2,
  warmup: 2,
  formatters: [Benchee.Formatters.Console]
)

# --- Run 2: block-level A/B -------------------------------------------
#
# Both arms are script-local - nothing in lib/ changes. This replicates
# what <assign> and <foreach> do today (rebuild the whole context after
# every write) against what a bind/3-threaded block would do instead
# (build the context once, bind each write into it).

defmodule BlockAB do
  @moduledoc false

  # Today's shape: every write rebuilds the whole context from the updated
  # machine_state.datamodel, exactly as Statifier.Machine.Content.Assign
  # does (lib/statifier/machine/content/assign.ex:76-91).
  def rebuild_per_write(machine_state, root, val, n) do
    Enum.reduce(1..n, machine_state, fn i, ms ->
      new_ms = %{ms | datamodel: Map.put(ms.datamodel, root, %{"n" => i, "val" => val})}
      _ctx = Evaluator.context(new_ms)
      new_ms
    end)
  end

  # The candidate shape: one context built once, bind/3 threaded through n
  # single-root writes.
  def bind_threaded(ctx, root, val, n) do
    Enum.reduce(1..n, ctx, fn i, acc ->
      Context.bind(acc, root, %{"n" => i, "val" => val})
    end)
  end
end

for {label, %{ms: ms, ctx: ctx, root: root, val: val}} <- Workload.size_points() do
  IO.puts("\n=== block-level A/B at size point #{inspect(label)} ===")

  Benchee.run(
    %{
      "rebuild-per-write (n=1)" => fn -> BlockAB.rebuild_per_write(ms, root, val, 1) end,
      "bind/3-threaded    (n=1)" => fn -> BlockAB.bind_threaded(ctx, root, val, 1) end,
      "rebuild-per-write (n=5)" => fn -> BlockAB.rebuild_per_write(ms, root, val, 5) end,
      "bind/3-threaded    (n=5)" => fn -> BlockAB.bind_threaded(ctx, root, val, 5) end,
      "rebuild-per-write (n=25)" => fn -> BlockAB.rebuild_per_write(ms, root, val, 25) end,
      "bind/3-threaded    (n=25)" => fn -> BlockAB.bind_threaded(ctx, root, val, 25) end,
      "rebuild-per-write (n=100)" => fn -> BlockAB.rebuild_per_write(ms, root, val, 100) end,
      "bind/3-threaded    (n=100)" => fn -> BlockAB.bind_threaded(ctx, root, val, 100) end
    },
    time: 3,
    memory_time: 1,
    warmup: 1,
    formatters: [Benchee.Formatters.Console]
  )
end
