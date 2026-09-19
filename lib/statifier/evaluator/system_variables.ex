defmodule Statifier.Evaluator.SystemVariables do
  @moduledoc """
  Spec 5.10's system variables, as the plain maps
  `Statifier.MachineState.datamodel` carries them in. Two functions, so that
  neither `Statifier.MachineState` nor `Statifier.Interpreter` grows spec
  5.10 knowledge of its own - `MachineState.new/2` calls `initial/3` once,
  and `MachineState.put_event/2` calls `event/1` on every write.

  Every writer here spells "declared, no value yet" as `:undefined` directly,
  never `nil` - `nil` is reserved for predicator's own null (ADR-0037,
  `docs/adr/0037-unbound-spelled-undefined-at-the-writer.md`). Writing the
  spec-correct "not bound" answer at the source means a
  `Statifier.Evaluator.context/1` wrap needs no normalization pass to produce
  it.
  """

  alias Statifier.{Event, Machine}
  alias Statifier.Send.Types

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
  requires to work as a `<send target>`. `_sessionid` stays the bare session id.
  """
  @spec scxml_location(session_id :: String.t()) :: String.t()
  def scxml_location(session_id), do: @scxml_session_target_prefix <> session_id

  @doc """
  All four system variables (spec 5.10) as they stand before any event.
  Called once, by `MachineState.new/2`, with its `:send_types` option as
  `send_types`.

  `_sessionid`, `_name`, and `_ioprocessors` are session-lifetime and are
  never rewritten afterward - `_sessionid` stays stable for the session's
  whole lifetime (ADR-0008). `_event` is different: it is seeded here to
  `:undefined` and thereafter written only by `MachineState.put_event/2`.

  `_name` binds `machine.name` (`String.t() | nil` on `Statifier.Machine`,
  since a `<scxml>` element may omit the optional `name` attribute). Spec
  5.10 only says the Processor "MUST bind the variable `_name` ... to the
  value of the 'name' attribute", and is silent on an absent attribute; an
  absent optional attribute is exactly "declared, no value yet", so a `nil`
  `machine.name` runs through `absent/1` the same as an absent `_event`
  field does, and `_name` reads as `:undefined` rather than as a datamodel
  null.

  ## `_ioprocessors` and registered send types

  5.10: "The SCXML Processor MUST bind the variable _ioprocessors to a set
  of values, one for each Event I/O Processor that it supports." The SCXML
  Event I/O Processor's entry, keyed by its URI and holding the session's
  `"location"`, is always there. A session that registers send types
  (ADR-0069) supports each of them too, so `_ioprocessors` also carries one
  entry per registered type string, whose value the type's processor
  supplied (`Statifier.Send.Types.from_send_types/1` read it). With
  `send_types` `nil`, which is what a session registering nothing carries,
  the map holds the SCXML entry alone, exactly as before registered types
  existed. A registered entry never replaces the SCXML entry: a set naming
  the processor URI still reads the SCXML entry under that key.

  The entries are written here, once, when the session starts, and
  nowhere else. `_ioprocessors` is part of the datamodel, so a persisted
  position (`Statifier.Position`) carries the entries as they were written,
  and a resumed session reads the entries it started with.
  `MachineState.put_send_types/2`, the driver's re-stamp on a resume
  (ADR-0064), replaces the classifier's set and does not rewrite
  `_ioprocessors`. The registration is fixed for the session's lifetime
  (ADR-0069 decision 2), and a host that re-stamps the set it started with
  reads the same entries it would have written; a set that changes across a
  resume is a mid-session registration, which ADR-0069 names as a trigger
  that would reopen that record.

  ## Why `_event` is seeded rather than left absent

  Spec 5.10's system variables are *declared* for the session's whole
  lifetime; `_event` merely has no value until an event is being processed.
  A datamodel is a plain map, so the only way to say "declared, no value
  yet" is to bind the key to `:undefined` directly. Leaving the key
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
  @spec initial(machine :: Machine.t(), session_id :: String.t(), send_types :: Types.t() | nil) ::
          map()
  def initial(%Machine{} = machine, session_id, send_types \\ nil) when is_binary(session_id) do
    %{
      "_sessionid" => session_id,
      "_name" => absent(machine.name),
      "_event" => :undefined,
      "_ioprocessors" =>
        Map.put(
          registered_entries(send_types),
          @scxml_event_processor,
          %{"location" => scxml_location(session_id)}
        )
    }
  end

  @spec registered_entries(send_types :: Types.t() | nil) :: %{String.t() => map()}
  defp registered_entries(nil), do: %{}
  defp registered_entries(%Types{entries: entries}), do: entries

  @doc """
  `_event`'s value for `event` - spec 5.10.1's fields, read straight off
  `Statifier.Event`. `sendid`/`origin`/`origintype`/`invokeid` are
  `String.t() | nil` on `Statifier.Event` (a datamodel null can never be one
  of them, so `nil` there is unambiguous - `Statifier.Event`'s moduledoc
  makes the same argument); `absent/1` translates a `nil` to `:undefined`
  here, where they cross into the datamodel (the same translation
  `initial/2` reuses for `_name`), so `_event`'s own fields spell "declared,
  no value yet" the way every other datamodel writer does. `data` is not
  translated - `Statifier.EventData.coerce/1`
  already spells `:undefined` for "no data" and `nil` for a null payload, so
  it passes through verbatim.
  """
  @spec event(event :: Event.t()) :: map()
  def event(%Event{} = event) do
    %{
      "name" => event.name,
      "type" => Atom.to_string(event.type),
      "sendid" => absent(event.sendid),
      "origin" => absent(event.origin),
      "origintype" => absent(event.origintype),
      "invokeid" => absent(event.invokeid),
      "data" => event.data
    }
  end

  @spec absent(value :: String.t() | nil) :: String.t() | :undefined
  defp absent(nil), do: :undefined
  defp absent(value), do: value
end
