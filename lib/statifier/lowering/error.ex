defmodule Statifier.Lowering.Error do
  @moduledoc """
  Lowering's own error shape: never raised, always collected into a list.

  Mirrors `Statifier.Parser.ParseError`'s shape (`reason`, `message`,
  `location`) but is a plain struct rather than a `defexception` - lowering
  never raises, and `Statifier.Lowering.lower/1` returns errors in a list
  rather than as a single exception (`docs/plans/260807-st-l5k.4-lowers-dom-to-document.md`
  Decision 2).

  The `reason` union below is the finished set for the whole bead, declared
  once here even though Phase 1 only produced `:unsupported_element`,
  `:stray_text`, and `:unexpected_root`. Later phases added a constructor
  rather than reopening the type: `missing_attribute/3` in Phase 3,
  `foreign_element/3` in Phase 5. `misplaced/3` was written in Phase 1 (Phase
  2 is its first caller) so all four Phase 1 constructors landed together.
  """

  alias Statifier.Parser.Location

  @type reason ::
          {:unsupported_element, name :: binary()}
          | {:misplaced_element, name :: binary(), parent :: binary()}
          | {:stray_text, text :: binary()}
          | {:unexpected_root, name :: binary()}
          | {:missing_attribute, element :: binary(), attribute :: binary()}
          | {:foreign_element, name :: binary(), uri :: binary()}

  @enforce_keys [:reason, :message, :location]
  defstruct [:reason, :message, :location]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t()
        }

  @doc """
  An element name with no entry in the dispatch map.
  """
  @spec unsupported(name :: binary(), location :: Location.t()) :: t()
  def unsupported(name, %Location{} = location) when is_binary(name) do
    %__MODULE__{
      reason: {:unsupported_element, name},
      message: "unsupported element #{inspect(name)}",
      location: location
    }
  end

  @doc """
  A known element built somewhere its parent has no slot for it.
  """
  @spec misplaced(name :: binary(), parent :: binary(), location :: Location.t()) :: t()
  def misplaced(name, parent, %Location{} = location)
      when is_binary(name) and is_binary(parent) do
    %__MODULE__{
      reason: {:misplaced_element, name, parent},
      message: "element #{inspect(name)} is not allowed inside #{inspect(parent)}",
      location: location
    }
  end

  @doc """
  Non-whitespace text found where the element's content model has no room
  for it.

  `text` is the trimmed run, truncated to a readable prefix so the message
  does not embed a paragraph.
  """
  @spec stray_text(text :: binary(), location :: Location.t()) :: t()
  def stray_text(text, %Location{} = location) when is_binary(text) do
    trimmed = String.trim(text)
    preview = String.slice(trimmed, 0, 40)

    preview =
      if String.length(trimmed) > 40 do
        preview <> "..."
      else
        preview
      end

    %__MODULE__{
      reason: {:stray_text, trimmed},
      message: "stray text #{inspect(preview)} is not allowed here",
      location: location
    }
  end

  @doc """
  The document's root element is not `<scxml>` (or, once Phase 5 resolves
  namespaces, does not resolve to it).
  """
  @spec unexpected_root(name :: binary(), location :: Location.t()) :: t()
  def unexpected_root(name, %Location{} = location) when is_binary(name) do
    %__MODULE__{
      reason: {:unexpected_root, name},
      message: "expected the document root to be <scxml>, got #{inspect(name)}",
      location: location
    }
  end

  @doc """
  A required attribute is absent, so the element's struct cannot be built at
  all - `<raise>` with no `event` is the first case (`:event` is
  `@enforce_keys`'d on `Statifier.Document.Raise`).
  """
  @spec missing_attribute(element :: binary(), attribute :: binary(), location :: Location.t()) ::
          t()
  def missing_attribute(element, attribute, %Location{} = location)
      when is_binary(element) and is_binary(attribute) do
    %__MODULE__{
      reason: {:missing_attribute, element, attribute},
      message: "element #{inspect(element)} is missing required attribute #{inspect(attribute)}",
      location: location
    }
  end

  @doc """
  An element resolves to a namespace URI that is neither absent nor the SCXML
  namespace - a genuinely foreign element (Decision 8). `name` is the
  qualified name exactly as written, prefix included, so the message points
  at what the source actually said.
  """
  @spec foreign_element(name :: binary(), uri :: binary(), location :: Location.t()) :: t()
  def foreign_element(name, uri, %Location{} = location)
      when is_binary(name) and is_binary(uri) do
    %__MODULE__{
      reason: {:foreign_element, name, uri},
      message:
        "element #{inspect(name)} is bound to foreign namespace #{inspect(uri)}, not SCXML",
      location: location
    }
  end
end
