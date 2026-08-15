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
    `evaluate/2` consumes: bound datamodel data, `In/1` resolved as a
    `Predicator.FunctionProvider` entry (`Statifier.Evaluator.Functions`),
    the `host` value `In/1` reads (`{machine, configuration}`), and the
    `on_unbound: :error` policy. "The `In/1` host function" described this
    struct's `functions` entry accurately by accident before ADR-0030; it is
    accurate on purpose now that `In/1` reads `host` rather than closing
    over anything. This is the "context" this module's own name refers to.
  - `Statifier.ExecutableContent.Context.t()` - the second argument every
    `Statifier.ExecutableContent.execute/2` call receives. It carries a
    built `Predicator.Context.t()` as a field; it is not one itself.
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

  ## What a context costs, and why it is still not a `MachineState` field

  Caching the context on `Statifier.MachineState` reads like the obvious
  optimization. `In/1` used to be a closure over `machine_state.machine` and
  `machine_state.configuration`, which made that optimization impossible
  outright: a struct field cannot outlive the closure it carries in any
  sense `docs/observability.md` constraint 1 (ADR-0012) would accept. `In/1`
  is a `Predicator.FunctionProvider` now
  (`Statifier.Evaluator.Functions`, below), so that particular impossibility
  is gone - and the decision not to store a context is still the decision,
  on three grounds recorded in full in ADR-0030
  (`docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md`):

  - **Non-resumability dissolved.** A closure in `functions` could not
    survive a node boundary, a code reload, or a round-trip through storage,
    so a `%MachineState{}` carrying one could never be the complete,
    inspectable, resumable position constraint 1 requires. Every resolved
    `functions` entry is now a `{module, atom}` pair - the only shape that
    can escape into a compile-time module attribute at all, since a
    `function()` value fails that escape at compile time - and
    `test/statifier/evaluator/functions_test.exs` and
    `test/statifier/evaluator_test.exs` assert mechanically that no built
    context's `functions` map ever holds one. This ground no longer blocks
    anything.
  - **Staleness survives, narrower.** A stored context's `host` can now be
    refreshed in O(1) with `Predicator.Context.put_host/2` instead of a
    whole rebuild - but `data` still needs a `bind/3` at every site the
    datamodel changes, and nothing added that refresh where none existed.
    Storage would turn "rebuild per evaluation site" from the correctness
    property it is today into an exhaustiveness obligation over every
    datamodel write site, some of which bind into no context today. A missed
    site answers stale silently rather than raising - a worse failure shape
    than the closure's outright non-resumability, and still enough to block
    storage on its own.
  - **A stored context would duplicate state `%MachineState{}` already
    holds** - its `data` against `machine_state.datamodel`, its `host`
    against `machine`/`configuration` - two representations of the same fact
    that must agree and can silently disagree, a different constraint-1
    failure mode from a closure's, related to the sharp edge
    `lib/statifier/machine_state.ex` already documents about `internal_queue`
    equality.

  The plain map on `MachineState.datamodel` stays the resumable truth, and
  this module builds a context over it on demand. The cost that buys is
  real - `Predicator.Context.new/2` deep-normalizes the whole datamodel and
  resolves the whole `functions` map every time, where
  `Predicator.Context.bind/3` is O(1) in the data's size and
  `Predicator.Context.put_host/2` is O(1) in `host`'s size. `context/1`
  never calls `Predicator.Context.new/2` on this hot path: it starts from
  `Statifier.Evaluator.Functions.base_context/0`, a compile-time constant
  holding the already-resolved `functions` map and `on_unbound: :error`,
  refreshes `host` with `put_host/2`, and binds each datamodel root with
  `bind/3`. Measured (ADR-0030,
  `bench/results/260814-st-l0t-provider-host-seam.md`): at a realistic
  corpus-shaped datamodel, this hoist drops one context build from 2.30 us /
  10.92 KB to 1.13 us / 4.77 KB, and the corpus-representative `realistic`
  macrostep from 17.39 us / 74.19 KB to 13.58 us / 43.18 KB. ADR-0028
  answers the within-block write case the same way at a finer grain:
  `<assign>`, `<foreach>`, and `<script>` bind each write into the block's
  already-threaded context instead of calling `context/1` again per write,
  without storing anything on `MachineState` - a block still never outlives
  the microstep it runs inside, so neither ground above is contradicted.
  Widening the threaded interval *across* blocks or microsteps - which would
  need a stored context - remains future work, still gated on staleness and
  duplication exactly as ADR-0030 leaves it.

  predicator 8.0 offers a `normalize: false` option on `Context.new/2` that
  skips the deep `normalize_value/1` walk on a caller's vouch that `data` is
  string-keyed at every level. It buys this path nothing, because this path
  does not call `new/2`: the constant `context/1` starts from holds an empty
  `data`, and each root arrives through `bind/3`, which normalizes its value
  unconditionally with no opt-out. Taking the vouch would mean rebuilding the
  whole context per site with `new/2` to get one walk instead of two -
  trading a size-scaling term for `new/2`'s per-call stamp-and-allocate work,
  and giving up the compile-time constant. Measured
  (`bench/results/260815-st-59d-predicator-8-0.md`): at `:corpus`,
  `Context.new(data, normalize: false)` (`T_new_nf`) costs 0.3788 us / 0.867
  KB, essentially flat across all four size points because it skips the
  size-scaling walk entirely - but the shipped path (`T_full`, this module's
  `context/1`) already costs 1.0755 us / 4.773 KB at `:corpus` without ever
  calling `new/2`, so `T_new_nf`'s flatness is not a number this path could
  collect.

  ## The membrane

  `evaluate/2` returns `{:ok, term()} | {:error, Statifier.Evaluator.Error.t()}`
  and never raises (`docs/architecture.md` principle 3). Only the
  interpreter turns an `{:error, _}` into an `error.execution` platform
  event; this module is a leaf and never rescues-to-default.

  ## `evaluate/2` reads, `execute/2` writes

  `evaluate/2` is the read side: a `Machine.expr()` over a context, no
  datamodel write possible. `execute/2` is the write side: a
  `Machine.program()` (ADR-0026) run against the same kind of context,
  producing a mutated `MachineState.t()`. Both build their context the same
  way, through `context/1` - a program is not a second evaluation
  mechanism, only a second thing this module's one context shape can be
  run against.
  """

  alias Statifier.Evaluator.Error
  alias Statifier.Evaluator.Functions
  alias Statifier.Machine
  alias Statifier.MachineState

  @doc """
  Builds the `Predicator.Context.t()` `evaluate/2` evaluates against, bound
  to `machine_state`'s datamodel plus `In(stateId)`
  (`Statifier.Evaluator.Functions`).

  Starts from `Statifier.Evaluator.Functions.base_context/0` - the compile-time
  constant carrying the resolved `functions` map and `on_unbound: :error` -
  and layers in this call's two moving parts: `host` via
  `Predicator.Context.put_host/2`, set to `machine_state.machine` and
  `machine_state.configuration` as they stand right now, and `data` via a
  `bind/3` fold over each of `machine_state.datamodel`'s top-level roots. No
  whole-map `Predicator.Context` construction, and therefore no function
  resolution pass, happens here - see `Statifier.Evaluator.Functions`'s
  moduledoc for why that resolution is a compile-time constant instead.

  The returned context is a position snapshot: `host` is fixed at the
  moment of this call, so a context built before a configuration change
  keeps answering `In/1` against the old configuration - callers rebuild
  per evaluation site rather than caching across one, which is the "never
  scoped to a whole macrostep" property above made concrete.

  Every top-level key in `machine_state.datamodel` must be a binary:
  `Predicator.Context.bind/3` (unlike `new/2`) guards `is_binary(name)` and
  raises a `FunctionClauseError` rather than stringifying an atom key. Every
  writer of `machine_state.datamodel` produces binary keys today (the seed
  in `MachineState.new/2`, `MachineState.put_event/2`'s `"_event"`,
  `<data id>` binding, a program's own writes, `<assign>`'s declared
  `location` root, and `<foreach>`'s declared `item`/`index`), so this is a
  louder failure for a case no writer can produce today, not a behavior
  change for any document this library can build a `MachineState` from.
  """
  @spec context(machine_state :: MachineState.t()) :: Predicator.Context.t()
  def context(%MachineState{machine: machine, configuration: configuration} = machine_state) do
    Functions.base_context()
    |> Predicator.Context.put_host({machine, configuration})
    |> bind_roots(machine_state.datamodel)
  end

  # Folds `bind/3` over `datamodel`'s top-level roots. `bind/3` applies
  # `undefine_nils/1` per root and hands off to `Predicator.Context.bind/3`,
  # which applies `normalize_value/1` - so this produces exactly the `data`
  # a whole-map construction would have produced for the same map, since
  # that whole-map path is `normalize_value(whole_map)` and `normalize_value`
  # on a map recurses per entry. `context/1`'s equivalence test
  # (`test/statifier/evaluator_test.exs`) is the mechanical check that this
  # claim holds.
  @spec bind_roots(context :: Predicator.Context.t(), datamodel :: map()) ::
          Predicator.Context.t()
  defp bind_roots(context, datamodel) do
    Enum.reduce(datamodel, context, fn {root, value}, acc -> bind(acc, root, value) end)
  end

  # `Predicator.Context.new/2` deep-normalized `nil` to `:undefined` through
  # predicator 5.x (`deps/predicator/lib/predicator/context.ex` on that
  # version: `normalize_value(nil), do: Undefined.value()`). predicator 6.0
  # (px-o9v) made `nil` the null literal's own value, distinct from
  # `:undefined`, and dropped that clause - `nil` now survives `Context.new/2`
  # unchanged. `machine_state.datamodel` still spells "declared but no value
  # yet" as a raw `nil` (`SystemVariables.initial/2`'s `_event`, a seeded
  # `<data>` with no child, `<foreach>`'s declared `item`/`index` - see
  # `Statifier.Evaluator.SystemVariables`'s and `Statifier.Machine.Content.
  # Foreach.declare/2`'s moduledocs), a convention this function's callers
  # never revisited because it used to be predicator's job to translate that
  # `nil` into the spec's "undefined" answer. This mirrors predicator 5.x's
  # own normalization, recursively, so every existing "seeded-but-unbound
  # reads as undefined" test (W3C test319/335/337/339, this module's own
  # `_event`/`_event.data` tests) keeps its predicator-5.x answer under
  # predicator 8.x. It does not (and, per the corpus, does not need to)
  # distinguish a genuine assigned `null` from an unbound datamodel entry -
  # no corpus document assigns one, and `docs/research/260812-st-unt-*` and
  # `docs/research/260812-st-af3.3-*` already record that gap as latent
  # rather than something this bump is asked to close.
  @spec undefine_nils(value :: term()) :: term()
  defp undefine_nils(nil), do: :undefined
  defp undefine_nils(list) when is_list(list), do: Enum.map(list, &undefine_nils/1)

  defp undefine_nils(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, undefine_nils(value)} end)
  end

  defp undefine_nils(other), do: other

  @doc """
  Binds `root`'s value into `context`, replacing whatever it held there and
  applying the same `nil` -> `:undefined` normalization `context/1` applies
  through `undefine_nils/1` - a bound `nil` has to read the same as a
  rebuilt one, or W3C test319/335/337/339 answer differently depending on
  which path built the context. `Predicator.Context.bind/3` does the write:
  a single `Map.put/3` plus normalizing `value` itself, O(size of `value`)
  rather than O(size of the whole datamodel), carrying `context`'s
  `functions`, `on_unbound`, and `host` over unchanged.

  This is safe **within** the executable-content block that already holds
  `context` and unsafe **across** one: `functions` and `host` (and with it
  `In/1`'s configuration) carry over verbatim, which is correct only while
  the block still runs inside the microstep it started in. A block
  never outlives that microstep, so binding into its own context is always
  safe there - but reusing a bound context after the block returns would
  answer `In/1` against a configuration the machine has already left, the
  same staleness `context/1`'s own moduledoc note warns about.

  `Predicator.Context.assign/3` is deliberately not used here: it writes at
  a path but skips `normalize_value/1` (`deps/predicator/lib/predicator/
  context.ex:313-318`), so a bound `nil` would stay `nil` instead of
  reading `:undefined`.
  """
  @spec bind(context :: Predicator.Context.t(), root :: String.t(), value :: term()) ::
          Predicator.Context.t()
  def bind(%Predicator.Context{} = context, root, value) when is_binary(root) do
    Predicator.Context.bind(context, root, undefine_nils(value))
  end

  @doc """
  Refreshes `context`'s `host` to `machine_state`'s current
  `{machine, configuration}`, leaving `data`, `functions`, and `on_unbound`
  untouched. A thin wrapper over `Predicator.Context.put_host/2`, named and
  documented the same way `bind/3` is a named wrapper over
  `Predicator.Context.bind/3` rather than a call site reaching into
  predicator directly.

  No `lib/` caller holds a `Predicator.Context.t()` across a configuration
  change today - every caller of `context/1` builds fresh, per evaluation
  site, and `bind/3`'s own `@doc` already says why holding one across a
  block boundary is unsafe. This is the seam such a caller would reach for
  if one existed: refresh `host` in place instead of rebuilding.

  **This does not address `data` staleness.** `host` is the only thing this
  function moves; `context`'s `data` still answers against whatever
  datamodel was bound in at construction (or the last `bind/3`), and a
  configuration change carries no promise that the datamodel agrees with
  it. A caller that needs both current would still need to re-bind every
  changed root itself - the same "ground 2" gap `context/1`'s own moduledoc
  section describes, restated here at the one other place a caller might
  reach for a shortcut around it.
  """
  @spec put_configuration(context :: Predicator.Context.t(), machine_state :: MachineState.t()) ::
          Predicator.Context.t()
  def put_configuration(%Predicator.Context{} = context, %MachineState{} = machine_state) do
    Predicator.Context.put_host(context, {machine_state.machine, machine_state.configuration})
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

  @doc """
  Runs `program` (a `Machine.program()`, ADR-0026) against `machine_state`'s
  datamodel and merges its writes back. A thin wrapper over `run_program/2`
  that drops the post-run `Predicator.Context.t()` it also returns - this
  function's own two/three-element shape is kept exactly as it was before
  `run_program/2` existed, since `Statifier.Interpreter`'s
  `run_global_script/3` (Appendix D's global-script step) is a caller with
  no block to thread a context into and no reason to change. See
  `run_program/2` for the full merge/diff contract both functions share.
  """
  @spec execute(machine_state :: MachineState.t(), program :: Machine.program()) ::
          {:ok, MachineState.t()}
          | {:error, MachineState.t(), Error.t() | {:system_variable, String.t()}}
  def execute(%MachineState{} = machine_state, program) do
    case run_program(machine_state, program) do
      {:ok, new_machine_state, _post_context} -> {:ok, new_machine_state}
      {:error, new_machine_state, error, _post_context} -> {:error, new_machine_state, error}
    end
  end

  @doc """
  Runs `program` (a `Machine.program()`, ADR-0026) against `machine_state`'s
  datamodel, merges its writes back, and also returns the post-run
  `Predicator.Context.t()` `Predicator.execute/3` built along the way.

  Builds the same `context/1` `evaluate/2` uses, keeps a copy of its
  pre-run `data`, then hands the compiled program to `Predicator.execute/3`.
  `Predicator.execute/3` returns `{:ok, %Predicator.Context{}}` on success
  or `{:error, error, %Predicator.Context{}}` on a mid-program failure -
  either way the returned context's `data` is the whole post-run datamodel,
  normalized (`undefine_nils/1`), so it is never written back wholesale
  (that would permanently rewrite every untouched `nil` root to
  `:undefined` - see `undefine_nils/1`'s own note).

  Instead this diffs `data` against the pre-run copy at the **top level
  only** - `store` (`deps/predicator/lib/predicator/evaluator.ex:1491-1523`)
  always writes through a root segment, so any nested write already changes
  its root's value and is caught by a top-level compare - and merges just
  the changed and newly-created roots into the *raw*
  `machine_state.datamodel` map, the same "write through the raw map"
  property `Statifier.Machine.Content.Assign`'s moduledoc protects, reached
  differently here because a program returns a whole context rather than
  one resolved path. A root the program never touches keeps its raw value
  untouched, so a seeded-but-unbound `<data>` id still reads `nil` after a
  run that never mentioned it. `store` never deletes a root, so there is no
  removal case here to handle.

  Unlike `Statifier.Machine.Content.Assign`'s `check_root/3`, a program
  writing a root no `<datamodel>` declared is not rejected: `<assign>`'s
  `location` is a *reference* to a location the document must already have
  (spec 5.9.2), while a predicator assignment *statement* is a declaration
  and a write in one, which is what W3C test302/test304 assert (ADR-0026
  decision 2, `Statifier.Machine.Content.Script`'s moduledoc).

  A changed root beginning with `_` is a system-variable write (spec
  5.10) and is never merged; if the diff finds one, this returns
  `{:error, machine_state, {:system_variable, root}, post_context}` - the
  same reason tuple `Statifier.Machine.Content.Assign.check_system_variable/1`
  produces, so `error.execution`'s `data:` reads identically whichever
  element attempted the write - with every non-system changed root from
  the *same* program still merged into the returned `machine_state` (spec
  4.9's stop-and-keep model, applied to the one statement that failed this
  check). When several changed roots are system roots, the one reported is
  the alphabetically first - the diff makes no claim about which
  assignment statement ran first, only about which roots differ.

  Known and accepted gap: a program that writes a system root and then
  writes it back to its original value is unobservable to this diff and
  is not caught, and 5.10 wants the write to fail *at the attempt* so
  later statements never observe it - this diff only refuses to merge
  it. Two things a pre-execution scan of assignment targets would not
  fix. It would fire on an assignment inside an `if` branch that never
  runs, while 5.10 owes the error only "when such an attempt is made";
  and it cannot make the write fail, only report it after the fact.
  (The scan itself would be complete, not bypassable: predicator's
  `location` grammar roots every target in a literal IDENTIFIER, and
  this check is root-only, so a computed bracket key never hides a
  root.) Closing the gap exactly needs a hook inside predicator's
  `store` - a protected-roots option on `Predicator.execute/3` - which
  is upstream work, not a shape this diff can reach.

  A `Predicator.execute/3` failure (a bad statement mid-program, or a
  program that never parsed - `Statifier.Compiler.Expressions.
  compile_program/3`'s deferred `{:invalid, _}` shape reaches here only
  through its caller, never through this function directly) is wrapped
  with `Statifier.Evaluator.Error.new(source, error)` (ADR-0026 decision
  6) so a consumer never has to branch on whether the expression path or
  the program path failed - both land in the same `Evaluator.Error.t()`
  shape.

  The returned `post_context` is safe to thread into the rest of the block
  that ran `program` (ADR-0028) and unsafe to keep past it, for the same
  reason `bind/3`'s own doc gives: `functions` and `host` (and with it
  `In/1`'s configuration) carry over from `predicator_context` unchanged,
  correct only while the block still runs inside the microstep it started
  in.
  """
  @spec run_program(machine_state :: MachineState.t(), program :: Machine.program()) ::
          {:ok, MachineState.t(), Predicator.Context.t()}
          | {:error, MachineState.t(), Error.t() | {:system_variable, String.t()},
             Predicator.Context.t()}
  def run_program(
        %MachineState{} = machine_state,
        {:program, %Predicator.Compiled{} = compiled, source}
      ) do
    predicator_context = context(machine_state)
    before_data = predicator_context.data

    {post_context, run_error} =
      case Predicator.execute(compiled, predicator_context) do
        {:ok, %Predicator.Context{} = post_context} -> {post_context, nil}
        {:error, error, %Predicator.Context{} = post_context} -> {post_context, error}
      end

    {system_changed, non_system_changed} = partition_changed_roots(before_data, post_context.data)

    new_machine_state = %{
      machine_state
      | datamodel: Map.merge(machine_state.datamodel, non_system_changed)
    }

    cond do
      run_error != nil ->
        {:error, new_machine_state, Error.new(source, run_error), post_context}

      map_size(system_changed) > 0 ->
        [{root, _value} | _rest] = Enum.sort(system_changed)
        {:error, new_machine_state, {:system_variable, root}, post_context}

      true ->
        {:ok, new_machine_state, post_context}
    end
  end

  # Decisions 3 and 4: the top-level diff `execute/2` builds its merge and
  # its system-variable check from, in one pass. `before` and `after_data`
  # are both `context/1`-normalized maps, so a root absent from `before`
  # (a program-created root, ADR-0026 decision 2) diffs against the
  # `:__absent__` sentinel and is treated as changed like any other.
  @spec partition_changed_roots(before :: map(), after_data :: map()) :: {map(), map()}
  defp partition_changed_roots(before, after_data) do
    changed =
      for {key, value} <- after_data,
          Map.get(before, key, :__absent__) !== value,
          into: %{},
          do: {key, value}

    Map.split_with(changed, fn {root, _value} -> String.starts_with?(root, "_") end)
  end
end
