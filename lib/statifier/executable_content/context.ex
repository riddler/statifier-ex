defmodule Statifier.ExecutableContent.Context do
  @moduledoc """
  The second argument every `Statifier.ExecutableContent.execute/2` call
  receives, alongside the node itself.

  ## Why a struct and not a bare `MachineState`

  A bare `Statifier.MachineState.t()` cannot carry everything a node needs
  today: `<raise>` stamps its cause with `{:content, c_index, owner}`
  (`Statifier.Event.Cause.origin/0`), and `owner` - which `<onentry>`/
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
  """

  alias Statifier.Machine.Content
  alias Statifier.MachineState

  @enforce_keys [:machine_state, :owner, :datamodel_context]
  defstruct [:machine_state, :owner, :datamodel_context]

  @type t :: %__MODULE__{
          machine_state: MachineState.t(),
          owner: Content.owner(),
          datamodel_context: Predicator.Context.t()
        }
end
