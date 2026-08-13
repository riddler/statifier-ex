defmodule Statifier.Document.If do
  @moduledoc """
  An `<if>` executable-content element (spec 4.3): the partitioned form of
  `<if>`/`<elseif>`/`<else>`, quoting spec 4.3.2 exactly:

  > The behavior of `<if>` is defined in terms of partitions of executable
  > content. The first partition consists of the executable content between
  > the `<if>` and the first `<elseif>`, `<else>` or `</if>` tag. Each
  > `<elseif>` tag defines a partition that extends from it to the next
  > `<elseif>`, `<else>` or `</if>` tag. The `<else>` tag defines a partition
  > that extends from it to the closing `</if>` tag.

  `Statifier.Lowering.Builders.build_if/2` has already done this
  partitioning by the time a `%Statifier.Document.If{}` exists: `branches`
  is never the raw, unpartitioned child list `<if>` wrote in the source, it
  is the ordered `[Statifier.Document.If.Branch.t()]` list the fold over
  `<elseif>`/`<else>` boundaries produced. `location` is the `<if>` element's
  own span - the whole element, `<if>` through `</if>`.
  """

  alias Statifier.Document
  alias Statifier.Document.If.Branch
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, branches: []]

  @type t :: %__MODULE__{
          location: Location.t(),
          branches: [Branch.t()]
        }

  defmodule Branch do
    @moduledoc """
    One partition of an `<if>` - the executable content between one
    partitioning tag (`<if>`, `<elseif>`, or `<else>`) and the next, per
    `Statifier.Document.If`'s moduledoc.

    `cond` is `nil` for the `<else>` branch and for a branch with no `cond`
    at all - spec 4.5.1: "`<else>` ... is equivalent to an `<elseif>` with a
    'cond' that always evaluates to true." `location` is this branch's own
    partitioning tag's span (the `<if>`, `<elseif>`, or `<else>` element
    itself), not the `<if>`'s overall span - it is where
    `Statifier.Validator.Checks.If` (Phase 3) reports a branch-ordering
    error against the *offending* branch rather than the whole `<if>`.
    `attribute_locations` carries `:cond`'s value span when the branch wrote
    one, following every other node's contract
    (`lib/statifier/document.ex:22-44`).

    Unlike `Statifier.Document.Assign`, there is no name collision here
    between an attribute value and the element's own span, so `location`
    keeps its usual meaning and needs no `node_location` rename.
    """

    alias Statifier.Document
    alias Statifier.Parser.Location

    @enforce_keys [:location]
    defstruct [:location, cond: nil, content: [], attribute_locations: %{}]

    @type t :: %__MODULE__{
            location: Location.t(),
            cond: String.t() | nil,
            content: [Document.content_node()],
            attribute_locations: Document.attribute_locations()
          }
  end
end
