defmodule Statifier.Validator.Checks.Script do
  @moduledoc """
  Spec 5.8.2: "A conformant SCXML document MUST specify either the 'src'
  attribute or child content, but not both." The `src`-and-content pair is
  unreachable through this codebase's lowering (`Statifier.Lowering.
  Builders.build_script/2` already refuses to build a struct when `src` is
  written, per ADR-0026 decision 2 - `src` is rejected regardless of any
  child text), so this check has exactly one remaining job: a `<script>`
  with **neither** `src` nor non-blank text is an empty script, which the
  spec's MUST also forbids. Reports `{:script_no_src_or_text}` at the
  `<script>`'s own element span.

  **Whitespace-only text is not text.** `Statifier.Parser.DOM.text/1`
  concatenates `<script>`'s direct text children verbatim and untrimmed, so
  a pretty-printed `<script>\\n  </script>` carries a `text` of `"\\n  "`.
  That is source formatting, not a payload - the same rule
  `Checks.Assign.blank?/1`, `Checks.Content.blank?/1`, and
  `Checks.Data.blank?/1` already follow.

  This check walks every state's own `onentry`/`onexit` blocks, every
  state's own transitions (both plain and a `:history` state's default),
  every state's `<initial>` element's own transition - the same three
  places `Checks.Assign` walks - descending into `<if>` branches and
  `<foreach>` bodies the same way, plus `document.scripts` for the
  top-level `<script>` children a state walk cannot reach at all
  (ADR-0026 Decision 7).
  """

  alias Statifier.Document
  alias Statifier.Document.Foreach, as: DForeach
  alias Statifier.Document.If, as: DIf
  alias Statifier.Document.Initial
  alias Statifier.Document.Script, as: DScript
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Walks every `<script>` reachable through a state's `onentry`/`onexit`
  blocks, its own (and its `<initial>` element's) transitions, and
  `document.scripts`, and returns a `:script_no_src_or_text` error for each
  one whose text is blank - `src` is already unreachable in a struct
  lowering ever built (see the moduledoc). Returns `[]` when every
  `<script>` in the document carries non-blank text.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states, scripts: scripts}, %Context{}) do
    scripts_from_states =
      states
      |> flatten()
      |> Enum.flat_map(&scripts_of/1)

    (scripts_from_states ++ scripts)
    |> Enum.flat_map(&check_script/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp scripts_of(%State{} = state) do
    block_scripts(state.onentry) ++
      block_scripts(state.onexit) ++
      transition_scripts(state.transitions) ++
      initial_scripts(state.initial_element)
  end

  defp block_scripts(blocks) do
    blocks
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DScript{}, &1))
  end

  defp transition_scripts(transitions) do
    transitions
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DScript{}, &1))
  end

  # Mirrors `Checks.Assign.descend/1`: a `%DIf{}`/`%DForeach{}` carries no
  # `<script>` itself, only branches/content that might, so the walk must
  # descend into both to reach a nested one (SCION's `if_else/test0`-shaped
  # nesting, generalized to `<script>`).
  defp descend(%DIf{branches: branches}) do
    branches |> Enum.flat_map(& &1.content) |> Enum.flat_map(&descend/1)
  end

  defp descend(%DForeach{content: content}), do: Enum.flat_map(content, &descend/1)

  defp descend(other), do: [other]

  defp initial_scripts(nil), do: []
  defp initial_scripts(%Initial{transitions: transitions}), do: transition_scripts(transitions)

  defp check_script(%DScript{src: src}) when not is_nil(src), do: []

  defp check_script(%DScript{text: text, location: location}) do
    if blank?(text) do
      [Error.script_no_src_or_text(location)]
    else
      []
    end
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
end
