defmodule StatifierTest do
  use ExUnit.Case, async: true

  alias Statifier.Machine

  # sabotage: in `Statifier.compile/1`, swap `Compiler.compile(document)` for
  # `{:ok, document}` (return the uncompiled document instead of running the
  # compiler) -> the `%Machine{}` pattern match below goes red because the
  # returned struct is a `%Statifier.Document{}`, not a `%Statifier.Machine{}`
  test "compiles a small document to a Machine whose id_to_index holds the written ids" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """

    assert {:ok, %Machine{id_to_index: id_to_index}} = Statifier.compile(xml)
    assert %{"a" => _a_index, "b" => _b_index} = id_to_index
  end

  # sabotage: in `Statifier.compile/1`'s private `parse/1` helper, change the
  # error clause to `{:error, error} -> {:error, error}` (drop the
  # one-element-list wrap) -> the `[%Statifier.Parser.ParseError{}]` pattern
  # below goes red because the error comes back bare, not wrapped in a list
  test "malformed XML fails at the parse stage with a list of ParseError" do
    xml = "<scxml><state id=\"a\"></scxml>"

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Parser.ParseError{}] = errors
  end

  # sabotage: in `Statifier.compile/1`, swap the `with` clause order so
  # `Validator.validate/2` runs before `Lowering.lower/1` (pass the DOM
  # root straight to the validator) -> this test reddens with a
  # FunctionClauseError instead of the expected [%Lowering.Error{}] match,
  # because the validator never receives a %Statifier.Document{}
  test "a foreign or unexpected root element fails at the lowering stage with a list of Lowering.Error" do
    xml = ~s(<foo/>)

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Lowering.Error{}] = errors
  end

  # sabotage: in `Statifier.compile/1`, drop the `Validator.validate/2` step
  # from the `with` chain (feed the lowered document straight to
  # `Compiler.compile/1`) -> this test reddens because the transition to an
  # unknown target no longer fails validation and the pipeline instead
  # returns {:ok, %Machine{}}
  test "a transition to an unknown target fails at the validation stage with a list of Validator.Error" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="missing"/>
        </state>
    </scxml>
    """

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Validator.Error{}] = errors
  end

  # sabotage: in `Statifier.compile/1`, replace the final `Compiler.compile(document)`
  # call with `{:ok, %Machine{states: {}, id_to_index: %{}, transitions: {},
  # contents: {}, location: document.location}}` (fabricate a Machine instead
  # of compiling) -> this test reddens because compile/1 now returns {:ok, _}
  # instead of the expected list of Compiler.Error for the broken expression
  test "an uncompilable expression fails at the compiler stage with a list of Compiler.Error" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" cond="1 &gt;" target="a"/>
        </state>
    </scxml>
    """

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Compiler.Error{}] = errors
  end
end
