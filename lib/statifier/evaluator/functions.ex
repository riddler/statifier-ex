defmodule Statifier.Evaluator.Functions do
  @moduledoc """
  The `Predicator.FunctionProvider` carrying `In/1` (spec 5.10), replacing
  `Statifier.Evaluator`'s former private closure-building helper.

  A provider entry is named by `{module, atom}` rather than by a captured
  `function()` value (`deps/predicator/lib/predicator/functions/provider.ex`),
  so `in_state/2` reads the current configuration from its
  `%Predicator.Context{}` argument's `host` slot instead of closing over it.
  `Statifier.Evaluator.context/1` sets `host` to `{machine, configuration}`
  and refreshes it per site with `Predicator.Context.put_host/2` - see that
  module's moduledoc for why this dissolves the "not a resumable position"
  ground the closure used to force.
  """

  @behaviour Predicator.FunctionProvider

  alias Statifier.Machine

  @functions %{"In" => {1, :in_state}}

  @doc """
  This provider's one entry: `In/1`, dispatched to `in_state/2`.
  """
  @impl Predicator.FunctionProvider
  @spec functions() :: %{String.t() => {non_neg_integer(), atom()}}
  def functions, do: @functions

  # The fixed half of every context `Statifier.Evaluator.context/1` builds:
  # `In/1` resolved once, at compile time, into an `{module, atom}` pair. The
  # entry is written by hand through the `:functions` option rather than as
  # `providers: [__MODULE__]`, because `Predicator.Context.resolve_functions/1`
  # would call `Code.ensure_loaded?/1` on this module while it is still being
  # compiled - a provider validated by name cannot validate itself mid-build.
  # `:functions` merges its entry unvalidated (`context.ex:158-167`), and
  # predicator's dispatch treats a `{module, atom}` pair identically whichever
  # option delivered it (`deps/predicator/lib/predicator/evaluator.ex:
  # 1319-1321`), so the hand-shaped tuple below is not a shortcut around
  # validation, only around validating a module against itself. `functions/0`
  # above is still the behaviour-required declaration and a test asserts the
  # two agree, so this entry cannot silently drift from it. Escaping into a
  # module attribute is what proves the resolved map holds no `function()`
  # value - a closure could not survive this compile step.
  @base_context Predicator.Context.new(%{},
                  builtins: true,
                  functions: %{"In" => {1, {__MODULE__, :in_state}}},
                  on_unbound: :error
                )

  @doc """
  The fixed half of every context this library builds: an empty `data`, a
  `nil` `host`, `on_unbound: :error`, and `functions` resolved once at
  compile time to `%{"In" => {1, {#{inspect(__MODULE__)}, :in_state}}}` plus
  the four builtin providers. `Statifier.Evaluator.context/1` starts from
  this constant on every call, then layers in `host` via
  `Predicator.Context.put_host/2` and the datamodel via
  `Statifier.Evaluator.bind/3` - so `Predicator.Context.new/2` and
  `Predicator.Context.resolve_functions/1` never run on that hot path.

  Two calls return the same term; nothing about this value varies at
  runtime.
  """
  @spec base_context() :: Predicator.Context.t()
  def base_context, do: @base_context

  # The `In(stateId)` host function (spec 5.10): true when `stateId` names a
  # state currently in the context's host configuration. `Machine.index/2`
  # returns `:error` for an id the document never declared - that is not an
  # evaluation failure, so it becomes `{:ok, false}` rather than an
  # `{:error, _}` here; a document asking `In()` about a state it does not
  # have is answered "not active", the same answer it would get for any
  # other inactive state.
  @doc """
  `In(stateId)`: true when `stateId` names a state in `context.host`'s
  configuration, false for an inactive or undeclared state id.

  `context.host` must be `{machine, configuration}`, the shape
  `Statifier.Evaluator.context/1` sets via `Predicator.Context.put_host/2`.
  """
  @spec in_state(args :: [Predicator.Types.value()], context :: Predicator.Context.t()) ::
          {:ok, boolean()}
  def in_state([state_id], %Predicator.Context{host: {machine, configuration}}) do
    case Machine.index(machine, state_id) do
      {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
      :error -> {:ok, false}
    end
  end
end
