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

  ## Where st-af3's datamodel context goes

  `docs/datamodel.md:41` commits to building the predicator evaluation
  context once per macrostep, not once per expression. That memoized context
  is neither `machine_state` (it is derived from the datamodel, and rebuilt
  only when the datamodel changes) nor node-local - it is exactly
  macrostep-scoped state that every node evaluating an `expr` needs to read.
  st-af3 adds it as a new field on this struct, which changes no protocol
  signature and no existing implementation that does not read the new field.
  The alternative - a third `execute/3` argument - would change every
  implementation's arity the day it landed; a struct field is the versionable
  slot instead, so the arity never has to move again.

  `machine_state` stays a full `Statifier.MachineState.t()` rather than a
  narrower projection of it: `<send>` and `<invoke>` (st-cmq) read the
  configuration and the machine itself, and narrowing the type now would be a
  guess about which fields a future node needs.
  """

  alias Statifier.Machine.Content
  alias Statifier.MachineState

  @enforce_keys [:machine_state, :owner]
  defstruct [:machine_state, :owner]

  @type t :: %__MODULE__{
          machine_state: MachineState.t(),
          owner: Content.owner()
        }
end
