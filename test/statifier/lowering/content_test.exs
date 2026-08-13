defmodule Statifier.Lowering.ContentTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Assign
  alias Statifier.Document.Block
  alias Statifier.Document.Foreach
  alias Statifier.Document.If
  alias Statifier.Document.Log
  alias Statifier.Document.Raise
  alias Statifier.Document.State
  alias Statifier.Document.Transition
  alias Statifier.Lowering
  alias Statifier.Lowering.Error

  defp parse!(xml) do
    {:ok, root} = Statifier.Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower()
    document
  end

  defp only_state(document) do
    assert [%State{} = state] = document.states
    state
  end

  describe "lower/1 - <onentry> and <onexit>, happy path" do
    # sabotage: `build_block/3` hardcodes the tag `:onentry` instead of using
    # its own `tag` argument -> the onexit assertion below reddens since the
    # block would land in `state.onentry` instead of `state.onexit`
    test "each produces one Block, placed into the matching State slot" do
      xml = """
      <scxml>
          <state id="s">
              <onentry><raise event="a"/></onentry>
              <onexit><raise event="b"/></onexit>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [%Block{content: [%Raise{event: "a"}]}] = state.onentry
      assert [%Block{content: [%Raise{event: "b"}]}] = state.onexit
    end

    # sabotage: `state_like/3`'s `place/3` clause for `{:onentry, block}`
    # appends instead of prepending, or `place_children/3`'s fold order is
    # reversed for a container that already accumulates children in reverse
    # -> flatten the three onentry blocks into one by merging their content
    # into a single Block in `build_block/3` -> this test reddens because
    # `state.onentry` would have length 1, not 3
    test "three <onentry> elements stay three Block structs, never flattened" do
      xml = """
      <scxml>
          <state id="s">
              <onentry><raise event="one"/></onentry>
              <onentry><raise event="two"/></onentry>
              <onentry><raise event="three"/></onentry>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [
               %Block{content: [%Raise{event: "one"}]},
               %Block{content: [%Raise{event: "two"}]},
               %Block{content: [%Raise{event: "three"}]}
             ] = state.onentry
    end

    # sabotage: `build_block/3` sets `location: nil` instead of
    # `element.location` -> this test reddens since each Block would carry
    # no distinct span
    test "each Block carries its own <onentry>/<onexit> element's location" do
      xml = """
      <scxml>
          <state id="s">
              <onentry/>
              <onexit/>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [%Block{location: onentry_location}] = state.onentry
      assert [%Block{location: onexit_location}] = state.onexit
      assert onentry_location != onexit_location
    end
  end

  describe "lower/1 - <raise>, happy path" do
    # sabotage: `build_raise/2` splits `event` with `Attributes.list/2`
    # instead of reading it raw with `Attributes.value/2` -> this test
    # reddens because `event` would become `["a", "b"]`, not the raw string
    test "event is stored as a single unsplit string, even with a space in it" do
      xml = ~s(<scxml><state id="s"><onentry><raise event="a b"/></onentry></state></scxml>)

      state = lower!(xml) |> only_state()

      assert [%Block{content: [%Raise{event: "a b"}]}] = state.onentry
    end
  end

  describe "lower/1 - <raise>, missing event" do
    # sabotage: `build_raise/2`'s `nil` branch is dropped in favor of always
    # building a `%Raise{event: nil}` (bypassing `@enforce_keys`'s guarantee
    # some other way) -> this test reddens because no
    # `{:missing_attribute, ...}` error would be produced
    test "a <raise> with no event attribute produces a missing_attribute error" do
      xml = ~s(<scxml><state id="s"><onentry><raise/></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:missing_attribute, "raise", "event"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - <log>, happy path" do
    # sabotage: `build_log/2` swaps the `label` and `expr` reads -> this test
    # reddens since the values would land on the wrong fields
    test "label and expr both lower as raw strings" do
      xml =
        ~s(<scxml><state id="s"><onentry><log label="hi" expr="x + 1"/></onentry></state></scxml>)

      state = lower!(xml) |> only_state()

      assert [%Block{content: [%Log{label: "hi", expr: "x + 1"}]}] = state.onentry
    end

    # sabotage: `build_log/2`'s `attribute_locations` pipeline replaces
    # `Attributes.put_location(:label, element, "label")` with an
    # unconditional `Map.put(:label, element.location)` -> the absent-label
    # `refute Map.has_key?/2` assertion below reddens, since the key would
    # be added even though `label` was never written
    test ~s(label="" lowers to "" with the key present; an absent label lowers to nil with no key) do
      xml_empty =
        ~s(<scxml><state id="s"><onentry><log label=""/></onentry></state></scxml>)

      xml_absent = ~s(<scxml><state id="s"><onentry><log/></onentry></state></scxml>)

      empty_state = lower!(xml_empty) |> only_state()
      absent_state = lower!(xml_absent) |> only_state()

      assert [%Block{content: [%Log{label: "", attribute_locations: empty_locations}]}] =
               empty_state.onentry

      assert [%Block{content: [%Log{label: nil, attribute_locations: absent_locations}]}] =
               absent_state.onentry

      assert Map.has_key?(empty_locations, :label)
      refute Map.has_key?(absent_locations, :label)
    end
  end

  describe "lower/1 - <assign>, happy path" do
    # sabotage: `build_assign/2` swaps the `location` and `expr` reads ->
    # this test reddens since the values would land on the wrong fields
    test "location and expr both lower as raw strings, with both attribute_locations recorded" do
      xml =
        ~s(<scxml><state id="s"><onentry><assign location="user.name" expr="'Ada'"/></onentry></state></scxml>)

      state = lower!(xml) |> only_state()

      assert [
               %Block{
                 content: [
                   %Assign{
                     location: "user.name",
                     expr: "'Ada'",
                     attribute_locations: attribute_locations
                   }
                 ]
               }
             ] = state.onentry

      assert Map.has_key?(attribute_locations, :location)
      assert Map.has_key?(attribute_locations, :expr)
    end
  end

  describe "lower/1 - <assign>, child text" do
    # sabotage: `build_assign/2`'s `%Assign{}` literal drops `text:
    # DOM.text(element)` (leaving the struct default `text: nil`) -> this
    # test reddens since `text` would be `nil` instead of the child text.
    test "child text is captured on the assign node" do
      xml =
        ~s(<scxml><state id="s"><onentry><assign location="x">hello</assign></onentry></state></scxml>)

      state = lower!(xml) |> only_state()

      assert [%Block{content: [%Assign{location: "x", text: "hello"}]}] = state.onentry
    end

    # sabotage: `build_assign/2`'s `misplaced_errors` binding is replaced
    # with a hardcoded `[]` instead of walking `DOM.elements(element)` ->
    # the element child would be silently dropped rather than reported,
    # reddening this test's `{:error, [...]}` match (`lower!/1` would return
    # `{:ok, _}` instead).
    test "an element child inside <assign> is a misplaced_element error" do
      xml =
        ~s(<scxml><state id="s"><onentry><assign location="x"><log label="hi"/></assign></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:misplaced_element, "log", "assign"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - <assign>, missing location" do
    # sabotage: `build_assign/2`'s `nil` branch is dropped in favor of always
    # building a `%Assign{location: nil}` (bypassing `@enforce_keys`'s
    # guarantee some other way) -> this test reddens because no
    # `{:missing_attribute, ...}` error would be produced
    test "an <assign> with no location attribute produces a missing_attribute error" do
      xml = ~s(<scxml><state id="s"><onentry><assign/></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:missing_attribute, "assign", "location"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - misplaced <assign>" do
    # sabotage: the `%Assign{}`-specific `place/3` clause in
    # `lib/statifier/lowering/builders.ex` is deleted, so a misplaced
    # `<assign>` falls into the generic `{:content_node, node}` clause, which
    # reads `node.location` (the raw path string, not a `%Location{}`) and
    # crashes `Error.misplaced/3`'s `%Location{}` match instead of returning
    # a clean error -> this test would raise rather than assert cleanly.
    test ~s(a <assign> inside a <state> produces {:misplaced_element, "assign", "state"}) do
      xml = ~s(<scxml><state id="s"><assign location="x" expr="1"/></state></scxml>)

      assert {:error, [%Error{reason: {:misplaced_element, "assign", "state"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - a transition's own content" do
    # sabotage: `build_transition/2` reverts to discarding `walk_children/2`'s
    # results (`{_results, errors} = ...`) instead of placing them via
    # `place_children/3` -> this test reddens because `transition.content`
    # would stay `[]`
    test "a <log> inside a <transition> lands in Transition.content, unwrapped" do
      xml = ~s(<scxml><state id="s"><transition><log label="hi"/></transition></state></scxml>)

      assert [%State{transitions: [%Transition{content: [%Log{label: "hi"}]}]}] =
               lower!(xml).states
    end
  end

  describe "lower/1 - misplaced content" do
    # sabotage: `place/3` gains a `{:state, _state}` clause for `%Block{}`
    # that silently drops the child (returning the parent unchanged, no
    # error) -> this test reddens because no `{:misplaced_element, ...}`
    # error would be produced; `lower/1` would return `{:ok, _}` instead
    test ~s(a <state> inside an <onentry> produces {:misplaced_element, "state", "onentry"}) do
      xml = ~s(<scxml><state id="s"><onentry><state id="nope"/></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:misplaced_element, "state", "onentry"}}]} =
               xml |> parse!() |> Lowering.lower()
    end
  end

  describe "lower/1 - <if>/<elseif>/<else>, happy path" do
    # sabotage: `place/3`'s `%If{}` clause for `{:elseif, _}`/`{:else, _}`
    # seals the open branch onto the *front* of `closed` instead of leaving
    # it as `[branch, open | closed]` (an off-by-one in the fold) -> the
    # first branch's content would land in the second branch instead,
    # reddening this test's per-branch content assertions.
    test "three partitioning tags produce three branches, each with its own cond and content" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <if cond="a">
                      <log label="one"/>
                      <elseif cond="b"/>
                      <log label="two"/>
                      <else/>
                      <log label="three"/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [
               %Block{
                 content: [
                   %If{
                     branches: [
                       %If.Branch{
                         cond: "a",
                         content: [%Log{label: "one"}],
                         attribute_locations: al0
                       },
                       %If.Branch{
                         cond: "b",
                         content: [%Log{label: "two"}],
                         attribute_locations: al1
                       },
                       %If.Branch{
                         cond: nil,
                         content: [%Log{label: "three"}],
                         attribute_locations: al2
                       }
                     ]
                   }
                 ]
               }
             ] = state.onentry

      assert Map.has_key?(al0, :cond)
      assert Map.has_key?(al1, :cond)
      refute Map.has_key?(al2, :cond)
    end
  end

  describe "lower/1 - <else/> as the first child, an empty first partition" do
    # sabotage: `build_if/2` builds the first branch's `content` field with
    # a hardcoded non-empty default instead of `[]` -> this test's empty-list
    # match on the first branch reddens.
    test "the first partition is empty when <else/> is the <if>'s first child" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <if cond="a">
                      <else/>
                      <log label="fallback"/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [
               %Block{
                 content: [
                   %If{
                     branches: [
                       %If.Branch{cond: "a", content: []},
                       %If.Branch{cond: nil, content: [%Log{label: "fallback"}]}
                     ]
                   }
                 ]
               }
             ] = state.onentry
    end
  end

  describe "lower/1 - <if>/<elseif>, missing cond" do
    # sabotage: `build_if/2`'s `nil` branch is dropped in favor of always
    # building an `%If{}` with a `nil`-cond first branch (bypassing the
    # required-attribute rule) -> this test reddens because no
    # `{:missing_attribute, ...}` error would be produced
    test "an <if> with no cond attribute produces a missing_attribute error" do
      xml = ~s(<scxml><state id="s"><onentry><if/></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:missing_attribute, "if", "cond"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end

    # sabotage: `build_elseif/2`'s `nil` branch is dropped the same way ->
    # no `{:missing_attribute, "elseif", "cond"}` error would be produced
    test "an <elseif> with no cond attribute produces a missing_attribute error" do
      xml =
        ~s(<scxml><state id="s"><onentry><if cond="a"><elseif/></if></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:missing_attribute, "elseif", "cond"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - a stray <elseif> outside any <if>" do
    # sabotage: a `place/3` clause is added that accepts `{:elseif, _}` into
    # any `%State{}` (dropping Decision 7's restriction to `%If{}` parents
    # only) -> this test reddens because `lower/1` would return `{:ok, _}`
    # instead of reporting the misplaced element.
    test ~s(a stray <elseif> directly under <state> produces {:misplaced_element, "elseif", "state"}) do
      xml = ~s(<scxml><state id="s"><elseif cond="true"/></state></scxml>)

      assert {:error, [%Error{reason: {:misplaced_element, "elseif", "state"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - a nested <if>" do
    # sabotage: `place/3`'s `%If{}` clause for `{:content_node, node}`
    # appends to `closed` instead of the currently `open` branch -> the
    # nested `%If{}` would land in the outer `<if>`'s wrong branch (or be
    # lost from the branch this test asserts against), reddening this match.
    test "an <if> nested inside another <if>'s branch lowers to a nested %If{}" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <if cond="a">
                      <if cond="b">
                          <log label="inner"/>
                      </if>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [
               %Block{
                 content: [
                   %If{
                     branches: [
                       %If.Branch{
                         cond: "a",
                         content: [
                           %If{
                             branches: [
                               %If.Branch{cond: "b", content: [%Log{label: "inner"}]}
                             ]
                           }
                         ]
                       }
                     ]
                   }
                 ]
               }
             ] = state.onentry
    end
  end

  describe "lower/1 - <foreach>, happy path" do
    # sabotage: `build_foreach/2` reads `element, "index"` through
    # `Attributes.value/2` unconditionally into `index` but the field is
    # dropped from the built `%Foreach{}` (hardcoded `nil` instead) -> this
    # test's `index: "i"` match reddens.
    test "both required attributes, optional index, and children in document order" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <foreach array="items" item="x" index="i">
                      <log label="one"/>
                      <log label="two"/>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [
               %Block{
                 content: [
                   %Foreach{
                     array: "items",
                     item: "x",
                     index: "i",
                     content: [%Log{label: "one"}, %Log{label: "two"}],
                     attribute_locations: attribute_locations
                   }
                 ]
               }
             ] = state.onentry

      assert Map.has_key?(attribute_locations, :array)
      assert Map.has_key?(attribute_locations, :item)
      assert Map.has_key?(attribute_locations, :index)
    end
  end

  describe "lower/1 - a self-closed <foreach>, an empty content list" do
    # sabotage: `build_foreach/2` builds the `%Foreach{}`'s `content` field
    # with a hardcoded non-empty default instead of the walked (empty)
    # children -> this test's empty-list match reddens.
    test "a self-closed <foreach> lowers to content: [] (Decision 6: legal, no error)" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <foreach array="items" item="x"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, document} = xml |> parse!() |> Lowering.lower()
      state = only_state(document)

      assert [%Block{content: [%Foreach{array: "items", item: "x", index: nil, content: []}]}] =
               state.onentry
    end
  end

  describe "lower/1 - <foreach>, missing required attributes" do
    # sabotage: `build_foreach/2`'s missing-attribute check for `array` is
    # dropped (only `item`'s absence is checked) -> this test would see no
    # `{:missing_attribute, "foreach", "array"}` error, reddening the match.
    test "a missing array produces a missing_attribute error" do
      xml = ~s(<scxml><state id="s"><onentry><foreach item="x"/></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:missing_attribute, "foreach", "array"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end

    # sabotage: same as above, mirrored for `item`
    test "a missing item produces a missing_attribute error" do
      xml = ~s(<scxml><state id="s"><onentry><foreach array="items"/></onentry></state></scxml>)

      assert {:error, [%Error{reason: {:missing_attribute, "foreach", "item"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end

    # sabotage: `build_foreach/2`'s missing-attribute check short-circuits
    # on the first absent attribute (`case`/`with` instead of the `for`
    # comprehension over both) -> only one error would be reported instead
    # of two, reddening this test's two-error match.
    test "a <foreach> missing both array and item reports two errors" do
      xml = ~s(<scxml><state id="s"><onentry><foreach/></onentry></state></scxml>)

      assert {:error,
              [
                %Error{reason: {:missing_attribute, "foreach", "array"}},
                %Error{reason: {:missing_attribute, "foreach", "item"}}
              ]} =
               xml |> parse!() |> Lowering.lower()
    end
  end

  describe "lower/1 - <assign> inside <foreach>" do
    # sabotage: `place/3`'s `%Foreach{}` clause is moved below the
    # unconditional `%Assign{}` clause -> the `%Assign{}` clause matches
    # `{:content_node, %Assign{}}` against any parent first, so this
    # `<assign>` would report `{:misplaced_element, "assign", "foreach"}`
    # instead of joining `content`, reddening this test.
    test "an <assign> inside a <foreach> body lands in content, not misplaced" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <foreach array="items" item="x">
                      <assign location="y" expr="x"/>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, document} = xml |> parse!() |> Lowering.lower()
      state = only_state(document)

      assert [%Block{content: [%Foreach{content: [%Assign{location: "y"}]}]}] = state.onentry
    end
  end

  describe "lower/1 - <foreach> and <if> nested in each other" do
    # sabotage: `place/3`'s `%Foreach{}` clause prepends into the wrong
    # field (e.g. always into a hardcoded `[]` rather than
    # `parent.content`) -> the nested `%If{}` would never appear inside the
    # outer `<foreach>`'s content, reddening this match.
    test "a <foreach> inside an <if> partition lowers to a %Foreach{} in that branch" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <if cond="a">
                      <foreach array="items" item="x">
                          <log label="inner"/>
                      </foreach>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [
               %Block{
                 content: [
                   %If{
                     branches: [
                       %If.Branch{
                         cond: "a",
                         content: [
                           %Foreach{array: "items", item: "x", content: [%Log{label: "inner"}]}
                         ]
                       }
                     ]
                   }
                 ]
               }
             ] = state.onentry
    end

    # sabotage: same clause, opposite nesting direction - a hardcoded `[]`
    # instead of threading `open`/`closed` through the outer `<foreach>`'s
    # own `place/3` step would drop the inner `%If{}` from `content`
    # entirely, reddening this match.
    test "an <if> inside a <foreach> body lowers to a %If{} in that content list" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <foreach array="items" item="x">
                      <if cond="b">
                          <log label="inner"/>
                      </if>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert [
               %Block{
                 content: [
                   %Foreach{
                     array: "items",
                     item: "x",
                     content: [
                       %If{branches: [%If.Branch{cond: "b", content: [%Log{label: "inner"}]}]}
                     ]
                   }
                 ]
               }
             ] = state.onentry
    end
  end
end
