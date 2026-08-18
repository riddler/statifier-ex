defmodule Statifier.Send.Routes do
  @moduledoc """
  A caller-declared, point-in-time claim about which `<send>` routes are
  live (ADR-0048 decision 1) - a plain value in `Statifier.Send.Target`'s
  neutral namespace (ADR-0047 decision 3), carrying exactly what
  `Statifier.Session.deliver/5` resolves today: the set of session ids
  reachable by `{:session, sid}`, whether a parent exists for `:parent`,
  and the set of live invoke ids reachable by `{:invoke, id}`.

  This is a claim, not an observation. It is stamped by the caller once per
  core drive (ADR-0048 decision 2) and carries no obligation to track
  anything between writes - point-in-time is its definition, not its
  failure mode (ADR-0048 decision 2's answer to ADR-0030's ground 2). It is
  deliberately **not** `Statifier.MachineState.active_invocations`: that
  field is the algorithm's own view of which invocations are active per
  Appendix D, while this struct's `invokes` set is the session's live
  table - a different fact that happens to share a shape.

  `:self` and `:internal` routes need no entry in this struct at all -
  they are reachable by construction (ADR-0048 decision 1) - so
  `reachable?/2` answers them without consulting any field.
  """

  alias Statifier.Send.Target

  defstruct sessions: MapSet.new(), parent?: false, invokes: MapSet.new()

  @type t :: %__MODULE__{
          sessions: MapSet.t(String.t()),
          parent?: boolean(),
          invokes: MapSet.t(String.t())
        }

  @doc """
  Builds a snapshot from `opts`: `:sessions` (default empty, a `MapSet` or
  any `Enum` of session ids - `MapSet.new/1` accepts either), `:parent?`
  (default `false`), and `:invokes` (default empty, same shape as
  `:sessions`).
  """
  @spec new(opts :: keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      sessions: opts |> Keyword.get(:sessions, MapSet.new()) |> MapSet.new(),
      parent?: Keyword.get(opts, :parent?, false),
      invokes: opts |> Keyword.get(:invokes, MapSet.new()) |> MapSet.new()
    }
  end

  # `:self` and `:internal` need no entry - reachable by construction
  # (ADR-0048 decision 1). `{:invalid, _}` is never asked: ADR-0047's static
  # arm rejects it first, in the same `execute/2`.
  @doc """
  Whether `route` is reachable per this snapshot. `:self` and `:internal`
  are always reachable; `{:session, sid}`, `:parent`, and `{:invoke, id}`
  are judged against this snapshot's own fields; `{:invalid, _target}` is
  always unreachable - covered here for completeness, though ADR-0047's
  static check in `Statifier.Machine.Content.Send.execute/2` rejects an
  `{:invalid, _}` target before this predicate is ever asked.
  """
  @spec reachable?(routes :: t(), route :: Target.route()) :: boolean()
  def reachable?(_routes, :self), do: true
  def reachable?(_routes, :internal), do: true

  def reachable?(%__MODULE__{sessions: sessions}, {:session, session_id}),
    do: MapSet.member?(sessions, session_id)

  def reachable?(%__MODULE__{parent?: parent?}, :parent), do: parent?

  def reachable?(%__MODULE__{invokes: invokes}, {:invoke, invoke_id}),
    do: MapSet.member?(invokes, invoke_id)

  def reachable?(_routes, {:invalid, _target}), do: false
end
