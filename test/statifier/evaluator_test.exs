defmodule Statifier.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Predicator.Errors.EvaluationError
  alias Predicator.Errors.TypeMismatchError
  alias Predicator.Errors.UndefinedVariableError
  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.Evaluator.Error
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
      <state id="s1"/>
      <state id="s2"/>
  </scxml>
  """

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp machine, do: compile!(@document)
  defp idx(machine, id), do: Machine.index(machine, id) |> elem(1)

  defp new_machine_state(opts \\ []) do
    machine = machine()
    ms = MachineState.new(machine, opts)

    case Keyword.get(opts, :configuration) do
      nil -> ms
      configuration -> %{ms | configuration: configuration}
    end
  end

  # `MachineState.new/2` has no `:configuration` option, so this builds one
  # directly with `s1` active - the fixture every `In/1` test starts from.
  defp machine_state_with_s1_active do
    machine = machine()
    ms = MachineState.new(machine)
    %{ms | configuration: MapSet.new([idx(machine, "s1")])}
  end

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  defp program(source) do
    {:ok, compiled} = Predicator.compile_program_with_positions(source)
    {:program, compiled, source}
  end

  describe "evaluate/2 - {:static, v}" do
    # sabotage: `evaluate/2`'s static clause routes the value through
    # `Predicator.evaluate/3` instead of returning it untouched -> a static
    # `nil` comes back normalized to `:undefined` instead of `nil`, and this
    # assertion reddens.
    test "returns the value untouched, with no predicator normalization" do
      context = Evaluator.context(new_machine_state())

      assert Evaluator.evaluate(context, {:static, nil}) == {:ok, nil}
      assert Evaluator.evaluate(context, {:static, %{a: 1}}) == {:ok, %{a: 1}}
      assert Evaluator.evaluate(context, {:static, :some_atom}) == {:ok, :some_atom}
    end
  end

  describe "evaluate/2 - {:compiled, _, _}" do
    # sabotage: `evaluate/2`'s compiled clause always returns `{:ok, false}`
    # regardless of `Predicator.evaluate/3`'s result -> this assertion
    # reddens because `score > 80` is true against the bound datamodel.
    test "evaluates true against a bound datamodel" do
      ms = new_machine_state(datamodel: %{"score" => 85})
      context = Evaluator.context(ms)

      assert Evaluator.evaluate(context, compiled_expr("score > 80")) == {:ok, true}
    end

    # sabotage: `evaluate/2`'s compiled clause always returns `{:ok, true}`
    # regardless of `Predicator.evaluate/3`'s result -> this assertion
    # reddens because `score < 80` is false against the bound datamodel.
    test "evaluates false against a bound datamodel" do
      ms = new_machine_state(datamodel: %{"score" => 85})
      context = Evaluator.context(ms)

      assert Evaluator.evaluate(context, compiled_expr("score < 80")) == {:ok, false}
    end

    # sabotage: `context/1` builds the context with `on_unbound: :undefined`
    # instead of `:error` -> `score OR true` no longer fails on the unbound
    # load; three-valued logic absorbs `score`'s `:undefined` and the whole
    # expression evaluates to `{:ok, true}` instead of erroring, so the
    # pattern match below fails to match an `{:error, _}` tuple. (A bare
    # `score` alone does not distinguish the two policies here - predicator
    # reports the same unbound-variable error either way when the *whole*
    # expression's result is `:undefined` - so this test deliberately uses
    # an expression whose result differs by policy.)
    test "an unbound root variable returns an error with a non-nil span" do
      context = Evaluator.context(new_machine_state())

      assert {:error,
              %Error{
                source: "score OR true",
                error: %UndefinedVariableError{variable: "score"},
                span: span
              }} =
               Evaluator.evaluate(context, compiled_expr("score OR true"))

      refute is_nil(span)
    end

    # sabotage: `evaluate/2`'s compiled clause returns `{:ok, error}` instead
    # of `{:error, Error.new(source, error)}` on predicator's error branch ->
    # this pattern match fails because the outer tag is `:ok`, not `:error`.
    test "a type mismatch returns an error carrying predicator's TypeMismatchError" do
      context = Evaluator.context(new_machine_state())

      assert {:error, %Error{error: %TypeMismatchError{}}} =
               Evaluator.evaluate(context, compiled_expr("1 * \"a\""))
    end

    # sabotage: `in_function/1`'s matched-id branch is swapped to always
    # return `{:ok, false}` -> `In("s1")` against a configuration containing
    # `s1` comes back false, and this assertion reddens.
    test "In/1 is true for a state in the configuration" do
      context = Evaluator.context(machine_state_with_s1_active())

      assert Evaluator.evaluate(context, compiled_expr("In('s1')")) == {:ok, true}
    end

    # sabotage: `in_function/1`'s matched-id branch is swapped to always
    # return `{:ok, true}` -> `In("s2")` against a configuration that does
    # not contain `s2` comes back true, and this assertion reddens.
    test "In/1 is false for a declared state that is not in the configuration" do
      context = Evaluator.context(machine_state_with_s1_active())

      assert Evaluator.evaluate(context, compiled_expr("In('s2')")) == {:ok, false}
    end

    # sabotage: `in_function/1`'s `:error` branch (from `Machine.index/2`) is
    # changed to `{:ok, true}` -> `In/1` on an id the document never
    # declared comes back true, and this assertion reddens. This is the only
    # test that reaches that branch - `Machine.index/2` returns `:error` only
    # for an id absent from `id_to_index`.
    test "In/1 is false for an id the machine never declared" do
      context = Evaluator.context(machine_state_with_s1_active())

      assert Evaluator.evaluate(context, compiled_expr("In('no-such-state')")) == {:ok, false}
    end

    # sabotage: `in_function/1` is changed to stash `configuration` in a
    # process-dictionary slot shared across every `context/1` call instead of
    # closing over it locally -> building `ctx2` overwrites the slot `ctx1`'s
    # closure also reads from, so re-evaluating `in_s2` against `ctx1` after
    # `ctx2` exists answers against `s2`'s configuration instead of `s1`'s,
    # and the final assertion reddens.
    test "the built context is a snapshot: a later configuration change needs a new context/1 call" do
      machine = machine()
      ms = MachineState.new(machine)
      ms_s1 = %{ms | configuration: MapSet.new([idx(machine, "s1")])}
      ctx1 = Evaluator.context(ms_s1)
      in_s2 = compiled_expr("In('s2')")

      assert Evaluator.evaluate(ctx1, in_s2) == {:ok, false}

      ms_s2 = %{ms | configuration: MapSet.new([idx(machine, "s2")])}
      ctx2 = Evaluator.context(ms_s2)

      assert Evaluator.evaluate(ctx2, in_s2) == {:ok, true}
      # ctx1 was built before the move and still answers against the old
      # configuration - it is not rebuilt by the mutation on `ms_s2`.
      assert Evaluator.evaluate(ctx1, in_s2) == {:ok, false}
    end

    # sabotage: `evaluate/2`'s compiled clause matches `{:error, error}` and
    # instead raises via `error.error` (a bare `raise error` on the
    # predicator error struct) -> `Predicator.evaluate/3`'s own division-by-
    # zero error propagates as a raised exception, and the surrounding
    # `assert {:error, _} = ...` crashes the test process rather than
    # matching.
    test "never raises: a division-by-zero expression returns an error tuple" do
      context = Evaluator.context(new_machine_state())

      assert {:error, %Error{error: %EvaluationError{reason: "division_by_zero"}}} =
               Evaluator.evaluate(context, compiled_expr("1 / 0"))
    end
  end

  describe "evaluate/2 - system variables before any event" do
    # sabotage: `SystemVariables.initial/2` drops its `"_event" => :undefined`
    # entry -> `_event` is absent from the datamodel, so `on_unbound: :error`
    # makes this an `{:error, %UndefinedVariableError{variable: "_event"}}`
    # instead of the undefined value, reddening both assertions.
    test "_event is declared-but-undefined, not an unbound variable" do
      context = Evaluator.context(new_machine_state())

      assert Evaluator.evaluate(context, compiled_expr("_event")) == {:ok, :undefined}
      assert Evaluator.evaluate(context, compiled_expr("_event.data")) == {:ok, :undefined}
    end

    # sabotage: `SystemVariables.initial/2` drops `"_event" => :undefined` ->
    # the comparison's left side errors before any comparison happens, so this
    # returns an `{:error, _}` rather than `{:ok, false}`.
    #
    # This is the shape the W3C corpus tests boundness with (test319): a
    # machine that has processed no event must decide `_event` is *not*
    # bound and take the `<else>` branch. A comparison that errors takes
    # neither branch.
    test "an unbound-probe comparison against _event evaluates rather than erroring" do
      context = Evaluator.context(new_machine_state())

      assert Evaluator.evaluate(
               context,
               compiled_expr("_event !== _ioprocessors.__absent__")
             ) == {:ok, false}
    end

    # sabotage: `MachineState.put_event/2` writes the raw `%Event{}` instead
    # of `SystemVariables.event/1`'s map -> `_event.name` no longer resolves
    # through map access and this reddens.
    test "put_event/2 replaces the seeded undefined with the event's own fields" do
      context =
        new_machine_state()
        |> MachineState.put_event(Statifier.Event.external("go"))
        |> Evaluator.context()

      assert Evaluator.evaluate(context, compiled_expr("_event.name")) == {:ok, "go"}
      # Absent event data stays undefined rather than becoming `%{}` - the
      # property `tools/corpus/scxml_w3/exclusions.exs:7-11` depends on.
      # `Event.external/2` itself now spells "no data" as `:undefined`
      # (ADR-0037, docs/adr/0037-unbound-spelled-undefined-at-the-writer.md);
      # a caller that means a genuinely null payload passes `data: nil`
      # explicitly (see Phase 3's sibling test once `undefine_nils/1` is
      # retired, which reads that case's `=== null` answer).
      assert Evaluator.evaluate(context, compiled_expr("_event.data")) == {:ok, :undefined}
    end
  end

  describe "execute/2" do
    # sabotage: in execute/2, merge `machine_state.datamodel` unchanged
    # instead of `Map.merge(machine_state.datamodel, non_system_changed)` ->
    # a successful program's own write never reaches the returned
    # machine_state, and this assertion reddens.
    test "a successful program merges its write into the returned machine_state" do
      ms = new_machine_state(datamodel: %{"x" => nil})

      assert {:ok, new_ms} = Evaluator.execute(ms, program("x = 1;"))
      assert new_ms.datamodel["x"] == 1
    end

    # sabotage: on the error branch, return the original `machine_state`
    # instead of `new_machine_state` (the one with the partial merge already
    # applied) -> the write `x = 1;` made before `nope` failed is discarded,
    # and this assertion reddens.
    test "a mid-program failure keeps the earlier write and reports the error" do
      ms = new_machine_state(datamodel: %{"x" => nil, "y" => nil})

      assert {:error, new_ms, %Error{error: %UndefinedVariableError{variable: "nope"}}} =
               Evaluator.execute(ms, program("x = 1; y = nope + 1;"))

      assert new_ms.datamodel["x"] == 1
      assert new_ms.datamodel["y"] == nil
    end

    # sabotage: in partition_changed_roots/2, require `Map.has_key?(before,
    # key)` before a root counts as changed -> a root the program creates
    # (absent from `before`) is filtered out of the diff entirely, and this
    # assertion reddens.
    test "a program may create a new top-level root no <datamodel> declared" do
      ms = new_machine_state(datamodel: %{})

      assert {:ok, new_ms} = Evaluator.execute(ms, program("newvar = 42;"))
      assert new_ms.datamodel["newvar"] == 42
    end

    # sabotage: swap partition_changed_roots/2's `String.starts_with?(root,
    # "_")` predicate for its negation -> a system root merges while a
    # non-system root from the same program is rejected instead, and this
    # test's shape inverts.
    test "a system-variable write is rejected, keeping the same program's other writes" do
      ms = new_machine_state(datamodel: %{"x" => nil})

      assert {:error, new_ms, {:system_variable, "_event"}} =
               Evaluator.execute(ms, program("_event = 1; x = 2;"))

      assert new_ms.datamodel["x"] == 2
      assert new_ms.datamodel["_event"] == :undefined
    end

    # sabotage: in execute/2, merge `after_data` wholesale instead of just
    # `non_system_changed` -> `z`, never mentioned by the program, comes back
    # `:undefined` (context/1's normalization) instead of staying `nil`, and
    # this assertion reddens.
    test "an untouched nil root stays nil after a successful program" do
      ms = new_machine_state(datamodel: %{"z" => nil, "x" => nil})

      assert {:ok, new_ms} = Evaluator.execute(ms, program("x = 1;"))
      assert new_ms.datamodel["z"] == nil
    end

    # sabotage: in `context/1`, drop the `functions: %{"In" => ...}` option
    # from the `Predicator.Context.new/2` call it makes on `execute/2`'s
    # behalf -> a fresh context built from the post-run machine_state can no
    # longer resolve `In/1`, and this assertion reddens.
    test "In/1 still answers after a program run, against a freshly built context" do
      ms = machine_state_with_s1_active()

      assert {:ok, new_ms} = Evaluator.execute(ms, program("x = 1;"))

      context = Evaluator.context(new_ms)
      assert Evaluator.evaluate(context, compiled_expr("In('s1')")) == {:ok, true}
    end
  end

  describe "run_program/2" do
    # sabotage: `run_program/2`'s success clause returns
    # `{:ok, new_machine_state, predicator_context}` (the pre-run context)
    # instead of `post_context` -> `post_context`'s caller-facing promise
    # (the run's own writes are visible on it) breaks, and evaluating "x"
    # against it answers `:undefined` (its pre-run, declared-but-unbound
    # value) instead of `1`, reddening the second assertion.
    test "returns the post-run context alongside the merged machine_state" do
      ms = new_machine_state(datamodel: %{"x" => nil})

      assert {:ok, new_ms, post_context} = Evaluator.run_program(ms, program("x = 1;"))
      assert new_ms.datamodel["x"] == 1
      assert Evaluator.evaluate(post_context, compiled_expr("x")) == {:ok, 1}
    end
  end

  describe "bind/3" do
    # sabotage: `bind/3` calls `Predicator.Context.bind(context, root, value)`
    # without `undefine_nils/1` -> the bound `nil` stays predicator 6.x's
    # own null literal instead of normalizing to `:undefined`, and
    # evaluating `y` returns `{:ok, nil}` instead of `{:ok, :undefined}`,
    # reddening this assertion.
    test "normalizes a bound nil to :undefined, matching context/1" do
      context = Evaluator.context(new_machine_state())

      bound = Evaluator.bind(context, "y", nil)

      assert Evaluator.evaluate(bound, compiled_expr("y")) == {:ok, :undefined}
    end

    # sabotage: `bind/3` is changed to build a brand-new
    # `Predicator.Context.new(%{root => undefine_nils(value)}, ...)` instead
    # of calling `Predicator.Context.bind/3` on the existing context -> every
    # key but the just-bound one is lost, and evaluating "b" or "c.d"
    # against the bound context answers `{:error, %UndefinedVariableError{}}`
    # instead of matching the rebuilt context's answer, reddening the last
    # two assertions.
    test "a bound context answers identically to a rebuilt one for every key, not just the bound one" do
      ms = new_machine_state(datamodel: %{"a" => 1, "b" => nil, "c" => %{"d" => 2}})
      context = Evaluator.context(ms)

      bound = Evaluator.bind(context, "a", 42)

      rebuilt =
        Evaluator.context(%{ms | datamodel: %{"a" => 42, "b" => nil, "c" => %{"d" => 2}}})

      assert Evaluator.evaluate(bound, compiled_expr("a")) ==
               Evaluator.evaluate(rebuilt, compiled_expr("a"))

      assert Evaluator.evaluate(bound, compiled_expr("b")) ==
               Evaluator.evaluate(rebuilt, compiled_expr("b"))

      assert Evaluator.evaluate(bound, compiled_expr("c.d")) ==
               Evaluator.evaluate(rebuilt, compiled_expr("c.d"))
    end

    # sabotage: `bind/3` is changed to build a fresh
    # `Predicator.Context.new(%{root => undefine_nils(value)}, ...)` with no
    # `functions:` option instead of calling `Predicator.Context.bind/3` on
    # the existing context -> `In/1` is no longer resolvable on the bound
    # context, and evaluating `In('s1')` returns an `{:error, _}` (an
    # undefined-function failure) instead of `{:ok, true}`, reddening this
    # assertion.
    test "In/1 still resolves against the block's configuration after a bind" do
      context = Evaluator.context(machine_state_with_s1_active())

      bound = Evaluator.bind(context, "x", 1)

      assert Evaluator.evaluate(bound, compiled_expr("In('s1')")) == {:ok, true}
    end

    # sabotage: `bind/3` is changed to build a fresh
    # `Predicator.Context.new(%{root => undefine_nils(value)}, on_unbound:
    # :undefined)` instead of calling `Predicator.Context.bind/3`, which
    # would have carried the existing context's `on_unbound: :error` policy
    # over unchanged -> an unbound load of "nope" answers `{:ok, :undefined}`
    # instead of failing, reddening this pattern match.
    test "on_unbound: :error survives a bind, still failing an unbound load" do
      context = Evaluator.context(new_machine_state())

      bound = Evaluator.bind(context, "x", 1)

      assert {:error, %Error{error: %UndefinedVariableError{variable: "nope"}}} =
               Evaluator.evaluate(bound, compiled_expr("nope"))
    end

    # sabotage: `bind/3` is changed to call `undefine_nils/1` only on
    # `value` itself, bypassing its recursive map clause (as if it were
    # `if is_nil(value), do: :undefined, else: value` instead of a full
    # deep walk) -> the nested `nil` inside `%{"inner" => nil}` is never
    # normalized, and evaluating `obj.inner` returns `{:ok, nil}` instead of
    # `{:ok, :undefined}`, reddening this assertion.
    test "binding a value with a nested nil normalizes the nested nil too" do
      context = Evaluator.context(new_machine_state())

      bound = Evaluator.bind(context, "obj", %{"inner" => nil})

      assert Evaluator.evaluate(bound, compiled_expr("obj.inner")) == {:ok, :undefined}
    end

    # sabotage: `bind/3`'s `is_binary(root)` guard is dropped along with the
    # whole clause head, replaced with a catch-all that ignores `root` and
    # always binds under the literal name `"root"` -> a genuinely new root
    # name like "brand_new" is never actually written, and evaluating it
    # answers `{:error, %UndefinedVariableError{}}` instead of `{:ok, 7}`,
    # reddening this assertion.
    test "binding a root not present in the context adds it, readable afterward" do
      context = Evaluator.context(new_machine_state())

      bound = Evaluator.bind(context, "brand_new", 7)

      assert Evaluator.evaluate(bound, compiled_expr("brand_new")) == {:ok, 7}
    end
  end

  describe "context/1 - the provider/host seam (st-l0t)" do
    # sabotage: `context/1` gains an extra `functions: %{"Sabotage" => {0,
    # fn _args, _ctx -> {:ok, true} end}}` option alongside `providers:` ->
    # the `:functions` option merges unvalidated, so a raw `function()`
    # value lands in the resolved map, and the `is_function/1` check below
    # finds it, reddening this assertion.
    test "a built context holds no function() value anywhere in its functions map" do
      context = Evaluator.context(machine_state_with_s1_active())

      for {_name, {_arity, entry}} <- context.functions do
        refute is_function(entry),
               "expected every functions entry to be an {module, atom} pair, got: #{inspect(entry)}"
      end
    end

    # sabotage: `context/1` is changed to set `host: machine_state.machine`
    # (dropping `configuration` from the tuple) instead of
    # `{machine_state.machine, machine_state.configuration}` -> `context.host`
    # is a bare `%Statifier.Machine{}` instead of a 2-tuple, and the pattern
    # match on `{machine, configuration}` below fails to match, reddening
    # this assertion.
    test "context.host is {machine, configuration}, matching machine_state" do
      ms = machine_state_with_s1_active()
      context = Evaluator.context(ms)

      assert {machine, configuration} = context.host
      assert machine == ms.machine
      assert configuration == ms.configuration
    end

    # sabotage: `Statifier.Evaluator.Functions.in_state/2`'s body is changed
    # to always return `{:ok, false}` regardless of what `host` says ->
    # `put_host/2`'s new `s2`-active configuration is never consulted, and
    # `In('s2')` stays `{:ok, false}` instead of moving to `{:ok, true}`,
    # reddening the final assertion.
    test "put_host/2 changes In/1's answer without rebuilding the context" do
      machine = machine()
      ms_s1 = %{MachineState.new(machine) | configuration: MapSet.new([idx(machine, "s1")])}
      context = Evaluator.context(ms_s1)
      in_s2 = compiled_expr("In('s2')")

      assert Evaluator.evaluate(context, in_s2) == {:ok, false}

      s2_configuration = MapSet.new([idx(machine, "s2")])
      refreshed = Predicator.Context.put_host(context, {machine, s2_configuration})

      assert Evaluator.evaluate(refreshed, in_s2) == {:ok, true}
    end

    # sabotage: `context/1` is changed to fold `bind/3` starting from
    # `Predicator.Context.new(%{}, ...)` instead of
    # `Statifier.Evaluator.Functions.base_context()` -> `on_unbound` reverts
    # to its `:undefined` default (`new/2`'s own default, never overridden by
    # this alternate construction), so `data` and `functions` still agree
    # but `on_unbound` diverges, reddening the third assertion below. This is
    # "the test to write first": the whole safety argument for bypassing
    # `new/2` is that folding `bind/3` over a compile-time base produces the
    # identical context `new/2` would have, for every shape `undefine_nils/1`
    # and `normalize_value/1` disagree about - nested maps, lists, a nil
    # root, a nested nil, a non-string scalar, and `_event`.
    test "context/1 builds a context equivalent to a direct new/2 call, for a representative datamodel" do
      datamodel = %{
        "score" => 85,
        "tags" => ["a", "b", nil],
        "profile" => %{"name" => "ok", "note" => nil, "nested" => %{"deep" => nil}},
        "root_nil" => nil,
        "flag" => true,
        "_event" => nil
      }

      ms = new_machine_state(datamodel: datamodel)
      built = Evaluator.context(ms)

      reference =
        Predicator.Context.new(
          deep_undefine_nils(ms.datamodel),
          providers: [Statifier.Evaluator.Functions],
          host: {ms.machine, ms.configuration},
          on_unbound: :error
        )

      assert built.data == reference.data
      assert built.on_unbound == reference.on_unbound
      assert built.functions == reference.functions
      assert built.host == reference.host
    end
  end

  # Mirrors `Statifier.Evaluator`'s own private `undefine_nils/1`, so the
  # equivalence test above can build the same "nil -> :undefined,
  # recursively" reference shape `Predicator.Context.new/2` would receive
  # through `Evaluator.context/1`, without reaching into a private function.
  defp deep_undefine_nils(nil), do: :undefined
  defp deep_undefine_nils(list) when is_list(list), do: Enum.map(list, &deep_undefine_nils/1)

  defp deep_undefine_nils(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, deep_undefine_nils(value)} end)
  end

  defp deep_undefine_nils(other), do: other

  describe "put_configuration/2" do
    # sabotage: `put_configuration/2` is changed to call
    # `Predicator.Context.put_host(context, machine_state.machine)` (dropping
    # `configuration` from the tuple) -> `context.host` becomes a bare
    # `%Statifier.Machine{}` instead of `{machine, configuration}`, and
    # evaluating `In('s2')` against it errors instead of answering `true`,
    # reddening the second assertion.
    test "changes In/1's answer and leaves data, functions, and on_unbound untouched" do
      machine = machine()
      ms_s1 = %{MachineState.new(machine) | configuration: MapSet.new([idx(machine, "s1")])}
      context = Evaluator.context(ms_s1)

      assert Evaluator.evaluate(context, compiled_expr("In('s2')")) == {:ok, false}

      ms_s2 = %{ms_s1 | configuration: MapSet.new([idx(machine, "s2")])}
      refreshed = Evaluator.put_configuration(context, ms_s2)

      assert Evaluator.evaluate(refreshed, compiled_expr("In('s2')")) == {:ok, true}
      assert refreshed.data == context.data
      assert refreshed.functions == context.functions
      assert refreshed.on_unbound == context.on_unbound
    end
  end
end
