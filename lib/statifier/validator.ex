defmodule Statifier.Validator do
  @moduledoc """
  The third arrow of the parser pipeline, and the only gate in front of the
  Machine compiler (`docs/architecture.md` principle 4): a `%Statifier.Document{}`
  in, `{:ok, document} | {:error, [Statifier.Validator.Error.t()]}` out. The
  interpreter only ever accepts a compiled Machine, so there is no
  "validate if not already validated" fallback anywhere downstream - this
  pass is the single place a malformed document is ever caught.

  Four contracts, inherited from `Statifier.Lowering`'s own and stated here
  so a reader does not have to infer them from the code:

  1. **Collect-all, never fail-fast.** Every check runs on every call, over
     the whole document; a document that trips five distinct checks reports
     five errors, not one.
  2. **Document-order sort.** The accumulated error list is sorted by
     `location.start_offset` before it is returned, regardless of which
     check happened to report first.
  3. **Never a partial result.** `validate/2` returns `{:ok, document}` only
     when the accumulated error list is empty, and `document` is always the
     caller's own input, unchanged - the validator never rewrites what it is
     given (contrast v1's source rewriting at
     `../statifier/lib/statifier/parser/scxml.ex:76-103`).
  4. **`source` must be the document's own binary.** `validate/2` takes the
     exact source `document` was parsed from, guarded by `is_binary/1`.
     Passing a different binary produces wrong `Location.slice/2` results in
     any check that reads it, not a crash - there is no arity-1 convenience
     that could silently disable those checks
     (`docs/plans/260808-st-l5k.5-document-validator.md` Decision 1).
  """

  alias Statifier.Document
  alias Statifier.Validator.Checks.Boilerplate
  alias Statifier.Validator.Checks.DefaultEntry
  alias Statifier.Validator.Checks.Donedata
  alias Statifier.Validator.Checks.Enums
  alias Statifier.Validator.Checks.Final
  alias Statifier.Validator.Checks.History
  alias Statifier.Validator.Checks.Ids
  alias Statifier.Validator.Checks.InitialElement
  alias Statifier.Validator.Checks.InitialTargets
  alias Statifier.Validator.Checks.Targets
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @checks [
    &Ids.check/2,
    &Targets.check/2,
    &InitialTargets.check/2,
    &InitialElement.check/2,
    &History.check/2,
    &Final.check/2,
    &DefaultEntry.check/2,
    &Donedata.check/2,
    &Boilerplate.check/2,
    &Enums.check/2
  ]

  @spec validate(document :: Document.t(), source :: binary()) ::
          {:ok, Document.t()} | {:error, [Error.t()]}
  def validate(%Document{} = document, source) when is_binary(source) do
    context = Context.build(document, source)

    errors =
      @checks
      |> Enum.flat_map(fn check -> check.(document, context) end)
      |> Enum.sort_by(fn error -> error.location.start_offset end)

    case errors do
      [] -> {:ok, document}
      errors -> {:error, errors}
    end
  end
end
