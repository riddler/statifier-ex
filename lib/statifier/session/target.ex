defmodule Statifier.Session.Target do
  @moduledoc """
  Spec 6.2.2's `target` attribute and C.1's special-target vocabulary,
  parsed into a route `Statifier.Session.Effects` plans against, plus the
  supported-`type` predicate 6.2.5 asks for. One pure module, no process, no
  effect calls - `Mix.Statifier.AdrGuard` has nothing to say about it and no
  exemption is needed.

  Resolving a route into an actual delivery (or `error.communication`) is
  `Statifier.Session`'s job, not this module's: this module only says *what
  kind* of destination a target string names, never whether that
  destination currently exists.
  """

  alias Statifier.Evaluator.SystemVariables

  @typedoc """
  What a `<send target>` names, before any session-runtime resolution:

  - `:self` - no `target` at all; the sending session's own external queue.
  - `:internal` - `#_internal`/`_internal` (C.1/6.2.2 disagree on the
    spelling; both are accepted, decision 6).
  - `{:session, session_id}` - `#_scxml_<sessionid>`.
  - `:parent` - `#_parent`.
  - `{:invoke, invokeid}` - `#_<invokeid>`, any other `#_`-prefixed target.
    Reserved here; no bead resolves it yet (see the plan's "What We're NOT
    Doing" and "Follow-up work").
  - `{:invalid, target}` - 6.2.4's "not supported or invalid" -
    `error.execution`, never delivered and never scheduled.
  """
  @type route ::
          :self
          | :internal
          | {:session, String.t()}
          | :parent
          | {:invoke, String.t()}
          | {:invalid, String.t()}

  @doc """
  Parses a `<send target>` string (or `nil`, meaning the attribute was
  absent) into a `route()`. Never fails: every input string that names no
  recognized special target becomes `{:invalid, target}` rather than
  raising, so a planner can turn it into 6.2.4's `error.execution` with no
  `case` fallback of its own to write.
  """
  @spec parse(target :: String.t() | nil) :: route()
  def parse(nil), do: :self
  def parse("#_internal"), do: :internal

  # 6.2.2's attribute table spells it `_internal`, C.1 spells it
  # `#_internal`, and the two clauses disagree with each other. Accepting
  # both is a superset that fails no test; the corpus writes the `#_` form.
  def parse("_internal"), do: :internal
  def parse("#_parent"), do: :parent
  def parse("#_scxml_" <> session_id) when session_id != "", do: {:session, session_id}

  # C.1's `#_invokeid`. An id naming no live invocation is "a session that
  # does not exist or is inaccessible" (C.1) - error.communication, not
  # error.execution. Resolution is the session's job, not the parser's.
  def parse("#_" <> invokeid) when invokeid != "", do: {:invoke, invokeid}
  # Anything else is 6.2.4's "not supported or invalid" -> error.execution.
  def parse(other), do: {:invalid, other}

  @doc """
  Whether this Event I/O Processor supports `type` (6.2.5). `nil` (the
  attribute omitted) defaults to the SCXML Event I/O Processor, which is
  always supported. `"scxml"` is 6.2.5's explicitly-permitted short form
  ("Processors MAY define short form notations") - a MAY this codebase
  chose to honor, not a MUST - and the processor's own type URI
  (`SystemVariables.scxml_event_processor/0`) is the long form. Anything
  else is unsupported: this engine implements only the SCXML Event I/O
  Processor (see the plan's "What We're NOT Doing" on BasicHTTP).
  """
  @spec supported_type?(type :: String.t() | nil) :: boolean()
  def supported_type?(nil), do: true
  def supported_type?("scxml"), do: true
  def supported_type?(type), do: type == SystemVariables.scxml_event_processor()

  @doc """
  6.4.2's URI for `<invoke type>`, mandated verbatim: "Platforms MUST
  support `http://www.w3.org/TR/scxml/` as a value for the 'type'
  attribute." This is a **different string** from `supported_type?/1`'s
  `SystemVariables.scxml_event_processor/0` URI
  (`http://www.w3.org/TR/scxml/#SCXMLEventProcessor`): 6.4.2 names the bare
  namespace URI for invoke's `type`, 6.2.5 names the processor URI with its
  `#SCXMLEventProcessor` fragment for send's. Conflating the two would fail
  the corpus in both directions - an `<invoke type="http://www.w3.org/TR/scxml/">`
  rejected as unsupported, or a `<send type="http://www.w3.org/TR/scxml/">`
  wrongly accepted.
  """
  @spec scxml_invoke_type() :: String.t()
  def scxml_invoke_type, do: "http://www.w3.org/TR/scxml/"

  @doc """
  Whether `<invoke type>` names the SCXML Event I/O processor (6.4.2). `nil`
  (the attribute omitted) defaults to it, same as `supported_type?/1`.
  `"scxml"` is the short form 6.2.5 permits and this codebase already
  honors for `<send>`; `<invoke>` gets no separate spec license for the
  short form, but accepting it here is the same no-cost superset decision
  `parse/1` already makes for `_internal`/`#_internal` and `_parent`/`#_parent`.
  Anything else - including `supported_type?/1`'s own processor URI - is
  unsupported: this engine implements only SCXML-typed invocations (see the
  plan's "What We're NOT Doing" on BasicHTTP and non-SCXML invoke types).
  """
  @spec supported_invoke_type?(type :: String.t() | nil) :: boolean()
  def supported_invoke_type?(nil), do: true
  def supported_invoke_type?("scxml"), do: true
  def supported_invoke_type?(type), do: type == scxml_invoke_type()
end
