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
  never rewritten afterward, except a registered `_ioprocessors` entry a
  host refreshes or replaces (see below) - `_sessionid` stays stable for the session's
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
  supplied. A processor that exports the optional
  `c:Statifier.Send.Processor.ioprocessors_entry/2` is asked here, with
  the type string and a context carrying `session_id` and the
  registration's `opts`, so its entry can address this one session
  (ADR-0075 decision 3); a processor that exports only
  `c:Statifier.Send.Processor.ioprocessors_entry/1` gets the entry
  `Statifier.Send.Types.from_send_types/1` read, exactly as before. With
  `send_types` `nil`, which is what a session registering nothing carries,
  the map holds the SCXML entry alone, exactly as before registered types
  existed. A registered entry never replaces the SCXML entry: a set naming
  the processor URI still reads the SCXML entry under that key.

  The entries are written here, when the session starts, and rewritten
  only when a host asks for it. `_ioprocessors` is part of the datamodel,
  so a persisted position (`Statifier.Position`) carries the entries as
  they were written, and a resumed session reads the entries it started
  with. `MachineState.put_send_types/2`, the driver's re-stamp on a resume
  (ADR-0064), replaces the classifier's set and does not rewrite
  `_ioprocessors`. The set of registered types is fixed for the session's
  lifetime (ADR-0069 decision 2), and a host that re-stamps the set it started with
  reads the same entries it would have written; a set that changes across a
  resume is a mid-session registration, which ADR-0069 names as a trigger
  that would reopen that record.

  Two host calls rewrite entries. The first is a host's explicit refresh
  (ADR-0075's Amendment of 2026-10-02): `Statifier.MachineState.refresh_ioprocessors/1`, and
  `Statifier.Session.refresh_ioprocessors/1` for a live session, ask every
  registered processor that exports
  `c:Statifier.Send.Processor.ioprocessors_entry/2` for its entry again,
  from the registration the position is stamped with, so a host whose
  base URL moved, or whose front rotated a location, can tell the chart.
  The refresh replaces entry values and nothing else: the SCXML entry, an
  entry from a processor that exports only
  `c:Statifier.Send.Processor.ioprocessors_entry/1`, and the set of keys
  stay as they were, so the registered type set stays fixed.

  The second is `Statifier.Session.replace_send_type/3` on a running
  session (ADR-0069's Amendment of 2026-10-09), which replaces one
  registered type's registration, its module and options, and rewrites
  that type's entry from the new registration as this function writes it
  at start: from `c:Statifier.Send.Processor.ioprocessors_entry/2` when the
  new module exports it, else from its
  `c:Statifier.Send.Processor.ioprocessors_entry/1` value, so an entry from
  a processor that exports only the `/1` callback changes too. The SCXML
  entry, every other type's entry and the set of keys stay as they were.

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
          registered_entries(send_types, session_id),
          @scxml_event_processor,
          %{"location" => scxml_location(session_id)}
        )
    }
  end

  @spec registered_entries(send_types :: Types.t() | nil, session_id :: String.t()) ::
          %{String.t() => map()}
  defp registered_entries(nil, _session_id), do: %{}

  defp registered_entries(%Types{entries: entries, processors: processors}, session_id) do
    Map.new(entries, fn {type, entry} ->
      case Map.fetch(processors, type) do
        {:ok, {module, opts}} -> {type, session_entry(module, type, opts, session_id, entry)}
        :error -> {type, entry}
      end
    end)
  end

  # ADR-0075 decision 3: a module that exports `/2` is asked for its entry
  # with the session id; one that exports only `/1` keeps the entry the
  # registered set was built with.
  @spec session_entry(
          module :: module(),
          type :: String.t(),
          opts :: keyword(),
          session_id :: String.t(),
          entry :: map()
        ) :: map()
  defp session_entry(module, type, opts, session_id, entry) do
    if function_exported?(module, :ioprocessors_entry, 2),
      do: Types.session_entry!(module, type, %{session_id: session_id, opts: opts}),
      else: entry
  end

  # The refresh `Statifier.MachineState.refresh_ioprocessors/1` writes
  # (ADR-0075's Amendment of 2026-10-02): `ioprocessors` with every key that
  # names a registered type whose processor exports `ioprocessors_entry/2`
  # recomputed from `send_types`'s registration and `session_id`. Every
  # such processor that exports `check_registration/2` is asked first, in
  # type order, and the first `{:error, reason}` is the answer, before any
  # entry is recomputed. A check that answers outside its contract does not
  # stop the refresh. Every entry is computed before any is returned, so a
  # refresh is all or nothing. An entry that raises, or is not a
  # string-keyed map, raises here when `on_raise` is `:raise`, as it does at
  # session start (the pure call), except that an Erlang-level error is
  # re-raised as the exception struct `rescue` normalised it to rather than
  # as its raw reason; when it is `:answer` (the live
  # session's call, which must not exit a running session) it answers
  # `{:error, {:ioprocessors_entry, type, exception}}` instead. Only an
  # exception is rescued: a throw or an exit out of an entry is outside
  # the callback's contract (it returns a map or raises) and passes
  # through. The guard is deliberate: a datamodel without an
  # `_ioprocessors` map or a string `_sessionid` is outside the refresh's
  # input (`Statifier.MachineState.refresh_ioprocessors/1` records it), so
  # it raises `FunctionClauseError` here. Internal, hence `@doc false`.
  @doc false
  @spec refreshed_ioprocessors(
          ioprocessors :: %{String.t() => map()},
          send_types :: Types.t(),
          session_id :: String.t(),
          on_raise :: :raise | :answer
        ) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def refreshed_ioprocessors(
        ioprocessors,
        %Types{processors: processors},
        session_id,
        on_raise
      )
      when is_map(ioprocessors) and is_binary(session_id) and on_raise in [:raise, :answer] do
    refreshable =
      processors
      |> Enum.filter(fn {type, {module, _opts}} ->
        type != @scxml_event_processor and Map.has_key?(ioprocessors, type) and
          Code.ensure_loaded?(module) and function_exported?(module, :ioprocessors_entry, 2)
      end)
      |> Enum.sort_by(fn {type, _processor} -> type end)

    case Enum.find_value(refreshable, &rejected/1) do
      nil -> refreshed_entries(refreshable, ioprocessors, session_id, on_raise)
      {:error, _reason} = error -> error
    end
  end

  # Every refreshable entry, computed into `ioprocessors` before any is
  # returned. The first entry that raises answers for the whole refresh
  # (`:answer`) or re-raises with its own stacktrace
  # (`:raise`), and the entries computed before it are dropped.
  @spec refreshed_entries(
          refreshable :: [{String.t(), {module(), keyword()}}],
          ioprocessors :: %{String.t() => map()},
          session_id :: String.t(),
          on_raise :: :raise | :answer
        ) :: {:ok, %{String.t() => map()}} | {:error, term()}
  defp refreshed_entries(refreshable, ioprocessors, session_id, on_raise) do
    Enum.reduce_while(refreshable, {:ok, ioprocessors}, fn {type, {module, opts}}, {:ok, acc} ->
      try do
        entry = Types.session_entry!(module, type, %{session_id: session_id, opts: opts})
        {:cont, {:ok, Map.put(acc, type, entry)}}
      rescue
        exception ->
          if on_raise == :raise, do: reraise(exception, __STACKTRACE__)
          {:halt, {:error, {:ioprocessors_entry, type, exception}}}
      end
    end)
  end

  # `ioprocessors` with `type`'s entry recomputed from `send_types`, the
  # set its registration was just replaced in, as `initial/3` computes a
  # registered entry: asked of a processor that exports
  # `ioprocessors_entry/2` with the type, `session_id` and the
  # registration's options, else the `ioprocessors_entry/1` value the set
  # holds. Only a key `ioprocessors` already has is rewritten, so no key is
  # added or dropped, as a refresh adds or drops none. An entry that raises,
  # or is not a string-keyed map, raises here; the caller answers it.
  # Internal: `Statifier.MachineState`'s replace step is its one caller,
  # hence `@doc false`.
  @doc false
  @spec replaced_ioprocessors(
          ioprocessors :: %{String.t() => map()},
          send_types :: Types.t(),
          type :: String.t(),
          session_id :: String.t()
        ) :: %{String.t() => map()}
  def replaced_ioprocessors(
        ioprocessors,
        %Types{entries: entries, processors: processors},
        type,
        session_id
      )
      when is_map(ioprocessors) and is_binary(type) and is_binary(session_id) do
    if Map.has_key?(ioprocessors, type) do
      {module, opts} = Map.fetch!(processors, type)
      entry = session_entry(module, type, opts, session_id, Map.fetch!(entries, type))
      Map.put(ioprocessors, type, entry)
    else
      ioprocessors
    end
  end

  @spec rejected({type :: String.t(), processor :: {module(), keyword()}}) ::
          {:error, term()} | nil
  defp rejected({type, processor}) do
    case Types.check_registration(type, processor) do
      {:error, _reason} = error -> error
      _ok_or_unanswered -> nil
    end
  end

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
