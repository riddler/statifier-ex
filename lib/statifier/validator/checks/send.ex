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
    `target="_internal"`. Detectable only when `target` is a literal
    attribute - with `targetexpr` the value is not known until execute
    time, so this check stays silent there rather than guessing.
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
  three-way constraint. `<content>` under `<send>` is the message
  *payload*, not the event name, and reading that sentence literally would
  refuse the extremely common `<send event="e"><content>...</content></send>`.
  Only the `event`/`eventexpr` pairwise exclusivity above is checked;
  `<content>`'s co-occurrence with `event` is fine. This is recorded here
  so the omission is a decision on the record rather than a gap a later
  reader closes by reflex.

  The walk reaches every block a `<send>` can appear in: a state's
  `onentry`/`onexit`, its own (and its `<initial>` element's) transitions,
  `<if>`/`<foreach>` bodies nested in any of those, and every `<invoke>`'s
  `<finalize>` block - mirroring `Checks.Assign`'s reach plus
  `Checks.Invoke`'s `finalize` walk, since a `<send>` inside `<finalize>`
  is 6.5.2's other forbidden case (`Checks.Invoke.forbidden/1`) and still
  has to satisfy 6.2.2's own constraints regardless of where it sits.
  """

  alias Statifier.Document
  alias Statifier.Document.Block
  alias Statifier.Document.Foreach, as: DForeach
  alias Statifier.Document.If, as: DIf
  alias Statifier.Document.Initial
  alias Statifier.Document.Send, as: DSend
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

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
  # and stays silent whenever `targetexpr` was written instead (see
  # moduledoc).
  defp delay_and_internal_target(
         %DSend{delay: delay, delayexpr: delayexpr, target: "_internal"},
         location
       )
       when not is_nil(delay) or not is_nil(delayexpr) do
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
