defmodule Statifier.Validator do
  @moduledoc """
  The third arrow of the parser pipeline, and the only gate in front of the
  Machine compiler (`docs/architecture.md` principle 4): a `%Statifier.Document{}`
  in, `{:ok, document, warnings} | {:error, errors, warnings}` out. The
  interpreter only ever accepts a compiled Machine, so there is no
  "validate if not already validated" fallback anywhere downstream - this
  pass is the single place a malformed document is ever caught.

  It also carries a second, non-fatal finding channel (ADR-0033): a check in
  `@warning_checks` reports a `Statifier.Validator.Warning`, a document
  conformance finding the engine has a defined behavior for either way, and
  it never gates compilation the way an `@checks` finding does.

  Five contracts, inherited from `Statifier.Lowering`'s own and stated here
  so a reader does not have to infer them from the code:

  1. **Collect-all, never fail-fast.** Every check runs on every call, over
     the whole document; a document that trips five distinct checks reports
     five errors, not one. This applies to both channels.
  2. **Document-order sort.** The accumulated error list, and separately the
     accumulated warning list, is sorted by `location.start_offset` before
     it is returned, regardless of which check happened to report first.
  3. **Never a partial result.** `validate/2` returns `{:ok, document, warnings}`
     only when the accumulated error list is empty, and `document` is always
     the caller's own input, unchanged - the validator never rewrites what it
     is given (contrast v1's source rewriting at
     `../statifier/lib/statifier/parser/scxml.ex:76-103`).
  4. **`source` must be the document's own binary.** `validate/2` takes the
     exact source `document` was parsed from, guarded by `is_binary/1`.
     Passing a different binary produces wrong `Location.slice/2` results in
     any check that reads it, not a crash - there is no arity-1 convenience
     that could silently disable those checks.
  5. **Both arms carry warnings.** The error arm carries the warning list
     too - dropping warnings whenever an error also fires would make the
     warning channel fail-fast against the error channel, which contract 1
     does not ask for on its own.
  """

  alias Statifier.Document
  alias Statifier.Validator.Checks.Assign
  alias Statifier.Validator.Checks.Boilerplate
  alias Statifier.Validator.Checks.Cancel
  alias Statifier.Validator.Checks.Content
  alias Statifier.Validator.Checks.Data
  alias Statifier.Validator.Checks.DefaultEntry
  alias Statifier.Validator.Checks.Donedata
  alias Statifier.Validator.Checks.Enums
  alias Statifier.Validator.Checks.Final
  alias Statifier.Validator.Checks.FinalParent
  alias Statifier.Validator.Checks.History
  alias Statifier.Validator.Checks.Ids
  alias Statifier.Validator.Checks.If
  alias Statifier.Validator.Checks.InitialElement
  alias Statifier.Validator.Checks.InitialTargets
  alias Statifier.Validator.Checks.Invoke
  alias Statifier.Validator.Checks.Param
  alias Statifier.Validator.Checks.Script
  alias Statifier.Validator.Checks.Send
  alias Statifier.Validator.Checks.Targets
  alias Statifier.Validator.{Context, Error, Warning}

  @checks [
    &Ids.check/2,
    &Targets.check/2,
    &InitialTargets.check/2,
    &InitialElement.check/2,
    &History.check/2,
    &Final.check/2,
    &FinalParent.check/2,
    &DefaultEntry.check/2,
    &Donedata.check/2,
    &Content.check/2,
    &Param.check/2,
    &Boilerplate.check/2,
    &Enums.check/2,
    &Data.check/2,
    &Assign.check/2,
    &If.check/2,
    &Script.check/2,
    &Invoke.check/2,
    &Send.check/2,
    &Cancel.check/2
  ]

  @warning_checks [
    &Invoke.warn/2
  ]

  @doc """
  Runs all twenty `@checks` and the `@warning_checks` against `document`,
  collecting every finding on each channel rather than stopping at the
  first one, and returns `{:ok, document, warnings}` when no error fired or
  `{:error, errors, warnings}` otherwise - both arms carry `warnings` per
  contract 5. Each of `errors` and `warnings` is sorted by
  `location.start_offset` regardless of which check reported it. `document`
  is returned unchanged on success - this pass never rewrites its input.

  `source` must be the exact binary `document` was parsed from; a mismatched
  `source` produces wrong `Location.slice/2` results in any check that reads
  it rather than raising, so callers must not pass a substitute binary.

  `opts` defaults to `[]` and is threaded straight onto
  `Statifier.Validator.Context.build/3`; today's one recognized option is
  `invoke_content_markup: true` (ADR-0042), which `Checks.Boilerplate` reads
  off the context to relax its root-namespace check. See `Statifier.compile/2`
  for what the flag is for and why it exists.
  """
  @spec validate(document :: Document.t(), source :: binary(), opts :: keyword()) ::
          {:ok, Document.t(), [Warning.t()]} | {:error, [Error.t()], [Warning.t()]}
  def validate(%Document{} = document, source, opts \\ [])
      when is_binary(source) and is_list(opts) do
    context = Context.build(document, source, opts)

    errors = run(@checks, document, context)
    warnings = run(@warning_checks, document, context)

    case errors do
      [] -> {:ok, document, warnings}
      errors -> {:error, errors, warnings}
    end
  end

  @spec run(
          checks :: [(Document.t(), Context.t() -> [Error.t()] | [Warning.t()])],
          document :: Document.t(),
          context :: Context.t()
        ) :: [Error.t()] | [Warning.t()]
  defp run(checks, document, context) do
    checks
    |> Enum.flat_map(fn check -> check.(document, context) end)
    |> Enum.sort_by(fn finding -> finding.location.start_offset end)
  end
end
