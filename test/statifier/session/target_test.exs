defmodule Statifier.Session.TargetTest do
  use ExUnit.Case, async: true

  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Session.Target

  describe "parse/1" do
    # sabotage: `parse/1`'s `def parse(nil), do: :self` clause is deleted,
    # falling through to the catch-all `{:invalid, other}` clause -> this
    # assertion reddens (`:self` no longer returned for `nil`)
    test "nil (no target attribute) is :self" do
      assert Target.parse(nil) == :self
    end

    # sabotage: the `"#_internal"` clause is deleted, falling through to the
    # `"#_" <> invokeid` clause -> this reddens (`{:invoke, "internal"}`
    # instead of `:internal`)
    test "#_internal is :internal" do
      assert Target.parse("#_internal") == :internal
    end

    # sabotage: the `"_internal"` clause is deleted, falling through to the
    # catch-all -> this reddens (`{:invalid, "_internal"}` instead of
    # `:internal`)
    test "_internal (6.2.2's own spelling) is also :internal" do
      assert Target.parse("_internal") == :internal
    end

    # sabotage: the `"#_parent"` clause is deleted, falling through to the
    # `"#_" <> invokeid` clause -> this reddens (`{:invoke, "parent"}`
    # instead of `:parent`)
    test "#_parent is :parent" do
      assert Target.parse("#_parent") == :parent
    end

    # sabotage: the `"#_scxml_" <> session_id` clause's guard
    # `when session_id != ""` is dropped -> `"#_scxml_"` alone (empty
    # session id) would now match this clause as `{:session, ""}` instead
    # of falling through to the next clause (`"#_" <> invokeid`, which
    # matches `invokeid: "scxml_"`), reddening the assertion below
    test "#_scxml_<sessionid> is {:session, sessionid}" do
      assert Target.parse("#_scxml_sess_abc123") == {:session, "sess_abc123"}
      assert Target.parse("#_scxml_") == {:invoke, "scxml_"}
    end

    # sabotage: the `"#_" <> invokeid` clause's guard `when invokeid != ""`
    # is dropped -> `"#_"` alone would now match as `{:invoke, ""}` instead
    # of falling through to `{:invalid, "#_"}`, reddening the empty-suffix
    # assertion below
    test "#_<invokeid> (any other #_-prefixed target) is {:invoke, invokeid}" do
      assert Target.parse("#_my_invoke_1") == {:invoke, "my_invoke_1"}
      assert Target.parse("#_") == {:invalid, "#_"}
    end

    # sabotage: the catch-all `def parse(other), do: {:invalid, other}`
    # clause is deleted entirely -> `parse/1` raises `FunctionClauseError`
    # for an ordinary URI target instead of returning `{:invalid, _}`,
    # reddening this assertion
    test "anything else is {:invalid, target}" do
      assert Target.parse("http://example.com/mailbox") ==
               {:invalid, "http://example.com/mailbox"}
    end
  end

  describe "supported_type?/1" do
    # sabotage: `supported_type?(nil)`'s clause returns `false` instead of
    # `true` -> this reddens
    test "nil defaults to the SCXML Event I/O Processor, supported" do
      assert Target.supported_type?(nil)
    end

    # sabotage: the `"scxml"` short-alias clause is deleted, falling through
    # to the URI-equality clause -> `"scxml"` no longer matches (it is not
    # equal to the URI string), reddening this assertion
    test ~s(the "scxml" short alias is supported) do
      assert Target.supported_type?("scxml")
    end

    # sabotage: `supported_type?/1`'s final clause changes `type ==
    # SystemVariables.scxml_event_processor()` to `type != ...` -> this
    # reddens (the URI itself would read as unsupported)
    test "the processor's own type URI is supported" do
      assert Target.supported_type?(SystemVariables.scxml_event_processor())
    end

    # sabotage: n/a - this test only confirms an arbitrary unrelated string
    # falls through every supported clause; it is the negative space of the
    # two positive clauses above, not a new mutation to sabotage
    # independently.
    test "an unsupported type string is unsupported" do
      refute Target.supported_type?("http://example.com/BasicHTTPEventProcessor")
    end
  end
end
