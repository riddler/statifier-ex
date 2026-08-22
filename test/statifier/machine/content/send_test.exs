defmodule Statifier.Machine.Content.SendTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Effect, Evaluator, ExecutableContent, Lowering}
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.Datamodel
  alias Statifier.{Machine, MachineState, Parser, Validator}
  alias Statifier.Send.Routes

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
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
          <data id="tgt" expr="'#_dyn_target'"/>
          <data id="typ" expr="'scxml'"/>
          <data id="p1" expr="10"/>
          <data id="p2" expr="20"/>
          <data id="loc"/>
          <data id="Var1" src="file:unfetched.txt"/>
      </datamodel>
      <state id="bare"><onentry><send event="ping"/></onentry></state>
      <state id="eventexpr"><onentry><send eventexpr="ev"/></onentry></state>
      <state id="target"><onentry><send event="e" target="#_t1"/></onentry></state>
      <state id="targetexpr"><onentry><send event="e" targetexpr="tgt"/></onentry></state>
      <state id="type"><onentry><send event="e" type="scxml"/></onentry></state>
      <state id="typeexpr"><onentry><send event="e" typeexpr="typ"/></onentry></state>
      <state id="namelist"><onentry><send event="e" namelist="p1 p2"/></onentry></state>
      <state id="namelist_unbound"><onentry><send event="e" namelist="Var1"/></onentry></state>
      <state id="namelist_undeclared">
          <onentry><send event="e" namelist="Undeclared"/></onentry>
      </state>
      <state id="namelist_invalid">
          <onentry><send event="e" namelist="&quot;foo"/></onentry>
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
      <state id="reject_target"><onentry><send event="e" target="baz"/></onentry></state>
      <state id="reject_target_idloc">
          <onentry><send event="e" target="baz" idlocation="loc"/></onentry>
      </state>
      <state id="reject_type_over_target">
          <onentry><send event="e" target="baz" type="http://example.com/bogus"/></onentry>
      </state>
      <state id="reject_delay">
          <onentry><send event="e" target="baz" delay="100ms"/></onentry>
      </state>
      <state id="valid_internal"><onentry><send event="e" target="#_internal"/></onentry></state>
      <state id="valid_session">
          <onentry><send event="e" target="#_scxml_x"/></onentry>
      </state>
      <state id="valid_invoke">
          <onentry><send event="e" target="#_someinvoke"/></onentry>
      </state>
      <state id="unreachable_session">
          <onentry><send event="e" target="#_scxml_foo"/></onentry>
      </state>
      <state id="unreachable_session_idloc">
          <onentry><send event="e" target="#_scxml_foo" idlocation="loc"/></onentry>
      </state>
      <state id="unreachable_delay">
          <onentry><send event="e" target="#_scxml_foo" delay="100ms"/></onentry>
      </state>
      <state id="unreachable_type_over">
          <onentry>
              <send event="e" target="#_scxml_foo" type="http://example.com/bogus"/>
          </onentry>
      </state>
      <state id="parent_target"><onentry><send event="e" target="#_parent"/></onentry></state>
      <state id="self_target">
          <onentry><send event="e" target="#_scxml_selfsess"/></onentry>
      </state>
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
    {ms, _effects} = m |> MachineState.new(opts) |> Datamodel.initialize()
    ms
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

      assert {:ok, _ctx, [{:send, %Effect.Send{target: "#_t1"}}]} =
               ExecutableContent.execute(send_node(m, "target"), context(ms))

      assert {:ok, _ctx, [{:send, %Effect.Send{target: "#_dyn_target"}}]} =
               ExecutableContent.execute(send_node(m, "targetexpr"), context(ms))
    end

    # sabotage: `Send`'s `execute/2` `with` clause for `type` reads
    # `node.target` instead of `node.type` -> `type="scxml"` would resolve
    # to `nil` (the "type" fixture writes no `target`) instead of
    # `"scxml"`, reddening this test's first assertion.
    test "type and typeexpr both resolve" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, _ctx, [{:send, %Effect.Send{type: "scxml"}}]} =
               ExecutableContent.execute(send_node(m, "type"), context(ms))

      assert {:ok, _ctx, [{:send, %Effect.Send{type: "scxml"}}]} =
               ExecutableContent.execute(send_node(m, "typeexpr"), context(ms))
    end
  end

  describe "execute/2 - round is stamped from the machine state (ADR-0046)" do
    # sabotage: `build_effect/6`'s `:send` clause drops `round: ms.round`
    # (the field simply omitted from the literal, `Effect.Send`'s own
    # default from `@enforce_keys` making that impossible to compile without
    # a further edit, so the mutation instead hardcodes `round: 0`) -> this
    # test's `round == 7` assertion reddens against a machine state whose
    # round has actually advanced past 0. Reverted and confirmed green.
    test "a bare <send> stamps the effect's round from machine_state.round" do
      m = machine()
      ms = %{machine_state(m) | round: 7}
      node = send_node(m, "bare")

      assert {:ok, _ctx, [{:send, %Effect.Send{round: 7}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: same mutation as above, applied to `build_effect/6`'s
    # `:send_delayed` clause instead -> this test's `round == 4` assertion
    # reddens. Reverted and confirmed green.
    test "a delayed <send> stamps the effect's round from machine_state.round" do
      m = machine()
      ms = %{machine_state(m) | round: 4}
      node = send_node(m, "delay_frac")

      assert {:ok, _ctx, [{:send_delayed, %Effect.SendDelayed{round: 4}}]} =
               ExecutableContent.execute(node, context(ms))
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
    # assuming it. `Var1` is declared with `src` (never fetched, ADR-0003)
    # rather than value-less, so it stays genuinely unbound at the seed -
    # a value-less `<data id="Var1"/>` instead compiles to `{:static, nil}`
    # and binds a real `nil` (see `test/statifier/interpreter/
    # datamodel_test.exs`'s "declared-unassigned" test), which is a
    # different, already-null case this test does not mean to exercise.
    #
    # sabotage: `resolve_params/2`'s success clause translates a bound
    # `:undefined` to `%{}` - written as
    # `if value == :undefined, do: %{}, else: value`, never as
    # `value || %{}`, which is a no-op here: `||` falls back only on
    # `nil`/`false`, and `:undefined` is a truthy atom -> `data` comes back
    # `%{"Var1" => %{}}` instead of `%{"Var1" => :undefined}` -> red.
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

  describe "execute/2 - timer_counter and ordinal (ADR-0059)" do
    # sabotage: `dispatch_or_reject/8`'s accepted arm starts the counter at
    # 1 instead of reading `machine_state.timer_counter` before bumping
    # (`advance_timer_counter/2` becomes `%{ms | timer_counter: 1}`, always)
    # -> both ordinals below come back `1` instead of `1` then `2`,
    # reddening the second assertion. Reverted and confirmed green.
    test "two sequential delayed sends mint sequential ordinals" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, ctx1, [{:send_delayed, %Effect.SendDelayed{ordinal: 1}}]} =
               ExecutableContent.execute(send_node(m, "delay_frac"), context(ms))

      assert {:ok, _ctx2, [{:send_delayed, %Effect.SendDelayed{ordinal: 2}}]} =
               ExecutableContent.execute(send_node(m, "delay_frac"), context(ctx1.machine_state))
    end

    # Decision 5: `ordinal`/`timer_counter` exist only for the two
    # durable-timer effects - an immediate `<send>` never builds one, so it
    # must leave the counter untouched.
    #
    # sabotage: `advance_timer_counter/2`'s `when is_integer(delay_ms)`
    # guard is dropped from its first clause, so it also matches the `nil`
    # (immediate-send) case and bumps the counter regardless -> this test's
    # `timer_counter == 0` assertion reddens. Reverted and confirmed green.
    test "an immediate <send> (no delay) leaves timer_counter untouched" do
      m = machine()
      ms = machine_state(m)

      assert {:ok, ctx, [{:send, %Effect.Send{}}]} =
               ExecutableContent.execute(send_node(m, "bare"), context(ms))

      assert ctx.machine_state.timer_counter == 0
    end

    # Decision 1: a rejected delayed send builds no effect, so it must not
    # advance the counter either.
    #
    # sabotage: `dispatch_or_reject/8`'s rejected arm is changed to call
    # `advance_timer_counter(machine_state, delay_ms)` before returning the
    # `{:error, new_context, _}` tuple (bumping the counter even on
    # rejection) -> this test's `timer_counter == 0` assertion reddens.
    # Reverted and confirmed green.
    test "a rejected delayed send leaves timer_counter untouched" do
      m = machine()
      ms = machine_state(m)

      assert {:error, new_context, _reason} =
               ExecutableContent.execute(send_node(m, "reject_delay"), context(ms))

      assert new_context.machine_state.timer_counter == 0
    end
  end

  describe "execute/2 - caller_context (ADR-0063)" do
    # sabotage: `build_effect/6`'s delayed clause stores `caller_context:
    # nil` instead of reading `ms.caller_context` -> the first assertion
    # reddens. Decision 3: the effect copies the machine state's transient
    # slot at the same site that reads the counters.
    test "a delayed <send> copies machine_state.caller_context onto the effect" do
      m = machine()
      host_context = %{trace_id: "abc"}
      ms = %{machine_state(m) | caller_context: host_context}

      assert {:ok, _ctx, [{:send_delayed, %Effect.SendDelayed{} = effect}]} =
               ExecutableContent.execute(send_node(m, "delay_frac"), context(ms))

      assert effect.caller_context == host_context
    end

    # sabotage: `build_effect/6`'s delayed clause hardcodes a non-nil
    # `caller_context` instead of reading `ms.caller_context` -> this
    # assertion reddens. A machine state whose macrostep attached no
    # context stamps `nil`, ADR-0063 decision 1's "no context attached".
    test "a delayed <send> under no caller context stamps nil" do
      m = machine()

      assert {:ok, _ctx, [{:send_delayed, %Effect.SendDelayed{caller_context: nil}}]} =
               ExecutableContent.execute(send_node(m, "delay_frac"), context(machine_state(m)))
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

      assert {:ok, _new_ctx,
              [{:datamodel_change, _change}, {:send, %Effect.Send{id_from_author?: true}}]} =
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

      assert {:ok, new_ctx,
              [
                {:datamodel_change, %Effect.DatamodelChange{}},
                {:send, %Effect.Send{send_id: send_id}}
              ]} =
               ExecutableContent.execute(node, context(ms))

      assert new_ctx.machine_state.datamodel["loc"] == send_id
      assert send_id != nil
    end

    # sabotage: `Send`'s `execute/2` builds the returned effect list as
    # `[effect | datamodel_change_effects(...)]` instead of
    # `datamodel_change_effects(...) ++ [effect]` -> the `:datamodel_change`
    # effect would land *after* `:send` instead of before it, reddening this
    # test's ordering assertion (the datamodel write must precede the send it
    # accompanies, since Session performs instructions in the core's effect
    # order). Confirmed red and reverted.
    test "the :datamodel_change effect precedes :send and names the raw idlocation, c_index, and owner" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "idlocation")
      owner = {:onexit, 3, 0}

      assert {:ok, _new_ctx,
              [
                {:datamodel_change, %Effect.DatamodelChange{} = change},
                {:send, %Effect.Send{send_id: send_id}}
              ]} = ExecutableContent.execute(node, context(ms, owner))

      assert change.location_path == ["loc"]
      assert change.location_source == "loc"
      assert change.new_value == send_id
      assert change.prior_value == nil
      assert change.c_index == node.c_index
      assert change.owner == owner
    end

    # sabotage: `maybe_write_idlocation/4`'s `nil`-idlocation clause is
    # changed to return a `%Datamodel.Write{}` record instead of `nil` ->
    # this "bare" (no idlocation) send would wrongly gain a
    # `:datamodel_change` effect, reddening this test's single-element match.
    # Confirmed red and reverted.
    test "no idlocation emits no :datamodel_change effect" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "bare")

      assert {:ok, _new_ctx, [{:send, %Effect.Send{}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `Send`'s `datamodel_change_effects/4` builds the
    # `%Effect.DatamodelChange{}` literal with a hardcoded `round: 0`
    # instead of `round: ms.round` -> reddens against this machine state's
    # round of 8. Confirmed red and reverted.
    test "the idlocation :datamodel_change effect's round matches the machine state's round it was stamped from" do
      m = machine()
      ms = %{machine_state(m) | round: 8}
      node = send_node(m, "idlocation")

      assert {:ok, _new_ctx,
              [
                {:datamodel_change, %Effect.DatamodelChange{round: 8}},
                {:send, %Effect.Send{round: 8}}
              ]} = ExecutableContent.execute(node, context(ms))
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

    # A `namelist` entry that failed to compile (5.9.4 deferral,
    # `{:invalid, error}` on the entry - see `Statifier.Machine.Param`) is one
    # more member of this discard set, not a special case: `evaluate_param/2`
    # turns it into `{:error, _}` ahead of the evaluator, same as any other
    # failing argument here.
    #
    # sabotage: `execute/2`'s `with` clause is changed from
    # `resolve_params(datamodel_context, node.namelist ++ node.params)` to
    # `resolve_params(datamodel_context, node.params)` (namelist dropped from
    # the merge) -> the deferred entry is never resolved at all, so no error
    # is raised and an effect is emitted, reddening this test.
    test "a deferred namelist entry yields {:error, _} and no effect" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "namelist_invalid")

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

  describe "execute/2 - static target/type rejection (ADR-0047)" do
    # sabotage: `reject_reason/4`'s `cond` is changed to unconditionally
    # return `nil` -> the invalid target below would dispatch a `{:send,
    # _}` effect instead of rejecting, reddening this test's match.
    # Confirmed red (the pattern match failed against `{:ok, _, [...]}`)
    # and reverted.
    test "an invalid target rejects with the composite error form and no effect" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "reject_target")

      assert {:error, _new_ctx, {:send_rejected, send_id, :execution, {:invalid_target, "baz"}}} =
               ExecutableContent.execute(node, context(ms))

      assert send_id != nil
    end

    # sabotage: same mutation as above (`reject_reason/4`'s `cond` forced
    # to `nil`) -> `execute/2` returns `{:ok, _, _}` instead of the
    # `{:error, new_ctx, _}` this test matches on, reddening it too.
    # Confirmed red and reverted.
    test "the send_counter still advances even though the send is rejected" do
      m = machine()
      ms = machine_state(m)
      before_counter = ms.send_counter
      node = send_node(m, "reject_target")

      assert {:error, new_ctx, {:send_rejected, _send_id, :execution, {:invalid_target, "baz"}}} =
               ExecutableContent.execute(node, context(ms))

      assert new_ctx.machine_state.send_counter == before_counter + 1
    end

    # sabotage: same mutation as above (`reject_reason/4`'s `cond` forced
    # to `nil`) -> `execute/2` returns `{:ok, _, _}` instead of the
    # `{:error, new_ctx, _}` this test matches on, reddening it too.
    # Confirmed red and reverted.
    test "idlocation is still written, and the reason's send_id matches it" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "reject_target_idloc")

      assert {:error, new_ctx, {:send_rejected, send_id, :execution, {:invalid_target, "baz"}}} =
               ExecutableContent.execute(node, context(ms))

      assert new_ctx.machine_state.datamodel["loc"] == send_id
    end

    # sabotage: `reject_reason/4`'s `cond` clauses are swapped (target
    # checked before type) -> this document's simultaneous unsupported type
    # and invalid target would reject as `{:invalid_target, "baz"}` instead
    # of `{:unsupported_type, _}`, reddening this test's match (only this
    # test - the other four cases in this describe stayed green under the
    # same mutation, confirming it is order-specific). Confirmed red and
    # reverted.
    test "an unsupported type takes priority over a simultaneously-invalid target" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "reject_type_over_target")

      assert {:error, _new_ctx,
              {:send_rejected, _send_id, :execution,
               {:unsupported_type, "http://example.com/bogus"}}} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: same mutation as the first two tests above
    # (`reject_reason/4`'s `cond` forced to `nil`) -> `execute/2` returns
    # `{:ok, _, [{:send_delayed, _}]}` instead of the `{:error, _, _}` this
    # test matches on, reddening it - proof the delayed path runs through
    # the same check as the immediate one. Confirmed red and reverted.
    test "a delay-bearing send with an invalid target rejects with no Effect.SendDelayed" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "reject_delay")

      assert {:error, _new_ctx, {:send_rejected, _send_id, :execution, {:invalid_target, "baz"}}} =
               ExecutableContent.execute(node, context(ms))
    end

    for {state, target} <- [
          {"bare", nil},
          {"valid_internal", "#_internal"},
          {"valid_session", "#_scxml_x"},
          {"valid_invoke", "#_someinvoke"}
        ] do
      # sabotage: `reject_reason/4`'s `not Target.supported_type?(type) ->`
      # clause changed to always fire (`true ->`) -> every one of these
      # routes rejects instead of dispatching, reddening every case of this
      # test -> red. Confirmed red and reverted.
      test "a valid target #{inspect(target)} still dispatches" do
        m = machine()
        ms = machine_state(m)
        node = send_node(m, unquote(state))

        assert {:ok, _new_ctx, [{:send, %Effect.Send{target: unquote(target)}}]} =
                 ExecutableContent.execute(node, context(ms))
      end
    end
  end

  describe "execute/2 - reachability against a route snapshot (ADR-0048)" do
    # sabotage: `unreachable?/3`'s `defp unreachable?(target, nil, routes),
    # do: not Routes.reachable?(routes, Target.parse(target))` clause
    # negation is dropped (`Routes.reachable?(...)` instead of
    # `not Routes.reachable?(...)`) -> a snapshot that omits "foo" from
    # `sessions` would be read as reachable, so this test would dispatch a
    # `{:send, _}` effect instead of rejecting, reddening the match below.
    # Confirmed red and reverted.
    test "an unreachable session route rejects as :communication with no effect" do
      m = machine()
      ms = machine_state(m, routes: Routes.new(sessions: ["other"]))
      node = send_node(m, "unreachable_session")

      assert {:error, _new_ctx,
              {:send_rejected, send_id, :communication, {:unreachable_target, "#_scxml_foo"}}} =
               ExecutableContent.execute(node, context(ms))

      assert send_id != nil
    end

    # sabotage: `unreachable?/3`'s final clause changed to
    # `defp unreachable?(_target, nil, _routes), do: true` (ignoring the
    # snapshot entirely) -> this send would reject even though "foo" is in
    # the snapshot, reddening the `{:ok, _, [...]}` match below. Confirmed
    # red and reverted.
    test "the same target dispatches once the snapshot includes its session" do
      m = machine()
      ms = machine_state(m, routes: Routes.new(sessions: ["foo"]))
      node = send_node(m, "unreachable_session")

      assert {:ok, _new_ctx, [{:send, %Effect.Send{target: "#_scxml_foo"}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `Routes.reachable?/2`'s `:parent` clause changed to
    # unconditionally return `true` -> the first case here (`parent?:
    # false`) would dispatch instead of rejecting, reddening its match.
    # Confirmed red and reverted.
    test ":parent is unreachable when parent?: false, reachable when true" do
      m = machine()
      node = send_node(m, "parent_target")

      ms_no_parent = machine_state(m, routes: Routes.new(parent?: false))

      assert {:error, _new_ctx,
              {:send_rejected, _send_id, :communication, {:unreachable_target, "#_parent"}}} =
               ExecutableContent.execute(node, context(ms_no_parent))

      ms_parent = machine_state(m, routes: Routes.new(parent?: true))

      assert {:ok, _new_ctx, [{:send, %Effect.Send{target: "#_parent"}}]} =
               ExecutableContent.execute(node, context(ms_parent))
    end

    # sabotage: `Routes.reachable?/2`'s `{:invoke, invoke_id}` clause
    # changed to unconditionally return `false` -> the second case here
    # (invoke id present in the snapshot) would reject instead of
    # dispatching, reddening its match. Confirmed red and reverted.
    test "{:invoke, id} is unreachable when absent from invokes, reachable when present" do
      m = machine()
      node = send_node(m, "valid_invoke")

      ms_no_invoke = machine_state(m, routes: Routes.new())

      assert {:error, _new_ctx,
              {:send_rejected, _send_id, :communication, {:unreachable_target, "#_someinvoke"}}} =
               ExecutableContent.execute(node, context(ms_no_invoke))

      ms_invoke = machine_state(m, routes: Routes.new(invokes: ["someinvoke"]))

      assert {:ok, _new_ctx, [{:send, %Effect.Send{target: "#_someinvoke"}}]} =
               ExecutableContent.execute(node, context(ms_invoke))
    end

    # ADR-0048 decision 4's mirror at the core layer: a session always
    # includes its own id in the snapshot's session set, so
    # `#_scxml_<own id>` is reachable with no registry involved.
    #
    # sabotage: `Routes.reachable?/2`'s `{:session, session_id}` clause
    # changed to unconditionally return `false` -> the self-addressed send
    # would reject instead of dispatching, reddening the match below.
    # Confirmed red and reverted.
    test "#_scxml_<own session id> is reachable when the snapshot's sessions contains it" do
      m = machine()
      ms = machine_state(m, session_id: "selfsess", routes: Routes.new(sessions: ["selfsess"]))
      node = send_node(m, "self_target")

      assert {:ok, _new_ctx, [{:send, %Effect.Send{target: "#_scxml_selfsess"}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # sabotage: `unreachable?/3`'s `defp unreachable?(_target, _delay_ms,
    # nil), do: false` clause changed to `do: true` -> a `nil` snapshot
    # would be read as "everything unreachable" instead of "no
    # determination", rejecting this send (and 35 other tests in this
    # file that rely on `nil` routes dispatching unchanged) instead of
    # dispatching it. Confirmed red and reverted.
    test "routes: nil emits the effect - today's behavior, unchanged" do
      m = machine()
      ms = machine_state(m)
      node = send_node(m, "unreachable_session")

      assert {:ok, _new_ctx, [{:send, %Effect.Send{target: "#_scxml_foo"}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # ADR-0048 decision 6's exemption: a delayed send gets no plan-time
    # reachability check at all.
    #
    # sabotage: `unreachable?/3`'s delayed-send clause changed from
    # `defp unreachable?(_target, delay_ms, _routes) when is_integer(delay_ms),
    # do: false` to `do: not Routes.reachable?(routes, Target.parse(target))`
    # - the same check the immediate-send clause runs - so a delayed send
    # to an unreachable target rejects instead of scheduling, reddening
    # the match below. Confirmed red and reverted.
    test "a delayed send to an unreachable target still emits Effect.SendDelayed" do
      m = machine()
      ms = machine_state(m, routes: Routes.new(sessions: ["other"]))
      node = send_node(m, "unreachable_delay")

      assert {:ok, _new_ctx, [{:send_delayed, %Effect.SendDelayed{target: "#_scxml_foo"}}]} =
               ExecutableContent.execute(node, context(ms))
    end

    # ADR-0047's arms keep priority over ADR-0048's reachability arm.
    #
    # sabotage: `reject_reason/4`'s `cond` clauses are reordered so the
    # `unreachable?/3` arm is checked before `Target.supported_type?/1` ->
    # this document's simultaneous unsupported type and unreachable target
    # would reject as `{:communication, {:unreachable_target, _}}` instead
    # of `{:execution, {:unsupported_type, _}}`, reddening this test's
    # match. Confirmed red and reverted.
    test "an unsupported type still wins over an unreachable target" do
      m = machine()
      ms = machine_state(m, routes: Routes.new(sessions: ["other"]))
      node = send_node(m, "unreachable_type_over")

      assert {:error, _new_ctx,
              {:send_rejected, _send_id, :execution,
               {:unsupported_type, "http://example.com/bogus"}}} =
               ExecutableContent.execute(node, context(ms))
    end

    # An `{:invalid, _}` target still rejects as :execution, never
    # :communication - ADR-0047's static arm keeps priority.
    #
    # sabotage: `reject_reason/4`'s `match?({:invalid, _reason},
    # Target.parse(target)) ->` arm's tag changed from `:execution` to
    # `:communication` -> this test's match on `:execution` reddens.
    # Confirmed red and reverted.
    test "an invalid target still rejects as :execution" do
      m = machine()
      ms = machine_state(m, routes: Routes.new())
      node = send_node(m, "reject_target")

      assert {:error, _new_ctx, {:send_rejected, _send_id, :execution, {:invalid_target, "baz"}}} =
               ExecutableContent.execute(node, context(ms))
    end

    # test332's ordering, now asserted for the reachability rejection: the
    # send id is minted and idlocation written before the :communication
    # rejection.
    #
    # sabotage: `reject_reason/4`'s `unreachable?(target, delay_ms, routes)
    # ->` cond clause is changed to `false ->` (never firing) -> this send
    # would dispatch a `{:send, _}` effect instead of rejecting, reddening
    # the `{:error, new_ctx, _}` match below. Confirmed red and reverted.
    test "the send id is minted and idlocation written before the reachability rejection" do
      m = machine()
      ms = machine_state(m, routes: Routes.new(sessions: ["other"]))
      node = send_node(m, "unreachable_session_idloc")

      assert {:error, new_ctx,
              {:send_rejected, send_id, :communication, {:unreachable_target, "#_scxml_foo"}}} =
               ExecutableContent.execute(node, context(ms))

      assert new_ctx.machine_state.datamodel["loc"] == send_id
    end
  end
end
