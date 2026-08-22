# Reference `Statifier.Invoke.Handler` implementations for the conformance
# case's own tests. `Conformant` is the fully conforming shape: pure planning
# callbacks, and a `perform/2` made idempotent by set semantics in the test
# process's dictionary (the checks call `perform/2` in-process, so the
# dictionary is a real observation point and dies with the test). The others
# each violate exactly one clause of the contract, so the negative tests can
# assert the case catches that clause and nothing else.
defmodule Statifier.Testing.HandlerCaseTest.Conformant do
  @moduledoc false
  @behaviour Statifier.Invoke.Handler

  alias Statifier.Effect.Invoke

  @impl Statifier.Invoke.Handler
  def start(%Invoke{invoke_id: invoke_id, params: params}, _ctx),
    do: {:ok, [{:handler, __MODULE__, {:enqueue, invoke_id, params}}]}

  @impl Statifier.Invoke.Handler
  def cancel(invoke_id, _ctx), do: {:ok, [{:handler, __MODULE__, {:cancel, invoke_id}}]}

  @impl Statifier.Invoke.Handler
  def forward(invoke_id, event, _ctx),
    do: {:ok, [{:handler, __MODULE__, {:forward, invoke_id, event.name}}]}

  @impl Statifier.Invoke.Handler
  def perform({:enqueue, invoke_id, _params}, _ctx), do: put_effect(invoke_id, :enqueued)
  def perform({:cancel, invoke_id}, _ctx), do: put_effect(invoke_id, :cancelled)
  def perform({:forward, invoke_id, name}, _ctx), do: put_effect(invoke_id, {:forwarded, name})

  @spec observed(invoke_id :: String.t()) :: MapSet.t()
  def observed(invoke_id), do: Process.get({__MODULE__, invoke_id}, MapSet.new())

  defp put_effect(invoke_id, effect) do
    key = {__MODULE__, invoke_id}
    Process.put(key, MapSet.put(Process.get(key, MapSet.new()), effect))
    :ok
  end
end

defmodule Statifier.Testing.HandlerCaseTest.NonIdempotent do
  @moduledoc false
  # Violates check 2: each perform/2 call appends, so a replayed pass
  # duplicates the observable effects.
  @behaviour Statifier.Invoke.Handler

  alias Statifier.Effect.Invoke

  @impl Statifier.Invoke.Handler
  def start(%Invoke{invoke_id: invoke_id}, _ctx),
    do: {:ok, [{:handler, __MODULE__, {:enqueue, invoke_id}}]}

  @impl Statifier.Invoke.Handler
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def perform({:enqueue, invoke_id}, _ctx) do
    key = {__MODULE__, invoke_id}
    Process.put(key, [:enqueued | Process.get(key, [])])
    :ok
  end

  @spec observed(invoke_id :: String.t()) :: [atom()]
  def observed(invoke_id), do: Process.get({__MODULE__, invoke_id}, [])
end

defmodule Statifier.Testing.HandlerCaseTest.NondeterministicStart do
  @moduledoc false
  # Violates check 1: two identical start/2 calls plan different payloads.
  @behaviour Statifier.Invoke.Handler

  @impl Statifier.Invoke.Handler
  def start(_invoke, _ctx), do: {:ok, [{:handler, __MODULE__, make_ref()}]}

  @impl Statifier.Invoke.Handler
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}
end

defmodule Statifier.Testing.HandlerCaseTest.RaisingCancel do
  @moduledoc false
  # Violates check 3: cancel/2 raises for an invoke_id it never saw.
  @behaviour Statifier.Invoke.Handler

  @impl Statifier.Invoke.Handler
  def start(_invoke, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def cancel("inv_1", _ctx), do: {:ok, []}
  def cancel(invoke_id, _ctx), do: raise(ArgumentError, "unknown invocation #{invoke_id}")

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}
end

defmodule Statifier.Testing.HandlerCaseTest.PerformingStart do
  @moduledoc false
  # Violates check 1's effect-free half: start/2 performs during planning.
  @behaviour Statifier.Invoke.Handler

  alias Statifier.Effect.Invoke

  @impl Statifier.Invoke.Handler
  def start(%Invoke{invoke_id: invoke_id}, _ctx) do
    key = {__MODULE__, invoke_id}
    Process.put(key, [:started_eagerly | Process.get(key, [])])
    {:ok, []}
  end

  @impl Statifier.Invoke.Handler
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}

  @spec observed(invoke_id :: String.t()) :: [atom()]
  def observed(invoke_id), do: Process.get({__MODULE__, invoke_id}, [])
end

