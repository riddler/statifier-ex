defmodule Mix.Statifier.Corpus.XmlFormatTest do
  use ExUnit.Case, async: true

  doctest Mix.Statifier.Corpus.XmlFormat

  alias Mix.Statifier.Corpus.XmlFormat

  describe "format/1" do
    # sabotage: render/2's text branch dropping escape_text/1 -> red
    test "keeps text and attribute values escaped, and drops mixed-content text" do
      xml =
        ~s|<scxml a="x &amp; &quot;y&quot;"><log expr="1 &lt; 2">a &lt; b</log><if>text<else/></if></scxml>|

      assert {:ok, {formatted, nil}} = XmlFormat.format(xml)

      assert formatted ==
               ~s|<?xml version="1.0" encoding="UTF-8"?>\n| <>
                 ~s|<scxml a="x &amp; &quot;y&quot;">\n| <>
                 ~s|    <log expr="1 &lt; 2">a &lt; b</log>\n| <>
                 ~s|    <if>\n        <else />\n    </if>\n| <>
                 ~s|</scxml>\n|
    end

    # sabotage: @dropped_attrs emptied (xmlns:conf kept) -> red
    test "drops the transform's xmlns:conf declaration and keeps the others" do
      xml =
        ~s|<scxml xmlns="http://www.w3.org/2005/07/scxml" xmlns:conf="urn:c" datamodel="predicator"/>|

      assert {:ok, {formatted, "predicator"}} = XmlFormat.format(xml)

      assert formatted =~
               ~s|<scxml xmlns="http://www.w3.org/2005/07/scxml" datamodel="predicator" />|
    end

    # sabotage: format/1's error clause raising the parser's error -> red
    test "refuses a document that does not parse, with a sentence" do
      assert {:error, "the document does not parse: " <> _reason} = XmlFormat.format("<scxml>")
    end
  end
end
