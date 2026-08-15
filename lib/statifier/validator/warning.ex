defmodule Statifier.Validator.Warning do
  @moduledoc """
  The validator's non-fatal finding shape: never raised, always collected
  into a list, and never gating compilation. Mirrors
  `Statifier.Validator.Error`'s shape character for character - the same
  three enforced fields (`reason`, `message`, `location`), a closed
  `reason` union declared once in full, one public constructor per variant,
  and a `code/1` tag extractor. `Error`'s own moduledoc already states that
  it and `Statifier.Lowering.Error` share a *shape*, not a type, precisely so
  a later diagnostic struct can join the family without any layer's reason
  union leaking into another's; this module is that later member.

  What distinguishes the two unions: an `Error` reason is a spec MUST the
  document violated with no defined engine behavior to fall back on, so the
  document is refused outright. A `Warning` reason is a document-conformance
  finding the engine has a defined behavior for either way - the document
  still lowers, validates past the error checks, and compiles whether or not
  the finding fires. A `Warning` never gates compilation; only `Error` does.
  """

  alias Statifier.Parser.Location

  @typedoc """
  Exactly one variant today: `element` occurred somewhere the spec forbids
  event-raising or external-action executable content, carrying the
  offending element's own name (e.g. `"raise"`) as data, the way
  `Statifier.Validator.Error`'s `{:duplicate_id, id}` carries an id.
  """
  @type reason :: {:finalize_forbidden_content, element :: binary()}

  @enforce_keys [:reason, :message, :location]
  defstruct [:reason, :message, :location]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t()
        }

  @doc """
  The reason tuple's tag - the stable warning code, mirroring
  `Statifier.Validator.Error.code/1`.
  """
  @spec code(reason :: reason()) :: atom()
  def code(reason) when is_tuple(reason), do: elem(reason, 0)

  @doc """
  Spec 6.5.2, quoted in full: "In a conformant SCXML document, the
  executable content inside `<finalize>` MUST NOT raise events or invoke
  external actions. In particular, the `<send>` and `<raise>` elements MUST
  NOT occur."

  `element` is the offending element's own name (`"raise"` today; `"send"`
  joins it when `Statifier.Document.Send` exists - see
  `Statifier.Validator.Checks.Invoke`'s moduledoc). `location` is the
  offending node's **own** span, never the enclosing `<invoke>`'s - matching
  every constructor in `error.ex` that reports at a nested element's own
  location rather than its container's.
  """
  @spec finalize_forbidden_content(element :: binary(), location :: Location.t()) :: t()
  def finalize_forbidden_content(element, %Location{} = location) when is_binary(element) do
    %__MODULE__{
      reason: {:finalize_forbidden_content, element},
      message: "<#{element}> must not occur inside <finalize>",
      location: location
    }
  end
end
