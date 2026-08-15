defmodule Statifier.Lowering.Builders do
  @moduledoc """
  One `build_*` function per supported SCXML element, reached through
  `Statifier.Lowering`'s dispatch map - the structural fix for v1's
  903-line, 73-clause `state_stack.ex` (`docs/architecture.md`,
  "adding an element touches one builder").

  Every builder lowers its own children first, through
  `Statifier.Lowering.walk_children/2`, before building its own struct, so
  errors accumulate in document order regardless of nesting depth. No
  builder here takes a parent element name as an argument: placement of a
  tagged child result into a parent's slot is each container's own
  `place/3`, never a fact the child itself needs to know.
  """

  alias Statifier.Document
  alias Statifier.Document.Assign
  alias Statifier.Document.Block
  alias Statifier.Document.Content
  alias Statifier.Document.Data
  alias Statifier.Document.Datamodel
  alias Statifier.Document.Donedata
  alias Statifier.Document.Foreach
  alias Statifier.Document.If
  alias Statifier.Document.Initial
  alias Statifier.Document.Invoke
  alias Statifier.Document.Log
  alias Statifier.Document.Param
  alias Statifier.Document.Raise
  alias Statifier.Document.Script
  alias Statifier.Document.State
  alias Statifier.Document.Transition
  alias Statifier.Lowering
  alias Statifier.Lowering.Attributes
  alias Statifier.Lowering.Error
  alias Statifier.Parser.DOM
  alias Statifier.Parser.DOM.Element

  @binding_values %{"early" => :early, "late" => :late}
  @history_type_values %{"shallow" => :shallow, "deep" => :deep}
  @transition_type_values %{"internal" => :internal, "external" => :external}
  @autoforward_values %{"true" => true, "false" => false}

  @doc """
  Builds the `%Statifier.Document{}` root from `<scxml>`.

  Reads `initial` (whitespace-split), `name`, `datamodel`, `binding` (atom,
  default `:early`), `version`, and `xmlns`. `<state>`, `<parallel>`, and
  `<final>` children are placed into `Document.states`, in document order;
  any other child misses `Document`'s one slot and is reported via `place/3`
  as `{:misplaced_element, name, "scxml"}`.
  """
  @spec build_scxml(element :: Element.t(), ctx :: map()) :: {Document.t(), [Error.t()]}
  def build_scxml(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:initial, element, "initial")
      |> Attributes.put_location(:name, element, "name")
      |> Attributes.put_location(:datamodel, element, "datamodel")
      |> Attributes.put_location(:binding, element, "binding")
      |> Attributes.put_location(:version, element, "version")
      |> Attributes.put_location(:xmlns, element, "xmlns")

    document = %Document{
      location: element.location,
      initial: Attributes.list(element, "initial"),
      name: Attributes.value(element, "name"),
      datamodel: Attributes.value(element, "datamodel"),
      binding: Attributes.atom(element, "binding", @binding_values, :early),
      version: Attributes.value(element, "version"),
      xmlns: Attributes.value(element, "xmlns"),
      attribute_locations: attribute_locations
    }

    {document, place_errors} = place_children(results, document, element.name)
    document = reverse_lists(document)

    {document, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :state` from `<state>`.
  """
  @spec build_state(element :: Element.t(), ctx :: map()) :: {{:state, State.t()}, [Error.t()]}
  def build_state(%Element{} = element, ctx), do: state_like(element, ctx, :state)

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :parallel` from
  `<parallel>`.
  """
  @spec build_parallel(element :: Element.t(), ctx :: map()) ::
          {{:state, State.t()}, [Error.t()]}
  def build_parallel(%Element{} = element, ctx), do: state_like(element, ctx, :parallel)

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :final` from `<final>`.
  """
  @spec build_final(element :: Element.t(), ctx :: map()) :: {{:state, State.t()}, [Error.t()]}
  def build_final(%Element{} = element, ctx), do: state_like(element, ctx, :final)

  @doc """
  Builds a `%Statifier.Document.State{}` with `kind: :history` from
  `<history>`.

  Additionally reads `type`, mapped to `:shallow | :deep` with `:shallow` as
  the default (spec 3.10) - an out-of-range value (`type="sideways"`) lowers
  to `:shallow` and still keeps its `attribute_locations` entry, rather than
  erroring, so a future validator check can point at the offending text.
  """
  @spec build_history(element :: Element.t(), ctx :: map()) :: {{:state, State.t()}, [Error.t()]}
  def build_history(%Element{} = element, ctx) do
    {{:state, state}, errors} = state_like(element, ctx, :history)

    state = %{
      state
      | history_type: Attributes.atom(element, "type", @history_type_values, :shallow),
        attribute_locations:
          Attributes.put_location(state.attribute_locations, :type, element, "type")
    }

    {{:state, state}, errors}
  end

  @doc """
  Builds a `%Statifier.Document.Initial{}` from `<initial>`.

  `transitions` holds however many `<transition>` children are present,
  including zero and two - lowering builds what is written; the transition
  count is the validator's check to make (`Statifier.Document.Initial`'s
  moduledoc).
  """
  @spec build_initial(element :: Element.t(), ctx :: map()) ::
          {{:initial, Initial.t()}, [Error.t()]}
  def build_initial(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    initial = %Initial{location: element.location}
    {initial, place_errors} = place_children(results, initial, element.name)
    initial = reverse_lists(initial)

    {{:initial, initial}, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Transition{}` from `<transition>`.

  Reads `event` and `target` (both whitespace-split), `cond` (raw source
  string), and `type` (atom, default `:external`). An out-of-range `type`
  value lowers to `:external` and still keeps its `attribute_locations`
  entry, so a future validator check can point at the offending text, the
  same rule `<history>`'s `type` follows.

  A `<transition>`'s executable content children (`<raise>`, `<log>`) are
  placed directly into `Transition.content`, unwrapped - a transition has no
  `<onentry>`-like element in the source to give a block its own location
  (`Statifier.Document.Block`'s moduledoc).
  """
  @spec build_transition(element :: Element.t(), ctx :: map()) ::
          {{:transition, Transition.t()}, [Error.t()]}
  def build_transition(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:event, element, "event")
      |> Attributes.put_location(:target, element, "target")
      |> Attributes.put_location(:cond, element, "cond")
      |> Attributes.put_location(:type, element, "type")

    transition = %Transition{
      location: element.location,
      event: Attributes.list(element, "event"),
      target: Attributes.list(element, "target"),
      cond: Attributes.value(element, "cond"),
      type: Attributes.atom(element, "type", @transition_type_values, :external),
      attribute_locations: attribute_locations
    }

    {transition, place_errors} = place_children(results, transition, element.name)
    transition = reverse_lists(transition)

    {{:transition, transition}, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Block{}` from an `<onentry>` element, tagged
  `{:onentry, block}`.

  Each `<onentry>` element becomes **one** `Block` with its own `location` -
  three `<onentry>` elements under one `<state>` become three entries in
  `State.onentry`, never one flattened list (spec 3.8/3.9, section 4's
  error-isolation rule).
  """
  @spec build_onentry(element :: Element.t(), ctx :: map()) ::
          {{:onentry, Block.t()}, [Error.t()]}
  def build_onentry(%Element{} = element, ctx), do: build_block(element, ctx, :onentry)

  @doc """
  Builds a `%Statifier.Document.Block{}` from an `<onexit>` element, tagged
  `{:onexit, block}`. See `build_onentry/2` - same shared `build_block/3`,
  same one-block-per-element rule.
  """
  @spec build_onexit(element :: Element.t(), ctx :: map()) ::
          {{:onexit, Block.t()}, [Error.t()]}
  def build_onexit(%Element{} = element, ctx), do: build_block(element, ctx, :onexit)

  @doc """
  Builds a `%Statifier.Document.Raise{}` from a `<raise>` element, tagged
  `{:content_node, raise}`.

  `event` is read as a **single unsplit string**
  (`Statifier.Document.Raise`'s moduledoc) - deliberately not tokenized the
  way `<transition>`'s `event` is. `event` is required (`:event` is
  `@enforce_keys`'d on `Raise`); when absent, no struct can be built and this
  returns `{nil, [%Error{reason: {:missing_attribute, "raise", "event"}}]}`.
  """
  @spec build_raise(element :: Element.t(), ctx :: map()) ::
          {{:content_node, Raise.t()} | nil, [Error.t()]}
  def build_raise(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    case Attributes.value(element, "event") do
      nil ->
        {nil, errors ++ [Error.missing_attribute("raise", "event", element.location)]}

      event ->
        attribute_locations = Attributes.put_location(%{}, :event, element, "event")

        raise_node = %Raise{
          location: element.location,
          event: event,
          attribute_locations: attribute_locations
        }

        {raise_node, place_errors} = place_children(results, raise_node, element.name)

        {{:content_node, raise_node}, errors ++ place_errors}
    end
  end

  @doc """
  Builds a `%Statifier.Document.Log{}` from a `<log>` element, tagged
  `{:content_node, log}`.

  Reads `label` and `expr`, both nilable, both raw strings - neither is
  tokenized or compiled here.
  """
  @spec build_log(element :: Element.t(), ctx :: map()) :: {{:content_node, Log.t()}, [Error.t()]}
  def build_log(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:label, element, "label")
      |> Attributes.put_location(:expr, element, "expr")

    log = %Log{
      location: element.location,
      label: Attributes.value(element, "label"),
      expr: Attributes.value(element, "expr"),
      attribute_locations: attribute_locations
    }

    {log, place_errors} = place_children(results, log, element.name)

    {{:content_node, log}, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Donedata{}` from a `<donedata>` element,
  tagged `{:donedata, donedata}`.

  `content` stays `nil` when `<donedata>` has no `<content>` child and
  becomes a `%Statifier.Document.Content{}` when it does. `params` holds
  however many `<param>` children are present, in document order - both
  slots are built here regardless of spec 5.5's content-model rule, which is
  `Statifier.Validator.Checks.Donedata`'s to report
  (`Statifier.Document.Donedata`'s moduledoc).
  """
  @spec build_donedata(element :: Element.t(), ctx :: map()) ::
          {{:donedata, Donedata.t()}, [Error.t()]}
  def build_donedata(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    donedata = %Donedata{location: element.location}
    {donedata, place_errors} = place_children(results, donedata, element.name)
    donedata = reverse_lists(donedata)

    {{:donedata, donedata}, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Param{}` from a `<param>` element, tagged
  `{:param, param}`.

  Reads `name` (required - spec 5.7.1), `expr`, and `location`. `expr` and
  `location` are both read as raw nilable strings - neither is tokenized or
  compiled here (`Statifier.Document.Param`'s moduledoc forbids `Predicator`
  under `lib/statifier/document/`, the same rule every other Document node
  follows). A missing `name` means no struct can be built at all, following
  `build_raise/2`'s required-attribute pattern:
  `{nil, [Error.missing_attribute("param", "name", element.location)]}`.
  """
  @spec build_param(element :: Element.t(), ctx :: map()) ::
          {{:param, Param.t()} | nil, [Error.t()]}
  def build_param(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    case Attributes.value(element, "name") do
      nil ->
        {nil, errors ++ [Error.missing_attribute("param", "name", element.location)]}

      name ->
        attribute_locations =
          %{}
          |> Attributes.put_location(:name, element, "name")
          |> Attributes.put_location(:expr, element, "expr")
          |> Attributes.put_location(:location, element, "location")

        param = %Param{
          location: element.location,
          name: name,
          expr: Attributes.value(element, "expr"),
          param_location: Attributes.value(element, "location"),
          attribute_locations: attribute_locations
        }

        {param, place_errors} = place_children(results, param, element.name)

        {{:param, param}, errors ++ place_errors}
    end
  end

  @doc """
  Builds a `%Statifier.Document.Content{}` from a `<content>` element,
  tagged `{:content, content}`.

  Reads `expr` and sets `text` to `Statifier.Parser.DOM.text/1`'s
  concatenation of `<content>`'s own direct text children, **verbatim and
  untrimmed** - the struct's own moduledoc defines `text` as exactly that
  concatenation. `<content>` is the one element exempt from the stray-text
  rule (its text *is* its payload), so this builder reads `element.children`
  directly rather than calling `Statifier.Lowering.walk_children/2`, which
  would otherwise flag that same text as a stray-text error. An element
  child is not silently dropped, though: each one produces
  `{:misplaced_element, name, "content"}`
  (`lib/statifier/document/content.ex:12-15`), not a build attempt of its
  own - `<content>` does not hold a markup subtree.
  """
  @spec build_content(element :: Element.t(), ctx :: map()) ::
          {{:content, Content.t()}, [Error.t()]}
  def build_content(%Element{} = element, _ctx) do
    errors =
      element
      |> DOM.elements()
      |> Enum.map(fn %Element{name: name, location: location} ->
        Error.misplaced(name, "content", location)
      end)

    attribute_locations = Attributes.put_location(%{}, :expr, element, "expr")

    content = %Content{
      location: element.location,
      expr: Attributes.value(element, "expr"),
      text: DOM.text(element),
      attribute_locations: attribute_locations
    }

    {{:content, content}, errors}
  end

  @doc """
  Builds a `%Statifier.Document.Datamodel{}` from a `<datamodel>` element,
  tagged `{:datamodel, datamodel}`.

  `<datamodel>` has no attributes of its own (spec 5.2.1). Its only
  children are `<data>` elements, placed into `Datamodel.data` in document
  order via `place/3` and `reverse_lists/1`, the same fold every other
  list-valued builder uses. `<datamodel>` is legal at both the document root
  and on a `:state`/`:parallel` state (`place/3` handles both), and lowering
  does not reject a `<datamodel>` on a `:final` or `:history` state either -
  that placement rule belongs to `Statifier.Validator.Checks.Data`, since one
  `%State{}` struct covers all four kinds and lowering has no way to
  distinguish them here.
  """
  @spec build_datamodel(element :: Element.t(), ctx :: map()) ::
          {{:datamodel, Datamodel.t()}, [Error.t()]}
  def build_datamodel(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    datamodel = %Datamodel{location: element.location}
    {datamodel, place_errors} = place_children(results, datamodel, element.name)
    datamodel = reverse_lists(datamodel)

    {{:datamodel, datamodel}, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Data{}` from a `<data>` element, tagged
  `{:data, data}`.

  Reads `id` (required - spec 5.3.1), `expr`, and `src`, all raw strings, and
  sets `text` to `Statifier.Parser.DOM.text/1`'s verbatim, untrimmed
  concatenation of `<data>`'s direct text children - a `<data>`'s text *is*
  its payload (spec 5.3.2), so this builder reads `element.children`
  directly rather than calling `Statifier.Lowering.walk_children/2`, the
  same exemption `build_content/2` takes. An element child is not silently
  dropped: each one produces `{:misplaced_element, name, "data"}` instead of
  a build attempt of its own - `<data>` does not hold a markup subtree.

  A missing `id` means no struct can be built at all (`:id` is
  `@enforce_keys`'d on `Data`), following `build_raise/2`'s required-attribute
  pattern: `{nil, [Error.missing_attribute("data", "id", element.location)]}`.
  """
  @spec build_data(element :: Element.t(), ctx :: map()) ::
          {{:data, Data.t()} | nil, [Error.t()]}
  def build_data(%Element{} = element, _ctx) do
    misplaced_errors =
      element
      |> DOM.elements()
      |> Enum.map(fn %Element{name: name, location: location} ->
        Error.misplaced(name, "data", location)
      end)

    case Attributes.value(element, "id") do
      nil ->
        {nil, misplaced_errors ++ [Error.missing_attribute("data", "id", element.location)]}

      id ->
        attribute_locations =
          %{}
          |> Attributes.put_location(:id, element, "id")
          |> Attributes.put_location(:expr, element, "expr")
          |> Attributes.put_location(:src, element, "src")

        data = %Data{
          id: id,
          location: element.location,
          expr: Attributes.value(element, "expr"),
          src: Attributes.value(element, "src"),
          text: DOM.text(element),
          attribute_locations: attribute_locations
        }

        {{:data, data}, misplaced_errors}
    end
  end

  @doc """
  Builds a `%Statifier.Document.Assign{}` from an `<assign>` element, tagged
  `{:content_node, assign}`.

  Reads `location` (required - spec 5.4.2) and `expr`, both raw strings -
  neither is resolved or compiled here (`Statifier.Document.Assign`'s
  moduledoc forbids `Predicator` under `lib/statifier/document/`). A missing
  `location` means no struct can be built at all (`:location` is
  `@enforce_keys`'d on `Assign`), following `build_raise/2`'s
  required-attribute pattern: `{nil, [Error.missing_attribute("assign",
  "location", element.location)]}`.

  `text` is set to `Statifier.Parser.DOM.text/1`'s verbatim, untrimmed
  concatenation of `<assign>`'s direct text children - spec 5.4.2's other
  value source, an `<assign>`'s children "provide an in-line specification
  of the legal data value" (5.4.2, 5.9.3), so this builder reads
  `element.children` directly rather than calling
  `Statifier.Lowering.walk_children/2`, the same exemption `build_data/2`
  and `build_content/2` take. An element child is not silently dropped:
  each one produces `{:misplaced_element, name, "assign"}` instead of a
  build attempt of its own - `<assign>` does not hold a markup subtree.
  """
  @spec build_assign(element :: Element.t(), ctx :: map()) ::
          {{:content_node, Assign.t()} | nil, [Error.t()]}
  def build_assign(%Element{} = element, _ctx) do
    misplaced_errors =
      element
      |> DOM.elements()
      |> Enum.map(fn %Element{name: name, location: location} ->
        Error.misplaced(name, "assign", location)
      end)

    case Attributes.value(element, "location") do
      nil ->
        {nil,
         misplaced_errors ++ [Error.missing_attribute("assign", "location", element.location)]}

      location ->
        attribute_locations =
          %{}
          |> Attributes.put_location(:location, element, "location")
          |> Attributes.put_location(:expr, element, "expr")

        assign_node = %Assign{
          node_location: element.location,
          location: location,
          expr: Attributes.value(element, "expr"),
          text: DOM.text(element),
          attribute_locations: attribute_locations
        }

        {{:content_node, assign_node}, misplaced_errors}
    end
  end

  @doc """
  Builds a `%Statifier.Document.If{}` from an `<if>` element (spec 4.3),
  tagged `{:content_node, if_node}`.

  Reads the required `cond` (4.3.1: `cond` is `required="true"` on `<if>`) -
  following `build_raise/2`'s required-attribute pattern: a missing `cond`
  means no struct can be built at all,
  `{nil, [Error.missing_attribute("if", "cond", element.location)]}`.

  Otherwise walks children through the shared dispatch, then folds the
  tagged results through `place/3`'s `%If{}`-specific clauses - spec
  4.3.2's partition definition, mechanically: one open branch starts,
  carrying `<if>`'s own `cond` and this element's own `location`; each
  `{:elseif, branch}` / `{:else, branch}` result closes the currently open
  branch and opens the next; each `{:content_node, node}` result appends to
  whichever branch is currently open. `reverse_lists/1`'s `%If{}` clause
  restores document order once the fold finishes (branches were built
  newest-first, the same convention every other list-valued builder here
  follows).
  """
  @spec build_if(element :: Element.t(), ctx :: map()) ::
          {{:content_node, If.t()} | nil, [Error.t()]}
  def build_if(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    case Attributes.value(element, "cond") do
      nil ->
        {nil, errors ++ [Error.missing_attribute("if", "cond", element.location)]}

      cond_source ->
        attribute_locations = Attributes.put_location(%{}, :cond, element, "cond")

        first_branch = %If.Branch{
          location: element.location,
          cond: cond_source,
          attribute_locations: attribute_locations
        }

        if_node = %If{location: element.location, branches: [first_branch]}
        {if_node, place_errors} = place_children(results, if_node, element.name)
        if_node = reverse_lists(if_node)

        {{:content_node, if_node}, errors ++ place_errors}
    end
  end

  @doc """
  Builds the partitioning tag for an `<elseif>` element (spec 4.4), tagged
  `{:elseif, branch}` for `build_if/2`'s own fold to consume.
  `place/3` has no clause accepting this tag for any parent but `%If{}`
  (Decision 7 of the plan cited on `Statifier.Document.If`) - anywhere else,
  the generic catch-all reports `{:misplaced_element, "elseif", parent_name}`
  with no code of its own, reading the branch's own `location` field the
  same way it reads every other tagged struct's.

  Reads the required `cond` (4.4.1) - following `build_raise/2`'s
  required-attribute pattern: a missing `cond` means no branch can be built
  at all. `<elseif>` takes no children of its own (4.4.1 gives it none, the
  same "empty element" shape `<else>` has); an element child is reported as
  `{:misplaced_element, name, "elseif"}` rather than built, the same
  exemption `build_data/2` and `build_content/2` take for their own
  childless/text-only content models.
  """
  @spec build_elseif(element :: Element.t(), ctx :: map()) ::
          {{:elseif, If.Branch.t()} | nil, [Error.t()]}
  def build_elseif(%Element{} = element, _ctx) do
    misplaced_errors =
      element
      |> DOM.elements()
      |> Enum.map(fn %Element{name: name, location: location} ->
        Error.misplaced(name, "elseif", location)
      end)

    case Attributes.value(element, "cond") do
      nil ->
        {nil, misplaced_errors ++ [Error.missing_attribute("elseif", "cond", element.location)]}

      cond_source ->
        attribute_locations = Attributes.put_location(%{}, :cond, element, "cond")

        branch = %If.Branch{
          location: element.location,
          cond: cond_source,
          attribute_locations: attribute_locations
        }

        {{:elseif, branch}, misplaced_errors}
    end
  end

  @doc """
  Builds the partitioning tag for an `<else>` element (spec 4.5), tagged
  `{:else, branch}`. Same placement rule as `build_elseif/2`'s doc describes
  - `place/3` accepts this tag only inside an `%If{}`.

  `<else>` takes no attributes at all (4.5.2 gives it none): any attribute
  written is reported as `{:unexpected_attribute, "else", name}` rather than
  silently ignored, though the branch (with `cond: nil`) still builds either
  way - an author who mistyped `cond` on an `<else>` should see both "this
  attribute is not allowed" and get the `<else>` behavior 4.5.1 defines
  regardless. Takes no element children either, the same exemption
  `build_elseif/2` takes.
  """
  @spec build_else(element :: Element.t(), ctx :: map()) :: {{:else, If.Branch.t()}, [Error.t()]}
  def build_else(%Element{} = element, _ctx) do
    misplaced_errors =
      element
      |> DOM.elements()
      |> Enum.map(fn %Element{name: name, location: location} ->
        Error.misplaced(name, "else", location)
      end)

    attribute_errors =
      case element.attributes do
        [] ->
          []

        [attribute | _rest] ->
          [
            Error.unexpected_attribute(
              "else",
              attribute.name,
              attribute.location || element.location
            )
          ]
      end

    branch = %If.Branch{location: element.location, cond: nil}

    {{:else, branch}, misplaced_errors ++ attribute_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Foreach{}` from a `<foreach>` element (spec
  4.6), tagged `{:content_node, foreach_node}`.

  Reads the two required attributes, `array` and `item` (4.6.2), following
  `build_raise/2`'s required-attribute shape - a missing one means no
  struct can be built at all. Unlike `build_raise/2`, **both** are checked
  before failing: a `<foreach>` missing both reports two
  `{:missing_attribute, "foreach", _}` errors rather than stopping at the
  first, since neither attribute's presence depends on the other and two
  errors is strictly more useful to a document author fixing both at once.
  `item`'s *legality* as a variable name is a runtime check (Decision 1 of
  `docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md`), not
  lowering's concern - only its presence is checked here.

  The optional `index` (4.6.2) is read unconditionally and defaults to
  `nil` when absent, following `Statifier.Document.Foreach`'s own default.

  Otherwise walks children through the shared dispatch, then places each
  tagged result into `content` via `place/3`'s `%Foreach{}` clause - no
  partitioning tags are produced or consumed here, unlike `<if>`, since
  `<foreach>` has exactly one child block (Decision 8).
  """
  @spec build_foreach(element :: Element.t(), ctx :: map()) ::
          {{:content_node, Foreach.t()} | nil, [Error.t()]}
  def build_foreach(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    array = Attributes.value(element, "array")
    item = Attributes.value(element, "item")

    # Built in reverse document order (`item`, then `array`) to match every
    # other list-valued builder's own accumulation convention
    # (`place_children/3`, `reverse_lists/1`): `Statifier.Lowering.walk_child/4`
    # reverses whatever a builder returns before prepending it onto the
    # caller's own error list, so building newest-first here is what makes
    # the two errors land in document order (`array`, then `item`) once
    # `Statifier.Lowering.lower/1` sorts the whole tree's errors by
    # `location.start_offset`.
    missing_errors =
      for {attribute, value} <- [{"item", item}, {"array", array}], is_nil(value) do
        Error.missing_attribute("foreach", attribute, element.location)
      end

    case missing_errors do
      [] ->
        attribute_locations =
          %{}
          |> Attributes.put_location(:array, element, "array")
          |> Attributes.put_location(:item, element, "item")
          |> Attributes.put_location(:index, element, "index")

        foreach_node = %Foreach{
          location: element.location,
          array: array,
          item: item,
          index: Attributes.value(element, "index"),
          attribute_locations: attribute_locations
        }

        {foreach_node, place_errors} = place_children(results, foreach_node, element.name)
        foreach_node = reverse_lists(foreach_node)

        {{:content_node, foreach_node}, errors ++ place_errors}

      _missing ->
        {nil, errors ++ missing_errors}
    end
  end

  @doc """
  Builds a `%Statifier.Document.Script{}` from a `<script>` element (spec
  5.8), tagged `{:content_node, script}`.

  On a written `src`, no struct is built at all: this reports
  `{:unsupported_attribute, "script", "src"}` (Decision 5, ADR-0026 decision
  2 - no external fetch) and stops there, following `build_raise/2`'s
  "cannot build" pattern. `src` plus child text is deliberately **not** a
  second error - spec 5.8.2 forbids the pair, but the document is already
  rejected on `src` alone, so a second error would add noise without adding
  information.

  Otherwise `text` is set to `Statifier.Parser.DOM.text/1`'s verbatim,
  untrimmed concatenation of `<script>`'s direct text children - the
  predicator program body (5.8.2). This builder reads `element.children`
  directly rather than calling `Statifier.Lowering.walk_children/2`, the
  same exemption `build_data/2`/`build_content/2`/`build_assign/2` take for
  their own text-only content models. An element child is not silently
  dropped: each one produces `{:misplaced_element, name, "script"}` instead
  of a build attempt of its own - `<script>` does not hold a markup
  subtree.
  """
  @spec build_script(element :: Element.t(), ctx :: map()) ::
          {{:content_node, Script.t()} | nil, [Error.t()]}
  def build_script(%Element{} = element, _ctx) do
    misplaced_errors =
      element
      |> DOM.elements()
      |> Enum.map(fn %Element{name: name, location: location} ->
        Error.misplaced(name, "script", location)
      end)

    case Attributes.value(element, "src") do
      nil ->
        attribute_locations = Attributes.put_location(%{}, :src, element, "src")

        script_node = %Script{
          location: element.location,
          text: DOM.text(element),
          attribute_locations: attribute_locations
        }

        {{:content_node, script_node}, misplaced_errors}

      _src ->
        {nil,
         misplaced_errors ++
           [Error.unsupported_attribute("script", "src", element.location)]}
    end
  end

  @doc """
  Builds a `%Statifier.Document.Invoke{}` from an `<invoke>` element (spec
  6.4), tagged `{:invoke, invoke}`.

  Reads all eight 6.4.1 attributes with `Attributes.value/2` (`namelist`
  with `Attributes.list/2`, `autoforward` with `Attributes.atom/4` against
  `"true"`/`"false"`, defaulting `false` per 6.4.1's own stated default) and
  records every one's span in `attribute_locations`. Like `<param>`'s
  deliberate expr/location pair, every mutually exclusive attribute pairing
  6.4.1 names (`type`/`typeexpr`, `src`/`srcexpr`, `id`/`idlocation`,
  `namelist`/`<param>`, and `src`|`srcexpr`/`<content>`) is lowered rather
  than refused - `Statifier.Validator.Checks.Invoke` reports the shape.

  `<param>` children accumulate into `params`, a `<content>` child sets
  `content`, and a `<finalize>` child sets `finalize` - all three via
  `place_children/3`'s own `%Invoke{}` clauses below.
  """
  @spec build_invoke(element :: Element.t(), ctx :: map()) ::
          {{:invoke, Invoke.t()}, [Error.t()]}
  def build_invoke(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:type, element, "type")
      |> Attributes.put_location(:typeexpr, element, "typeexpr")
      |> Attributes.put_location(:src, element, "src")
      |> Attributes.put_location(:srcexpr, element, "srcexpr")
      |> Attributes.put_location(:id, element, "id")
      |> Attributes.put_location(:idlocation, element, "idlocation")
      |> Attributes.put_location(:namelist, element, "namelist")
      |> Attributes.put_location(:autoforward, element, "autoforward")

    invoke = %Invoke{
      location: element.location,
      type: Attributes.value(element, "type"),
      typeexpr: Attributes.value(element, "typeexpr"),
      src: Attributes.value(element, "src"),
      srcexpr: Attributes.value(element, "srcexpr"),
      id: Attributes.value(element, "id"),
      idlocation: Attributes.value(element, "idlocation"),
      namelist: Attributes.list(element, "namelist"),
      autoforward: Attributes.atom(element, "autoforward", @autoforward_values, false),
      attribute_locations: attribute_locations
    }

    {invoke, place_errors} = place_children(results, invoke, element.name)
    invoke = reverse_lists(invoke)

    {{:invoke, invoke}, errors ++ place_errors}
  end

  @doc """
  Builds a `%Statifier.Document.Block{}` from a `<finalize>` element (spec
  6.5), tagged `{:finalize, block}`.

  Mirrors `build_onentry/2`/`build_onexit/2`'s shared `build_block/3` - one
  `Block` per `<finalize>`, carrying its own `location` - but is not routed
  through that helper since its tag is `:finalize`, not `:onentry`/`:onexit`.
  An `<invoke>` with no `<finalize>` child leaves `Invoke.finalize` at its
  struct default of `nil`; a written but childless `<finalize/>` still
  builds a `%Block{content: []}` here, which is how `Invoke.finalize`
  distinguishes absent from empty (6.5, `Statifier.Document.Invoke`'s
  moduledoc).
  """
  @spec build_finalize(element :: Element.t(), ctx :: map()) ::
          {{:finalize, Block.t()}, [Error.t()]}
  def build_finalize(%Element{} = element, ctx) do
    {results, errors} = Lowering.walk_children(element, ctx)

    block = %Block{location: element.location}
    {block, place_errors} = place_children(results, block, element.name)
    block = reverse_lists(block)

    {{:finalize, block}, errors ++ place_errors}
  end

  # Shared by `build_onentry/2` and `build_onexit/2` (`build_block/3` takes a
  # `tag` atom, its own contribution - never a parent element name). `Block`
  # has no slot for anything but `Document.content_node`
  # children; any other child (a `<state>`, say) misses that slot and comes
  # back from `place/3` as `{:misplaced_element, name, "onentry"|"onexit"}`.
  @spec build_block(element :: Element.t(), ctx :: map(), tag :: :onentry | :onexit) ::
          {{:onentry | :onexit, Block.t()}, [Error.t()]}
  defp build_block(%Element{} = element, ctx, tag) do
    {results, errors} = Lowering.walk_children(element, ctx)

    block = %Block{location: element.location}
    {block, place_errors} = place_children(results, block, element.name)
    block = reverse_lists(block)

    {{tag, block}, errors ++ place_errors}
  end

  # Shared by `build_state/2`, `build_parallel/2`, `build_final/2`, and
  # `build_history/2` (`state_like/3` takes a `kind` atom, its own
  # contribution - never a parent element name). Reads the
  # attributes meaningful across the state family (`id`, `initial`), places
  # its children into `states`, `transitions`, and `initial_element` via
  # `place/3`, and tags the result `{:state, state}` - the slot every one of
  # the four kinds is placed into by its own parent, regardless of which of
  # the four it is.
  @spec state_like(element :: Element.t(), ctx :: map(), kind :: Document.state_kind()) ::
          {{:state, State.t()}, [Error.t()]}
  defp state_like(%Element{} = element, ctx, kind) do
    {results, errors} = Lowering.walk_children(element, ctx)

    attribute_locations =
      %{}
      |> Attributes.put_location(:id, element, "id")
      |> Attributes.put_location(:initial, element, "initial")

    state = %State{
      kind: kind,
      location: element.location,
      id: Attributes.value(element, "id"),
      initial: Attributes.list(element, "initial"),
      attribute_locations: attribute_locations
    }

    {state, place_errors} = place_children(results, state, element.name)
    state = reverse_lists(state)

    {{:state, state}, errors ++ place_errors}
  end

  # Folds `results` (a container's own tagged, walked children) into
  # `container` via `place/3`, threading errors alongside. List slots are
  # prepended here and reversed once by `reverse_lists/1`, never appended per
  # child.
  @spec place_children(results :: [term()], container :: struct(), parent_name :: binary()) ::
          {struct(), [Error.t()]}
  defp place_children(results, container, parent_name) do
    Enum.reduce(results, {container, []}, fn result, {container, errors} ->
      case place(result, container, parent_name) do
        {container, nil} -> {container, errors}
        {container, error} -> {container, [error | errors]}
      end
    end)
  end

  # One clause per slot the container owns; the catch-all reports
  # `{:misplaced_element, name, parent_name}` for anything else, deriving
  # `name` from the child's own tag rather than a hardcoded literal - every
  # tag besides `:state` names exactly one element, and `:state` never
  # reaches the catch-all since both containers that accept state-family
  # children own the `states` slot.
  @spec place(child :: term(), container :: struct(), parent_name :: binary()) ::
          {struct(), Error.t() | nil}
  defp place(nil, parent, _parent_name), do: {parent, nil}

  defp place({:state, state}, %State{} = parent, _parent_name) do
    {%{parent | states: [state | parent.states]}, nil}
  end

  defp place({:transition, transition}, %State{} = parent, _parent_name) do
    {%{parent | transitions: [transition | parent.transitions]}, nil}
  end

  defp place({:initial, initial}, %State{} = parent, _parent_name) do
    {%{parent | initial_element: initial}, nil}
  end

  defp place({:onentry, block}, %State{} = parent, _parent_name) do
    {%{parent | onentry: [block | parent.onentry]}, nil}
  end

  defp place({:onexit, block}, %State{} = parent, _parent_name) do
    {%{parent | onexit: [block | parent.onexit]}, nil}
  end

  defp place({:donedata, donedata}, %State{} = parent, _parent_name) do
    {%{parent | donedata: donedata}, nil}
  end

  defp place({:datamodel, datamodel}, %State{} = parent, _parent_name) do
    {%{parent | datamodel_element: datamodel}, nil}
  end

  defp place({:invoke, invoke}, %State{} = parent, _parent_name) do
    {%{parent | invoke: [invoke | parent.invoke]}, nil}
  end

  defp place({:param, param}, %Invoke{} = parent, _parent_name) do
    {%{parent | params: [param | parent.params]}, nil}
  end

  defp place({:content, content}, %Invoke{} = parent, _parent_name) do
    {%{parent | content: content}, nil}
  end

  defp place({:finalize, block}, %Invoke{} = parent, _parent_name) do
    {%{parent | finalize: block}, nil}
  end

  defp place({:datamodel, datamodel}, %Document{} = parent, _parent_name) do
    {%{parent | datamodel_element: datamodel}, nil}
  end

  defp place({:data, data}, %Datamodel{} = parent, _parent_name) do
    {%{parent | data: [data | parent.data]}, nil}
  end

  defp place({:content, content}, %Donedata{} = parent, _parent_name) do
    {%{parent | content: content}, nil}
  end

  defp place({:param, param}, %Donedata{} = parent, _parent_name) do
    {%{parent | params: [param | parent.params]}, nil}
  end

  defp place({:transition, transition}, %Initial{} = parent, _parent_name) do
    {%{parent | transitions: [transition | parent.transitions]}, nil}
  end

  defp place({:state, state}, %Document{} = parent, _parent_name) do
    {%{parent | states: [state | parent.states]}, nil}
  end

  defp place({:content_node, node}, %Block{} = parent, _parent_name) do
    {%{parent | content: [node | parent.content]}, nil}
  end

  defp place({:content_node, node}, %Transition{} = parent, _parent_name) do
    {%{parent | content: [node | parent.content]}, nil}
  end

  # The three `%If{}`-specific clauses (Decision 7 of the plan cited on
  # `Statifier.Document.If`): `branches` is threaded as `[open | closed]`
  # while the walk is in progress - `open` is the branch currently
  # accepting content, `closed` are the ones already sealed by a later
  # `<elseif>`/`<else>`. A `{:elseif, _}`/`{:else, _}` result seals `open`
  # and opens the new branch; a `{:content_node, _}` result appends to
  # `open`. `reverse_lists/1`'s `%If{}` clause restores document order
  # (branches newest-first here, each branch's own content newest-first too)
  # once the fold finishes - the same two-step every other list-valued
  # builder in this module takes.
  #
  # This clause, and `%Foreach{}`'s right below it, must precede the
  # `%Assign{}`-specific clause below: that clause matches
  # `{:content_node, %Assign{}}` against *any* parent (unconditionally), so
  # an `<assign>` landing inside an `<if>` partition or a `<foreach>` body
  # would otherwise always report misplaced instead of joining its branch
  # or content list.
  defp place({:content_node, node}, %If{branches: [open | closed]} = parent, _parent_name) do
    open = %{open | content: [node | open.content]}
    {%{parent | branches: [open | closed]}, nil}
  end

  defp place({:elseif, branch}, %If{branches: [open | closed]} = parent, _parent_name) do
    {%{parent | branches: [branch, open | closed]}, nil}
  end

  defp place({:else, branch}, %If{branches: [open | closed]} = parent, _parent_name) do
    {%{parent | branches: [branch, open | closed]}, nil}
  end

  # `<foreach>` has no partitioning (Decision 8) - every `{:content_node,
  # _}` result its children produce lands directly in `content`, the same
  # single-slot shape `%Block{}` and `%Transition{}` use.
  defp place({:content_node, node}, %Foreach{} = parent, _parent_name) do
    {%{parent | content: [node | parent.content]}, nil}
  end

  # `%Assign{}`'s own element span lives under `node_location`, not
  # `location` - `location` on that struct is the SCXML `location` *attribute*
  # (a raw path string, not a `Location.t()`), per
  # `Statifier.Document.Assign`'s moduledoc. This clause must precede the
  # generic one below so a misplaced `<assign>` reports its element span
  # rather than crashing `Error.misplaced/3`'s `%Location{}` match on a
  # binary.
  defp place({:content_node, %Assign{node_location: node_location} = node}, parent, parent_name) do
    {parent, Error.misplaced(content_node_name(node), parent_name, node_location)}
  end

  # A `<script>` that is a direct child of `<scxml>` (spec 5.8) has its own
  # slot, `Document.scripts` (ADR-0026 Decision 7) - unlike `<assign>`, a
  # top-level `<script>` is not misplaced. This clause must precede the
  # generic catch-all below, for the same ordering reason
  # `%Block{}`/`%Transition{}`/`%If{}`/`%Foreach{}`'s own generic
  # `{:content_node, node}` clauses precede `%Assign{}`'s: a more specific
  # parent match must be tried first. Unlike `%Assign{}`, `%Script{}` needs
  # no misplaced-elsewhere clause of its own: `Statifier.Document.Script`
  # carries a plain `location` field (it has no competing SCXML attribute
  # named `location` the way `<assign>` does), so the generic catch-all
  # below already reads its span correctly.
  defp place({:content_node, %Script{} = node}, %Document{} = parent, _parent_name) do
    {%{parent | scripts: [node | parent.scripts]}, nil}
  end

  # `:content_node` covers four elements (`<raise>`, `<log>`, `<assign>`,
  # `<script>`), unlike every other tag which names exactly one - so its
  # misplaced-element name comes from the struct itself, not the tag, ahead
  # of the generic catch-all.
  defp place({:content_node, node}, parent, parent_name) do
    {parent, Error.misplaced(content_node_name(node), parent_name, node.location)}
  end

  defp place({tag, value}, parent, parent_name) do
    {parent, Error.misplaced(Atom.to_string(tag), parent_name, Map.fetch!(value, :location))}
  end

  @spec content_node_name(
          node :: Raise.t() | Log.t() | Assign.t() | If.t() | Foreach.t() | Script.t()
        ) :: binary()
  defp content_node_name(%Raise{}), do: "raise"
  defp content_node_name(%Log{}), do: "log"
  defp content_node_name(%Assign{}), do: "assign"
  defp content_node_name(%If{}), do: "if"
  defp content_node_name(%Foreach{}), do: "foreach"
  defp content_node_name(%Script{}), do: "script"

  @spec reverse_lists(container :: struct()) :: struct()
  defp reverse_lists(%State{} = state) do
    %{
      state
      | states: Enum.reverse(state.states),
        transitions: Enum.reverse(state.transitions),
        onentry: Enum.reverse(state.onentry),
        onexit: Enum.reverse(state.onexit),
        invoke: Enum.reverse(state.invoke)
    }
  end

  defp reverse_lists(%Initial{} = initial) do
    %{initial | transitions: Enum.reverse(initial.transitions)}
  end

  defp reverse_lists(%Document{} = document) do
    %{document | states: Enum.reverse(document.states), scripts: Enum.reverse(document.scripts)}
  end

  defp reverse_lists(%Block{} = block) do
    %{block | content: Enum.reverse(block.content)}
  end

  defp reverse_lists(%Transition{} = transition) do
    %{transition | content: Enum.reverse(transition.content)}
  end

  defp reverse_lists(%Datamodel{} = datamodel) do
    %{datamodel | data: Enum.reverse(datamodel.data)}
  end

  defp reverse_lists(%Donedata{} = donedata) do
    %{donedata | params: Enum.reverse(donedata.params)}
  end

  defp reverse_lists(%Invoke{} = invoke) do
    %{invoke | params: Enum.reverse(invoke.params)}
  end

  # `%If{}`'s branches were built newest-first (`place/3`'s `%If{}` clauses
  # prepend); each branch's own `content` list was built the same way while
  # it was the open branch. Both need reversing to restore document order -
  # the branches themselves, and each one's own content.
  defp reverse_lists(%If{} = if_node) do
    branches =
      if_node.branches
      |> Enum.reverse()
      |> Enum.map(fn %If.Branch{content: content} = branch ->
        %{branch | content: Enum.reverse(content)}
      end)

    %{if_node | branches: branches}
  end

  # `%Foreach{}`'s `content` was built newest-first, the same plain
  # one-list shape `%Block{}`'s clause above reverses - no second nesting
  # level, unlike `%If{}`'s branches (Decision 8: one flat content list).
  defp reverse_lists(%Foreach{} = foreach_node) do
    %{foreach_node | content: Enum.reverse(foreach_node.content)}
  end
end
