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
     phrase; Decision 1,
     `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`).
  2. Seed: `Map.put_new(datamodel, id, nil)` for every `%Machine.Data{}` in
     `machine.data_elements`, regardless of binding - 5.3.3 makes *creation*
     unconditional under both bindings, and `Predicator.Context.new/2`
     normalizes `nil` to `:undefined` recursively, so a seeded-but-unbound id
     answers `=== undefined`/`!== undefined` rather than raising
     `UndefinedVariableError` (Decision 3).
  3. Bind, in ascending `d_index` order: under `:early`, every `d_index`;
     under `:late`, only the root state's own (`Machine.at(machine, 0).data`)
     - the top-level `<data>`, which 5.3.3's per-state deferral has no state
     to defer to (Decision 7, and this module's own `initialize/1` `@doc`
     below). A top-level `d_index` whose id is in `env_ids` is skipped
     entirely, leaving its seeded `nil` in place - Decision 1's
     environment-wins rule. A state-scoped `<data>` is never skipped this
     way: 5.3.2 scopes the override to top-level only.

  Binding a `d_index`: `{:invalid, error}` (a `<data expr>` that failed to
  compile, Decision 2) and `{:src, uri}` (never fetched, ADR-0003) both
  short-circuit straight to the failure branch with no evaluation attempted;
  any other `Machine.expr()` goes through `Statifier.Evaluator.evaluate/2`
  and takes the failure branch on `{:error, _}`. Either way the id keeps the
  `nil` step 2 already wrote - 5.3.2's "MUST create an empty data element" is
  satisfied by *not overwriting* the seed, never by writing `nil` after an
  error (Decision 3) - and
  `MachineState.raise_platform(machine_state, "error.execution", {:data,
  d_index}, data: reason)` runs: `raise_platform/4`, not `raise_internal/4`,
  because spec 5.10.1 classifies `error.*` as a platform event, matching the
  two existing raise sites
  (`Statifier.Interpreter.Content.raise_execution_error/4`,
  `Statifier.Interpreter.Selection.raise_cond_errors/2`).
  """

  alias Statifier.Evaluator
  alias Statifier.Machine
  alias Statifier.MachineState

  @doc """
  `interpret`'s datamodel preamble (Appendix D `:101-102`, prose above), plus
  the top-level half of `enterStates`' per-state binding (`:312`) that late
  binding would otherwise defer forever - see the moduledoc's "no Appendix D
  procedure body" section and Decision 7
  (`docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`) for why
  the `if doc.binding == "early":` guard that wraps the `interpret` call site
  in the pseudocode moves off that call site and into this function instead:
  a top-level `<data>` is contained in no state, so under `binding="late"` it
  never reaches `enterStates`' `statesToEnter` loop at all, and deferring its
  binding to a state entry that never happens would leave it permanently
  unassigned - a spec violation, not a conforming late-binding delay.

  Returns a bare `MachineState.t()`, never `{machine_state, [effect]}` like
  every other function in `Statifier.Interpreter`: binding a `<data>`
  produces no trace effect today
  (`docs/observability.md`'s minimum trace vocabulary is a closed table and
  datamodel binding is not a member of it) and no core effect either - the
  one observable event a binding pass can produce, `error.execution`, is
  already an ordinary internal event that travels on `machine_state`'s own
  queue. Inventing a permanently-empty effect list at every call site would
  be a shape built for symmetry with this module's siblings, not for a
  caller that has anything to do with it; a future trace row would add the
  second return value at that point, with its own caller.
  """
  @spec initialize(machine_state :: MachineState.t()) :: MachineState.t()
  def initialize(%MachineState{machine: machine} = machine_state) do
    env_ids = MapSet.new(Map.keys(machine_state.datamodel))

    machine_state = seed(machine_state, machine)

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

    Enum.reduce(d_indexes, machine_state, fn d_index, ms ->
      bind(ms, machine, context, d_index, top_level_indexes, env_ids)
    end)
  end

  # Every declared <data> id, seeded to nil - 5.3.3's unconditional-creation
  # half, run before any value is evaluated (Decision 3). Map.put_new/3
  # never overwrites a datamodel key the environment already supplied.
  @spec seed(machine_state :: MachineState.t(), machine :: Machine.t()) :: MachineState.t()
  defp seed(machine_state, machine) do
    Enum.reduce(Tuple.to_list(machine.data_elements), machine_state, fn data, ms ->
      %{ms | datamodel: Map.put_new(ms.datamodel, data.id, nil)}
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

  # One <data>'s bind step: skip (leaving the seeded nil) when it is
  # top-level and the environment already supplied its id (Decision 1);
  # otherwise evaluate its value and either write it or raise
  # error.execution, keeping the seeded nil either way (Decision 3).
  @spec bind(
          machine_state :: MachineState.t(),
          machine :: Machine.t(),
          context :: Predicator.Context.t(),
          d_index :: non_neg_integer(),
          top_level_indexes :: MapSet.t(),
          env_ids :: MapSet.t()
        ) :: MachineState.t()
  defp bind(machine_state, machine, context, d_index, top_level_indexes, env_ids) do
    data = Machine.data(machine, d_index)

    if MapSet.member?(top_level_indexes, d_index) and MapSet.member?(env_ids, data.id) do
      machine_state
    else
      bind_value(machine_state, context, d_index, data)
    end
  end

  @spec bind_value(
          machine_state :: MachineState.t(),
          context :: Predicator.Context.t(),
          d_index :: non_neg_integer(),
          data :: Machine.Data.t()
        ) :: MachineState.t()
  defp bind_value(machine_state, _context, d_index, %{value: {:invalid, error}}) do
    raise_binding_error(machine_state, d_index, error)
  end

  defp bind_value(machine_state, _context, d_index, %{value: {:src, uri}}) do
    raise_binding_error(machine_state, d_index, {:src, uri})
  end

  defp bind_value(machine_state, context, d_index, %{id: id} = data) do
    case Evaluator.evaluate(context, data.value) do
      {:ok, value} -> %{machine_state | datamodel: Map.put(machine_state.datamodel, id, value)}
      {:error, reason} -> raise_binding_error(machine_state, d_index, reason)
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

  A no-op, returning `machine_state` unchanged with no allocation, in three
  cases: under `binding == :early` (every `d_index` was already bound at
  `initialize/1`, before any state was entered), under `binding == :late`
  on a state whose own `<datamodel>` is empty (`data == []` - nothing to
  bind), and on `state_index == 0` for the reason below.

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
  silently discard the values its parent passed it (st-cmq).

  Otherwise: one `Evaluator.context/1` for `state_index`'s whole `data` list
  (B.2.2's "no ordering dependencies" licenses this exactly as it does in
  `initialize/1`), each `d_index` bound through the same `bind_value/4` this
  module's `initialize/1` uses - same seeded-`nil`-on-failure,
  `raise_platform/4` shape, Decision 2/3 unchanged. There is no environment
  override on this path: Decision 1 scopes that skip to top-level `<data>`
  only, and a state-scoped `<data>` on any state but the root is never
  top-level.
  """
  @spec enter_state(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          MachineState.t()
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
        ) :: MachineState.t()
  defp bind_state_data(machine_state, _machine, :early, _state_index), do: machine_state

  # The root's own data is the top-level data, already bound by initialize/1 -
  # see this function's "Why `state_index == 0` is a no-op" section. Must
  # precede the general :late clause.
  defp bind_state_data(machine_state, _machine, :late, 0), do: machine_state

  defp bind_state_data(machine_state, machine, :late, state_index) do
    case Machine.at(machine, state_index).data do
      [] ->
        machine_state

      d_indexes ->
        context = Evaluator.context(machine_state)

        Enum.reduce(d_indexes, machine_state, fn d_index, ms ->
          bind_value(ms, context, d_index, Machine.data(machine, d_index))
        end)
    end
  end

  # The errors-are-events conversion for a <data> that could not be bound -
  # raise_platform/4, not raise_internal/4, for the same spec 5.10.1 reason
  # Statifier.Interpreter.Content.raise_execution_error/4 and
  # Statifier.Interpreter.Selection.raise_cond_errors/2 give: error.* is a
  # platform event regardless of what raised it. The datamodel keeps its
  # seeded nil - this function never writes to `datamodel` itself.
  @spec raise_binding_error(
          machine_state :: MachineState.t(),
          d_index :: non_neg_integer(),
          reason :: term()
        ) :: MachineState.t()
  defp raise_binding_error(machine_state, d_index, reason) do
    MachineState.raise_platform(machine_state, "error.execution", {:data, d_index}, data: reason)
  end
end
