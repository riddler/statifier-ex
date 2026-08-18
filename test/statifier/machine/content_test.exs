defmodule Statifier.Machine.ContentTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Lowering, Machine, Parser, Validator}
  alias Statifier.Machine.Content.{Assign, Foreach, If, Log, Raise, Send}
  alias Statifier.Machine.Param
  alias Statifier.Parser.Location

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
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

  describe "compile/1 - assign content" do
    @assign_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <assign location="user.profile.name" expr="'Ada'"/>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_content_node/2`'s `%DAssign{}`
    # expr-bearing clause hardcodes `location: nil` instead of
    # `assign.location` -> this pattern match reddens.
    test "a compiled <assign> carries the raw location string, a compiled expr, and a location_location span" do
      m = compile!(@assign_document)
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [assign_c_index] = onentry_block.content
      assign_content = Machine.content(m, assign_c_index)

      assert %Assign{
               location: "user.profile.name",
               value: {:compiled, %Predicator.Compiled{}, "'Ada'"},
               location_location: location_location
             } = assign_content

      refute location_location == nil
    end

    @invalid_expr_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <assign location="x" expr="{p1: 'v1'"/>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: the `%DAssign{}` expr-bearing clause returns `{:error, error}`
    # on a compile failure, like `<log>`'s clause does, instead of capturing
    # `{:invalid, error}` on the compiled node (Decision 6) -> `compile!/1`'s
    # `{:ok, document}` match inside `compile!/1` still succeeds since
    # lowering/validation are unaffected, but `Compiler.compile/1` itself
    # would return `{:error, _}` instead of `{:ok, _}`, reddening the
    # `compile!/1` helper's own match and failing this test with a
    # `MatchError` instead of reaching the assertion below.
    test "a syntactically bad expr compiles the document, capturing {:invalid, %Compiler.Error{}} on the node" do
      m = compile!(@invalid_expr_document)
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [assign_c_index] = onentry_block.content
      assign_content = Machine.content(m, assign_c_index)

      assert %Assign{value: {:invalid, %Statifier.Compiler.Error{}}} = assign_content
    end

    @child_list_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <assign location="x">[1, 2, 3]</assign>
            </onentry>
        </state>
    </scxml>
    """

    @child_string_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <assign location="x">hello</assign>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.assign_text_value/1` calls
    # `Expressions.compile(text, {:content, c_index}, ...)` instead of
    # `Expressions.inline_value(text)` -> the `[1, 2, 3]` case would compile
    # to a `{:compiled, _, _}` datamodel read instead of folding at compile
    # time to a `{:static, [1, 2, 3]}` literal, reddening this pattern
    # match.
    test ~s(<assign location="x">[1, 2, 3]</assign> compiles to {:static, [1, 2, 3]}) do
      m = compile!(@child_list_document)
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [assign_c_index] = onentry_block.content
      assign_content = Machine.content(m, assign_c_index)

      assert %Assign{value: {:static, [1, 2, 3]}} = assign_content
    end

    # sabotage: see the note above - the same `inline_value/1` ->
    # `Expressions.compile/3` swap reddens this case too, since `hello`
    # would compile to a `{:compiled, _, _}` unbound-identifier read instead
    # of folding to the static string literal `"hello"`.
    test ~s(<assign location="x">hello</assign> compiles to {:static, "hello"}) do
      m = compile!(@child_string_document)
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      [assign_c_index] = onentry_block.content
      assign_content = Machine.content(m, assign_c_index)

      assert %Assign{value: {:static, "hello"}} = assign_content
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

  describe "compile/1 - donedata markup (ADR-0041)" do
    @donedata_markup_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="f">
        <final id="f">
            <donedata>
                <content><data-payload xmlns="urn:example" value="1"/></content>
            </donedata>
        </final>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_content_expr/2`'s markup clause
    # (`%DContent{expr: nil, markup: markup} when is_binary(markup)`) is
    # changed to build `Expressions.static(nil)` instead of
    # `Expressions.static(markup)` -> this pattern match reddens because
    # `expr` folds to `{:static, nil}` instead of the sliced markup.
    test "a <donedata><content><foo/></content></donedata> folds its markup to {:static, markup}, not text" do
      m = compile!(@donedata_markup_document)
      f = state_of(m, "f")

      assert %Machine.Donedata{expr: {:static, markup}} = f.donedata
      assert markup =~ "<data-payload"
      assert markup =~ "urn:example"
    end

    # sabotage: `Statifier.Compiler.content_expr_location/1`'s markup clause
    # (`%DContent{expr: nil, markup_location: %Location{} = location}`) is
    # deleted, so a markup-bearing `<content>` falls through to the plain
    # `location`/`node's own location` clause instead -> `expr_location`
    # becomes the `<content>` node's own span rather than the markup's, and
    # slicing it no longer round-trips to the folded markup, reddening this
    # assertion.
    test "the markup fold's expr_location is markup_location, and Location.slice/2 round-trips it" do
      {:ok, root} = Parser.parse(@donedata_markup_document)
      {:ok, document} = Lowering.lower(root, @donedata_markup_document)
      {:ok, document, _warnings} = Validator.validate(document, @donedata_markup_document)
      {:ok, m} = Compiler.compile(document)
      f = state_of(m, "f")

      assert %Machine.Donedata{expr: {:static, markup}, expr_location: %Location{} = location} =
               f.donedata

      assert Location.slice(location, @donedata_markup_document) == markup
    end
  end

  describe "compile/1 - send markup (ADR-0041)" do
    @send_markup_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <send event="e">
                    <content><data-payload xmlns="urn:example" value="1"/></content>
                </send>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: same mutation as the donedata markup test above -
    # `Statifier.Compiler.build_content_expr/2`'s markup clause returns
    # `Expressions.static(nil)` instead of `Expressions.static(markup)` ->
    # this pattern match reddens too, since `<send>` folds `<content>`
    # through the same shared `build_content_expr/2`.
    test "a <send><content><foo/></content></send> folds its markup to {:static, markup} on Content.Send" do
      m = compile!(@send_markup_document)
      a = state_of(m, "a")
      [onentry_block] = a.onentry
      [send_c_index] = onentry_block.content
      send_content = Machine.content(m, send_c_index)

      assert %Send{content: {:static, markup}} = send_content
      assert markup =~ "<data-payload"
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

  describe "compile/1 - if content" do
    # Hand-drawn c_index assignment, document order (Decision 2 of
    # docs/plans/260813-st-af3.5-if-elseif-else-conditional-executable-content.md):
    # the outer <if>'s own c_index is assigned before any of its branches',
    # and a nested <if>'s own c_index is assigned before *its* branches',
    # to arbitrary depth.
    #
    #  c0  the outer <if>
    #  c1  <log label="one"/>   - outer branch 0 ("a")
    #  c2  the inner <if>       - outer branch 1 ("b")'s own content
    #  c3  <log label="nested"/> - inner branch 0 ("c")
    #  c4  <log label="three"/> - outer branch 2 (<else>)
    @if_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <if cond="a">
                    <log label="one"/>
                    <elseif cond="b"/>
                    <if cond="c">
                        <log label="nested"/>
                    </if>
                    <else/>
                    <log label="three"/>
                </if>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.assign_content_node/2`'s `%DIf{}` clause
    # assigns the `<if>`'s own `c_index` *after* recursing into its branches
    # (moving the `c_index = acc.c_next` / `c_next: c_index + 1` step below
    # the `Enum.map_reduce/3` call) -> the outer `<if>` would be numbered
    # after its own first branch's content instead of before it, reddening
    # this density/order assertion.
    test "c_indexes are dense and in document order, including across a nested <if>" do
      m = compile!(@if_document)
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      assert onentry_block.content == [0]

      assert tuple_size(m.contents) == 5
      assert m.contents |> Tuple.to_list() |> Enum.map(& &1.c_index) == [0, 1, 2, 3, 4]

      outer_if = Machine.content(m, 0)
      assert %If{c_index: 0} = outer_if

      assert [
               %If.Branch{content: [1]},
               %If.Branch{content: [2]},
               %If.Branch{content: [4]}
             ] = outer_if.branches

      inner_if = Machine.content(m, 2)
      assert %If{c_index: 2, branches: [%If.Branch{content: [3]}]} = inner_if

      assert %Log{c_index: 1, label: "one"} = Machine.content(m, 1)
      assert %Log{c_index: 3, label: "nested"} = Machine.content(m, 3)
      assert %Log{c_index: 4, label: "three"} = Machine.content(m, 4)
    end

    # sabotage: `Statifier.Compiler.build_if_branch/3`'s expr-bearing clause
    # is changed to build `%MIf.Branch{cond: nil, ...}` unconditionally
    # (dropping the compiled `cond_expr`) instead of compiling `source`
    # through `Expressions.compile/3` -> this pattern match reddens.
    test "each branch's cond compiles to a Machine.expr(), nil for <else>" do
      m = compile!(@if_document)
      outer_if = Machine.content(m, 0)

      assert [
               %If.Branch{cond: {:compiled, %Predicator.Compiled{}, "a"}, cond_location: a_loc},
               %If.Branch{cond: {:compiled, %Predicator.Compiled{}, "b"}, cond_location: b_loc},
               %If.Branch{cond: nil, cond_location: nil}
             ] = outer_if.branches

      refute a_loc == nil
      refute b_loc == nil
    end

    @bad_cond_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <if cond="{p1: 'v1'">
                    <log label="unreachable"/>
                </if>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_if_branch/3`'s expr-bearing clause
    # captures a compile failure as `{:invalid, error}` on the branch
    # instead of returning `{:error, error}` (borrowing Decision 6's
    # `<assign expr>` deferral, which Decision 6 of this plan explicitly
    # says `<if>`/`<elseif>` do NOT get) -> `Compiler.compile/1` would
    # return `{:ok, _}` instead of `{:error, _}`, reddening this match.
    test "a syntactically bad cond fails Compiler.compile/1, never deferred" do
      {:ok, root} = Parser.parse(@bad_cond_document)
      {:ok, document} = Lowering.lower(root, @bad_cond_document)
      {:ok, document, _warnings} = Validator.validate(document, @bad_cond_document)

      assert {:error, [%Statifier.Compiler.Error{}]} = Compiler.compile(document)
    end
  end

  describe "compile/1 - foreach content" do
    # Hand-drawn c_index assignment, document order: the outer <foreach>'s
    # own c_index is assigned before its content (Decision 2, extended to
    # <foreach> by Decision 8 of
    # docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md), same as
    # <if>'s own c_index precedes its branches'; a <foreach> nested inside
    # an <if> nested inside the outer <foreach> is numbered to arbitrary
    # depth the same way a nested <if> is.
    #
    #  c0  the outer <foreach>
    #  c1  <log label="one"/>       - outer foreach's own content
    #  c2  the <if>                 - outer foreach's own content
    #  c3  the inner <foreach>      - the <if>'s only branch's content
    #  c4  <log label="nested"/>    - inner foreach's own content
    @foreach_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <foreach array="items" item="x" index="i">
                    <log label="one"/>
                    <if cond="a">
                        <foreach array="inner" item="y">
                            <log label="nested"/>
                        </foreach>
                    </if>
                </foreach>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.assign_content_node/2`'s `%DForeach{}`
    # clause assigns the `<foreach>`'s own `c_index` *after* recursing into
    # its content (moving the `c_index = acc.c_next` / `c_next: c_index + 1`
    # step below the `assign_content_nodes/2` call) -> the outer `<foreach>`
    # would be numbered after its own first content node instead of before
    # it, reddening this density/order assertion.
    test "c_indexes are dense and in document order, including across a nested <if>/<foreach>" do
      m = compile!(@foreach_document)
      a = state_of(m, "a")

      [onentry_block] = a.onentry
      assert onentry_block.content == [0]

      assert tuple_size(m.contents) == 5
      assert m.contents |> Tuple.to_list() |> Enum.map(& &1.c_index) == [0, 1, 2, 3, 4]

      outer_foreach = Machine.content(m, 0)
      assert %Foreach{c_index: 0, item: "x", index: "i", content: [1, 2]} = outer_foreach

      assert %Log{c_index: 1, label: "one"} = Machine.content(m, 1)

      inner_if = Machine.content(m, 2)
      assert %If{c_index: 2, branches: [%If.Branch{content: [3]}]} = inner_if

      inner_foreach = Machine.content(m, 3)
      assert %Foreach{c_index: 3, item: "y", index: nil, content: [4]} = inner_foreach

      assert %Log{c_index: 4, label: "nested"} = Machine.content(m, 4)
    end

    # sabotage: `Statifier.Compiler.build_content_node/2`'s `%{foreach: _,
    # content: _}` clause is changed to build `%MForeach{array: {:static,
    # nil}, ...}` unconditionally (dropping the compiled `array_expr`)
    # instead of compiling `foreach_node.array` through
    # `Expressions.compile/3` -> this pattern match reddens.
    test "array compiles to a Machine.expr()" do
      m = compile!(@foreach_document)
      outer_foreach = Machine.content(m, 0)

      assert %Foreach{array: {:compiled, %Predicator.Compiled{}, "items"}, array_location: loc} =
               outer_foreach

      refute loc == nil
    end

    @bad_array_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <foreach array="{p1: 'v1'" item="x">
                    <log label="unreachable"/>
                </foreach>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_content_node/2`'s `%{foreach: _,
    # content: _}` clause captures a compile failure as `{:invalid, error}`
    # on the node instead of returning `{:error, error}` (borrowing
    # Decision 6's `<assign expr>` deferral, which the plan's own Decision 6
    # closing paragraph explicitly says `array` does NOT get - `array`
    # joins `cond` on the load-time-failure side of the ladder) ->
    # `Compiler.compile/1` would return `{:ok, _}` instead of `{:error, _}`,
    # reddening this match.
    test "a syntactically bad array expression fails Compiler.compile/1, never deferred" do
      {:ok, root} = Parser.parse(@bad_array_document)
      {:ok, document} = Lowering.lower(root, @bad_array_document)
      {:ok, document, _warnings} = Validator.validate(document, @bad_array_document)

      assert {:error, [%Statifier.Compiler.Error{}]} = Compiler.compile(document)
    end
  end

  describe "compile/1 - <param> under donedata" do
    @param_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="g">
        <final id="g">
            <donedata>
                <param name="first" expr="1 + 1"/>
                <param name="second" location="second"/>
            </donedata>
        </final>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_donedata_param/2`'s clauses are
    # swapped, matching `location` set on the `param_location: nil` head
    # instead of `expr` -> `first`'s param compiles with `kind: :location`
    # instead of `:expr`, reddening the first assertion below.
    test "compiles into Machine.Param structs in document order, kind set from the written attribute" do
      m = compile!(@param_document)
      g = state_of(m, "g")

      assert %Machine.Donedata{
               expr: nil,
               params: [
                 %Param{
                   name: "first",
                   kind: :expr,
                   expr: {:compiled, %Predicator.Compiled{}, "1 + 1"}
                 },
                 %Param{
                   name: "second",
                   kind: :location,
                   expr: {:compiled, %Predicator.Compiled{}, "second"}
                 }
               ]
             } = g.donedata

      [first, second] = g.donedata.params
      refute first.expr_location == nil
      refute second.expr_location == nil
      refute first.location == nil
    end

    @bad_param_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="h">
        <final id="h">
            <donedata>
                <param name="bad" expr="1 +"/>
            </donedata>
        </final>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_param/4` returns `{:ok, ...}`
    # unconditionally instead of matching `Expressions.compile/3`'s result
    # -> a syntactically invalid `<param expr>` would compile successfully
    # instead of failing, reddening this assertion.
    test "a syntactically bad <param expr> fails Compiler.compile/1" do
      {:ok, root} = Parser.parse(@bad_param_document)
      {:ok, document} = Lowering.lower(root, @bad_param_document)
      {:ok, document, _warnings} = Validator.validate(document, @bad_param_document)

      assert {:error, [%Statifier.Compiler.Error{}]} = Compiler.compile(document)
    end
  end
end
