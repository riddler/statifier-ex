defmodule Statifier.Parser do
  @moduledoc """
  XML source in, generic DOM tree out.

  The first arrow of the pipeline in `docs/architecture.md`: this layer knows
  XML and nothing else. It produces a `Statifier.Parser.DOM.Element` tree with
  a source span on every node, and a later pass lowers that tree into typed
  structs.

  ## What it does not do

  Nothing is validated, or resolved beyond what an XML processor must do
  before a value exists at all. Unknown names, duplicate attributes, missing
  namespace declarations, and structurally nonsensical documents all parse
  successfully - "make invalid states unrepresentable" is the validator's
  principle to enforce, and it cannot enforce it against things the parser has
  already thrown away. The two exceptions are attribute-value normalization
  and character-data line-break folding: XML 1.0 3.3.3, XML 1.0 2.11, and
  SCXML Appendix A.2 make both a processor obligation rather than vocabulary
  knowledge, so `Statifier.Parser.DOM.Attribute.value` is 3.3.3-normalized and
  entity-expanded (ADR-0043) and `Statifier.Parser.DOM.Text.value` is
  2.11-folded and entity-expanded (ADR-0045); nothing else in this list is
  touched. In particular:

  - Names are the raw qualified bytes, prefix included. A namespace
    declaration is an ordinary attribute, reachable as
    `Statifier.Parser.DOM.attribute(root, "xmlns")`.
  - Whitespace is preserved verbatim as runs, including whitespace-only text
    runs - dropping them would need the parser to know which vocabulary
    treats whitespace as significant, which is exactly the knowledge this
    layer does not have (`Statifier.Parser.DOM.elements/1` is the filter) -
    but a run's line breaks are 2.11-folded (ADR-0045): a literal CRLF or
    lone CR becomes a single `\n`, the same as any other character data.
  - Comments and processing instructions produce no nodes. Saxy emits no
    events for them, so surfacing them would mean driving the tree from the
    scanner instead of the event stream. The scanner still skips them
    correctly, so they cost locations nothing.
  - Anything outside the root element - the prolog, the XML declaration,
    trailing whitespace - is discarded.

  ## Relaxed input

  `parse/1` takes the caller's binary and parses *that binary*. It never
  normalizes, and in particular never inserts `xmlns` or `version` into the
  start tag and never prepends an XML declaration. Every span therefore
  slices out of the caller's own source with `Location.slice/2`, and
  ADR-0014's attribute-relative arithmetic needs no translation.

  Boilerplate-free fragments are supported, unconditionally and with no
  option. v1's `:relaxed` (default `true`) and `:xml_declaration` (default
  `false`) have no v2 equivalents: relaxation is not a mode here, it is what
  this layer is, and the prolog is discarded anyway so an inserted
  declaration would buy nothing but v1's documented line shift.

  Rejecting a fragment for missing boilerplate is the validator's job,
  because a `%Document{}` with `xmlns: nil` is representable and this layer
  reports only what it cannot represent.

  ## Locations

  Saxy 1.6.1 passes handlers no position data of any kind and has no option
  to enable it (`deps/saxy/lib/saxy/handler.ex`), so positions come from a
  second pass: `Statifier.Parser.Markup` scans the same source for markup
  boundaries and `Statifier.Parser.Handler` zips its records against the
  event stream by index. The alternatives were each rejected for a stated
  reason: v1's re-scan-per-element regex was documented wrong (per-line
  occurrence counting, first-occurrence columns, matches inside comments) and
  O(n^2); `Saxy.Partial` yields chunk brackets, not per-element positions;
  `:xmerl_sax_parser` reports a line but no column and turns names into
  atoms; and forking Saxy is a permanent maintenance liability for one field
  upstream has never discussed.

  One consequence is worth stating where callers will read it: an attribute's
  `value` is XML 1.0 3.3.3-normalized and entity-expanded (ADR-0043) while its
  `value_location` covers raw source, so a literal newline, tab, or carriage
  return in the raw text is a single space in `value`, and offsets *inside* a
  value whose raw text contains a reference or a normalized whitespace
  character do not map 1:1 onto the document. Character data has the same
  split: a text node's `value` is XML 1.0 2.11-folded and entity-expanded
  (ADR-0045) while its `location` covers raw source, so a literal CRLF or
  lone CR in the raw text is a single `\n` in `value`, and offsets inside a
  value whose raw text contains a reference, a CDATA delimiter, a comment, a
  PI, or a folded line break do not map 1:1 onto the document either.

  ## Errors

  Malformed input returns `{:error, %Statifier.Parser.ParseError{}}` and this
  function never raises - `Saxy.parse_string/4` reports errors as tuples, and
  the location-desync guard aborts through `{:stop, _}`, which Saxy hands
  back as an ordinary result. The one path where Saxy itself breaks that
  contract, a truncated prolog comment or processing instruction, is caught
  and converted (`Statifier.Parser.ParseError.from_exception/1`), so "never
  raises" holds for every binary and not merely every *well-formed-ish* one.
  """

  alias Statifier.Parser.DOM
  alias Statifier.Parser.Handler
  alias Statifier.Parser.Markup
  alias Statifier.Parser.ParseError

  @doc """
  Parses `source` into its root element.

  Returns `{:ok, root}` for any well-formed XML, or `{:error, error}` with a
  location at the failing byte offset. Never raises.
  """
  @spec parse(source :: binary()) :: {:ok, DOM.Element.t()} | {:error, ParseError.t()}
  def parse(source) when is_binary(source) do
    markup = Markup.scan(source)

    case run_saxy(source, Handler.init(source, markup)) do
      {:ok, {:error, %ParseError{} = error}} -> {:error, error}
      {:ok, %DOM.Element{} = root} -> {:ok, root}
      {:error, %Saxy.ParseError{} = error} -> {:error, ParseError.from_saxy(error, source)}
      {:crashed, exception} -> {:error, ParseError.from_exception(exception)}
    end
  end

  # `cdata_as_characters: false` keeps CDATA on its own event rather than
  # disguising it as character data. Both are coalesced into one text node
  # either way; the separate event is what lets the handler stay honest about
  # which of the two it saw.
  #
  # The rescue is not a rescue-to-default: it converts, it does not recover.
  # Saxy 1.6.1 raises on a truncated prolog comment or PI instead of
  # returning (see `ParseError.from_exception/1`), and this parser's stated
  # contract is that no binary makes it raise.
  defp run_saxy(source, initial_state) do
    Saxy.parse_string(source, Handler, initial_state, cdata_as_characters: false)
  rescue
    exception -> {:crashed, exception}
  end
end
