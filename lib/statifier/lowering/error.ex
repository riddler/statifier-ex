defmodule Statifier.Lowering.Error do
  @moduledoc """
  Lowering's own error shape: never raised, always collected into a list.

  Mirrors `Statifier.Parser.ParseError`'s shape (`reason`, `message`,
  `location`) but is a plain struct rather than a `defexception` - lowering
  never raises, and `Statifier.Lowering.lower` returns errors in a list
  rather than as a single exception, so a builder that fails on its own
  account can still return a partial result, the walk keeps going, and
  every error found in one pass is reported rather than just the first.

  The `reason` union below is declared as the complete, closed set of
  shapes lowering can report. `missing_attribute/3` and `foreign_element/3`
  extend it alongside the `unsupported_element`, `stray_text`,
  `unexpected_root`, and `misplaced_element` constructors, each added
  without reopening the type.
  """

  alias Statifier.Parser.Location

  @type reason ::
          {:unsupported_element, name :: binary()}
          | {:misplaced_element, name :: binary(), parent :: binary()}
          | {:stray_text, text :: binary()}
          | {:unexpected_root, name :: binary()}
          | {:missing_attribute, element :: binary(), attribute :: binary()}
          | {:foreign_element, name :: binary(), uri :: binary()}
          | {:unexpected_attribute, element :: binary(), attribute :: binary()}
          | {:unsupported_attribute, element :: binary(), attribute :: binary()}

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
  The document's root element is not `<scxml>` (or does not resolve to it
  once namespace prefixes are resolved).
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
  An element that takes no attributes at all (spec 4.5.2's `<else>`) was
  written with one anyway - unlike `missing_attribute/3`, this never blocks
  the element's own struct from being built (`<else>` needs no attribute to
  build its branch), so the caller reports this alongside the struct it
  still constructs, not instead of it.
  """
  @spec unexpected_attribute(element :: binary(), attribute :: binary(), location :: Location.t()) ::
          t()
  def unexpected_attribute(element, attribute, %Location{} = location)
      when is_binary(element) and is_binary(attribute) do
    %__MODULE__{
      reason: {:unexpected_attribute, element, attribute},
      message: "element #{inspect(element)} does not accept attribute #{inspect(attribute)}",
      location: location
    }
  end

  @doc """
  The spec defines `attribute` on `element`, but this engine does not
  implement it - deliberately distinct from `unexpected_attribute/3`, whose
  "does not accept attribute" message would be false here: the spec
  defines it, this engine simply refuses to act on it. `<script src>` is
  the first case (ADR-0026 decision 2: `<script>`'s `src` attribute is
  rejected at load, never fetched - the same unresolved external-fetch
  question `<data src>` leaves open, see ADR-0024). No struct is built when this
  fires; the caller reports this error alone rather than also attempting a
  build.
  """
  @spec unsupported_attribute(
          element :: binary(),
          attribute :: binary(),
          location :: Location.t()
        ) ::
          t()
  def unsupported_attribute(element, attribute, %Location{} = location)
      when is_binary(element) and is_binary(attribute) do
    %__MODULE__{
      reason: {:unsupported_attribute, element, attribute},
      message:
        "element #{inspect(element)}'s #{inspect(attribute)} attribute is defined by the " <>
          "spec but not implemented by this engine (ADR-0026)",
      location: location
    }
  end

  @doc """
  An element resolves to a namespace URI that is neither absent nor the SCXML
  namespace - a genuinely foreign element, since an unprefixed element or one
  declaring no `xmlns` still dispatches as SCXML's own vocabulary. `name` is
  the qualified name exactly as written, prefix included, so the message
  points at what the source actually said.
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
