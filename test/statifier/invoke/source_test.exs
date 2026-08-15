defmodule Statifier.Invoke.SourceTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.Source
  alias Statifier.Machine

  defp invoke(fields) do
    struct!(
      Invoke,
      Keyword.merge(
        [invoke_id: "i1", state_index: 0, invoke_index: 0, macrostep: 1, microstep: 1],
        fields
      )
    )
  end

  @child_xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s1" version="1.0" datamodel="predicator">
      <final id="s1" />
  </scxml>
  """

  describe "resolve/2" do
    # sabotage: the `content is a binary` success clause's `{:ok, machine} ->
    # {:ok, machine}` branch is changed to `{:ok, _machine} -> {:error,
    # :sabotage}` -> the `{:ok, %Machine{}}` match below reddens
    test "content is a binary -> Statifier.compile/1, success" do
      assert {:ok, %Machine{}} = Source.resolve(invoke(content: @child_xml), [])
    end

    # sabotage: `resolve/2`'s `content is a binary` clause's `{:error, errors}`
    # branch is changed to `{:error, {:content_not_markup, errors}}` (wrong
    # tag) -> the assertion on `{:compile, [_ | _]}` below reddens
    test "content is a binary -> Statifier.compile/1, failure folds to {:compile, errors}" do
      assert {:error, {:compile, [_error | _rest]}} =
               Source.resolve(invoke(content: "<not-scxml/>"), [])
    end

    # sabotage: the `content is nil, src is a binary, opts[:invoke_source] is
    # a fun` clause's `resolver.(src)` call is changed to `resolver.("wrong")`
    # -> the resolver is called with the wrong argument, and the assertion
    # that the resolver received the original `src` reddens
    test "content is nil, src is a binary, opts[:invoke_source] is a fun -> fun.(src)" do
      test_pid = self()

      resolver = fn src ->
        send(test_pid, {:resolved, src})
        Statifier.compile(@child_xml)
      end

      assert {:ok, %Machine{}} =
               Source.resolve(invoke(content: nil, src: "file:child.scxml"),
                 invoke_source: resolver
               )

      assert_received {:resolved, "file:child.scxml"}
    end

    # sabotage: the resolver-branch clause wraps the resolver's return in an
    # extra `{:ok, _}` (`{:ok, resolver.(src)}` instead of `resolver.(src)`)
    # -> this assertion reddens (`{:ok, {:error, :boom}}` instead of
    # `{:error, :boom}`)
    test "content is nil, src is a binary, opts[:invoke_source] returns {:error, _} unchanged" do
      resolver = fn _src -> {:error, :boom} end

      assert {:error, :boom} =
               Source.resolve(invoke(content: nil, src: "file:child.scxml"),
                 invoke_source: resolver
               )
    end

    # sabotage: the `no resolver` branch is changed from
    # `{:error, :src_not_resolved}` to `{:ok, nil}` -> this assertion reddens
    test "content is nil, src is a binary, no resolver -> {:error, :src_not_resolved}" do
      assert {:error, :src_not_resolved} =
               Source.resolve(invoke(content: nil, src: "file:x.scxml"), [])
    end

    # sabotage: the `content_not_markup` clause's guard `not is_nil(content)`
    # is dropped, so this clause also matches a `nil` content and the
    # `:no_source` test below reddens (it now returns `{:content_not_markup,
    # nil}` instead of `{:error, :no_source}`)
    test "content is neither nil nor a binary -> {:error, {:content_not_markup, content}}" do
      assert {:error, {:content_not_markup, %{a: 1}}} =
               Source.resolve(invoke(content: %{a: 1}), [])
    end

    # sabotage: the `src`-checking clause is reordered ahead of the
    # `content`-checking clause -> a `src` with no `invoke_source` configured
    # now wins over a compilable `content`, and this assertion reddens
    # (`{:error, :src_not_resolved}` instead of `{:ok, %Machine{}}`)
    test "content wins over src when both are present" do
      assert {:ok, %Machine{}} =
               Source.resolve(invoke(content: @child_xml, src: "file:ignored.scxml"), [])
    end

    # sabotage: the final clause's `{:error, :no_source}` is changed to
    # `{:error, :src_not_resolved}` -> this assertion reddens
    test "neither src nor content -> {:error, :no_source}" do
      assert {:error, :no_source} = Source.resolve(invoke(content: nil, src: nil), [])
    end
  end
end
