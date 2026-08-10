defmodule Statifier.TestContent do
  @moduledoc """
  A test-only executable-content node, data-driven so one struct covers both
  jobs the protocol's acceptance criteria need:

  1. It proves open extension - a node struct defined entirely outside
     `lib/` implements `Statifier.ExecutableContent` and runs through the
     block runner untouched, with no central dispatcher anywhere to update.
  2. It is the failing node the stop-on-error criterion needs: the built-in
     `<raise>`/`<log>` executable-content nodes cannot fail, so a `fail: true`
     instance stands in for a node that returns `{:error, _}`, which is how
     the stop-on-error contract stays tested despite neither real node ever
     erroring.

  It lives in `test/support/` because `elixirc_paths(:test)` (`mix.exs:36`)
  compiles that directory into the app only under `MIX_ENV=test`, so this
  `defimpl` consolidates in the test env and cannot reach `dev`/`prod`. No
  `mix.exs` change, therefore no ADR-0011 ledger entry.

  Getting it in front of the runner: the runner resolves nodes through
  `Statifier.Machine.content/2`, so a test compiles a real document and then
  substitutes one cell -
  `%{machine | contents: put_elem(machine.contents, i, %TestContent{...})}` -
  which is a `Machine` built by the compiler with one cell replaced, not a
  `%Machine{}` literal, so it stays inside the convention that test fixtures
  come from the compiler pipeline rather than a hand-written struct.
  """

  defstruct [:c_index, :label, fail: false]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          label: String.t(),
          fail: boolean()
        }

  # sabotage: n/a - harness plumbing, asserts no lib/ behavior
  defimpl Statifier.ExecutableContent do
    @moduledoc false

    alias Statifier.ExecutableContent.Context
    alias Statifier.TestContent

    @spec execute(node :: TestContent.t(), context :: Context.t()) ::
            Statifier.ExecutableContent.result()
    def execute(%TestContent{fail: true, label: label}, %Context{}) do
      {:error, {:test_content, label}}
    end

    def execute(%TestContent{label: label}, %Context{} = context) do
      {:ok, context, [{:log, %Statifier.Effect.Log{label: label, macrostep: 0, microstep: 0}}]}
    end
  end
end
