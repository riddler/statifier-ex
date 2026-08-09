defmodule Statifier.Machine do
  @moduledoc """
  The compiled, valid-by-construction interpreter input
  (`docs/architecture.md:47-51`, principle 4). `Statifier.Compiler.compile/1`
  is the only producer; the interpreter is the only consumer that matters -
  every other layer stops at `%Statifier.Document{}`.

  ## Layout (ADR-0005)

  `states` is a tuple of `Statifier.Machine.State.t()` in document order,
  index 0 being the synthesized `:scxml` root (plan Decision 2: `parent`
  `nil`, `id` `nil`). Every compiled state carries its own `index`, its
  `parent` index (`nil` only at the root), and `last` - the highest index in
  its own subtree, making the range `index..last` self-inclusive and
  contiguous by construction (plan Decision 3). `descendant?/3`, `ancestor?/3`,
  `lcca/2`, `document_order/2`, and `exit_order/2` below are exactly the
  integer/range comparisons ADR-0005 was adopted for - no precomputed cache,
  no ancestor-path table.

  `id_to_index` is partial: an entry only for a state with a non-nil,
  non-empty id (plan Decision 10, mirroring
  `Statifier.Validator.Checks.Ids`'s own uniqueness set). There is no
  `index_to_id` map - `elem(states, i).id` is already that function, total
  with `nil`s, exposed here as `id/2`.

  `transitions` and `contents` are dense tuples indexed by `t_index`/`c_index`
  (ADR-0012 item 3). Phase 4 populates `transitions` (`transition/2` below is
  its `elem/2` reader, mirroring `at/2`); `contents` is still empty and
  Phase 5 populates it without changing this struct's shape.

  ## Expressions

  Every `cond`, every `<log expr=...>`, every `<content expr=...>` or
  `<content>` text body compiles once into `expr()`
  (`docs/architecture.md:76-82`, ADR-0014). Nothing before Phase 3 builds one;
  the type is declared here because it is Machine data, not because anything
  yet produces a `{:compiled, ...}` value.

  ## No top-level `initial`

  Decision 12: the root state at index 0 already carries resolved `initial`
  indexes (Decision 2 exists precisely so the root needs no special case), so
  a second, Machine-level `initial` field would duplicate that fact the way
  Decision 3 rejects for `first`. `initial/1` reads it off index 0.
  """

  alias Statifier.Machine.State
  alias Statifier.Machine.Transition
  alias Statifier.Parser.Location

  @enforce_keys [:states, :id_to_index, :transitions, :contents, :location]
  defstruct [
    :states,
    :id_to_index,
    :transitions,
    :contents,
    :name,
    :datamodel,
    :binding,
    :location
  ]

  @typedoc """
  Every `foo`/`fooexpr` slot in the Machine holds one of these
  (`docs/architecture.md:76-82`). `{:static, term()}` is a literal value with
  no expression to evaluate; `{:compiled, %Predicator.Compiled{}, source}`
  carries the compiled instructions and span table (ADR-0014 items 1-2)
  alongside the original source string for diagnostics.
  """
  @type expr :: {:static, term()} | {:compiled, Predicator.Compiled.t(), source :: String.t()}

  @type t :: %__MODULE__{
          states: tuple(),
          id_to_index: %{optional(String.t()) => non_neg_integer()},
          transitions: tuple(),
          contents: tuple(),
          name: String.t() | nil,
          datamodel: String.t() | nil,
          binding: :early | :late,
          location: Location.t()
        }

  @doc """
  The state at `index`, raised if out of range - every index this module
  hands back came from the Machine itself, so an out-of-range index is
  always a caller bug.
  """
  @spec at(machine :: t(), index :: non_neg_integer()) :: State.t()
  def at(%__MODULE__{states: states}, index), do: elem(states, index)

  @doc """
  The transition at `t_index`, raised if out of range - every `t_index` this
  module hands back (via a state's `transitions`, `initial_transition`, or
  `history_default`) came from the Machine itself, so an out-of-range index
  is always a caller bug (mirrors `at/2`).
  """
  @spec transition(machine :: t(), t_index :: non_neg_integer()) :: Transition.t()
  def transition(%__MODULE__{transitions: transitions}, t_index), do: elem(transitions, t_index)

  @doc """
  Whether `descendant` is `ancestor` or one of `ancestor`'s descendants.

  Self-inclusive: `descendant?(m, i, i)` is always true, since `first` is the
  ancestor's own index by construction (plan Decision 3) - the shape
  Appendix D's entry sets use.
  """
  @spec descendant?(
          machine :: t(),
          descendant :: non_neg_integer(),
          ancestor :: non_neg_integer()
        ) ::
          boolean()
  def descendant?(%__MODULE__{} = machine, descendant, ancestor) do
    %State{last: last} = at(machine, ancestor)
    ancestor <= descendant and descendant <= last
  end

  @doc """
  Whether `ancestor` is `descendant` or one of `descendant`'s ancestors -
  `descendant?/3` with its arguments swapped, spelled for the reader who
  wants "is X an ancestor of Y" rather than "is Y a descendant of X".
  """
  @spec ancestor?(machine :: t(), ancestor :: non_neg_integer(), descendant :: non_neg_integer()) ::
          boolean()
  def ancestor?(%__MODULE__{} = machine, ancestor, descendant) do
    descendant?(machine, descendant, ancestor)
  end

  @doc """
  Whether `index`'s state is atomic - no children. A `:final` is atomic
  (plan Decision 4): `kind` and atomicity are independent facts.
  """
  @spec atomic?(machine :: t(), index :: non_neg_integer()) :: boolean()
  def atomic?(%__MODULE__{} = machine, index) do
    %State{children: children} = at(machine, index)
    children == []
  end

  @doc """
  Whether `index`'s state is compound: a `:state` or `:scxml` with at least
  one child (plan Decision 4 - derived, never stored). A `:parallel` is
  never compound even though it has children: it enters every region
  simultaneously rather than defaulting into one, so it has no positional
  default entry the way a compound `:state` does.
  """
  @spec compound?(machine :: t(), index :: non_neg_integer()) :: boolean()
  def compound?(%__MODULE__{} = machine, index) do
    %State{kind: kind, children: children} = at(machine, index)
    kind in [:state, :scxml] and children != []
  end

  @doc "Whether `index`'s state is a `<parallel>`."
  @spec parallel?(machine :: t(), index :: non_neg_integer()) :: boolean()
  def parallel?(%__MODULE__{} = machine, index), do: at(machine, index).kind == :parallel

  @doc "Whether `index`'s state is a `<final>`."
  @spec final?(machine :: t(), index :: non_neg_integer()) :: boolean()
  def final?(%__MODULE__{} = machine, index), do: at(machine, index).kind == :final

  @doc "Whether `index`'s state is a `<history>` pseudo-state."
  @spec history?(machine :: t(), index :: non_neg_integer()) :: boolean()
  def history?(%__MODULE__{} = machine, index), do: at(machine, index).kind == :history

  @doc """
  `index`'s direct children, in document order - `getChildStates` (Appendix
  D).
  """
  @spec child_indexes(machine :: t(), index :: non_neg_integer()) :: [non_neg_integer()]
  def child_indexes(%__MODULE__{} = machine, index), do: at(machine, index).children

  @doc """
  `index`'s proper ancestors, nearest first, root last - `getProperAncestors`
  (Appendix D) called with no `root` bound, i.e. every ancestor up to and
  including the `:scxml` root. `index` itself is excluded.
  """
  @spec proper_ancestors(machine :: t(), index :: non_neg_integer()) :: [non_neg_integer()]
  def proper_ancestors(%__MODULE__{} = machine, index) do
    case at(machine, index).parent do
      nil -> []
      parent -> [parent | proper_ancestors(machine, parent)]
    end
  end

  @doc """
  The least common compound ancestor of every index in `indexes` -
  `findLCCA` (Appendix D): the nearest proper ancestor of the first index
  that is compound (`compound?/2`) and is an ancestor of every index in the
  list. Walking up from the first index's parent and stopping at the first
  ancestor whose range covers every index is O(depth) with no
  precomputation (ADR-0005) - the `:scxml` root always qualifies, so this is
  total over any non-empty list of indexes belonging to one machine.
  """
  @spec lcca(machine :: t(), indexes :: [non_neg_integer()]) :: non_neg_integer()
  def lcca(%__MODULE__{} = machine, [first | _rest] = indexes) do
    machine
    |> proper_ancestors(first)
    |> Enum.filter(&compound?(machine, &1))
    |> Enum.find(fn candidate ->
      Enum.all?(indexes, &descendant?(machine, &1, candidate))
    end)
  end

  @doc "The index a written state `id` was interned to, or `:error` when unknown."
  @spec index(machine :: t(), id :: String.t()) :: {:ok, non_neg_integer()} | :error
  def index(%__MODULE__{id_to_index: id_to_index}, id), do: Map.fetch(id_to_index, id)

  @doc """
  The id `index`'s state was written with, or `nil` for the root and for
  every nameless state - the total reverse of `index/2` (plan Decision 10,
  ADR-0005's "both directions").
  """
  @spec id(machine :: t(), index :: non_neg_integer()) :: String.t() | nil
  def id(%__MODULE__{} = machine, index), do: at(machine, index).id

  @doc "`indexes` sorted ascending - document order, an integer sort (ADR-0005)."
  @spec document_order(machine :: t(), indexes :: Enumerable.t()) :: [non_neg_integer()]
  def document_order(%__MODULE__{}, indexes), do: Enum.sort(indexes)

  @doc "`indexes` sorted descending - exit order, the exact reverse of document order."
  @spec exit_order(machine :: t(), indexes :: Enumerable.t()) :: [non_neg_integer()]
  def exit_order(%__MODULE__{}, indexes), do: Enum.sort(indexes, :desc)

  @doc """
  The root's resolved `initial` indexes (Decision 12) - there is no
  Machine-level `initial` field; index 0 already carries it.
  """
  @spec initial(machine :: t()) :: [non_neg_integer()]
  def initial(%__MODULE__{} = machine), do: at(machine, 0).initial
end
