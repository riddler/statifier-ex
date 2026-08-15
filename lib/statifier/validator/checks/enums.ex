defmodule Statifier.Validator.Checks.Enums do
  @moduledoc """
  Out-of-range enumerated attribute values (spec 3.2.1 and 3.5).

  `Statifier.Lowering.Attributes.atom/4` maps an unrecognised value onto the
  attribute's default rather than erroring, so `type="sideways"` lowers to
  `:external` and `binding="whenever"` lowers to `:early` - indistinguishable
  on the struct from the valid spellings that produce the same atom. Only the
  source text can tell them apart, which is what `validate/2`'s `source`
  argument exists for: the written attribute's span is sliced
  back out and compared against the range.

  Four reasons, one per enumerated attribute this check owns:

  - `{:transition_bad_type, raw}` - a `<transition type="...">` that is
    neither `"internal"` nor `"external"` (spec 3.5). Covers every
    transition the document holds, including those under an `<initial>`
    element and a `<history>`'s default transition, since
    `Statifier.Validator.Context` already walks all three.
  - `{:scxml_bad_binding, raw}` - an `<scxml binding="...">` that is neither
    `"early"` nor `"late"` (spec 3.2.1).
  - `{:scxml_bad_datamodel, raw}` - an `<scxml datamodel="...">` outside
    `["predicator", "elixir", "null", "ecmascript", "xpath"]` (spec 3.2.1,
    Decision 9 in
    `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`).
    3.2.1's Valid Values clause is itself open-ended - `"null", "ecmascript",
    "xpath" or other platform-defined values` - so the allow-list is the
    spec's three named values plus this platform's two
    (`docs/datamodel.md:6-7`), not a strict `["predicator", "elixir"]`
    rejection of everything else. Accepting `"ecmascript"` does **not** mean
    this engine implements ECMAScript: which datamodel actually runs is
    ADR-0004's answer and the corpus tooling's, never this attribute's. What
    this check catches is a typo (`datamodel="predicater"`,
    `datamodel="javascript"`) - the ordinary job of a validator check on an
    enumerated NMTOKEN. An absent `datamodel` attribute is `"predicator"`,
    this platform's documented default (3.2.2), so it is never reported.
  - `{:invoke_bad_autoforward, raw}` - an `<invoke autoforward="...">` that
    is neither `"true"` nor `"false"` (spec 6.4.1). Walks every `<invoke>`
    in the document directly (this check's own `flatten/1`, the same shape
    `Checks.Donedata`/`Checks.Content`/`Checks.Param` use), since
    `Statifier.Validator.Context` indexes transitions but not invocations.

  The fifth enumerated attribute lowering maps this way, `<history
  type="...">`, is **not** here: `Statifier.Validator.Checks.History` reports
  it as `:history_bad_type` under spec 3.10, alongside that element's other
  structural rules. The slice-and-compare shape is duplicated between the two
  modules rather than shared, so each check stays readable on its own and
  neither has to reach into the other's spec section.

  An attribute that was never written has no `attribute_locations` entry and
  is not reported - an absent enumerated attribute is its default, which is
  always in range.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @transition_types ["internal", "external"]
  @bindings ["early", "late"]
  @datamodels ["predicator", "elixir", "null", "ecmascript", "xpath"]
  @autoforwards ["true", "false"]

  @doc """
  Returns a `:transition_bad_type` error for every `<transition type="...">`
  whose written value is neither `"internal"` nor `"external"`, a
  `:scxml_bad_binding` error when the root `<scxml binding="...">` is neither
  `"early"` nor `"late"`, a `:scxml_bad_datamodel` error when the root
  `<scxml datamodel="...">` is outside `["predicator", "elixir", "null",
  "ecmascript", "xpath"]`, and an `:invoke_bad_autoforward` error for every
  `<invoke autoforward="...">` whose written value is neither `"true"` nor
  `"false"`. All four slice the raw source text rather than trusting the
  lowered atom/boolean, since an out-of-range value and a valid one can
  lower to the same default. Returns `[]` when all four enumerated
  attributes are in range everywhere they were written.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{} = document, %Context{} = context) do
    transition_type_errors(context) ++
      binding_errors(document, context) ++
      datamodel_errors(document, context) ++ autoforward_errors(document, context)
  end

  defp transition_type_errors(%Context{transitions: transitions} = context) do
    Enum.flat_map(transitions, fn {transition, _owner} ->
      out_of_range(transition.attribute_locations, :type, @transition_types, context, fn raw,
                                                                                         location ->
        Error.transition_bad_type(raw, location)
      end)
    end)
  end

  defp binding_errors(%Document{attribute_locations: attribute_locations}, context) do
    out_of_range(attribute_locations, :binding, @bindings, context, fn raw, location ->
      Error.scxml_bad_binding(raw, location)
    end)
  end

  defp datamodel_errors(%Document{attribute_locations: attribute_locations}, context) do
    out_of_range(attribute_locations, :datamodel, @datamodels, context, fn raw, location ->
      Error.scxml_bad_datamodel(raw, location)
    end)
  end

  defp autoforward_errors(%Document{states: states}, context) do
    states
    |> flatten()
    |> Enum.flat_map(& &1.invoke)
    |> Enum.flat_map(fn invoke ->
      out_of_range(invoke.attribute_locations, :autoforward, @autoforwards, context, fn raw,
                                                                                        location ->
        Error.invoke_bad_autoforward(raw, location)
      end)
    end)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp out_of_range(attribute_locations, key, allowed, %Context{source: source}, build) do
    case Map.fetch(attribute_locations, key) do
      :error ->
        []

      {:ok, %Location{} = location} ->
        raw = Location.slice(location, source)
        if raw in allowed, do: [], else: [build.(raw, location)]
    end
  end
end
