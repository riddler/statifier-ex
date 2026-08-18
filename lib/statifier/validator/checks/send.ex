defmodule Statifier.Validator.Checks.Send do
  @moduledoc """
  Spec 6.2.2's mutual-exclusion constraints on `<send>`'s attributes and
  children, each reported at the `<send>` element's own `location`:

  - `{:send_event_and_eventexpr}` - "event: Must not occur with
    'eventexpr'."
  - `{:send_target_and_targetexpr}` - "target: Must not occur with
    'targetexpr'."
  - `{:send_type_and_typeexpr}` - "type: Must not occur with 'typeexpr'."
  - `{:send_id_and_idlocation}` - "id: Must not occur with 'idlocation'."
  - `{:send_delay_and_delayexpr}` - "delay: Must not occur with
    'delayexpr' or when the attribute 'target' has the value '_internal'."
    - the `delay`/`delayexpr` half of that constraint.
  - `{:send_delay_and_internal_target}` - the other half of the same
    constraint: `delay` or `delayexpr` alongside a literal
    `target="_internal"` (or `target="#_internal"`, decision 6). Detectable
    only when `target` is a literal attribute - with `targetexpr` the value
    is not known until execute time, so this check stays silent there
    rather than guessing.
  - `{:send_namelist_and_content}` / `{:send_param_and_content}` - 6.2.3:
    "A conformant document MUST NOT specify 'namelist' or `<param>` with
    `<content>`."

  `lib/statifier/document/send.ex` makes every one of these pairs
  simultaneously representable precisely so this check can report the
  shape rather than lowering refusing to build it - the same division of
  labour `Checks.Invoke` has for its own five constraints. Collect-all: a
  `<send>` that trips more than one constraint reports every one it trips,
  not just the first.

  Deliberately **not** enforced: 6.2.3's "A conformant SCXML document MUST
  specify exactly one of 'event', 'eventexpr' and `<content>`" as a
  three-way constraint. Only the `event`/`eventexpr` pairwise exclusivity
  above is checked; `<content>` alongside `event` passes.

  Read literally, that sentence makes `<send event="e"><content>...</content></send>`
  nonconformant, and 6.2.6 restates the same split ("the document author
  can specify the message content in one of two mutually exclusive ways"),
  so it is not a drafting slip in a single clause. The omission rests on
  two things that outweigh the letter rather than on reading it away:

  - The W3C's own **mandatory** conformance tests violate it.
    `test/scxml_tests/mandatory/send/test179_test.exs` and
    `test/scxml_tests/mandatory/scxml_event_processor/test354_test.exs`
    both carry `<send event="..."><content>123</content></send>`, and both
    carry the `send_elements` feature atom. Enforcing the constraint at
    error severity would reject two mandatory tests the moment that atom
    is flipped. No corpus file specifies `<content>` without `event`, so
    the pairwise checks above reject nothing that exists.
  - 6.2.3 contradicts 6.2.2's own attribute table. The `event` row reads
    "If the type is http://www.w3.org/TR/scxml/#SCXMLEventProcessor,
    either this attribute or 'eventexpr' must be present", and that
    processor is the default type (6.2.5) - so a `<content>`-only `<send>`
    with no `type` satisfies "exactly one" and violates the event-presence
    requirement at the same time. The letter is unsatisfiable for a
    content-bearing send over the default processor, and the WG's test
    suite resolves it the way this check does.

  ADR-0033's warning tier is the natural home for a document-directed MUST
  the engine has defined behavior for, and it was considered; a warning
  that fires on the W3C's own conformance suite is noise rather than
  diligence, so this stays silent. Do not "fix" the omission by reflex on
  finding 6.2.6: the behavior is forced by the corpus, and changing it
  needs the two facts above rebutted first.

  The same clause also forbids **zero** of the three, and that half is
  unchecked too: a `<send/>` with neither `event`, `eventexpr`, nor
  `<content>` is accepted and produces an effect with `event: nil`. No
  corpus file does this, so unlike the three-way constraint it has no
  evidence against it - a fair warning-tier candidate if one is ever
  wanted, left alone here because nothing needs it yet.

  The walk reaches every block a `<send>` can appear in: a state's
  `onentry`/`onexit`, its own (and its `<initial>` element's) transitions,
  `<if>`/`<foreach>` bodies nested in any of those, and every `<invoke>`'s
  `<finalize>` block - mirroring `Checks.Assign`'s reach plus
  `Checks.Invoke`'s `finalize` walk, since a `<send>` inside `<finalize>`
  is 6.5.2's other forbidden case (`Checks.Invoke.forbidden/1`) and still
  has to satisfy 6.2.2's own constraints regardless of where it sits.
  """

  alias Statifier.Document
  alias Statifier.Document.{Block, Initial, State}
  alias Statifier.Document.Foreach, as: DForeach
  alias Statifier.Document.If, as: DIf
  alias Statifier.Document.Send, as: DSend
  alias Statifier.Validator.{Context, Error}

  @doc """
  Walks every `<send>` in the document and returns one error per 6.2.2/6.2.3
  constraint it violates. Returns `[]` when every `<send>` in the document
  satisfies all eight.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(&sends_of/1)
    |> Enum.flat_map(&check_send/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp sends_of(%State{} = state) do
    block_sends(state.onentry) ++
      block_sends(state.onexit) ++
      transition_sends(state.transitions) ++
      initial_sends(state.initial_element) ++
      invoke_finalize_sends(state.invoke)
  end

  defp block_sends(blocks) do
    blocks
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DSend{}, &1))
  end

  defp transition_sends(transitions) do
    transitions
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DSend{}, &1))
  end

  # Mirrors `Checks.Assign.descend/1` / `Checks.Invoke.descend/1`: a
  # `%DIf{}`/`%DForeach{}` carries no `<send>` itself, only branches/content
  # that might, so the walk must descend into both to reach a nested one.
  defp descend(%DIf{branches: branches}) do
    branches |> Enum.flat_map(& &1.content) |> Enum.flat_map(&descend/1)
  end

  defp descend(%DForeach{content: content}), do: Enum.flat_map(content, &descend/1)

  defp descend(other), do: [other]

  defp initial_sends(nil), do: []
  defp initial_sends(%Initial{transitions: transitions}), do: transition_sends(transitions)

  defp invoke_finalize_sends(invokes) do
    invokes
    |> Enum.map(& &1.finalize)
    |> Enum.flat_map(&finalize_sends/1)
  end

  defp finalize_sends(nil), do: []

  defp finalize_sends(%Block{content: content}) do
    content
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DSend{}, &1))
  end

  defp check_send(%DSend{location: location} = send) do
    event_and_eventexpr(send, location) ++
      target_and_targetexpr(send, location) ++
      type_and_typeexpr(send, location) ++
      id_and_idlocation(send, location) ++
      delay_and_delayexpr(send, location) ++
      delay_and_internal_target(send, location) ++
      namelist_and_content(send, location) ++
      param_and_content(send, location)
  end

  defp event_and_eventexpr(%DSend{event: event, eventexpr: eventexpr}, location)
       when not is_nil(event) and not is_nil(eventexpr) do
    [Error.send_event_and_eventexpr(location)]
  end

  defp event_and_eventexpr(%DSend{}, _location), do: []

  defp target_and_targetexpr(%DSend{target: target, targetexpr: targetexpr}, location)
       when not is_nil(target) and not is_nil(targetexpr) do
    [Error.send_target_and_targetexpr(location)]
  end

  defp target_and_targetexpr(%DSend{}, _location), do: []

  defp type_and_typeexpr(%DSend{type: type, typeexpr: typeexpr}, location)
       when not is_nil(type) and not is_nil(typeexpr) do
    [Error.send_type_and_typeexpr(location)]
  end

  defp type_and_typeexpr(%DSend{}, _location), do: []

  defp id_and_idlocation(%DSend{id: id, idlocation: idlocation}, location)
       when not is_nil(id) and not is_nil(idlocation) do
    [Error.send_id_and_idlocation(location)]
  end

  defp id_and_idlocation(%DSend{}, _location), do: []

  defp delay_and_delayexpr(%DSend{delay: delay, delayexpr: delayexpr}, location)
       when not is_nil(delay) and not is_nil(delayexpr) do
    [Error.send_delay_and_delayexpr(location)]
  end

  defp delay_and_delayexpr(%DSend{}, _location), do: []

  # Detectable only when `target` is a **literal** attribute - a `<send
  # delayexpr="..." targetexpr="who">` cannot be checked until execute time,
  # so this clause's guard only ever matches a literal `target: "_internal"`
  # (or `"#_internal"`) and stays silent whenever `targetexpr` was written
  # instead (see moduledoc). Both spellings match for decision 6's reason:
  # 6.2.2's attribute table spells it `_internal`, C.1 spells it
  # `#_internal`, and the two clauses of the spec disagree with each other -
  # accepting both here is the same superset `Statifier.Send.Target.parse/1`
  # accepts.
  defp delay_and_internal_target(
         %DSend{delay: delay, delayexpr: delayexpr, target: target},
         location
       )
       when target in ["_internal", "#_internal"] and (not is_nil(delay) or not is_nil(delayexpr)) do
    [Error.send_delay_and_internal_target(location)]
  end

  defp delay_and_internal_target(%DSend{}, _location), do: []

  defp namelist_and_content(%DSend{namelist: namelist, content: content}, location)
       when namelist != [] and not is_nil(content) do
    [Error.send_namelist_and_content(location)]
  end

  defp namelist_and_content(%DSend{}, _location), do: []

  defp param_and_content(%DSend{params: params, content: content}, location)
       when params != [] and not is_nil(content) do
    [Error.send_param_and_content(location)]
  end

  defp param_and_content(%DSend{}, _location), do: []
end
