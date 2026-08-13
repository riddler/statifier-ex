defmodule Statifier.Validator.Error do
  @moduledoc """
  The validator's own error shape: never raised, always collected into a
  list. Mirrors `Statifier.Lowering.Error`'s shape (`reason`, `message`,
  `location`) with character-identical field names, so a future common
  diagnostic protocol can adopt both without either layer's reason union
  leaking into the other's. The two layers' error lists are never observed
  together - `Statifier.Validator.validate/2` only ever receives a document
  lowering already accepted - so sharing the *shape* rather than the type is
  enough.

  `reason` is a closed tagged-tuple union, declared once in full here even
  though initially only `:duplicate_id` has a constructor. Later additions
  add a constructor per reason rather than reopening the type, following
  `Statifier.Lowering.Error`'s own precedent.

  `code/1` returns the reason tuple's tag atom - the stable error code the
  bead's acceptance criteria ask for - while `reason` itself keeps carrying
  the offending ids as data, the way the rest of the repo does.
  """

  alias Statifier.Lowering.Namespace
  alias Statifier.Parser.Location

  @typedoc """
  Which slot a shared transition-shape violation (`:transition_count`,
  `:transition_missing_target`, `:transition_forbidden_attribute`) came
  from: a state's `<initial>` element, or a `:history` state's own default
  transition. The id is `nil` exactly when the owning state's own `id` is.
  """
  @type owner :: {:initial, String.t() | nil} | {:history, String.t() | nil}

  @type reason ::
          {:duplicate_id, id :: binary()}
          | {:empty_id}
          | {:unresolved_target, id :: binary()}
          | {:unresolved_initial, id :: binary()}
          | {:initial_not_descendant, id :: binary(), parent_id :: binary()}
          | {:initial_not_top_level, id :: binary()}
          | {:initial_on_atomic_state, id :: binary()}
          | {:initial_attribute_and_element, id :: binary()}
          | {:transition_count, owner :: owner(), count :: non_neg_integer()}
          | {:transition_missing_target, owner :: owner()}
          | {:transition_forbidden_attribute, owner :: owner(), attr :: :event | :cond}
          | {:history_bad_parent, id :: binary(), parent_kind :: atom()}
          | {:history_bad_type, raw :: binary()}
          | {:transition_bad_type, raw :: binary()}
          | {:scxml_bad_binding, raw :: binary()}
          | {:final_has_states, id :: binary()}
          | {:final_has_transitions, id :: binary() | nil}
          | {:final_parent_missing_id, final_id :: binary() | nil}
          | {:default_entry_not_enterable, id :: binary(), child_kind :: atom()}
          | {:donedata_not_on_final, id :: binary()}
          | {:content_expr_and_text, expr :: binary()}
          | {:bad_namespace, uri :: binary() | nil}
          | {:bad_version, version :: binary() | nil}
          | {:scxml_bad_datamodel, raw :: binary()}
          | {:data_expr_and_src, id :: binary()}
          | {:data_value_and_children, id :: binary()}
          | {:data_reserved_id, id :: binary()}
          | {:datamodel_bad_parent, kind :: atom()}
          | {:assign_expr_and_text, expr :: binary()}

  @enforce_keys [:reason, :message, :location]
  defstruct [:reason, :message, :location]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t()
        }

  @doc """
  The reason tuple's tag - the stable error code.
  """
  @spec code(reason :: reason()) :: atom()
  def code(reason) when is_tuple(reason), do: elem(reason, 0)

  @doc """
  Check 1 (spec 3.14): `id` names more than one state in the document. The
  location is the offending (non-first) occurrence's own span, never the
  canonical one.
  """
  @spec duplicate_id(id :: binary(), location :: Location.t()) :: t()
  def duplicate_id(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:duplicate_id, id},
      message: "duplicate state id #{inspect(id)}",
      location: location
    }
  end

  @doc """
  Check 1 (spec 3.14): a state was written with `id=""`. `id` is
  typed as an XML Schema ID, whose lexical space is an XML `Name` and
  therefore excludes the empty string, so an empty id is not a name a
  transition could ever target.

  This is a different case from an absent `id`, which is legal and reported
  by nothing (`lib/statifier/document/state.ex`): the two are told apart by
  the `attribute_locations[:id]` key, never by the value alone. The reason
  carries no payload - the offending value is the empty string, and the
  location is the span the author wrote it at.
  """
  @spec empty_id(location :: Location.t()) :: t()
  def empty_id(%Location{} = location) do
    %__MODULE__{
      reason: {:empty_id},
      message: "state id must not be empty - an absent id is legal, an empty one is not",
      location: location
    }
  end

  @doc """
  Check 2 (spec 3.5): a `<transition>`'s `target` names `id`, and no state
  in the document carries that id. Reported once per unresolved id, at the
  transition's own `target` span (or the transition's, when unwritten).
  """
  @spec unresolved_target(id :: binary(), location :: Location.t()) :: t()
  def unresolved_target(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:unresolved_target, id},
      message: "transition target #{inspect(id)} does not resolve to a state in the document",
      location: location
    }
  end

  @doc """
  Check 3 (spec 3.3, 3.6): an `initial` attribute or `Document.initial`
  names `id`, and no state in the document carries that id. An `<initial>`
  element's own transition targets are never reported by this constructor -
  check 2 already owns their existence.
  """
  @spec unresolved_initial(id :: binary(), location :: Location.t()) :: t()
  def unresolved_initial(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:unresolved_initial, id},
      message: "initial state #{inspect(id)} does not resolve to a state in the document",
      location: location
    }
  end

  @doc """
  Check 3 (spec 3.3, 3.6): a resolved initial target `id` is not a
  descendant of the state it initializes, `parent_id` - ancestry, not
  direct-child membership (v1's bug).
  """
  @spec initial_not_descendant(id :: binary(), parent_id :: binary(), location :: Location.t()) ::
          t()
  def initial_not_descendant(id, parent_id, %Location{} = location)
      when is_binary(id) and is_binary(parent_id) do
    %__MODULE__{
      reason: {:initial_not_descendant, id, parent_id},
      message: "initial state #{inspect(id)} is not a descendant of #{inspect(parent_id)}",
      location: location
    }
  end

  @doc """
  Check 3 (spec 3.3): a resolved `Document.initial` id names a state that
  exists but is not itself a top-level state - the root's own substitute
  for the descendancy check a named state gets.
  """
  @spec initial_not_top_level(id :: binary(), location :: Location.t()) :: t()
  def initial_not_top_level(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:initial_not_top_level, id},
      message: "document initial #{inspect(id)} does not resolve to a top-level state",
      location: location
    }
  end

  @doc """
  Check 3 (spec 3.3): `id` names a state carrying an `initial`
  attribute or `<initial>` element, and the spec MUST NOT: an atomic state
  (no `states` children, or a `:parallel`, `:final`, or `:history` kind) has
  nothing to default into. Fires ahead of, and suppresses, the descendancy
  check for the same state.
  """
  @spec initial_on_atomic_state(id :: binary(), location :: Location.t()) :: t()
  def initial_on_atomic_state(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:initial_on_atomic_state, id},
      message: "state #{inspect(id)} has no child states to default into",
      location: location
    }
  end

  @doc """
  Check 4 (spec 3.3, 3.6): a state carries both an `initial` attribute and
  an `<initial>` element - at most one is legal. Reported at the
  `<initial>` element's own span.
  """
  @spec initial_attribute_and_element(id :: binary() | nil, location :: Location.t()) :: t()
  def initial_attribute_and_element(id, %Location{} = location) do
    %__MODULE__{
      reason: {:initial_attribute_and_element, id},
      message:
        "state #{inspect(id)} has both an initial attribute and an <initial> element - at most one is legal",
      location: location
    }
  end

  @doc """
  Checks 4 and 5 (spec 3.6, 3.10): `owner`'s content model is
  exactly one `<transition>`, and it holds `count` instead. Fires for both
  zero (nothing to default into) and two-or-more (which one wins is
  undefined).
  """
  @spec transition_count(owner :: owner(), count :: non_neg_integer(), location :: Location.t()) ::
          t()
  def transition_count(owner, count, %Location{} = location)
      when is_tuple(owner) and is_integer(count) and count >= 0 do
    %__MODULE__{
      reason: {:transition_count, owner, count},
      message: "#{owner_description(owner)} must have exactly one transition, found #{count}",
      location: location
    }
  end

  @doc """
  Checks 4 and 5 (spec 3.6, 3.10): `owner`'s one transition
  carries no usable `target` - `target=""` and an absent `target` are the
  same failure here.
  """
  @spec transition_missing_target(owner :: owner(), location :: Location.t()) :: t()
  def transition_missing_target(owner, %Location{} = location) when is_tuple(owner) do
    %__MODULE__{
      reason: {:transition_missing_target, owner},
      message: "#{owner_description(owner)} transition must specify a target",
      location: location
    }
  end

  @doc """
  Checks 4 and 5 (spec 3.6, 3.10): `owner`'s one transition carries `attr`
  (`:event` or `:cond`), which neither an `<initial>` nor a `<history>`
  default transition may specify.
  """
  @spec transition_forbidden_attribute(
          owner :: owner(),
          attr :: :event | :cond,
          location :: Location.t()
        ) :: t()
  def transition_forbidden_attribute(owner, attr, %Location{} = location)
      when is_tuple(owner) and attr in [:event, :cond] do
    %__MODULE__{
      reason: {:transition_forbidden_attribute, owner, attr},
      message: "#{owner_description(owner)} transition must not specify #{attr}",
      location: location
    }
  end

  @doc """
  Check 5 (spec 3.10): a `:history` state `id` is a child of `parent_kind`,
  which is not a compound `<state>` or `<parallel>` - the only two legal
  parents for a history pseudo-state. `parent_kind` is `:scxml` for the
  document root itself.
  """
  @spec history_bad_parent(id :: binary() | nil, parent_kind :: atom(), location :: Location.t()) ::
          t()
  def history_bad_parent(id, parent_kind, %Location{} = location) when is_atom(parent_kind) do
    %__MODULE__{
      reason: {:history_bad_parent, id, parent_kind},
      message:
        "history #{inspect(id)} must be a child of a compound <state> or <parallel>, not #{parent_kind}",
      location: location
    }
  end

  @doc """
  Check 5 (spec 3.10): a `<history type="...">` value that is neither
  `"shallow"` nor `"deep"`. `raw` is the source text as written
  (`Location.slice/2`), so the message quotes what the author
  actually typed rather than the default it silently lowered to.
  """
  @spec history_bad_type(raw :: binary(), location :: Location.t()) :: t()
  def history_bad_type(raw, %Location{} = location) when is_binary(raw) do
    %__MODULE__{
      reason: {:history_bad_type, raw},
      message: "history type #{inspect(raw)} must be \"shallow\" or \"deep\"",
      location: location
    }
  end

  @doc """
  Spec 3.5: a `<transition type="...">` value that is neither
  `"internal"` nor `"external"`. `raw` is the source text as written
  (`Location.slice/2`) - lowering maps any out-of-range value
  onto the `:external` default, so the atom alone cannot tell
  `type="external"` from `type="sideways"`.
  """
  @spec transition_bad_type(raw :: binary(), location :: Location.t()) :: t()
  def transition_bad_type(raw, %Location{} = location) when is_binary(raw) do
    %__MODULE__{
      reason: {:transition_bad_type, raw},
      message: "transition type #{inspect(raw)} must be \"internal\" or \"external\"",
      location: location
    }
  end

  @doc """
  Spec 3.2.1: an `<scxml binding="...">` value that is neither
  `"early"` nor `"late"`. Same slice-back substrate as
  `transition_bad_type/2`, against the `:early` default.
  """
  @spec scxml_bad_binding(raw :: binary(), location :: Location.t()) :: t()
  def scxml_bad_binding(raw, %Location{} = location) when is_binary(raw) do
    %__MODULE__{
      reason: {:scxml_bad_binding, raw},
      message: "binding #{inspect(raw)} must be \"early\" or \"late\"",
      location: location
    }
  end

  @doc """
  Check 6 (spec 3.7): `id` names a state child of a `:final` - only
  `onentry`, `onexit`, and `donedata` are legal there. Reported once per
  offending child, at the **child's own** `location` (not the `<final>`'s),
  so the caret lands on the element that should not be there.
  """
  @spec final_has_states(id :: binary() | nil, location :: Location.t()) :: t()
  def final_has_states(id, %Location{} = location) do
    %__MODULE__{
      reason: {:final_has_states, id},
      message:
        "state #{inspect(id)} must not be a child of <final> - only onentry, " <>
          "onexit, and donedata are legal there",
      location: location
    }
  end

  @doc """
  Check 6 (spec 3.7): `id` names a `:final` carrying a `<transition>`. A
  `<final>` is where a region stops, so it has no outgoing transitions to
  take - spec 3.7's content model is `onentry`, `onexit`, and `donedata`
  only. Reported once per offending transition, at the **transition's own**
  `location` rather than the `<final>`'s, matching `final_has_states/2`.
  """
  @spec final_has_transitions(id :: binary() | nil, location :: Location.t()) :: t()
  def final_has_transitions(id, %Location{} = location) do
    %__MODULE__{
      reason: {:final_has_transitions, id},
      message:
        "state #{inspect(id)} is a <final> and must not carry a <transition> - " <>
          "only onentry, onexit, and donedata are legal there",
      location: location
    }
  end

  @doc """
  Check 12 (spec 3.7, Appendix D `enterStates`): a `<final>` state's parent
  carries no `id`. Entering a non-top-level `<final>` raises
  `done.state.{parent.id}`, so a parent with no written id has a completion
  event the spec names after a name it does not have - and no transition
  could match `"done.state."` even if it were raised. `final_id` is the
  offending `<final>` child's own id, which names the completion the
  document loses; it rides in `reason` and stays **out** of `message`,
  because it is itself optionally `nil` and interpolating that reads as a
  bug ("containing <final> nil") in the one case the check exists for. The
  location is the **parent's** span, since the parent is the element that
  has to change.
  """
  @spec final_parent_missing_id(final_id :: binary() | nil, location :: Location.t()) :: t()
  def final_parent_missing_id(final_id, %Location{} = location) do
    %__MODULE__{
      reason: {:final_parent_missing_id, final_id},
      message:
        "a state containing a <final> child must have an id - its " <>
          "completion event is named done.state.<id>",
      location: location
    }
  end

  @doc """
  Check 7 (spec 3.3): `id` names a compound state with no
  `initial` attribute and no `<initial>` element, whose first child in
  document order has `child_kind` - a `:history` pseudo-state cannot be
  entered by the spec 3.3 default-entry fallback. Reported at the first
  child's own `location`.
  """
  @spec default_entry_not_enterable(
          id :: binary() | nil,
          child_kind :: atom(),
          location :: Location.t()
        ) :: t()
  def default_entry_not_enterable(id, child_kind, %Location{} = location)
      when is_atom(child_kind) do
    %__MODULE__{
      reason: {:default_entry_not_enterable, id, child_kind},
      message:
        "state #{inspect(id)} has no initial attribute or <initial> element, and its " <>
          "first child is a #{child_kind} pseudo-state, which cannot be entered by default",
      location: location
    }
  end

  @doc """
  Check 8 (spec 3.7, 5.7): `id` names a non-`:final` state carrying a
  non-nil `donedata` - `<donedata>` is only legal on `:final`. Reported at
  the `donedata`'s own `location`.
  """
  @spec donedata_not_on_final(id :: binary() | nil, location :: Location.t()) :: t()
  def donedata_not_on_final(id, %Location{} = location) do
    %__MODULE__{
      reason: {:donedata_not_on_final, id},
      message: "state #{inspect(id)} carries <donedata>, which is only legal on <final>",
      location: location
    }
  end

  @doc """
  Spec 5.6: a `<content>` element carries both an `expr` attribute
  and inline text - the spec's "MUST NOT specify both" that
  `lib/statifier/document/content.ex` deliberately leaves representable so
  this check can report it. `expr` is the attribute's value as lowered, so
  the message quotes the expression rather than the text, which has no span
  of its own (`Statifier.Document.Content`'s moduledoc). Reported at the
  `<content>` element's own `location`, the only span covering both halves
  of the conflict.
  """
  @spec content_expr_and_text(expr :: binary(), location :: Location.t()) :: t()
  def content_expr_and_text(expr, %Location{} = location) when is_binary(expr) do
    %__MODULE__{
      reason: {:content_expr_and_text, expr},
      message:
        "<content> must not specify both an expr attribute (#{inspect(expr)}) and inline text",
      location: location
    }
  end

  @doc """
  Check 9 (spec 3.2.1): the root element's resolved namespace,
  `document.namespace`, is not the SCXML namespace. `uri` is
  `document.namespace` itself - `nil` for a fragment that declares no
  namespace at all, the boilerplate-free case that relaxed parsing left
  representable.
  """
  @spec bad_namespace(uri :: binary() | nil, location :: Location.t()) :: t()
  def bad_namespace(uri, %Location{} = location) do
    %__MODULE__{
      reason: {:bad_namespace, uri},
      message: bad_namespace_message(uri),
      location: location
    }
  end

  @spec bad_namespace_message(uri :: binary() | nil) :: binary()
  defp bad_namespace_message(nil) do
    "the root element declares no namespace - expected xmlns=" <>
      inspect(Namespace.scxml_namespace())
  end

  defp bad_namespace_message(uri) do
    "the root element's namespace #{inspect(uri)} is not the SCXML namespace " <>
      inspect(Namespace.scxml_namespace())
  end

  @doc """
  Check 10 (spec 3.2.1): the root element's `version` is not `"1.0"`.
  `version` is `nil` when the attribute is absent.
  """
  @spec bad_version(version :: binary() | nil, location :: Location.t()) :: t()
  def bad_version(version, %Location{} = location) do
    %__MODULE__{
      reason: {:bad_version, version},
      message: bad_version_message(version),
      location: location
    }
  end

  @spec bad_version_message(version :: binary() | nil) :: binary()
  defp bad_version_message(nil), do: "the root element has no version attribute, expected \"1.0\""

  defp bad_version_message(version) do
    "the root element's version #{inspect(version)} must be \"1.0\""
  end

  @doc """
  Check 13 (spec 3.2.1): a `datamodel="..."` value outside
  `["predicator", "elixir", "null", "ecmascript", "xpath"]` - the spec's own
  three named values (`"null"`, `"ecmascript"`, `"xpath"`) plus this
  platform's two (`"predicator"`, its default; `"elixir"`, an alias for
  v1-converted documents). Accepting `"ecmascript"` and `"xpath"` does not
  claim this engine implements either datamodel - spec 3.2.1's Valid Values
  clause names "other platform-defined values" as legal too, and Appendix
  B's intro states no rule for what a processor does with a datamodel it
  does not implement. What this check actually catches is a typo
  (`datamodel="predicater"`, `datamodel="javascript"`); which datamodel this
  engine runs is `docs/datamodel.md`'s answer, not this attribute's. `raw`
  is the source text as written (`Location.slice/2`), the same substrate as
  `scxml_bad_binding/2`.
  """
  @spec scxml_bad_datamodel(raw :: binary(), location :: Location.t()) :: t()
  def scxml_bad_datamodel(raw, %Location{} = location) when is_binary(raw) do
    %__MODULE__{
      reason: {:scxml_bad_datamodel, raw},
      message:
        "datamodel #{inspect(raw)} must be one of " <>
          ~s("predicator", "elixir", "null", "ecmascript", or "xpath"),
      location: location
    }
  end

  @doc """
  Check 13 (spec 5.3.2): a `<data>` carries both an `expr` and a `src`
  attribute - "MAY have either a 'src' or an 'expr' attribute, but MUST NOT
  have both". `id` is the offending `<data>`'s own id.
  """
  @spec data_expr_and_src(id :: binary(), location :: Location.t()) :: t()
  def data_expr_and_src(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:data_expr_and_src, id},
      message: "<data> #{inspect(id)} must not specify both expr and src",
      location: location
    }
  end

  @doc """
  Check 13 (spec 5.3.2): a `<data>` carries an `expr` or `src` attribute
  **and** non-blank child text - "if either attribute is present, the
  element MUST NOT have any children". Whitespace-only text does not count
  (`Checks.Data.blank?/1`).
  """
  @spec data_value_and_children(id :: binary(), location :: Location.t()) :: t()
  def data_value_and_children(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:data_value_and_children, id},
      message: "<data> #{inspect(id)} must not specify expr or src together with child content",
      location: location
    }
  end

  @doc """
  Check 13 (spec 5.10): a `<data id="...">` begins with `_` - "A conformant
  SCXML document MUST NOT contain ids beginning with '_' in the `<data>`
  element".
  """
  @spec data_reserved_id(id :: binary(), location :: Location.t()) :: t()
  def data_reserved_id(id, %Location{} = location) when is_binary(id) do
    %__MODULE__{
      reason: {:data_reserved_id, id},
      message: "<data> id #{inspect(id)} must not begin with \"_\" - that prefix is reserved",
      location: location
    }
  end

  @doc """
  Check 13 (spec 3.2.2 / 3.3.2 / 3.4.2): a `<datamodel>` sits on a `:final`
  or `:history` state - legal only under `<scxml>`, `<state>`, and
  `<parallel>`. `kind` is the offending state's own kind.
  """
  @spec datamodel_bad_parent(kind :: atom(), location :: Location.t()) :: t()
  def datamodel_bad_parent(kind, %Location{} = location) when is_atom(kind) do
    %__MODULE__{
      reason: {:datamodel_bad_parent, kind},
      message: "<datamodel> must not be a child of a #{kind} state",
      location: location
    }
  end

  @doc """
  Spec 5.4.2: an `<assign>` element carries both an `expr` attribute and
  non-blank child content - "A conformant SCXML document MUST specify
  either 'expr' or children of `<assign>`, but not both." `expr` is the
  attribute's value as lowered, so the message quotes the expression rather
  than the text, which has no span of its own. Reported at the `<assign>`'s
  own element span (`Statifier.Document.Assign.node_location`, not the
  SCXML `location` *attribute* that struct also carries -
  `Statifier.Document.Assign`'s moduledoc names the two spans apart).
  """
  @spec assign_expr_and_text(expr :: binary(), location :: Location.t()) :: t()
  def assign_expr_and_text(expr, %Location{} = location) when is_binary(expr) do
    %__MODULE__{
      reason: {:assign_expr_and_text, expr},
      message:
        "<assign> must not specify both an expr attribute (#{inspect(expr)}) and child content",
      location: location
    }
  end

  @spec owner_description(owner :: owner()) :: binary()
  defp owner_description({:initial, nil}), do: "<initial>"
  defp owner_description({:initial, id}), do: "<initial> on #{inspect(id)}"
  defp owner_description({:history, nil}), do: "<history>"
  defp owner_description({:history, id}), do: "<history> #{inspect(id)}"
end
