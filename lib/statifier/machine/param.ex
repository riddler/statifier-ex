defmodule Statifier.Machine.Param do
  @moduledoc """
  One compiled `<param>` element - the interned counterpart to
  `Statifier.Document.Param`. A `%Param{}` is not reachable only through
  `Statifier.Machine.Donedata.params`: `Statifier.Machine.Content.Send` and
  `Statifier.Machine.Invoke` each own a `namelist` and a `params` list of
  `Param.t()` too.

  `kind` records which of `expr`/`location` the author wrote (`:expr` or
  `:location`) - `Statifier.Validator.Checks.Param` already guarantees
  exactly one is present, so this field is never ambiguous. Both kinds are
  read through `expr`/`expr_location` today: a `<param location>` compiles
  its path string the same way a `<param expr>` compiles its expression
  (Decision 4), which is only sound because a bound datamodel location is
  itself a legal value-producing expression in this engine's predicator
  value space. `kind` is kept anyway so a later read-only location-resolve
  switch (the epic's own Phase 4 mentioned in the plan) is a one-site change
  in the interpreter fold, not a lowering, `Document`, or validator change.

  `expr` and `expr_location` follow `Statifier.Machine.Donedata`'s own
  naming for the same shape: `expr` is the compiled `Machine.expr()`,
  `expr_location` is the diagnostic span for it (`attribute_locations[:expr]`
  or `attribute_locations[:location]`, whichever attribute was written).

  `location` is `<param>`'s own element span, mirroring
  `Statifier.Document.Param`'s inverted-from-`Assign` convention (see that
  module's moduledoc) - it is not a compiled path, just the node's position
  in the source document.

  No `c_index`: like `Statifier.Machine.Donedata.expr`, a `<param>` is not
  executable content, never appears in a block, and no `execute_block` ever
  runs it.
  """

  alias Statifier.Compiler.Error, as: CompilerError
  alias Statifier.Machine
  alias Statifier.Parser.Location

  @enforce_keys [:name, :kind, :location]
  defstruct [:name, :kind, :expr, :expr_location, :location]

  @type kind :: :expr | :location

  @typedoc """
  The compiled location/expression, or `{:invalid, error}` when a `namelist`
  entry failed to compile. Only a `namelist` entry ever carries the deferral
  arm: a `<param>` element's `expr`/`location` still fails
  `Statifier.Compiler.compile/1` (see `docs/datamodel.md`'s per-element-class
  policy). Spec 5.9.4 permits either timing; deferral is what lets a document
  with an ill-formed `namelist` load at all, so 6.2.2's discard MUST and 6.4's
  terminate MUST (ADR-0036, ADR-0031) get to run.
  """
  @type expr :: Machine.expr() | {:invalid, CompilerError.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          expr: expr(),
          expr_location: Location.t(),
          location: Location.t()
        }
end
