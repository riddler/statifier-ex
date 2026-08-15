defmodule Statifier.Evaluator.SystemVariables do
  @moduledoc """
  Spec 5.10's system variables, as the plain maps
  `Statifier.MachineState.datamodel` carries them in. Two functions, so that
  neither `Statifier.MachineState` nor `Statifier.Interpreter` grows spec
  5.10 knowledge of its own - `MachineState.new/2` calls `initial/2` once,
  and `MachineState.put_event/2` calls `event/1` on every write.

  `nil` for an absent field is deliberate everywhere it appears here, not an
  oversight: `Statifier.Evaluator`'s own `undefine_nils/1`
  (`lib/statifier/evaluator.ex`) normalizes `nil` to `:undefined` recursively,
  so a `nil` written here becomes the spec-correct "not bound" answer once a
  `Statifier.Evaluator.context/1` wraps it, rather than the `%{}` a naive
  default would produce.
  """

  alias Statifier.Event
  alias Statifier.Machine

  @scxml_event_processor "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"
  @scxml_session_target_prefix "#_scxml_"

  @doc """
  The SCXML Event I/O Processor's type URI (spec 6.2.5 / C.1). Public so the
  session's target router names the same string this module keys
  `_ioprocessors` by, rather than a second copy of it.
  """
  @spec scxml_event_processor() :: String.t()
  def scxml_event_processor, do: @scxml_event_processor

  @doc """
  The address C.1.1 asks for: a value external entities can use to reach this
  session, which C.1 also makes the delivered event's `origin` and 5.10.1
  requires to work as a `<send target>`. `_sessionid` stays the bare UXID.
  """
  @spec scxml_location(session_id :: String.t()) :: String.t()
  def scxml_location(session_id), do: @scxml_session_target_prefix <> session_id

  @doc """
  All four system variables (spec 5.10) as they stand before any event.
  Called once, by `MachineState.new/2`.

  `_sessionid`, `_name`, and `_ioprocessors` are session-lifetime and are
  never rewritten afterward - `_sessionid` stays stable for the session's
  whole lifetime (ADR-0008). `_event` is different: it is seeded here to
  `nil` and thereafter written only by `MachineState.put_event/2`.

  ## Why `_event` is seeded rather than left absent

  Spec 5.10's system variables are *declared* for the session's whole
  lifetime; `_event` merely has no value until an event is being processed.
  A datamodel is a plain map, so the only way to say "declared, no value
  yet" is to bind the key to `nil` and let
  `Predicator.Context.new/2` normalize it to `:undefined`. Leaving the key
  out instead says something different and wrong - "no such variable" -
  which under `Statifier.Evaluator.context/1`'s `on_unbound: :error`
  (ADR-0014 item 5) makes every pre-event `_event` reference an
  `UndefinedVariableError` rather than the undefined value the spec wants.

  The W3C corpus is the evidence for which reading is right: test319 asserts
  that `_event` compares equal to undefined before any event has been
  processed, and takes its `<else>` branch to pass. Under the ECMAScript
  datamodel those tests were written against, an *undeclared* identifier
  throws `ReferenceError` - so the test can only pass if `_event` is
  declared and holds undefined, which is exactly what seeding reproduces.
  """
  @spec initial(machine :: Machine.t(), session_id :: String.t()) :: map()
  def initial(%Machine{} = machine, session_id) when is_binary(session_id) do
    %{
      "_sessionid" => session_id,
      "_name" => machine.name,
      "_event" => nil,
      "_ioprocessors" => %{
        @scxml_event_processor => %{"location" => scxml_location(session_id)}
      }
    }
  end

  @doc """
  `_event`'s value for `event` - spec 5.10.1's fields, read straight off
  `Statifier.Event`.
  """
  @spec event(event :: Event.t()) :: map()
  def event(%Event{} = event) do
    %{
      "name" => event.name,
      "type" => Atom.to_string(event.type),
      "sendid" => event.sendid,
      "origin" => event.origin,
      "origintype" => event.origintype,
      "invokeid" => event.invokeid,
      "data" => event.data
    }
  end
end
