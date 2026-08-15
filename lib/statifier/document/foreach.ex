defmodule Statifier.Document.Foreach do
  @moduledoc """
  A `<foreach>` executable-content element (spec 4.6): iterates over an
  array, binding `item` (and, optionally, `index`) in the datamodel for
  each element, then running its own child content once per iteration.

  4.6.2's attribute table:

  > `array` (Executable Content Attribute, Compiled Value expressions)
  > require="true". The expression evaluates to a legal iterable
  > collection.
  >
  > `item` require="true". The name of the variable that holds the current
  > item of the array. Any errors in evaluating this expression, or, more
  > generally, any errors on entering the `<foreach>` element MUST cause
  > processing within this element to cease.
  >
  > `index` require="false". The name of a variable that holds the current
  > index. If unspecified, no index variable is used.

  4.6.3 treats the whole `<foreach>` body as a single unit:

  > if the SCXML processor encounters an error while evaluating [the
  > `<foreach>` element's contents], it must ... treat these actions as
  > part of the same block of executable content as the parent `<foreach>`
  > element.

  Unlike `Statifier.Document.If`, `<foreach>` has no partitioning: `content`
  is the flat `[Document.content_node()]` list `<foreach>`'s children lower
  into, in document order - never a
  branch struct, since there is exactly one child block and the `array`/
  `item`/`index` attributes all belong to `<foreach>` itself rather than to
  any partition of it.

  `array` and `item` are the raw, uncompiled attribute strings (this layer
  never references `Predicator` - `Statifier.Document`'s moduledoc); `item`
  legality (a bare variable name, not a system variable) is a *runtime*
  check, not a lowering or validator one (Decision 1 of the plan above).
  `index` is `nil` when the author wrote none. `location` is the `<foreach>`
  element's own span - as with `%Document.If{}`, and unlike
  `%Document.Assign{}`, there is no name collision between an attribute and
  the element's own span here, so no `node_location` rename is needed.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location, :array, :item]
  defstruct [:location, :array, :item, index: nil, content: [], attribute_locations: %{}]

  @type t :: %__MODULE__{
          location: Location.t(),
          array: String.t(),
          item: String.t(),
          index: String.t() | nil,
          content: [Document.content_node()],
          attribute_locations: Document.attribute_locations()
        }
end
