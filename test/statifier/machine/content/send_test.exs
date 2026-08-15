defmodule Statifier.Machine.Content.SendTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.Datamodel
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # One state per attribute/failure variant under test, each with a single
  # <send> in its own <onentry> - the same "one c_index per named state"
  # shape `content_acceptance_test.exs` uses. `p1`/`p2`/`loc` are declared
  # datamodel roots: `p1`/`p2` so namelist/<param>/<content expr> have
  # something to read, `loc` so `idlocation` has a pre-declared root to
  # write into (`Interpreter.Datamodel.write_location/4`'s step 3).
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="bare">
      <datamodel>
          <data id="ev" expr="'dyn_event'"/>
          <data id="tgt" expr="'dyn_target'"/>
          <data id="typ" expr="'dyn_type'"/>
          <data id="p1" expr="10"/>
          <data id="p2" expr="20"/>
          <data id="loc"/>
          <data id="Var1"/>
      </datamodel>
      <state id="bare"><onentry><send event="ping"/></onentry></state>
      <state id="eventexpr"><onentry><send eventexpr="ev"/></onentry></state>
      <state id="target"><onentry><send event="e" target="t1"/></onentry></state>
      <state id="targetexpr"><onentry><send event="e" targetexpr="tgt"/></onentry></state>
      <state id="type"><onentry><send event="e" type="ty1"/></onentry></state>
      <state id="typeexpr"><onentry><send event="e" typeexpr="typ"/></onentry></state>
      <state id="namelist"><onentry><send event="e" namelist="p1 p2"/></onentry></state>
      <state id="namelist_unbound"><onentry><send event="e" namelist="Var1"/></onentry></state>
      <state id="namelist_undeclared">
          <onentry><send event="e" namelist="Undeclared"/></onentry>
      </state>
      <state id="param">
          <onentry><send event="e"><param name="a" expr="p1"/></send></onentry>
      </state>
      <state id="content_text">
          <onentry><send event="e"><content>hello</content></send></onentry>
      </state>
      <state id="content_expr">
          <onentry><send event="e"><content expr="p1"/></send></onentry>
      </state>
      <state id="content_null">
          <onentry>
              <send event="e"><content>{"foo": null, "bar": 1}</content></send>
          </onentry>
      </state>
      <state id="delay_frac"><onentry><send event="e" delay="1.5s"/></onentry></state>
      <state id="delay_leaddot"><onentry><send event="e" delay=".5s"/></onentry></state>
      <state id="delayexpr_string">
          <onentry><send event="e" delayexpr="'250ms'"/></onentry>
      </state>
      <state id="delayexpr_duration">
          <onentry><send event="e" delayexpr="2s"/></onentry>
      </state>
      <state id="id_literal"><onentry><send event="e" id="myid"/></onentry></state>
      <state id="id_generated"><onentry><send event="e"/></onentry></state>
      <state id="idlocation"><onentry><send event="e" idlocation="loc"/></onentry></state>
      <state id="fail_eventexpr"><onentry><send eventexpr="nope"/></onentry></state>
      <state id="fail_param">
          <onentry><send event="e"><param name="a" expr="nope"/></send></onentry>
      </state>
      <state id="fail_content_expr">
          <onentry><send event="e"><content expr="nope"/></send></onentry>
      </state>
      <state id="fail_idlocation"><onentry><send event="e" idlocation="_sessionid"/></onentry></state>
  </scxml>
  """

  defp machine, do: compile!(@document)
  defp idx(machine, name), do: machine |> Machine.index(name) |> elem(1)

  defp send_node(machine, name) do
    [block] = Machine.at(machine, idx(machine, name)).onentry
    [c_index] = block.content
    Machine.content(machine, c_index)
  end

  defp machine_state(m, opts \\ []) do
    m |> MachineState.new(opts) |> Datamodel.initialize()
  end

  defp context(ms, owner \\ {:onentry, 0, 0}) do
    %Context{machine_state: ms, owner: owner, datamodel_context: Evaluator.context(ms)}
  end

  describe "execute/2 - bare event and *expr variants" do
    # sabotage: `Send`'s `execute/2` reads `node.target` where it should
    # read `node.event` (arguments swapped in the `with`'s first two
    # clauses) -> this test's `event: "ping"` assertion reddens
    test "a bare event resolves to Effect.Send with event set" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "bare")

      assert {:ok, _ctx, [{:send, %Effect.Send{event: "ping", target: nil, type: nil}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `resolve_expr/2`'s non-nil clause is changed to
    # `Evaluator.evaluate(datamodel_context, {:static, nil})` (ignoring the
    # passed `expr`) -> `eventexpr="ev"` would resolve to `nil` instead of
    # `"dyn_event"`, reddening this test.
    test "eventexpr evaluates against the datamodel" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "eventexpr")

      assert {:ok, _ctx, [{:send, %Effect.Send{event: "dyn_event"}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `Send`'s `execute/2` reads `node.event` where it should
    # read `node.target` (the second `with` clause reuses the first's
    # expression instead of its own) -> `target="t1"` would resolve to
    # `nil` (there is no `event` written on the "target" fixture) instead of
    # `"t1"`, reddening this test's first assertion.
    test "target and target expr both resolve" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{target: "t1"}}]} =
               ExecutableContent.execute(send_node(m, "target"), context(ms))

      assert {:ok, _ctx, [{:send, %Effect.Send{target: "dyn_target"}}]} =
               ExecutableContent.execute(send_node(m, "targetexpr"), context(ms))
    end

    # sabotage: `Send`'s `execute/2` `with` clause for `type` reads
    # `node.target` instead of `node.type` -> `type="ty1"` would resolve to
    # `nil` (the "type" fixture writes no `target`) instead of `"ty1"`,
    # reddening this test's first assertion.
    test "type and typeexpr both resolve" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{type: "ty1"}}]} =
               ExecutableContent.execute(send_node(m, "type"), context(ms))

      assert {:ok, _ctx, [{:send, %Effect.Send{type: "dyn_type"}}]} =
               ExecutableContent.execute(send_node(m, "typeexpr"), context(ms))
    end
  end

  describe "execute/2 - data (namelist, <param>, <content>)" do
    # sabotage: `resolve_params/2`'s accumulator is changed from
    # `[{name, value} | pairs]` to `pairs` (dropping the pair) -> `data`
    # would come back `nil` instead of the two-key map, reddening this test.
    test "namelist reads the named locations into event data" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{data: %{"p1" => 10, "p2" => 20}}}]} =
               ExecutableContent.execute(send_node(m, "namelist"), context(ms))
    end

    # sabotage: `resolve_params/2`'s closure pattern
    # `fn %Param{name: name, expr: expr}, {:ok, pairs} -> ... end` has
    # `name`/`expr` swapped to `fn %Param{name: expr, expr: name}, ... end`
    # -> `expr` is bound to the param's own name (a raw string, not a
    # compiled `Machine.expr()`), so `Evaluator.evaluate/2` has no matching
    # clause and raises `FunctionClauseError` instead of cleanly returning
    # `%{"a" => 10}`, reddening this test with a crash.
    test "a <param> evaluates its expr into event data" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{data: %{"a" => 10}}}]} =
               ExecutableContent.execute(send_node(m, "param"), context(ms))
    end

    # Open question 1's pin (ADR-0037,
    # docs/adr/0037-unbound-spelled-undefined-at-the-writer.md): a
    # namelist entry over a declared-but-unbound root reads `:undefined`
    # off the normalized context and lands in `data` untranslated - the
    # escape is already the shipped behavior; this asserts it rather than
    # assuming it.
    #
    # sabotage: `resolve_params/2`'s success clause is changed to
    # `{:cont, {:ok, [{name, value || %{}} | pairs]}}` (translate a bound
    # `:undefined` to `%{}`) -> `data` would come back `%{"Var1" => %{}}`
    # instead of `%{"Var1" => :undefined}`, reddening this test.
    test "namelist over a declared-but-unbound root puts :undefined in event data" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{data: %{"Var1" => :undefined}}}]} =
               ExecutableContent.execute(send_node(m, "namelist_unbound"), context(ms))
    end

    # Companion to the pin above: an *undeclared* namelist root is a
    # different case entirely - ADR-0036's element-level discard, not a
    # value that ever reaches `data`.
    #
    # sabotage: `resolve_params/2`'s `{:error, reason} -> {:halt, ...}`
    # branch is changed to `{:cont, {:ok, pairs}}` (skip the failed pair
    # instead of halting) -> the undeclared-root failure would be silently
    # dropped and the send would still emit an effect, reddening this test.
    test "namelist over an undeclared root produces no effect at all" do
      m = machine()
      ms = machine_state(m)

      assert {:error, _reason} =
               ExecutableContent.execute(send_node(m, "namelist_undeclared"), context(ms))
    end

    # sabotage: `data/3`'s clauses are swapped (`%Send{content: nil}` picks
    # `content` and the other clause picks the params coercion) -> a
    # `<content>text</content>` send would report its params coercion
    # (`nil`, since no params were written) instead of the text, reddening
    # this test.
    test "<content> text becomes event data, not the empty params map" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{data: "hello"}}]} =
               ExecutableContent.execute(send_node(m, "content_text"), context(ms))
    end

    # sabotage: `resolve_content/2`'s `{:compiled, _, _}` clause's success
    # arm is changed to `{:ok, value} -> {:ok, value}` (skipping
    # `EventData.coerce({:value, value})`) -> this specific test does not
    # redden (coercing an already-numeric value through `{:value, _}` is a
    # no-op), so the mutation that does is `resolve_content/2`'s
    # `{:compiled, _, _}` clause being dropped entirely, falling through to
    # the `{:static, text}` clause's `EventData.coerce({:text, text})` on
    # the raw, uncompiled `<content expr>` source string -> `data: 10` would
    # instead be `data: "p1"`, reddening this assertion.
    test "<content expr> evaluates and coerces into event data" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{data: 10}}]} =
               ExecutableContent.execute(send_node(m, "content_expr"), context(ms))
    end

    # Decision 3's verified half: `EventData.coerce/1` preserves a
    # present-and-null field rather than collapsing it.
    #
    # sabotage: `resolve_content/2`'s `{:static, text}` clause is changed to
    # `EventData.coerce({:value, text})` (skipping JSON parsing) -> this
    # test's map assertion reddens, since the raw JSON string would become
    # the event data verbatim instead of being parsed.
    test ~s(<content>{"foo": null, "bar": 1}</content> preserves the present-and-null field) do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{data: %{"foo" => nil, "bar" => 1}}}]} =
               ExecutableContent.execute(send_node(m, "content_null"), context(ms))
    end
  end

  describe "execute/2 - delay and delayexpr" do
    # sabotage: `resolve_delay/2`'s `nil` clause is dropped, falling through
    # to the evaluator clause with `nil` as the expression -> `execute/2`
    # would crash (`Evaluator.evaluate/2` has no clause for a bare `nil`)
    # instead of cleanly emitting `{:send, _}` with no delay, reddening this
    # test with a raise.
    test "no delay/delayexpr emits :send, never :send_delayed" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{}}]} =
               ExecutableContent.execute(send_node(m, "bare"), context(ms))
    end

    # sabotage: `build_effect/6`'s guard `when is_integer(delay_ms)` is
    # dropped from the `:send_delayed` clause, and its own clause is moved
    # above the `nil`-delay `:send` clause -> every send, delayed or not,
    # would emit `:send_delayed`, reddening the `delay_ms: 1500` assertion's
    # sibling `:send`-shaped tests above.
    test ~s(delay="1.5s" resolves to delay_ms: 1500) do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send_delayed, %Effect.SendDelayed{delay_ms: 1500}}]} =
               ExecutableContent.execute(send_node(m, "delay_frac"), context(ms))
    end

    # sabotage: `Statifier.Duration.normalize_leading_dot/1`'s leading-dot
    # clause is removed (see `duration_test.exs`'s own sabotage note) ->
    # `.5s` would fail to parse and this test's `{:ok, _}` shape would
    # instead be `{:error, _}`.
    test ~s(delay=".5s" resolves to delay_ms: 500) do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send_delayed, %Effect.SendDelayed{delay_ms: 500}}]} =
               ExecutableContent.execute(send_node(m, "delay_leaddot"), context(ms))
    end

    # sabotage: `resolve_delay/2`'s evaluator-result guard
    # `when is_binary(value) or is_map(value)` drops the `is_binary(value)`
    # half -> a `delayexpr` returning a plain string would fall to the
    # `{:ok, other} -> {:error, {:invalid_delay, other}}` clause instead of
    # resolving, reddening this test's `{:ok, _}` shape.
    test "delayexpr returning a string resolves through Duration.to_ms/1" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send_delayed, %Effect.SendDelayed{delay_ms: 250}}]} =
               ExecutableContent.execute(send_node(m, "delayexpr_string"), context(ms))
    end

    # sabotage: `resolve_delay/2`'s evaluator-result guard
    # `when is_binary(value) or is_map(value)` drops the `is_map(value)`
    # half -> a `delayexpr` returning a native duration value would fall to
    # the `{:ok, other} -> {:error, {:invalid_delay, other}}` clause instead
    # of resolving, reddening this test's `{:ok, _}` shape.
    test "delayexpr returning a native duration value resolves through Duration.to_ms/1" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send_delayed, %Effect.SendDelayed{delay_ms: 2_000}}]} =
               ExecutableContent.execute(send_node(m, "delayexpr_duration"), context(ms))
    end
  end

  describe "execute/2 - send id (ADR-0035)" do
    # sabotage: `generate_send_id/2`'s `is_binary(id)` clause is dropped, so
    # even an author-written `id` falls to the counter-generating clause ->
    # this test's `send_id: "myid"` assertion reddens (it would instead be
    # "send_1"), and the counter would advance for an id-carrying element.
    test "an author-written id is used verbatim and the counter is untouched" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "id_literal")

      assert {:ok, new_ctx, [{:send, %Effect.Send{send_id: "myid"}}]} =
               ExecutableContent.execute(node, context(ms))

      assert new_ctx.machine_state.send_counter == 0
    end

    # sabotage: `generate_send_id/2`'s generated-id clause formats
    # `"send_" <> Integer.to_string(counter)` (off by one - reads the
    # pre-increment counter instead of `counter + 1`) -> the first
    # generated id would be "send_0" instead of "send_1", reddening this
    # test.
    test "no id generates send_1 the first time and advances the counter" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "id_generated")

      assert {:ok, new_ctx, [{:send, %Effect.Send{send_id: "send_1"}}]} =
               ExecutableContent.execute(node, context(ms))

      assert new_ctx.machine_state.send_counter == 1
    end

    # sabotage: `generate_send_id/2`'s generated-id clause is changed to
    # leave `machine_state` untouched (never writing `send_counter: counter
    # + 1` back) -> both executions below would generate "send_1", reddening
    # the second assertion.
    test "two executions of the same element generate two different ids" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "id_generated")

      assert {:ok, ctx_1, [{:send, %Effect.Send{send_id: "send_1"}}]} =
               ExecutableContent.execute(node, context(ms))

      assert {:ok, _ctx_2, [{:send, %Effect.Send{send_id: "send_2"}}]} =
               ExecutableContent.execute(node, context(ctx_1.machine_state))
    end

    # sabotage: `id_from_author?/1` is changed to `true or idlocation != nil`
    # (always true) -> this assertion reddens, since a generated id would
    # now also read as author-written.
    test "id_from_author? is false when the author wrote neither id nor idlocation" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "id_generated")

      assert {:ok, _new_ctx, [{:send, %Effect.Send{id_from_author?: false}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `id_from_author?/1` is changed to `false` unconditionally ->
    # this assertion reddens for an author-written literal id.
    test "id_from_author? is true when the author wrote id" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "id_literal")

      assert {:ok, _new_ctx, [{:send, %Effect.Send{id_from_author?: true}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `id_from_author?/1` is changed to `false` unconditionally
    # (same mutation as the "wrote id" test above) -> this assertion reddens
    # too, for a send that named only `idlocation`.
    test "id_from_author? is true when the author wrote idlocation" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "idlocation")

      assert {:ok, _new_ctx, [{:send, %Effect.Send{id_from_author?: true}}]} =
               ExecutableContent.execute(node, context(ms))
    end
  end

  describe "execute/2 - idlocation" do
    # sabotage: `maybe_write_idlocation/4`'s non-nil clause is changed to
    # `{:ok, machine_state, datamodel_context}` (a no-op, never calling
    # `Datamodel.write_location/4`) -> the datamodel's `"loc"` key would stay
    # `nil` instead of receiving the generated id, reddening this test.
    test "idlocation writes the send id through to the datamodel" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "idlocation")

      assert {:ok, new_ctx, [{:send, %Effect.Send{send_id: send_id}}]} =
               ExecutableContent.execute(node, context(ms))

      assert new_ctx.machine_state.datamodel["loc"] == send_id
      assert send_id != nil
    end
  end

  describe "execute/2 - owner is carried from context for every block kind" do
    # sabotage: `build_effect/6`'s `owner: owner` field is changed to
    # `owner: nil` -> every owner shape below would fail to round-trip,
    # reddening every iteration of this test.
    for owner <- [
          {:onentry, 0, 0},
          {:onexit, 0, 0},
          {:transition, 0},
          {:finalize, 0, 0}
        ] do
      # sabotage: see the note above this loop - a single `owner: nil`
      # mutation in `build_effect/6` reddens every iteration below.
      test "owner #{inspect(owner)} round-trips onto the effect" do
        m = machine()
        ms = machine_state(m)
        node = send_node(m, "bare")
        owner = unquote(Macro.escape(owner))

        assert {:ok, _ctx, [{:send, %Effect.Send{owner: ^owner}}]} =
                 ExecutableContent.execute(node, context(ms, owner))
      end
    end
  end

  describe "execute/2 - argument failure discards the message (ADR-0036)" do
    # sabotage: `execute/2`'s `with` is changed to a plain `case
    # resolve_expr(...)` that ignores an `{:error, _}` and proceeds with
    # `nil` -> a failing `eventexpr` would still emit `{:send, _}` instead of
    # `{:error, _}`, reddening this test.
    test "a failing eventexpr yields {:error, _} and no effect" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "fail_eventexpr")

      assert {:error, _reason} = ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `resolve_params/2`'s `{:error, reason} -> {:halt, ...}`
    # branch is changed to `{:cont, {:ok, pairs}}` (skip the failed pair
    # instead of halting) -> a failing `<param>` would no longer abort the
    # whole `<send>`, reddening this test.
    test "a failing <param> expr yields {:error, _} and no effect" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "fail_param")

      assert {:error, _reason} = ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `resolve_content/2`'s `{:compiled, _, _}` clause's
    # `{:error, reason} -> {:error, reason}` branch is changed to
    # `{:error, _reason} -> {:ok, EventData.coerce({:text, ""})}` (5.6.2's
    # empty-string rung, which ADR-0036 forbids under <send>) -> a failing
    # <content expr> would emit an effect with empty data instead of
    # discarding the message, reddening this test.
    test "a failing <content expr> yields {:error, _} and no effect" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "fail_content_expr")

      assert {:error, _reason} = ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `maybe_write_idlocation/4`'s failure branch
    # (`Datamodel.write_location/4`'s own `{:error, _}`) is caught and
    # mapped to `{:ok, machine_state, datamodel_context}` instead of
    # propagated -> a write against a system-variable idlocation would
    # silently succeed (no effect on the datamodel, but no error either)
    # instead of failing, reddening this test.
    test "a failing idlocation write yields {:error, _} and no effect" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "fail_idlocation")

      assert {:error, _reason} = ExecutableContent.execute(node, context(ms))
    end
  end
end
