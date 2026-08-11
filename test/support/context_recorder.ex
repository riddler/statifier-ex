defmodule Statifier.ContextRecorder do
  @moduledoc """
  A test-only executable-content node that records the `datamodel_context`
  it received on `Statifier.ExecutableContent.Context`, since no shipped
  node reads that field yet (`lib/statifier/executable_content/context.ex`).
  `execute/2` returns the received `Predicator.Context.t()` as a `:log`
  effect's `value`, which lets a test assert on it directly - both that it
  is the same value across every node in a block (the once-per-block
  property) and that it evaluates `In(...)` correctly for the configuration
  the block ran at.

  The optional `:put` field lets one instance stand in for a future
  datamodel-mutating node (`<assign>`, st-af3.4): when set, `execute/2`
  merges it into `machine_state.datamodel` and returns a `Context` carrying
  that updated `machine_state` - but *not* a rebuilt `datamodel_context`,
  since no shipped node rebuilds that field either (`execute_block/3` builds
  it exactly once, before the block's nodes run at all). This is what makes
  the once-per-block property observable through data rather than only
  through reference equality: a later node in the same block still evaluates
  against the pre-mutation snapshot.

  It lives in `test/support/` for the same reason `Statifier.TestContent`
  does: `elixirc_paths(:test)` (`mix.exs:36`) compiles this directory only
  under `MIX_ENV=test`, so the `defimpl` below consolidates in the test env
  and cannot reach `dev`/`prod`. No `mix.exs` change, therefore no ADR-0011
  ledger entry.

  This struct itself asserts no `lib/` behavior - it is harness plumbing,
  like `Statifier.TestContent` - so it carries no sabotage line of its own;
  the sabotage lines belong to the tests that use it, per
  `.claude/wurk/implement.md`'s sabotage protocol.
  """

  defstruct [:c_index, :label, put: nil]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          label: String.t(),
          put: map() | nil
        }

  # sabotage: n/a - harness plumbing, asserts no lib/ behavior
  defimpl Statifier.ExecutableContent do
    @moduledoc false

    alias Statifier.ContextRecorder
    alias Statifier.ExecutableContent.Context

    @spec execute(node :: ContextRecorder.t(), context :: Context.t()) ::
            Statifier.ExecutableContent.result()
    def execute(
          %ContextRecorder{label: label, put: nil},
          %Context{
            datamodel_context: datamodel_context
          } = context
        ) do
      {:ok, context,
       [
         {:log,
          %Statifier.Effect.Log{
            label: label,
            value: datamodel_context,
            macrostep: 0,
            microstep: 0
          }}
       ]}
    end

    def execute(
          %ContextRecorder{label: label, put: put},
          %Context{
            datamodel_context: datamodel_context,
            machine_state: machine_state
          } = context
        ) do
      new_machine_state = %{machine_state | datamodel: Map.merge(machine_state.datamodel, put)}
      new_context = %{context | machine_state: new_machine_state}

      {:ok, new_context,
       [
         {:log,
          %Statifier.Effect.Log{
            label: label,
            value: datamodel_context,
            macrostep: 0,
            microstep: 0
          }}
       ]}
    end
  end
end
