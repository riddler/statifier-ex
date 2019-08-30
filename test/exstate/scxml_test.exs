defmodule Exstate.ScxmlTest do
  use ExUnit.Case

  test "parses basic0" do
    scxml_path = "./test/fixtures/scxml/basic/basic0.scxml"
    {:ok, xmldoc} = File.read Path.expand scxml_path

    sc_map = Exstate.Scxml.parse_statechart xmldoc

    assert %{
      id: "",
      initial: "a",
      states: [
        %{ id: "a", initial: "", states: [], transitions: [] }
      ],
      transitions: []
    } === sc_map
  end

  test "parses basic1" do
    scxml_path = "./test/fixtures/scxml/basic/basic1.scxml"
    {:ok, xmldoc} = File.read Path.expand scxml_path

    sc_map = Exstate.Scxml.parse_statechart xmldoc

    assert %{
      id: "",
      initial: "",
      states: [
        %{ id: "a", initial: "", states: [], transitions: [
          %{ event: "t", target: "b" }
        ]},
        %{ id: "b", initial: "", states: [], transitions: []}
      ],
      transitions: []
    } == sc_map
  end

  test "parses basic2" do
    scxml_path = "./test/fixtures/scxml/basic/basic2.scxml"
    {:ok, xmldoc} = File.read Path.expand scxml_path

    sc_map = Exstate.Scxml.parse_statechart xmldoc

    assert %{
      id: "",
      initial: "",
      states: [
        %{ id: "a", initial: "", states: [], transitions: [
          %{ event: "t", target: "b" }
        ]},
        %{ id: "b", initial: "", states: [], transitions: [
          %{ event: "t2", target: "c" }
        ]},
        %{ id: "c", initial: "", states: [], transitions: []}
      ],
      transitions: []
    } == sc_map
  end
end

