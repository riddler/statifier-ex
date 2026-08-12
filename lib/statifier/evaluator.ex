defmodule Statifier.Evaluator do
  @moduledoc """
  The evaluation half of `docs/datamodel.md`'s evaluation contract
  (ADR-0014): one module, one `evaluate/2` over both arms of
  `Statifier.Machine.expr()`, built against a context this module's own
  `context/1` produces. Mirrors `Statifier.Compiler.Expressions` - one
  module per side of the compile/evaluate seam.

  ## The three `Context`s

  This codebase has three same-named-ish structs, and confusing any pair of
  them is the mistake this section exists to head off:

  - `Predicator.Context.t()` - the value `context/1` below builds and
    `evaluate/2` consumes: bound datamodel data, the `In/1` host function,
    and the `on_unbound: :error` policy. This is the "context" this module's
    own name refers to.
  - `Statifier.ExecutableContent.Context.t()` - the second argument every
    `Statifier.ExecutableContent.execute/2` call receives. It carries a
    built `Predicator.Context.t()` as a field (once a later phase adds that
    field); it is not one itself.
  - `Statifier.Validator.Context.t()` - unrelated: a validation-time
    accumulator, nothing to do with expression evaluation.

  ## Never scoped to a whole macrostep

  `docs/datamodel.md` was originally written to say this context is built
  once for the whole macrostep; that reading is provably wrong, because two
  of the context's own inputs change within a macrostep - `_event` is
  rewritten on every internal-event round, and `In(stateId)` reads a
  configuration that moves at every microstep. This module is instead
  called once per evaluation site (once per executable-content block today;
  once per selection round once `cond` is wired), which keeps the actual
  commitment - never once per expression - while staying fresh where a
  snapshot spanning the whole macrostep could not be.

  ## Why the built context is not a `MachineState` field

  Caching the context on `Statifier.MachineState` reads like the obvious
  optimization, and it is ruled out on two grounds of different weight:

  - **It would not be a resumable position, today.** `docs/observability.md`
    constraint 1 (ADR-0012) commits to any `%MachineState{}` value being a
    complete, inspectable, resumable position. `context/1` puts a closure
    in `functions` (`In/1`, below), and a local fun is a reference to a
    specific module and code version: a struct carrying one does not
    survive a node boundary, a code reload, or being written to disk and
    read back later, and it cannot be meaningfully diffed. A step debugger
    being `microstep/1` in a REPL is the property that field would cost.
    This ground is contingent on the closure: taking the px-8ii seam below
    (a `FunctionProvider` bound by name instead of a captured fun) would
    dissolve it.
  - **It would be stale by construction.** That closure captures the
    configuration, which moves at every microstep, so a stored context
    would keep answering `In/1` against a configuration the machine has
    already left. Rebuilding per evaluation site is not a missed
    optimization here; it is the correctness property, and the
    position-snapshot note on `context/1` says so at the call site. This
    ground is structural and survives the px-8ii seam entirely: whatever
    builds `functions`, a stored context still answers against a
    configuration the machine has moved past.

  The plain map on `MachineState.datamodel` stays the resumable truth, and
  this module builds a context over it on demand. The cost that buys is
  real - `Predicator.Context.new/2` deep-normalizes the whole datamodel
  every time, where `Predicator.Context.bind/3` is O(1) in the data's size
  and carries `functions` and `on_unbound` over unchanged. Nothing
  evaluates in a hot path yet, so there is nothing to measure; st-sdh
  tracks that question. The upstream seam that would let a context be
  both cheap to refresh and safe to store landed in predicator 5.0.0
  (px-8ii): `Predicator.FunctionProvider` plus `Context.new/2`'s `host:`
  option and `Context.put_host/2`.

  ## The membrane

  `evaluate/2` returns `{:ok, term()} | {:error, Statifier.Evaluator.Error.t()}`
  and never raises (`docs/architecture.md` principle 3). Only the
  interpreter turns an `{:error, _}` into an `error.execution` platform
  event; this module is a leaf and never rescues-to-default.
  """

  alias Statifier.Evaluator.Error
  alias Statifier.Machine
  alias Statifier.MachineState

  @doc """
  Builds the `Predicator.Context.t()` `evaluate/2` evaluates against, bound
  to `machine_state`'s datamodel plus the `In(stateId)` host function.

  The returned context is a position snapshot: `In/1`'s closure captures
  `machine_state.machine` and `machine_state.configuration` as they stand at
  the moment of this call, so a context built before a configuration change
  keeps answering `In/1` against the old configuration - callers rebuild
  per evaluation site rather than caching across one, which is the "never
  scoped to a whole macrostep" property above made concrete.
  """
  @spec context(machine_state :: MachineState.t()) :: Predicator.Context.t()
  def context(%MachineState{} = machine_state) do
    Predicator.Context.new(machine_state.datamodel,
      functions: %{"In" => {1, in_function(machine_state)}},
      on_unbound: :error
    )
  end

  @doc """
  Evaluates `expr` against `context`.

  `{:static, value}` returns `value` untouched - a static value came from
  the document as a literal with no expression to evaluate
  (`Statifier.Compiler.Expressions.static/1`), so it never passes through
  predicator's own value normalization.

  `{:compiled, compiled, source}` hands `compiled` to `Predicator.evaluate/3`
  whole, never with a `:positions` option: a `%Predicator.Compiled{}` already
  carries its own span table, and passing both raises `ArgumentError`
  (ADR-0014 item 2). `context`'s own `functions:`/`on_unbound:` are honored
  as built - they are not re-passed as per-call options here, since a
  prebuilt `%Predicator.Context{}` is used as given rather than routed
  through `Predicator.Context.new/2` again.
  """
  @spec evaluate(context :: Predicator.Context.t(), expr :: Machine.expr()) ::
          {:ok, term()} | {:error, Error.t()}
  def evaluate(%Predicator.Context{}, {:static, value}), do: {:ok, value}

  def evaluate(
        %Predicator.Context{} = context,
        {:compiled, %Predicator.Compiled{} = compiled, source}
      ) do
    case Predicator.evaluate(compiled, context) do
      {:ok, value} -> {:ok, value}
      {:error, error} -> {:error, Error.new(source, error)}
    end
  end

  # The `In(stateId)` host function (spec 5.10): true when `stateId` names a
  # state currently in `machine_state`'s configuration. `Machine.index/2`
  # returns `:error` for an id the document never declared - that is not an
  # evaluation failure, so it becomes `{:ok, false}` rather than an
  # `{:error, _}` here; a document asking `In()` about a state it does not
  # have is answered "not active", the same answer it would get for any
  # other inactive state.
  @spec in_function(machine_state :: MachineState.t()) ::
          (list(), Predicator.Context.t() -> {:ok, boolean()})
  defp in_function(%MachineState{machine: machine, configuration: configuration}) do
    fn [state_id], _predicator_context ->
      case Machine.index(machine, state_id) do
        {:ok, index} -> {:ok, MapSet.member?(configuration, index)}
        :error -> {:ok, false}
      end
    end
  end
end
