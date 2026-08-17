defmodule Statifier.Interpreter.Datamodel do
  @moduledoc """
  Datamodel creation and early/top-level binding - the `interpret` preamble
  hook (`Statifier.Interpreter.initialize/2`).

  ## No Appendix D procedure body to port

  `initializeDatamodel`/`initializeDataModel` have **no procedure body
  anywhere in Appendix D**. A case-insensitive grep over
  `spec-cache/appendix-d.txt` returns exactly two hits, both call sites, and
  they do not even agree with each other: `:102`, inside `interpret`, calls
  `initializeDatamodel(datamodel, doc)`; `:312`, inside `enterStates`, calls
  `initializeDataModel(datamodel.s, doc.s)` - different capitalization,
  different arity meaning (whole-document vs. per-state). `new Datamodel(doc)`
  (`:101`) is never defined either. So there is nothing to diff this module's
  bodies against; ADR-0002's port obligation here is the two call sites
  (this module's `initialize/1`, and Phase 5's `enter_state/2`), not a
  pseudocode block. This module's semantics instead come from the prose of
  clauses 5.3.2, 5.3.3, and B.2.2:

  - **5.3.2 (environment override, scoped to top-level)**: "The SCXML
    Processor MUST use any values provided by the environment at
    instantiation time in place of those contained in the top-level `<data>`
    elements. (Top-level data elements are those that are children of the
    `<datamodel>` element that is a child of `<scxml>`)."
  - **5.3.2 (the failure clause)**: "If the value specified for a `<data>`
    element (by 'src', children, or the environment) is not a legal data
    value, the SCXML Processor MUST raise place error.execution in the
    internal event queue and MUST create an empty data element in the data
    model with the specified id." ("MUST raise place" is the REC's own typo.)
    An `expr` failure is 5.9.3's case instead: "If a value expression does
    not return a legal data value, the SCXML Processor MUST place the error
    'error.execution' in the internal event queue."
  - **5.3.3 (binding)**: "When 'binding' is assigned the value \"early\" (the
    default), the SCXML Processor MUST create all data elements and assign
    their initial values at document initialization time. When 'binding' is
    assigned the value \"late\", the SCXML Processor MUST create the data
    elements at document initialization time, but MUST assign the specified
    initial value to a given data element only when the state that contains
    it is entered for the first time, before any `<onentry>` markup."
  - **B.2.2 (no ordering dependencies)**: "Ordering dependencies between
    `<data>` elements are not permitted... the SCXML Processor MUST evaluate
    all `<data>` elements at initialization time but MAY do so in any order
    it chooses."

  ## Algorithm (`initialize/1`)

  1. `env_ids = MapSet.new(Map.keys(machine_state.datamodel))`, captured
     **first**, before any seeding - `MachineState.new/2`'s only writers of
     `datamodel` at this point are the `:datamodel` option and
     `SystemVariables.initial/2`, so key presence here is definitionally
     "provided by the environment at instantiation time" (5.3.2's own
     phrase).
  2. Seed: `Map.put_new(datamodel, id, :undefined)` for every `%Machine.Data{}`
     in `machine.data_elements`, regardless of binding - 5.3.3 makes
     *creation* unconditional under both bindings, and writing `:undefined`
     directly means a seeded-but-unbound id answers `=== undefined`/
     `!== undefined` rather than raising `UndefinedVariableError`
     (Decision 3).
  3. Bind, in ascending `d_index` order: under `:early`, every `d_index`;
     under `:late`, only the root state's own (`Machine.at(machine, 0).data`)
     - the top-level `<data>`, which 5.3.3's per-state deferral has no state
     to defer to (Decision 7, and this module's own `initialize/1` `@doc`
     below). A top-level `d_index` whose id is in `env_ids` is skipped
     entirely, leaving its seeded `:undefined` in place - Decision 1's
     environment-wins rule. A state-scoped `<data>` is never skipped this
     way: 5.3.2 scopes the override to top-level only.

  Binding a `d_index`: `{:invalid, error}` (a `<data expr>` that failed to
  compile, Decision 2) and `{:src, uri}` (never fetched, ADR-0003) both
  short-circuit straight to the failure branch with no evaluation attempted;
  any other `Machine.expr()` goes through `Statifier.Evaluator.evaluate/2`
  and takes the failure branch on `{:error, _}`. Either way the id keeps the
  `:undefined` step 2 already wrote - 5.3.2's "MUST create an empty data
  element" is satisfied by *not overwriting* the seed, never by writing
  `:undefined` after an error (Decision 3) - and
  `MachineState.raise_platform(machine_state, "error.execution", {:data,
  d_index}, data: reason)` runs: `raise_platform/4`, not `raise_internal/4`,
  because spec 5.10.1 classifies `error.*` as a platform event, matching the
  two existing raise sites
  (`Statifier.Interpreter.Content.raise_execution_error/4`,
  `Statifier.Interpreter.Selection.raise_cond_errors/2`).
  """

  alias Statifier.Effect
  alias Statifier.Evaluator
  alias Statifier.Interpreter.Datamodel.Write
  alias Statifier.Machine
  alias Statifier.MachineState

  @doc """
  Writes `value` at `path_source` (a raw, uncompiled path expression such as
  `"foo.bar.baz"` or `"items[0]"`) against `machine_state`'s datamodel,
  rebinding the written root into `datamodel_context` for callers that thread
  a context across a block (ADR-0028). Extracted from
  `Statifier.Machine.Content.Assign`'s defimpl - see that module's moduledoc
  for the vivification and system-variable reasoning this function's five
  steps carry out unchanged; this is a pure mechanics move, not a new
  decision.

  1. Resolve `path_source` against `datamodel_context.data` (the normalized
     view, so a bracket key such as `items[i]` reads `i` exactly as an
     expression would).
  2. Reject a resolved root beginning with `"_"` (spec 5.10 - a system
     variable).
  3. Require the resolved root to already be a key of
     `machine_state.datamodel` - auto-vivification only ever creates
     intermediate containers, never an undeclared top-level variable.
  4. Write into the *raw* `machine_state.datamodel`, never the normalized
     `.data` read in step 1.
  5. Bind just the written root into `datamodel_context` - O(size of that
     root), not O(size of the datamodel).

  Every predicator failure returns as a bare `{:error, term()}` - the caller
  is the sole `error.execution` conversion site (ADR-0003).

  On success, the fourth element is a `Statifier.Interpreter.Datamodel.Write`
  report of the write - the resolved `path`, the `prior_value` read at that
  full path immediately before the write, and the `new_value` written.
  Reporting is all this function does; building an effect from the report is
  each caller's own job.
  """
  @spec write_location(
          machine_state :: MachineState.t(),
          datamodel_context :: Predicator.Context.t(),
          path_source :: String.t(),
          value :: term()
        ) ::
          {:ok, MachineState.t(), Predicator.Context.t(), Write.t()} | {:error, term()}
  def write_location(
        %MachineState{} = machine_state,
        %Predicator.Context{} = datamodel_context,
        path_source,
        value
      )
      when is_binary(path_source) do
    with {:ok, path} <- resolve_location(path_source, datamodel_context),
         :ok <- check_system_variable(path),
         :ok <- check_root(machine_state, path_source, path),
         prior_value = read_path(machine_state.datamodel, path),
         {:ok, new_datamodel} <- write(machine_state, path_source, path, value) do
      new_machine_state = %{machine_state | datamodel: new_datamodel}
      [root | _rest] = path

      {:ok, new_machine_state,
       Evaluator.bind(datamodel_context, root, Map.fetch!(new_datamodel, root)),
       %Write{path: path, prior_value: prior_value, new_value: value}}
    end
  end

  # The value at the resolved `path`, read from the *pre-write* datamodel -
  # placed before `write/4` runs (deliberately: reading after would see the
  # value just written, defeating the whole point of a prior read).
  # `Predicator.ContextLocation` has `put/3` but no getter
  # (`deps/predicator/lib/predicator/context_location.ex:210`), so this is a
  # local walk: `Map.fetch/2` on a binary key against a map, `Enum.fetch/2` on
  # an integer index against a list, `:undefined` on any miss or on a
  # non-container - ADR-0037's single spelling for an unbound value, at the
  # full path rather than the whole root. This walk deliberately reads the
  # *full* path, so it conflates "nothing was ever written here" with
  # "`:undefined` was written here" - accepted, since `prior_value` is never
  # consulted for reconstruction, only for diffing/undo.
  @spec read_path(datamodel :: map(), path :: Predicator.ContextLocation.location_path()) ::
          term()
  defp read_path(datamodel, path) do
    Enum.reduce_while(path, datamodel, fn
      segment, container when is_binary(segment) and is_map(container) ->
        case Map.fetch(container, segment) do
          {:ok, value} -> {:cont, value}
          :error -> {:halt, :undefined}
        end

      segment, container when is_integer(segment) and is_list(container) ->
        case Enum.fetch(container, segment) do
          {:ok, value} -> {:cont, value}
          :error -> {:halt, :undefined}
        end

      _segment, _container ->
        {:halt, :undefined}
    end)
  end

  # Step 1: resolve `path_source` into a path. Resolution reads
  # `datamodel_context.data` - the normalized view - never the
  # `%Predicator.Context{}` struct itself, which would also satisfy
  # `context_location/3`'s `is_map/1` guard and then look up the wrong keys
  # entirely.
  @spec resolve_location(path_source :: String.t(), datamodel_context :: Predicator.Context.t()) ::
          {:ok, Predicator.ContextLocation.location_path()} | {:error, term()}
  defp resolve_location(path_source, %Predicator.Context{data: data}) do
    case Predicator.context_location(path_source, data) do
      {:ok, path} -> {:ok, path}
      {:error, error} -> {:error, Evaluator.Error.new(path_source, error)}
    end
  end

  # Step 2 (spec 5.10): the resolved root segment must not begin with "_". A
  # prefix test on the *resolved* root (rather than a membership test
  # against the four named variables) can never collide with a legitimate
  # author id and covers `_x` (5.10's platform-variable root) and any future
  # system variable for free. This runs before step 3's root-existence
  # check, so an undeclared system-looking root reports as a
  # system-variable violation rather than an unbound location.
  @spec check_system_variable(path :: Predicator.ContextLocation.location_path()) ::
          :ok | {:error, {:system_variable, String.t()}}
  defp check_system_variable([root | _rest]) when is_binary(root) do
    if String.starts_with?(root, "_") do
      {:error, {:system_variable, root}}
    else
      :ok
    end
  end

  defp check_system_variable(_path), do: :ok

  # Step 3: the resolved root segment must already be a key of
  # `machine_state.datamodel` - predicator's own `put/3` would happily
  # vivify an undeclared root, but this requires it to fail when a location
  # "cannot be evaluated to yield a valid location" - auto-vivification of
  # *intermediate* containers only, never creation of undeclared top-level
  # variables.
  @spec check_root(
          machine_state :: MachineState.t(),
          path_source :: String.t(),
          path :: Predicator.ContextLocation.location_path()
        ) :: :ok | {:error, term()}
  defp check_root(%MachineState{datamodel: datamodel}, path_source, path) do
    if Map.has_key?(datamodel, List.first(path)) do
      :ok
    else
      {:error, {:unbound_location, path_source}}
    end
  end

  # Step 4: the write itself, against the *raw* `machine_state.datamodel`
  # rather than the normalized context read in step 1 - the raw map is
  # `MachineState`'s resumable truth (ADR-0012 / `docs/observability.md`
  # constraint 1), and writing through it is what keeps every other,
  # untouched root in `machine_state.datamodel` unaffected by this write.
  @spec write(
          machine_state :: MachineState.t(),
          path_source :: String.t(),
          path :: Predicator.ContextLocation.location_path(),
          value :: term()
        ) :: {:ok, map()} | {:error, term()}
  defp write(%MachineState{datamodel: datamodel}, path_source, path, value) do
    case Predicator.ContextLocation.put(datamodel, path, value) do
      {:ok, new_datamodel} -> {:ok, new_datamodel}
      {:error, error} -> {:error, Evaluator.Error.new(path_source, error)}
    end
  end

  @doc """
  `interpret`'s datamodel preamble (Appendix D `:101-102`, prose above), plus
  the top-level half of `enterStates`' per-state binding (`:312`) that late
  binding would otherwise defer forever - see the moduledoc's "no Appendix D
  procedure body" section and spec 5.3.3's binding rule for why
  the `if doc.binding == "early":` guard that wraps the `interpret` call site
  in the pseudocode moves off that call site and into this function instead:
  a top-level `<data>` is contained in no state, so under `binding="late"` it
  never reaches `enterStates`' `statesToEnter` loop at all, and deferring its
  binding to a state entry that never happens would leave it permanently
  unassigned - a spec violation, not a conforming late-binding delay.

  Returns `{MachineState.t(), [Effect.t()]}`, like every other function in
  `Statifier.Interpreter`: the first effect on the list is always the
  `{:datamodel_init, %Effect.DatamodelInit{}}` baseline, built from
  `machine_state` right after `seed/2` and before the binding fold - the
  datamodel as it stands the instant every declared `<data>` exists but
  before any of them has a value (see `Statifier.Effect.DatamodelInit`'s own
  moduledoc for what the map does and does not carry). Every effect after it,
  in ascending `d_index` order, is a `{:datamodel_change,
  %Effect.DatamodelChange{}}` for one successful `<data>` binding
  (`bind_value/4`, decision 3) - a failed or environment-skipped
  binding emits nothing (decision 5). No trace effect is produced either way
  (`docs/observability.md`'s minimum trace vocabulary is a closed table and
  datamodel binding is not a member of it); the one observable event a failed
  binding can produce, `error.execution`, is already an ordinary internal
  event that travels on `machine_state`'s own queue.
  """
  @spec initialize(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  def initialize(%MachineState{machine: machine} = machine_state) do
    env_ids = MapSet.new(Map.keys(machine_state.datamodel))

    machine_state = seed(machine_state, machine)

    # Built here, deliberately, before the binding fold below - decision 1's
    # "the baseline is taken pre-binding" - so it carries exactly the three
    # contributions no {:datamodel_change, _} effect could ever describe.
    init_effect =
      {:datamodel_init,
       %Effect.DatamodelInit{
         datamodel: machine_state.datamodel,
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep
       }}

    top_level_indexes = MapSet.new(Machine.at(machine, 0).data)
    d_indexes = d_indexes_to_bind(machine, top_level_indexes)

    # One Evaluator.context/1 for the whole binding pass, not one per
    # <data> - licensed by B.2.2's "Ordering dependencies between <data>
    # elements are not permitted", quoted in full above. This does not
    # conflict with docs/datamodel.md's "once per evaluation site, never
    # once per expression" rule: one binding pass over the whole datamodel
    # *is* one evaluation site here, the same way one executable-content
    # block is one evaluation site in Statifier.Interpreter.Content -
    # nothing here evaluates per-expression against a stale context, since
    # no <data>'s value may read another <data> in the same pass.
    context = Evaluator.context(machine_state)

    {machine_state, binding_effects} =
      Enum.reduce(d_indexes, {machine_state, []}, fn d_index, {ms, effects} ->
        {ms, new_effects} = bind(ms, machine, context, d_index, top_level_indexes, env_ids)
        {ms, effects ++ new_effects}
      end)

    {machine_state, [init_effect | binding_effects]}
  end

  # Every declared <data> id, seeded to :undefined - 5.3.3's
  # unconditional-creation half, run before any value is evaluated
  # (Decision 3). Map.put_new/3 never overwrites a datamodel key the
  # environment already supplied.
  @spec seed(machine_state :: MachineState.t(), machine :: Machine.t()) :: MachineState.t()
  defp seed(machine_state, machine) do
    Enum.reduce(Tuple.to_list(machine.data_elements), machine_state, fn data, ms ->
      %{ms | datamodel: Map.put_new(ms.datamodel, data.id, :undefined)}
    end)
  end

  # The d_indexes step 3 of the moduledoc's algorithm binds, in ascending
  # order: every d_index under :early, only the root's own under :late.
  @spec d_indexes_to_bind(machine :: Machine.t(), top_level_indexes :: MapSet.t()) :: [
          non_neg_integer()
        ]
  defp d_indexes_to_bind(%Machine{binding: :early} = machine, _top_level_indexes) do
    0..(tuple_size(machine.data_elements) - 1)//1
  end

  defp d_indexes_to_bind(%Machine{binding: :late}, top_level_indexes) do
    Enum.sort(top_level_indexes)
  end

  # One <data>'s bind step: skip (leaving the seeded :undefined) when it is
  # top-level and the environment already supplied its id (Decision 1);
  # otherwise evaluate its value and either write it or raise
  # error.execution, keeping the seeded :undefined either way (Decision 3).
  @spec bind(
          machine_state :: MachineState.t(),
          machine :: Machine.t(),
          context :: Predicator.Context.t(),
          d_index :: non_neg_integer(),
          top_level_indexes :: MapSet.t(),
          env_ids :: MapSet.t()
        ) :: {MachineState.t(), [Effect.t()]}
  defp bind(machine_state, machine, context, d_index, top_level_indexes, env_ids) do
    data = Machine.data(machine, d_index)

    if MapSet.member?(top_level_indexes, d_index) and MapSet.member?(env_ids, data.id) do
      # Environment-supplied top-level <data> - decision 5's other half. The
      # environment's value is already on the datamodel (5.3.2's override),
      # and the baseline effect already carries it, so no
      # {:datamodel_change, _} is emitted for a value nothing here wrote.
      {machine_state, []}
    else
      bind_value(machine_state, context, d_index, data)
    end
  end

  @spec bind_value(
          machine_state :: MachineState.t(),
          context :: Predicator.Context.t(),
          d_index :: non_neg_integer(),
          data :: Machine.Data.t()
        ) :: {MachineState.t(), [Effect.t()]}
  # Decision 5: a failed or short-circuited binding emits no effect - the
  # datamodel did not change beyond the :undefined the baseline already
  # reported, and the failure is already observable as error.execution.
  defp bind_value(machine_state, _context, d_index, %{value: {:invalid, error}}) do
    {raise_binding_error(machine_state, d_index, error), []}
  end

  defp bind_value(machine_state, _context, d_index, %{value: {:src, uri}}) do
    {raise_binding_error(machine_state, d_index, {:src, uri}), []}
  end

  defp bind_value(machine_state, context, d_index, %{id: id} = data) do
    case Evaluator.evaluate(context, data.value) do
      {:ok, value} ->
        # A binding writes at the root key, so the prior value is one
        # Map.get/3 - no read_path/2 walk is needed, and :undefined is
        # ADR-0037's spelling for the seed seed/2 wrote. Under
        # binding="late" this is not always the seed: an <assign> may have
        # written the id before the containing state was first entered.
        prior_value = Map.get(machine_state.datamodel, id, :undefined)

        {%{machine_state | datamodel: Map.put(machine_state.datamodel, id, value)},
         [
           {:datamodel_change,
            %Effect.DatamodelChange{
              location_path: [id],
              location_source: id,
              new_value: value,
              prior_value: prior_value,
              d_index: d_index,
              c_index: nil,
              owner: nil,
              macrostep: machine_state.macrostep,
              microstep: machine_state.microstep
            }}
         ]}

      {:error, reason} ->
        {raise_binding_error(machine_state, d_index, reason), []}
    end
  end

  @doc """
  `enterStates`'s per-state datamodel step (Appendix D `:312`, prose in the
  moduledoc's "no Appendix D procedure body" section above) - binds
  `state_index`'s own `<datamodel>` (`Machine.at(machine, state_index).data`)
  under `binding == :late`.

  This function does not itself test "is this the first time `state_index`
  has been entered" - Appendix D's `s.isFirstEntry` (`appendix-d.txt:312`).
  `Statifier.Interpreter.ExitEntry.arrive/3` is the only caller, and it tests
  membership in `MachineState.entered_states` (the ADR-0002 substitute for
  `s.isFirstEntry`, documented at that field) *before* calling this function,
  so by the time this function runs, "first entry" has already been decided.
  Splitting it this way keeps this module free of `MachineState.configuration`/
  `entered_states` mutation, which `arrive/3` already owns for every other
  step of the same pseudocode body.

  A no-op, returning `{machine_state, []}` unchanged, in three cases: under
  `binding == :early` (every `d_index` was already bound at `initialize/1`,
  before any state was entered), under `binding == :late` on a state whose
  own `<datamodel>` is empty (`data == []` - nothing to bind), and on
  `state_index == 0` for the reason below.

  ## Why `state_index == 0` is a no-op

  Index 0 is the document root, and it is in `configuration` like any other
  state, so `arrive/3` calls this function for it. But the root's own `data`
  list **is** the top-level data list - the `<datamodel>` that is a child of
  `<scxml>` - which `initialize/1` has already bound (Decision 3: top-level
  `<data>` binds at initialization under both bindings, since 5.3.3's "the
  state that contains it" has no answer for a `<data>` contained in no
  state). Binding it a second time here is duplication, and not harmless
  duplication: this function deliberately applies no environment override,
  so the second pass would overwrite an environment-supplied value with the
  document's own and violate 5.3.2's

      "The SCXML Processor MUST use any values provided by the environment
      at instantiation time in place of those contained in the top-level
      <data> elements."

  Only `binding == "late"` reaches this path at all, and only a document
  whose environment seeds a top-level id observes it - which is why no
  corpus file catches it. Spec 6.4.3 makes it reachable in practice: an
  invoked session's `<param>`/`namelist` values arrive as exactly this
  environment seed, so without this guard a late-bound invoked child would
  silently discard the values its parent passed it - the child-session half
  of `<invoke>` that would deliver them does not exist yet, per
  `docs/architecture.md`'s "Sessions and invoke" section.

  Otherwise: one `Evaluator.context/1` for `state_index`'s whole `data` list
  (B.2.2's "no ordering dependencies" licenses this exactly as it does in
  `initialize/1`), each `d_index` bound through the same `bind_value/4` this
  module's `initialize/1` uses - same seeded-`:undefined`-on-failure,
  `raise_platform/4` shape, Decision 2/3 unchanged, and the same
  `{:datamodel_change, %Effect.DatamodelChange{}}` emission per successful
  binding (decision 3). There is no environment override on this
  path: Decision 1 scopes that skip to top-level `<data>` only, and a
  state-scoped `<data>` on any state but the root is never top-level.
  """
  @spec enter_state(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  # Not a re-derivation of enterStates: that name stays on
  # Statifier.Interpreter.ExitEntry.enter_states/2, the actual Appendix D
  # port. This is the state-scoped datamodel pass ADR-0002's "no procedure
  # body to port" note above names as this module's own call site, one level
  # under enterStates, the same relationship initialize/1 has to interpret.
  # ADR-0002.
  def enter_state(%MachineState{machine: machine} = machine_state, state_index) do
    bind_state_data(machine_state, machine, machine.binding, state_index)
  end

  @spec bind_state_data(
          machine_state :: MachineState.t(),
          machine :: Machine.t(),
          binding :: :early | :late,
          state_index :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  defp bind_state_data(machine_state, _machine, :early, _state_index), do: {machine_state, []}

  # The root's own data is the top-level data, already bound by initialize/1 -
  # see this function's "Why `state_index == 0` is a no-op" section. Must
  # precede the general :late clause.
  defp bind_state_data(machine_state, _machine, :late, 0), do: {machine_state, []}

  defp bind_state_data(machine_state, machine, :late, state_index) do
    case Machine.at(machine, state_index).data do
      [] ->
        {machine_state, []}

      d_indexes ->
        context = Evaluator.context(machine_state)

        Enum.reduce(d_indexes, {machine_state, []}, fn d_index, {ms, effects} ->
          {ms, new_effects} = bind_value(ms, context, d_index, Machine.data(machine, d_index))
          {ms, effects ++ new_effects}
        end)
    end
  end

  # The errors-are-events conversion for a <data> that could not be bound -
  # raise_platform/4, not raise_internal/4, for the same spec 5.10.1 reason
  # Statifier.Interpreter.Content.raise_execution_error/4 and
  # Statifier.Interpreter.Selection.raise_cond_errors/2 give: error.* is a
  # platform event regardless of what raised it. The datamodel keeps its
  # seeded :undefined - this function never writes to `datamodel` itself.
  @spec raise_binding_error(
          machine_state :: MachineState.t(),
          d_index :: non_neg_integer(),
          reason :: term()
        ) :: MachineState.t()
  defp raise_binding_error(machine_state, d_index, reason) do
    MachineState.raise_platform(machine_state, "error.execution", {:data, d_index}, data: reason)
  end
end
