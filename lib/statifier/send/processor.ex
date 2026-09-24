defmodule Statifier.Send.Processor do
  @moduledoc """
  The behaviour a host implements for an Event I/O Processor type it
  registers with `Statifier.Session.start_link/2`'s `:send_types` option
  (ADR-0069). A `<send>` whose type is registered is handed to the module
  registered for it, with the event already built
  (`Statifier.Send.Event.build/3`), and the library delivers nothing for it
  itself.

  The split is `Statifier.Invoke.Handler`'s (ADR-0051 decision 4):

  1. **`deliver/3` and `cancel/2` are pure planning callbacks**, called from
     `Statifier.Session.Effects.plan/2`'s fold with no process, no clock and
     no I/O. They return instructions for an executor to perform and perform
     nothing themselves. A processor's usual instruction is
     `{:handler, __MODULE__, payload}`, which the executor routes back to
     `perform/2`.
  2. **`perform/2` is the impure half, and MAY be called more than once for
     the same send.** After a crash and a retry a host may perform the same
     effect again, so a processor MUST be idempotent on the ADR-0054
     decision 3 dedup key's components read off the effect: the send id,
     the step counters, `c_index`, `owner`, and `ordinal` (every
     registered-type send carries one - ADR-0059 decision 5 as amended),
     with the session scope the host supplies.

  ## What `deliver/3` is handed

  The `%Statifier.Effect.Send{}` or `%Statifier.Effect.SendDelayed{}` the
  core produced, and the event built from it with the default `origin` and
  `origintype`. `target` is the processor's own opaque route string: the
  library never parses it. A processor that wants a reply to reach its own
  address rather than the sender's session builds the event again with
  `:origin` and `:origintype`.

  **A delayed send is the processor's timer.** For a
  `%Statifier.Effect.SendDelayed{}` the session schedules nothing: the
  processor owns the delay, and spec 6.2's discard at termination is its
  fire-time check (ADR-0054 decision 4).

  ## What `cancel/2` is handed

  A `<cancel>` whose send id names a delayed send this processor was handed
  reaches `cancel/2` with the `%Statifier.Effect.Cancel{}` itself, whose
  `send_id` and the host's session scope are ADR-0054 decision 3's
  cancellation key. The session keeps which processor holds each such send
  id, so a cancel reaches only the processors that were handed a delayed
  send under that id. A processor MUST tolerate a cancel for a send it has
  already fired.

  Those holds are the live session's own state. They are not part of the
  persisted position (`Statifier.Position`), so a session resumed from a
  position holds nothing: a `<cancel>` it runs for a delayed send handed
  over before the position was saved reaches no processor. Routing that
  cancel is the host's job, as re-arming timers after a resume is
  (ADR-0060 decision 7): the resumed session still emits the
  `%Statifier.Effect.Cancel{}`, and the host matches it under ADR-0054
  decision 3's cancellation key against the send id it recorded when its
  processor was handed the delayed send.

  A hold is released only when a `<cancel>` naming its send id is routed;
  the library never learns that a processor's timer fired. A live session
  therefore keeps one entry per distinct send id handed to a processor and
  not cancelled since: an author-written id reused by later sends stays one
  entry, and a generated id adds one per uncancelled send. The entries go
  with the session process when it stops.

  ## When the host cannot deliver

  A processor that cannot deliver a send while its sender still exists
  reports the miss through `Statifier.Session.failed_send/3`, called by the
  host, never by `deliver/3` or `cancel/2`: the sender then sees C.1's
  `error.communication`, carrying the send id, on its internal queue. When
  the sender has reached a final state or no longer exists there is no
  queue to write, and the host records the miss as a dead letter keyed by
  the send's dedup key, with its reason. `failed_send/3`'s own
  documentation states both rules.

  ## The `_ioprocessors` entry

  Spec 5.10 binds `_ioprocessors` to one entry for each Event I/O Processor
  a session supports, and a registered type is one. The session's
  `_ioprocessors` carries an entry keyed by each registered type string,
  whose value is the map the optional
  `c:Statifier.Send.Processor.ioprocessors_entry/1` callback returns for that
  type, or an empty map when the processor does not implement it.
  `Statifier.Send.Types.from_send_types/1` reads the value and
  `Statifier.MachineState.new/2` writes it, once, when the session starts;
  `Statifier.Send.Types.from_send_types/1` says how it reads after a resume.

  ## `ctx`

  The plan context `Statifier.Session.Effects.plan/2` threads through its
  fold, handed over unchanged: a plain map carrying `session_id` (spec
  5.10's `_sessionid`) and no pid, no `%MachineState{}` and no session
  struct, so a processor cannot reach into the session through it. A key
  added to it later is additive for every processor already written.
  """

  alias Statifier.{Effect, Event}

  @typedoc "The plan context - see the moduledoc's \"`ctx`\" section."
  @type ctx :: %{required(:session_id) => String.t(), optional(atom()) => term()}

  @typedoc """
  One instruction a planning callback returns - an element of
  `t:Statifier.Session.Effects.instruction/0`, typed opaquely here as
  `t:Statifier.Invoke.Handler.instruction/0` is.
  """
  @type instruction :: term()

  @doc """
  Plans the hand-off of one registered-type send. Pure. `effect` is the
  send the core produced and `event` the event built from it. For a delayed
  send the processor owns the delay.
  """
  @callback deliver(
              effect :: Effect.Send.t() | Effect.SendDelayed.t(),
              event :: Event.t(),
              ctx :: ctx()
            ) :: {:ok, [instruction()]}

  @doc """
  Plans the cancellation of the delayed sends this processor was handed
  under `cancel.send_id` (spec 6.3's cancel-them-all). Pure.
  """
  @callback cancel(cancel :: Effect.Cancel.t(), ctx :: ctx()) :: {:ok, [instruction()]}

  @doc """
  Performs one `{:handler, module, payload}` instruction a planning callback
  returned - the impure half. MAY be called more than once for the same
  send (see the moduledoc's point 2). Optional: a processor whose planning
  callbacks return no such instruction needs none.
  """
  @callback perform(payload :: term(), ctx :: ctx()) :: :ok | {:error, term()}

  @doc """
  The value of this processor's `_ioprocessors` entry (spec 5.10) for the
  registered type string `type` - for example a `"location"` a receiver
  can address this processor by. Pure and deterministic: the library calls
  it whenever it builds a registered set, which a replay and a resume do
  again. The map must be string-keyed at every level, as every datamodel
  value is. Optional: a processor that does not implement it gets an empty
  map.
  """
  @callback ioprocessors_entry(type :: String.t()) :: map()

  @optional_callbacks perform: 2, ioprocessors_entry: 1
end