defmodule Statifier.Testing.HandlerCaseTest.NoPerform do
  @moduledoc false
  # The built-in scxml handler's own shape: no {:handler, _, _} instruction
  # ever planned, perform/2 not exported.
  @behaviour Statifier.Invoke.Handler

  @impl Statifier.Invoke.Handler
  def start(_invoke, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def cancel(_invoke_id, _ctx), do: {:ok, []}

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx), do: {:ok, []}
end

defmodule Statifier.Testing.HandlerCaseTest do
  use ExUnit.Case, async: true

  alias ExUnit.AssertionError
  alias Statifier.Invoke.Types
  alias Statifier.Testing.HandlerCase

  alias Statifier.Testing.HandlerCaseTest.{
    Conformant,
    NondeterministicStart,
    NonIdempotent,
    NoPerform,
    PerformingStart,
    RaisingCancel
  }

  @type_string "test:conformant"

  defp fixtures(handler) do
    {HandlerCase.build_invoke(@type_string), HandlerCase.build_ctx(@type_string, handler),
     HandlerCase.build_event()}
  end

  describe "fixture builders" do
    # sabotage: build_invoke/2 stops threading `type` into the defaults
    # (hardcodes `type: nil`) -> red
    test "build_invoke/2 carries the type and applies overrides" do
      invoke = HandlerCase.build_invoke(@type_string, params: %{"a" => 1})

      assert invoke.type == @type_string
      assert invoke.invoke_id == "inv_1"
      assert invoke.params == %{"a" => 1}
    end

    # sabotage: build_ctx/3 builds `invoke_types` with `Types.new()` (drops
    # the declared type) -> red
    test "build_ctx/3 declares the type registered and dispatches it to the handler" do
      ctx = HandlerCase.build_ctx(@type_string, Conformant, session_id: "sess_custom")

      assert Types.registered?(ctx.invoke_types, @type_string)
      assert ctx.invoke_handlers == %{@type_string => Conformant}
      assert ctx.session_id == "sess_custom"
    end

    # sabotage: build_event/1's defaults drop `name: "conformance.ping"`
    # for `name: "ping"` -> red
    test "build_event/1 builds an external event with overridable fields" do
      assert %Statifier.Event{name: "conformance.ping", type: :external} =
               HandlerCase.build_event()

      assert HandlerCase.build_event(name: "other").name == "other"
    end
  end

  describe "assert_start_contract/4" do
    # sabotage: assert_start_contract/4's shape assertion drops the
    # `{:ok, list}` arm (only `{:error, _}` accepted) -> red
    test "passes a conforming start/2" do
      {invoke, ctx, _event} = fixtures(Conformant)

      assert :ok ==
               HandlerCase.assert_start_contract(
                 Conformant,
                 invoke,
                 ctx,
                 &Conformant.observed/1
               )
    end

    # sabotage: assert_start_contract/4 compares `first == first` instead of
    # `first == second` -> the nondeterministic handler is no longer caught
    # -> red
    test "fails a nondeterministic start/2" do
      {invoke, ctx, _event} = fixtures(NondeterministicStart)

      assert_raise AssertionError, ~r/deterministic/, fn ->
        HandlerCase.assert_start_contract(
          NondeterministicStart,
          invoke,
          ctx,
          fn _invoke_id -> :unobserved end
        )
      end
    end

    # sabotage: assert_planning_left_no_trace/4 returns :ok unconditionally
    # (the unobserved guard is widened to every input) -> the eager perform
    # in start/2 goes unnoticed -> red
    test "fails a start/2 that performs during planning" do
      {invoke, ctx, _event} = fixtures(PerformingStart)

      assert_raise AssertionError, ~r/must not perform/, fn ->
        HandlerCase.assert_start_contract(
          PerformingStart,
          invoke,
          ctx,
          &PerformingStart.observed/1
        )
      end
    end
  end

  describe "assert_cancel_contract/4" do
    # sabotage: assert_cancel_contract/4's shape assertion inverts to
    # require `{:error, _}` -> red
    test "passes a conforming cancel/2, unknown invoke_id included" do
      {invoke, ctx, _event} = fixtures(Conformant)

      assert :ok ==
               HandlerCase.assert_cancel_contract(
                 Conformant,
                 invoke,
                 ctx,
                 &Conformant.observed/1
               )
    end

    # sabotage: assert_cancel_contract/4 probes the unknown-id arm with
    # `invoke.invoke_id` instead of `@unknown_invoke_id` -> RaisingCancel's
    # known-id clause answers and nothing raises -> red
    test "flunks a cancel/2 that raises for an unknown invoke_id" do
      {invoke, ctx, _event} = fixtures(RaisingCancel)

      assert_raise AssertionError, ~r/never a raise/, fn ->
        HandlerCase.assert_cancel_contract(
          RaisingCancel,
          invoke,
          ctx,
          fn _invoke_id -> :unobserved end
        )
      end
    end
  end

  describe "assert_forward_contract/5" do
    # sabotage: assert_forward_contract/5's shape assertion inverts to
    # require `{:error, _}` -> red
    test "passes a conforming forward/3" do
      {invoke, ctx, event} = fixtures(Conformant)

      assert :ok ==
               HandlerCase.assert_forward_contract(
                 Conformant,
                 invoke,
                 ctx,
                 event,
                 &Conformant.observed/1
               )
    end
  end

  describe "assert_perform_idempotent/5" do
    # sabotage: assert_perform_idempotent/5's final comparison inverts to
    # `once != twice` -> the idempotent reference handler now fails -> red
    test "passes an idempotent perform/2" do
      {invoke, ctx, event} = fixtures(Conformant)

      assert :ok ==
               HandlerCase.assert_perform_idempotent(
                 Conformant,
                 invoke,
                 ctx,
                 event,
                 &Conformant.observed/1
               )

      # The lifecycle really was performed - twice, with set semantics.
      assert Conformant.observed("inv_1") ==
               MapSet.new([:enqueued, :cancelled, {:forwarded, "conformance.ping"}])
    end

    # sabotage: assert_perform_idempotent/5 reads `twice` from the same
    # snapshot as `once` (never re-observes after the second pass) -> the
    # duplicate-appending handler is no longer caught -> red
    test "fails a perform/2 that duplicates effects on a replayed pass" do
      {invoke, ctx, event} = fixtures(NonIdempotent)

      assert_raise AssertionError, ~r/idempotent on invoke_id/, fn ->
        HandlerCase.assert_perform_idempotent(
          NonIdempotent,
          invoke,
          ctx,
          event,
          &NonIdempotent.observed/1
        )
      end
    end

    # sabotage: the `:unobserved` flunk branch's guard compares against
    # `:never_matches` instead -> the missing observation point is waved
    # through into perform/observe with no failure -> red
    test "flunks naming observed_effects/1 when the handler performs but nothing is observed" do
      {invoke, ctx, event} = fixtures(Conformant)

      assert_raise AssertionError, ~r/observed_effects\/1/, fn ->
        HandlerCase.assert_perform_idempotent(
          Conformant,
          invoke,
          ctx,
          event,
          fn _invoke_id -> :unobserved end
        )
      end
    end

    # sabotage: the `instructions == []` early arm is removed (everything
    # falls through to the observation-point requirement) -> NoPerform now
    # flunks despite routing nothing to perform/2 -> red
    test "asserts trivially for a handler that routes nothing to perform/2" do
      {invoke, ctx, event} = fixtures(NoPerform)

      assert :ok ==
               HandlerCase.assert_perform_idempotent(
                 NoPerform,
                 invoke,
                 ctx,
                 event,
                 fn _invoke_id -> :unobserved end
               )
    end
  end

  describe "assert_erroring_start/3" do
    # sabotage: assert_erroring_start/3's match inverts to expect
    # `{:ok, _}` -> red
    test "accepts a deterministic {:error, _} and rejects a succeeding start/2" do
      {invoke, ctx, _event} = fixtures(HandlerCase.FailingStart)

      assert :ok == HandlerCase.assert_erroring_start(HandlerCase.FailingStart, invoke, ctx)

      {invoke, ctx, _event} = fixtures(Conformant)

      assert_raise AssertionError, ~r/\{:error, term\}/, fn ->
        HandlerCase.assert_erroring_start(Conformant, invoke, ctx)
      end
    end
  end
