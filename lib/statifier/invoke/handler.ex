defmodule Statifier.Invoke.Handler do
  @moduledoc """
  The extension seam `docs/datamodel.md` has always pointed hosts at
  ("real computation belongs in the host application, reached through
  `<invoke>` handlers") but never had until ADR-0051: a behaviour a host
  implements to serve `<invoke type="...">` values beyond the built-in
  `scxml` handler (`Statifier.Invoke.Handler.Scxml`, sitting beside this
  module the way `Statifier.Invoke.Source` does).

  Four things a reader needs before writing one, in order:

  1. **`start/2`, `cancel/2`, and `forward/3` are pure planning callbacks,
     called from `Statifier.Session.Effects.plan/2`'s own fold** - the same
     pure function that decides every other effect's instructions. They run
     with no process, no clock, and no I/O; they return instructions for an
     executor to perform, never perform anything themselves. This is what
     makes the whole contract executable by a durable host that drives
     `Statifier.Interpreter` directly, with no `Statifier.Session` process
     in the loop at all.
  2. **`perform/2` is the impure half, and MAY be called more than once for
     the same `invoke_id`.** An executor (`Statifier.Session` is one; a
     durable host's own executor is another) calls it to actually run one of
     the instructions a planning callback returned. A host that crashes
     between starting an instruction and durably recording that it ran may
     re-run the same drive after recovery, producing the byte-identical
     instruction again - so **a handler implementing `perform/2` MUST be
     idempotent on `invoke_id`**. The library performs no deduplication
     itself and cannot: it has no view of a host's durable store. This is
     the documented contract, not a suggestion.
  3. **`invoke_id` is a deterministic `%MachineState{}` counter** (ADR-0008,
     as amended), not a freshly minted value - which is exactly what makes
     it usable as an idempotency key across a crash and retry: replaying the
     same drive from the same persisted position always produces the same
     `invoke_id` for the same `<invoke>`, so a handler keying its own
     dedup table on it is keying on a value that is stable by construction,
     not by convention.
  4. **A handler must not expect this library to fetch a URI on its
     behalf** (ADR-0024, ADR-0038). `Statifier.Invoke.Source` - the module
     that resolves `<invoke src="...">`/`<content>` into a child
     `Statifier.Machine.t()` - is an implementation detail of the built-in
     `scxml` handler alone, not a general resolution path every handler
     inherits. A handler that needs to reach a URI does so as ordinary
     embedder code, on the same security posture ADR-0024 already applies
     to `<data src>`: a document-named URI dereferenced by the engine by
     default is a request-forgery surface handed to whoever writes the
     document.

  This is the repository's first project-authored `@behaviour` -
  `lib/statifier/evaluator/functions.ex` and `lib/statifier/parser/handler.ex`
  are the only two others, and both implement a *dependency*-owned
  behaviour, so there is no earlier project-authored one to model this
  moduledoc's weight against.

  ## `ctx`

  `ctx` is not a new concept invented for this behaviour - it is exactly the
  plan context `Statifier.Session.Effects.plan/2` already threads through
  its fold, handed to a planning callback unchanged:

      %{
        session_id: session_id,
        invoke_types: invoke_types,
        invoke_handlers: invoke_handlers
      }

  Three properties matter to a handler author:

    - It carries `session_id` (spec 5.10's `_sessionid`) because a handler
      addressing an external system usually needs to say who is asking.
    - It carries **no pid, no `%MachineState{}`, and no session struct** -
      a handler cannot reach into `Statifier.Session` internals through
      `ctx`, by construction rather than by discipline. Per-invocation
      identity (`invoke_id`, `state_index`, `invoke_index`) is read off the
      `%Statifier.Effect.Invoke{}` a planning callback already receives as
      its own argument, not off `ctx`.
    - It is a **plain map**, not a struct, so a key added here later is
      additive for every handler already written - no `%__MODULE__{}`
      pattern match anywhere in a handler module can break on a widened
      shape.

  ## The instruction vocabulary

  A planning callback's returned instructions are elements of
  `Statifier.Session.Effects.t:instruction/0` - the same list
  `Statifier.Session` and `Statifier.Replay` already fold. This behaviour
  adds exactly one opaque member to that vocabulary, `{:handler, module,
  term}`, which an executor routes back to `module.perform/2` - the
  built-in `scxml` handler never returns one, since its own instructions
  (`{:start_child, _, _}`, `{:stop_child, _}`, `{:forward, _, _}`) already
  have dedicated executor clauses in `Statifier.Session`.
  """

  alias Statifier.{Effect, Event}
  alias Statifier.Invoke.Types

  @typedoc "The plan context - see the moduledoc's \"`ctx`\" section."
  @type ctx :: %{
          session_id: String.t(),
          invoke_types: Types.t() | nil,
          invoke_handlers: %{String.t() => module()}
        }

  @typedoc """
  One instruction a planning callback returns - an element of
  `Statifier.Session.Effects.t:instruction/0`, typed opaquely here so this
  behaviour carries no compile-time dependency on that module's concrete
  shape.
  """
  @type instruction :: term()

  @doc """
  Plans the instructions that start `invoke` (spec 6.4's `<invoke>`). Pure:
  no I/O, called from `Statifier.Session.Effects.plan/2`'s own fold. The
  built-in handler returns `{:ok, [{:start_child, invoke, effect}]}`; a
  handler for a different type typically returns `{:ok, [{:handler,
  __MODULE__, payload}]}`, where `payload` is whatever `perform/2` needs to
  actually start the invocation.
  """
  @callback start(invoke :: Effect.Invoke.t(), ctx :: ctx()) ::
              {:ok, [instruction()]} | {:error, term()}

  @doc """
  Plans the instructions that cancel the invocation named `invoke_id` (spec
  6.4.3). Pure, for the same reason `start/2` is.
  """
  @callback cancel(invoke_id :: String.t(), ctx :: ctx()) :: {:ok, [instruction()]}

  @doc """
  Plans the instructions that forward `event` to the invocation named
  `invoke_id` (spec 6.4.2's `autoforward`). Pure, for the same reason
  `start/2` is.
  """
  @callback forward(invoke_id :: String.t(), event :: Event.t(), ctx :: ctx()) ::
              {:ok, [instruction()]}

  @doc """
  Performs one instruction a planning callback returned - the impure half.
  MAY be called more than once for the same `invoke_id` (see the
  moduledoc's point 2); a handler implementing this MUST be idempotent on
  it. Optional: a handler whose planning callbacks never return a
  `{:handler, __MODULE__, _}` instruction (the built-in `scxml` handler,
  for one) needs no implementation.
  """
  @callback perform(instruction :: instruction(), ctx :: ctx()) :: :ok | {:error, term()}

  @optional_callbacks perform: 2
end
