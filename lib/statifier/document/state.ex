defmodule Statifier.Document.State do
  @moduledoc """
  One `<state>`, `<parallel>`, `<final>`, or `<history>` element - a single
  struct with a `kind` atom rather than four per-kind structs.

  One struct with a `kind` atom rather than four per-kind structs, with two
  refinements beyond that basic shape, both carried forward into this
  moduledoc:

  ## The kind set

  `kind :: :state | :parallel | :final | :history`, equal to the element
  name that produced it. The rule the set follows: **a kind is a thing with
  an id that a transition can target.** `<state>`, `<parallel>`, `<final>`,
  and `<history>` all qualify - `id` is optional on each, but present in the
  grammar and targetable when given.

  `:initial` is deliberately absent. `<initial>` has no `id` attribute at
  all (spec 3.6), so it is not a state; it is a slot on its parent,
  `initial_element` below (see `Statifier.Document.Initial`).

  `:atomic` and `:compound` are also absent. v1 widened its atom set at
  parse time so `isCompoundState` became a pure atom match
  (`../statifier/lib/statifier/parser/scxml/state_stack.ex:194-207`); v2
  does not, for two reasons. First, keeping `kind` equal to the element name
  means lowering never has to decide anything semantic - the widening, if
  any, happens in the compiler, the layer ADR-0002 already assigns Appendix
  D's predicates to. Second, v1's widening is exactly what produced the
  `:final`-is-not-`:atomic` divergence that made
  `collect_atomic_descendants/1` fall through final states
  (`../statifier/lib/statifier/history_tracker.ex:163-170`). The compiler
  remains free to stamp a widened discriminator on the *compiled* state -
  this Document layer's `kind` set constrains only lowering's own output,
  never whatever field the compiler's compiled-state struct uses for its
  own `kind`.

  ## Fields that are kind-scoped

  Not every field is meaningful on every kind. Rather than four structs each
  omitting what does not apply, one struct names, per field, which kind it
  is meaningful on, what a misuse looks like, and which check catches it:

  | Field | Meaningful on | Representable misuse | Caught by |
  |---|---|---|---|
  | `donedata` | `:final` | donedata on a non-final state | the validator's check 8 |
  | `datamodel_element` | `:state`, `:parallel` | a `<datamodel>` on a `:final` or `:history` state | `Statifier.Validator.Checks.Data`'s `:datamodel_bad_parent` |
  | `states` | `:state`, `:parallel` | state children under a `:final` | the validator's check 6 |
  | `states` | any | a `:history` child of `:final` or of another `:history` | the validator's check 5 |
  | `initial` / `initial_element` | `:state` | both forms on one state | the validator's check 4 |
  | `initial` / `initial_element` | `:state` | an initial on an atomic state | the validator's check 3 (target resolution and descendancy) |
  | `history_type` | `:history` | `history_type` on a non-history kind | **nothing** - unbuildable from lowering, see below |
  | `transitions` | `:state`, `:parallel`, `:history`, `:initial` slot | transitions on a `:final` | the validator's check 6, widened to also cover this case |
  | `id` | any | `nil` id | not an error; the spec makes `id` optional |
  | `id` | any | `id=""` written explicitly | the validator's check 1, widened to treat an explicit empty id as an error |

  The remaining "nothing" row is stated here rather than hidden.
  `history_type` on a non-history kind is unreachable from lowering, which
  only ever sets it from a `<history type="...">` attribute; it is a shape a
  *hand-built* Document (a test fixture, or a future programmatic builder)
  could produce, and this moduledoc says so rather than implying a check
  exists for it.

  A `:final` carrying `transitions` **is** reachable from lowering (spec 3.7
  gives `<final>` no `<transition>` children, but nothing here refuses to
  build one). The validator's check 6 was widened to cover this case rather
  than adding a ninth check. This struct was unaffected either way.

  `id: String.t() | nil` no longer overloads `nil` the way it might if
  `<initial>` were a kind: with `<initial>` off the kind set entirely,
  `nil` means exactly one thing here - the author omitted an optional `id`.
  An `id` written as `""` is a different thing and lowering keeps it that
  way: the validator treats it as an error (spec 3.14 types `id` as an XML
  Schema ID, whose lexical space excludes the empty string), reported by
  check 1 as `{:empty_id}` and, like a `nil` id, excluded from that check's
  uniqueness set.

  ## What this module is not

  No Appendix D predicate (`is_compound_state?`, `is_atomic_state?`, and
  friends) is defined in this module or anywhere under
  `lib/statifier/document/`. Those live on the Machine per ADR-0002;
  defining them here would duplicate them in the layer that does not run
  them.
  """

  alias Statifier.Document
  alias Statifier.Document.Block
  alias Statifier.Document.Datamodel
  alias Statifier.Document.Donedata
  alias Statifier.Document.Initial
  alias Statifier.Document.Transition
  alias Statifier.Parser.Location

  @enforce_keys [:kind, :location]
  defstruct [
    :kind,
    :location,
    id: nil,
    initial: [],
    initial_element: nil,
    states: [],
    transitions: [],
    onentry: [],
    onexit: [],
    history_type: nil,
    donedata: nil,
    datamodel_element: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          kind: Document.state_kind(),
          id: String.t() | nil,
          initial: [String.t()],
          initial_element: Initial.t() | nil,
          states: [t()],
          transitions: [Transition.t()],
          onentry: [Block.t()],
          onexit: [Block.t()],
          history_type: :shallow | :deep | nil,
          donedata: Donedata.t() | nil,
          datamodel_element: Datamodel.t() | nil,
          location: Location.t(),
          attribute_locations: Document.attribute_locations()
        }
end