end

# The whole case, `use`d the way a downstream handler suite would - the
# seven generated tests run here against the conforming reference handler.
#
# The two chart-driven library pins the `use` generates were sabotage-
# verified against the library code they cover (no literal `test` blocks
# exist here for the scanner to demand notes on, but the protocol still
# applies):
# - `Statifier.Session.Effects.plan_invoke/3`'s `{:error, _reason}` arm
#   changed to plan `[]` instead of the error.execution raise -> the
#   "{:error, _} from start/2 surfaces as error.execution" test reddens
#   (the probe chart never leaves "invoking"). Reverted and confirmed
#   green.
# - `Statifier.Session.Effects.plan_invoke/3`'s `start/2` dispatch wrapped
#   in `try/rescue` returning the error.execution instruction -> the
#   "handler exceptions propagate" test reddens (the session survives the
#   probe's raise, so no EXIT ever arrives). Reverted and confirmed green.
defmodule Statifier.Testing.HandlerCaseConformantTest do
  use ExUnit.Case, async: true

  use Statifier.Testing.HandlerCase,
    handler: Statifier.Testing.HandlerCaseTest.Conformant,
    type: "test:conformant"

  alias Statifier.Testing.HandlerCaseTest.Conformant

  @spec observed_effects(invoke_id :: String.t()) :: MapSet.t()
  def observed_effects(invoke_id), do: Conformant.observed(invoke_id)
end
