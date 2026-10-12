defmodule Statifier.Evaluator.Functions do
  @moduledoc """
  The `Predicator.FunctionProvider` carrying `In/1` (spec 5.9.1), replacing
  `Statifier.Evaluator`'s former private closure-building helper.

  A provider entry is named by `{module, atom}` rather than by a captured
  `function()` value (`deps/predicator/lib/predicator/functions/provider.ex`),
  so `in_state/2` reads the current configuration from its
  `%Predicator.Context{}` argument's `host` slot instead of closing over it.
  `Statifier.Evaluator.context/1` sets `host` to `{machine, configuration}`
  and refreshes it per site with `Predicator.Context.put_host/2` - see that
  module's moduledoc for why this dissolves the "not a resumable position"
  ground the closure used to force.

  It also resolves a host's `:function_providers` list
  (`from_providers/1`) into the full dispatch map a session stamps onto
  `Statifier.MachineState`'s `functions` field, which `Statifier.Evaluator.context/1` then
  uses in place of the constant's own map (ADR-0078).
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
  #
  # `Context.resolve_functions/1`'s provider validation is memoized in
  # `:persistent_term` as of predicator 8.0, so a `Context.new/2` call no
  # longer re-pays `Code.ensure_loaded?/1` plus `function_exported?/3` per
  # entry. It still pays, on every call, one `Code.ensure_loaded?/1` and one
  # `module_info(:md5)` per provider module to compute the cache stamp, plus
  # a `:persistent_term.get/2`, a map lookup keyed on the provider list, and
  # a stamp-list comparison - and then allocates the struct. A module
  # attribute is a compile-time literal read and costs none of that -
  # predicator's own docs (`deps/predicator/lib/predicator/context.ex:150-155`,
  # the `## Performance` section) say the memo "removes re-validation, not
  # the allocation and struct construction `new/2` does on every call" and
  # still name per-evaluation `new/2` as the anti-pattern. So the hoist
  # below stays.
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

  @typedoc """
  A resolved dispatch map: function name to `{arity, {module, atom}}`, the
  shape `Predicator.Context` keeps in its `functions` field. The map
  `from_providers/1` returns holds every name `base_context/0` holds plus
  each host provider's names.
  """
  @type registered :: %{String.t() => {Predicator.Evaluator.function_arity(), {module(), atom()}}}

  @doc """
  The names every chart can call without registering anything: `In` and
  the builtin providers' names, sorted. `Statifier.compile/2` adds the
  names of its `:function_providers` to this set before it checks the
  calls a chart makes.
  """
  @spec base_names() :: [String.t()]
  def base_names, do: @base_context.functions |> Map.keys() |> Enum.sort()

  @doc """
  Resolves a host's `:function_providers` list into the dispatch map an
  evaluation context uses: `base_context/0`'s map with every provider's
  functions merged in.

  `nil` and `[]` both answer `{:ok, nil}`, which means "no host function":
  `Statifier.Evaluator.context/1` then uses `base_context/0` unchanged.

  Refuses, without raising, with:

    - `{:error, {:not_a_list, value}}` - the option is not a list.
    - `{:error, {:invalid_provider, module, message}}` - a list entry is
      not an atom, or names a module that does not load, export
      `functions/0`, or export each named function at arity 2.
      `Predicator.Context.resolve_functions/1` does the check, and
      `message` is its text.
    - `{:error, {:shadowed_names, names}}` - a provider names a function
      the base set already has (`base_names/0`), so `In` and the
      builtins always mean the same thing. `names` is sorted.
  """
  @spec from_providers(providers :: [module()] | nil) ::
          {:ok, registered() | nil}
          | {:error,
             {:not_a_list, term()}
             | {:invalid_provider, term(), String.t()}
             | {:shadowed_names, [String.t()]}}
  def from_providers(nil), do: {:ok, nil}
  def from_providers([]), do: {:ok, nil}

  def from_providers(providers) when is_list(providers) do
    with {:ok, host} <- resolve(providers) do
      case host |> Map.keys() |> Enum.filter(&Map.has_key?(@base_context.functions, &1)) do
        [] -> {:ok, Map.merge(@base_context.functions, host)}
        shadowed -> {:error, {:shadowed_names, Enum.sort(shadowed)}}
      end
    end
  end

  def from_providers(other), do: {:error, {:not_a_list, other}}

  @doc """
  `from_providers/1`, raising `ArgumentError` on a refusal. The form
  `Statifier.MachineState.new/2` and `put_function_providers/2` use: a bad
  provider list is host misuse, refused the way a bad `:datamodel` is.
  """
  @spec from_providers!(providers :: [module()] | nil) :: registered() | nil
  def from_providers!(providers) do
    case from_providers(providers) do
      {:ok, registered} -> registered
      {:error, reason} -> raise ArgumentError, "invalid :function_providers: #{inspect(reason)}"
    end
  end

  @doc """
  The names a `:function_providers` list registers, sorted, after the same
  checks `from_providers/1` makes. `nil` and `[]` answer `{:ok, []}`.
  """
  @spec provider_names(providers :: [module()] | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  def provider_names(providers) do
    case from_providers(providers) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, registered} ->
        {:ok,
         registered |> Map.drop(Map.keys(@base_context.functions)) |> Map.keys() |> Enum.sort()}

      {:error, _reason} = error ->
        error
    end
  end

  # Each entry is checked on its own first, through predicator's own
  # validation (`Predicator.Context.resolve_functions/1`, which memoizes
  # it), so a refusal names the module at fault; the whole list is then
  # resolved once, with `builtins: false`, so only the host's own entries
  # come back, a later provider shadowing an earlier one as predicator
  # orders them.
  @spec resolve(providers :: list()) ::
          {:ok, registered()} | {:error, {:invalid_provider, term(), String.t()}}
  defp resolve(providers) do
    case Enum.find_value(providers, &invalid_provider/1) do
      nil -> {:ok, Predicator.Context.resolve_functions(builtins: false, providers: providers)}
      refusal -> {:error, refusal}
    end
  end

  @spec invalid_provider(provider :: term()) :: {:invalid_provider, term(), String.t()} | nil
  defp invalid_provider(provider) when is_atom(provider) do
    _resolved = Predicator.Context.resolve_functions(builtins: false, providers: [provider])
    nil
  rescue
    error in ArgumentError -> {:invalid_provider, provider, Exception.message(error)}
  end

  defp invalid_provider(provider), do: {:invalid_provider, provider, "not a module name"}

  # The `In(stateId)` host function: true when `stateId` names a state
  # currently in the context's host configuration. Spec 5.9.1 is the clause
  # that requires it ("all data models MUST support the 'In()' predicate,
  # which takes a state ID as its argument and returns true if the state
  # machine is in that state"); B.1.2 states the same rule as an iff, which
  # is what makes the `:error` arm below an answer rather than a failure.
  # Not 5.10 - that clause is System Variables, and this comment cited it
  # for the whole life of the closure this provider replaced.
  # `Machine.index/2`
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
