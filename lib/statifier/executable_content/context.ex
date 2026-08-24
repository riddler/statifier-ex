defmodule Statifier.ExecutableContent.Context do
  @moduledoc """
  The second argument every `Statifier.ExecutableContent.execute/2` call
  receives, alongside the node itself.

  ## Why a struct and not a bare `MachineState`

  A bare `Statifier.MachineState.t()` cannot carry everything a node needs
  today: `<raise>` stamps its cause with `{:content, c_index, owner}`
  (`t:Statifier.Event.Cause.origin/0`), and `owner` - which `<onentry>`/
  `<onexit>` block or `<transition>` the node lives in - is a property of the
  *block* the runner is executing, not of `machine_state` or of the node
  struct itself. With a two-argument protocol function there is nowhere else
  to put it, so it rides here instead.

  ## Where the datamodel context goes

  `datamodel_context` carries the `Predicator.Context.t()` every node in a
  block evaluates its `expr` against - `Predicator.Context` is upstream's
  own envelope, not a statifier-side wrapper (the same call ADR-0014 item 2
  made for the compiled struct). It is built once per **block** by
  `Statifier.Interpreter.Content.execute_block/3`, not once for the whole
  macrostep: `_event` is rewritten on every internal-event round and `In/1`
  reads a configuration that moves at every microstep, so a snapshot
  spanning the whole macrostep would already be stale by the time a later
  block in that same macrostep read it. Once per block is the tightest
  interval that stays correct while still holding the "never per
  expression" commitment `docs/datamodel.md` makes.
  The alternative - a third `execute/3` argument - would change every
  implementation's arity the day it landed; a struct field is the versionable
  slot instead, so the arity never has to move again.

  `machine_state` stays a full `Statifier.MachineState.t()` rather than a
  narrower projection of it: `<send>` and `<invoke>`, once implemented, read
  the configuration and the machine itself, and narrowing the type now
  would be a guess about which fields a future node needs.

  ## Non-fatal errors

  `pending_errors` is where a node records a spec-5.9.1-shaped error it has
  already recovered from: "If a conditional expression cannot be evaluated
  as a boolean value ('true' or 'false') or if its evaluation causes an
  error, the SCXML Processor MUST treat the expression as if it evaluated to
  'false' **and** MUST place the error 'error.execution' in the internal
  event queue." A node that hits this treats the expression as `false` and
  keeps running - it does not halt - but the platform still owes an
  `error.execution` for it. Entries are bare `term()` reasons, in the order
  the node produced them; the node never converts them itself
  (`Statifier.ExecutableContent.execute/2` never constructs a
  `Statifier.Event` and never raises, per ADR-0003). `Statifier.Interpreter.Content`
  drains this list and clears it after every node it runs.

  This is *not* the fatal channel: a node with a non-empty `pending_errors`
  still ran to completion and returned `{:ok, context, effects}` (or, for a
  composite node whose own child content failed, the three-element
  `{:error, context, reason}` form) - it is not the same as the node itself
  returning `{:error, reason}`.
  """

  alias Statifier.Machine.Content
  alias Statifier.MachineState

  @enforce_keys [:machine_state, :owner, :datamodel_context]
  defstruct [:machine_state, :owner, :datamodel_context, pending_errors: []]

  @type t :: %__MODULE__{
          machine_state: MachineState.t(),
          owner: Content.owner(),
          datamodel_context: Predicator.Context.t(),
          pending_errors: [term()]
        }
end
