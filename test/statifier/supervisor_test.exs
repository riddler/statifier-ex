defmodule Statifier.SupervisorTest do
  use ExUnit.Case, async: false

  # `Statifier.Registry` and `Statifier.SessionSupervisor` are fixed,
  # module-qualified names (ADR-0027's "one instance, no `:name` option"),
  # so this module inspects the one runtime `test/test_helper.exs` places for
  # the whole run rather than starting its own. `async: false` keeps its
  # tests from tripping over each other on the assumption that no other
  # process crashes the shared runtime out from under them mid-run.

  describe "init/1" do
    # sabotage: `init/1`'s `Supervisor.init(children, strategy: :rest_for_one)`
    # is changed to `strategy: :one_for_one` -> the `sup_flags.strategy ==
    # :rest_for_one` assertion below reddens directly. Reverted and
    # confirmed green.
    test "declares :rest_for_one, with Registry ordered before the DynamicSupervisor" do
      assert {:ok, {sup_flags, [registry_spec, session_supervisor_spec]}} =
               Statifier.Supervisor.init(:unused)

      assert sup_flags.strategy == :rest_for_one
      assert registry_spec.id == Statifier.Registry
      assert session_supervisor_spec.id == Statifier.SessionSupervisor
    end
  end

  describe "start_link/1" do
    # sabotage: `init/1`'s children list is changed to hold only the
    # `Registry` entry (the `DynamicSupervisor` child is dropped) ->
    # `Process.whereis(Statifier.SessionSupervisor)` comes back `nil`,
    # reddening the second assertion below. Reverted and confirmed green.
    test "starts Statifier.Registry and Statifier.SessionSupervisor as named children" do
      assert is_pid(Process.whereis(Statifier.Registry))
      assert is_pid(Process.whereis(Statifier.SessionSupervisor))
    end
  end

  # Deliberately not a live "`Process.exit(registry_pid, :kill)` and watch
  # `Statifier.SessionSupervisor` go down too" test. Elixir's `Registry`
  # records its partition layout in `:persistent_term`, cleaned up by its
  # own `terminate/2` on a graceful stop; a `:kill` bypasses `terminate/2`
  # entirely, so the automatic restart attempt finds stale
  # `:persistent_term` state and fails immediately, exhausting
  # `Statifier.Supervisor`'s own restart intensity and taking the whole
  # tree down - which does demonstrate this module's `:rest_for_one` claim,
  # but leaves the stale `:persistent_term` entry (and the orphaned
  # `Statifier.Registry.PIDPartition0` name) behind for the rest of the
  # suite, non-deterministically breaking *other* tests that place
  # `Statifier.Supervisor` later, depending on run order/seed - verified by
  # running this file directly with several `--seed` values. The `init/1`
  # test above is what actually isolates the `:rest_for_one` vs
  # `:one_for_one` distinction (it inspects the declared strategy, which is
  # what determines this behavior, without living through a real crash),
  # and is the one this module keeps.
end
