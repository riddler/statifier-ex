defmodule Statifier.Machine.ContentTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Content.Log
  alias Statifier.Machine.Content.Raise
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp state_of(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    elem(machine.states, index)
  end

  # Exercises every content role the compiler assigns a `c_index` to: `a`'s
  # onentry (two nodes: a raise, then a plain log), `a`'s onexit (one raise),
  # and `a`'s own transition content (a log with expr). `b`'s <donedata>
  # holds a static <content> text body and carries no c_index.
  # Hand-drawn source order:
  #
  #  c0  a's onentry raise ("enter")
  #  c1  a's onentry log (label "hi", no expr)
  #  c2  a's onexit raise ("leave")
  #  c3  a's transition's log (expr "1 + 1")
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry>
              <raise event="enter"/>
              <log label="hi"/>
          </onentry>
          <onexit>
              <raise event="leave"/>
          </onexit>
          <transition event="go" target="b">
              <log expr="1 + 1"/>
          </transition>
      </state>
      <final id="b">
          <donedata>
              <content>done text</content>
          </donedata>
      </final>
  </scxml>
  """

  defp machine, do: compile!(@document)

  describe "compile/1 - c_index density and document order" do
    # sabotage: `Statifier.Compiler.assign_content_nodes/2` increments with
    # `{[c_index | c_indexes], acc}` instead of `c_index: c_index + 1` on the
    # threaded acc -> every content node in one block/transition collides on
    # the same c_index key, collapsing the tuple to far fewer than 4
    # entries, reddening this count.
    test "one c_index per <raise>/<log> node outside <donedata>, dense from 0" do
      m = machine()

      assert tuple_size(m.contents) == 4
      assert m.contents |> Tuple.to_list() |> Enum.map(& &1.c_index) == [0, 1, 2, 3]
    end

    # sabotage: `Statifier.Compiler.assign_own_content_and_transitions/3`'s
    # non-history clause assigns onexit before onentry (the two
    # `assign_blocks` calls swapped) -> `a`'s onexit raise gets a lower
    # c_index than its onentry content, reddening this ordering assertion.
    test "onentry content is numbered before onexit content, before transition content" do
      m = machine()
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [onexit_block] = a.onexit
      [transition_t_index] = a.transitions
      transition = Machine.transition(m, transition_t_index)

      assert Enum.max(onentry_block.content) < Enum.min(onexit_block.content)
      assert Enum.max(onexit_block.content) < Enum.min(transition.content)
    end
  end

  describe "compile/1 - block locations" do
    # sabotage: `Statifier.Compiler.assign_blocks/2` builds `%MBlock{location:
    # nil, ...}` instead of `location: block.location` -> this refutation
    # reddens.
    test "onentry/onexit block locations are retained" do
      m = machine()
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [onexit_block] = a.onexit

      refute onentry_block.location == nil
      refute onexit_block.location == nil
    end
  end

  describe "compile/1 - raise content" do
    # sabotage: `Statifier.Compiler.build_content_node/2`'s `%DRaise{}` clause
    # builds a `%Content.Log{}` instead of a `%Content.Raise{}` -> this
    # pattern match reddens.
    test "a <raise> node compiles to a Content.Raise struct with its event name" do
      m = machine()
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [raise_c_index, _log_c_index] = onentry_block.content
      raise_content = Machine.content(m, raise_c_index)

      assert %Raise{event: "enter"} = raise_content
    end

    # sabotage: `Statifier.Machine.Content.Raise`'s `defstruct` gains a
    # `label: nil` field (the union struct's shape leaking back in) -> this
    # refutation reddens because `Map.has_key?/2` starts returning `true`.
    test "a Content.Raise node has no label or expr field at all" do
      m = machine()
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [raise_c_index, _log_c_index] = onentry_block.content
      raise_content = Machine.content(m, raise_c_index)

      fields = raise_content |> Map.from_struct() |> Map.keys()

      refute :label in fields
      refute :expr in fields
    end
  end

  describe "compile/1 - log content" do
    # sabotage: `Statifier.Compiler.build_content_node/2`'s no-expr `%DLog{}`
    # clause hardcodes `label: nil` instead of `label: label` -> this
    # assertion reddens.
    test "a plain <log> node (no expr) compiles with its label and a nil expr" do
      m = machine()
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [_raise_c_index, log_c_index] = onentry_block.content
      log_content = Machine.content(m, log_c_index)

      assert %Log{label: "hi", expr: nil} = log_content
    end

    # sabotage: `Statifier.Compiler.build_content_node/2`'s expr-bearing
    # `%DLog{}` clause hardcodes `expr: nil` instead of compiling `source`
    # through `Expressions.compile/3` -> this pattern match reddens.
    test "a <log expr=...> node holds a compiled Machine.expr()" do
      m = machine()
      a = state_of(m, "a")

      [transition_t_index] = a.transitions
      transition = Machine.transition(m, transition_t_index)
      [log_c_index] = transition.content
      log_content = Machine.content(m, log_c_index)

      assert %Log{expr: {:compiled, %Predicator.Compiled{}, "1 + 1"}} = log_content
    end

    # sabotage: `Statifier.Compiler.build_content_node/2`'s `%DRaise{}` clause
    # is changed to build a `%Content.Log{}` instead of a `%Content.Raise{}`
    # -> `Machine.content/2` at the raise's own `c_index` no longer returns a
    # `%Raise{}`, reddening this pattern match.
    test "Machine.content/2 returns each kind at its own c_index" do
      m = machine()
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [raise_c_index, log_c_index] = onentry_block.content

      assert %Raise{c_index: ^raise_c_index} = Machine.content(m, raise_c_index)
      assert %Log{c_index: ^log_c_index} = Machine.content(m, log_c_index)
    end
  end

  describe "compile/1 - donedata" do
    # sabotage: `Statifier.Compiler.build_content_expr/2`'s no-expr clause
    # wraps `nil` instead of `Expressions.static(text)` -> this pattern match
    # reddens.
    test "a <donedata><content>text</content></donedata> holds {:static, text} on the final state" do
      m = machine()
      b = state_of(m, "b")

      assert %Machine.Donedata{expr: {:static, "done text"}} = b.donedata
      refute b.donedata.expr_location == nil
    end

    # sabotage: `Statifier.Compiler.walk_siblings/4` is changed to also run
    # `assign_content_nodes/2` over a fabricated content node whenever
    # `dstate.donedata` is present, growing `c_next`/`contents_acc` the way
    # a Decision-8 violation would -> `tuple_size(m.contents)` comes back 5
    # instead of 4, reddening this assertion.
    test "donedata content is absent from machine.contents" do
      m = machine()

      # Only 4 executable-content nodes exist in the whole document (the
      # onentry/onexit/transition ones); donedata's <content> is not among
      # them.
      assert tuple_size(m.contents) == 4

      refute Enum.any?(Tuple.to_list(m.contents), fn
               %Log{expr: expr} -> match?({:static, "done text"}, expr)
               %Raise{} -> false
             end)
    end
  end

  describe "compile/1 - a <content expr=...> under donedata" do
    @expr_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="f">
        <final id="f">
            <donedata>
                <content expr="1 + 1"/>
            </donedata>
        </final>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_content_expr/2`'s expr-bearing
    # clause reads `content.text` instead of `content.expr` as the source ->
    # since `text` is `""` here (no text body was written), this reddens
    # with a parse failure the test does not expect (or a mismatched
    # source).
    test "compiles to {:compiled, ...} and carries no c_index" do
      m = compile!(@expr_document)
      f = state_of(m, "f")

      assert %Machine.Donedata{expr: {:compiled, %Predicator.Compiled{}, "1 + 1"}} = f.donedata
      assert tuple_size(m.contents) == 0
    end
  end
end
