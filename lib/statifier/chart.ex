defmodule Statifier.Chart do
  @moduledoc """
  The questions a host asks about a *chart* - a compiled
  `Statifier.Machine.t()` - without running it. Two are answered here: its
  versioned binary contract (`to_binary/1`, `from_binary/1`) and its event
  vocabulary (`events/1`), with the check of a declaration against that
  vocabulary (`check_accepts/2`).

  ## The binary contract

  The versioned binary contract for a chart is a `Statifier.Machine.t()`
  reduced to the inputs that reproduce it: its SCXML source, the persisted
  subset of the options it was compiled with, and its
  `Statifier.Machine.Identity.t()`. No compiled term is written - `from_binary/1`
  rebuilds a `Machine.t()` by recompiling the stored source with the stored
  options through `Statifier.compile/2`, the same pipeline any other caller
  runs, rather than by deserializing compiler output directly.

  This is boundary work, not core work (`docs/architecture.md` principle 2),
  and it could not live on `Machine` even if that boundary argument were set
  aside: `from_binary/1` calls `Statifier.compile/2` to rebuild its result,
  and `Statifier.compile/2` itself builds a `Machine.t()` (ADR-0003's
  layering - the thing produced does not call back into its own producer).
  Putting the pair here instead keeps the dependency pointing one direction:
  `Statifier.Chart` depends on `Statifier` and `Statifier.Machine`, never the
  reverse. It also keeps `lib/statifier/machine.ex`'s moduledoc - already
  carrying the full 100% Doctor burden for the compiled struct itself - free
  of a second concern (persisting a chart across a process or storage
  boundary) that has nothing to do with what the struct means once compiled.

  `to_binary/1` refuses to encode a `Machine` carrying no `identity` or no
  `source` (`{:error, :unidentified_chart}`): a `Machine` built without
  either has nothing for a future `from_binary/1` to recompile from or check
  against, so no blob is produced for it at all. `from_binary/1` decodes
  safely, checks the envelope's tag and shape, checks its format version,
  recompiles the stored source under the stored options, and only then
  compares the recompiled `Machine`'s identity against the blob's - in that
  order, for the same reason `Statifier.Position` checks version before
  identity: a future format whose identity representation changed should
  report the version mismatch, not a confusing identity one.

  ## The event vocabulary

  `events/1` answers which event descriptors the chart listens for: every
  descriptor on a transition whose source state can be active, each
  returned as authored, a pattern reported as a pattern and never expanded.
  "Can be active" is a static rule over the chart's structure, stated on
  `events/1`; it over-counts and never under-counts, and it reads no `cond`.
  The function reads only the compiled machine - no source text, no
  `identity` - and runs nothing.

  `check_accepts/2` compares a declaration of the event names a chart
  accepts with that vocabulary, under the descriptor matching transition
  selection uses, and answers the names the chart can never select on
  (`unreachable`) and the descriptors the declaration does not state
  (`undeclared`). It reports and refuses nothing: which list a host refuses a
  publish on, if either, is the host's decision. With no declaration (`nil`)
  the computed vocabulary is the contract, so both lists are empty; asked
  with a one-name declaration, it is the membership answer for a receiver
  that declares nothing.

  Both live here, not in `Statifier.Validator`: `validate/3` judges a
  document against the spec and takes no deployment state, and the
  vocabulary is what a host compares a deployment's claims against before
  any execution starts - the same posture as
  `Statifier.Send.Types.unsupported_sends/2` (ADR-0071, after ADR-0069
  decision 3). They keep this module's layering: they depend on
  `Statifier.Machine` (and `check_accepts/2` on
  `Statifier.Interpreter.NameMatch`), never the reverse.

  ## No I/O

  No function here performs I/O; encoding and decoding a binary in memory,
  recompiling source already held in memory, and walking a compiled machine
  are not effects a caller has to route around (ADR-0003 does not apply
  here, and this module is not listed in `@effect_interpreter_paths`).
  """

  alias Statifier.Interpreter.NameMatch
  alias Statifier.Machine
  alias Statifier.Machine.{Identity, State}

  # `@sobelow_skip` is read out of this file's AST by Sobelow, never at
  # runtime, so the compiler sees an attribute that is set and never used and
  # rejects the build under `--warnings-as-errors`. Registering it as
  # persisted is what makes it a declaration rather than dead code; see its
  # one use site below, and .sobelow-conf for the mechanism (the same one
  # `lib/statifier/position.ex` already uses).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @format_version 1

  @doc """
  The version tag `to_binary/1` writes and `from_binary/1` checks. A bare
  integer, so a future format change is a version bump here rather than an
  inference from the blob's shape.
  """
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Encodes `machine` as a tagged, versioned binary envelope carrying its SCXML
  `source`, its persisted `compile_opts`, and its `Statifier.Machine.Identity.t()`
  - never a compiled term.

  Returns `{:error, :unidentified_chart}` when `machine.identity` or
  `machine.source` is `nil` - a `Machine` built without either (for instance
  one that came straight from `Statifier.Compiler.compile/1` rather than
  `Statifier.compile/2`) has nothing for `from_binary/1` to recompile from or
  check a future load against, so no blob is produced for it at all.

  The payload is `machine.source` and `machine.compile_opts` verbatim, never
  `machine` itself - the whole point of this module is that a chart's binary
  form holds nothing `Statifier.compile/2` cannot reproduce, which is what
  keeps the blob far smaller than `term_to_binary(machine)` for the same
  chart: the compiled states, transitions, and expressions are the
  overwhelming majority of a `Machine`'s bytes.
  """
  @spec to_binary(machine :: Machine.t()) :: {:ok, binary()} | {:error, :unidentified_chart}
  def to_binary(%Machine{identity: nil}), do: {:error, :unidentified_chart}
  def to_binary(%Machine{source: nil}), do: {:error, :unidentified_chart}

  def to_binary(%Machine{identity: identity, source: source, compile_opts: opts}) do
    {:ok, :erlang.term_to_binary({:statifier_chart, @format_version, identity, source, opts})}
  end

  @doc """
  Decodes a `to_binary/1` envelope and recompiles it into a `Machine.t()`.

  Checks run in this order, and the order matters: decode safely, then check
  the envelope's tag and shape, then its format version, then recompile the
  stored source under the stored options through `Statifier.compile/2`, then
  compare the recompiled `Machine`'s identity against the blob's own. Version
  before recompile before identity, because the identity being checked is
  the *recompiled* `Machine`'s - there is no identity to compare until the
  recompile has run, and a version this build cannot read at all should
  report as a version mismatch rather than failing to compile for reasons
  that have nothing to do with the source.

  `{:error, {:compile_failed, errors}}` carries `Statifier.compile/2`'s own
  `[Statifier.error()]` list unchanged - a blob whose source no longer
  compiles under this build (for instance a validator check tightened across
  a library upgrade) is a real, distinct failure and must not be flattened
  into `:not_a_statifier_blob`.

  `{:error, {:identity_mismatch, expected, actual}}`'s `expected` is the
  blob's own stored identity and `actual` is the recompiled `Machine`'s -
  Position's own argument order. Both are compared with
  `Statifier.Machine.Identity.matches?/2`, never `==/2` on the struct
  (ADR-0052 decision 1): a future identity field addition should not
  silently change what "the same chart" means at this call site either.

  Returns `{:error, :not_a_statifier_blob}` for anything that is not this
  module's tagged envelope - a foreign `term_to_binary` blob, garbage bytes,
  or a well-formed envelope whose source is not a binary or whose opts are
  not a keyword list.
  """
  @spec from_binary(blob :: binary()) ::
          {:ok, Machine.t()}
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
          | {:error, {:compile_failed, [Statifier.error()]}}
          | {:error, {:identity_mismatch, expected :: Identity.t(), actual :: Identity.t() | nil}}
  def from_binary(blob) when is_binary(blob) do
    case safe_decode(blob) do
      {:ok, {:statifier_chart, version, identity, source, opts}}
      when is_binary(source) and is_list(opts) ->
        with :ok <- check_version(version),
             {:ok, machine} <- recompile(source, opts) do
          check_identity(identity, machine)
        end

      _other ->
        {:error, :not_a_statifier_blob}
    end
  end

  @doc """
  The chart's event vocabulary: every event descriptor on a transition whose
  source state can be active, computed from the compiled `machine` alone.

  Each descriptor is returned as authored - its dot-split tokens joined back
  with `.`, so `loan.renew` returns `loan.renew` and `loan.` returns
  `loan.`. **A pattern is reported as a pattern, never expanded**: `*` and
  `loan.*` come back as written, and the function never guesses which names
  a pattern stands for. Platform and internal descriptors (`done.state.`,
  `error.`, a name the chart raises itself) are descriptors the chart
  listens for and are included. An eventless transition contributes
  nothing; a chart with no transition carrying an `event` answers `[]`.

  Descriptors appear in `t_index` order (states in document order, each
  state's own transitions before its children's), and within one `event`
  attribute in the order written; a descriptor equal, as a string, to one
  already returned is dropped. A document given inline to `<invoke>` is its
  own chart and is not read.

  **"Can be active" is a static rule over the chart's structure: a state
  some path enters, its ancestors included.** It follows Appendix D's
  `addDescendantStatesToEnter` and `addAncestorStatesToEnter`. The root is
  entered by its default. Entering a state by its default enters it and
  then its `initial` states as targets (a compound state or the root),
  every child that is not a history by its default (a parallel state), or
  its `history_default` transition's targets as targets (a history
  pseudo-state). Entering a state as a target enters it by its default,
  enters each of its proper ancestors, and, for each parallel ancestor,
  enters by its default every child region that holds none of the
  transition's targets. Every transition in an entered state's
  `transitions` enters its targets as targets. A transition's `cond` and
  `event` are not read, so a transition whose condition is never true in
  practice still counts. A state's descriptors join the vocabulary when it
  is entered and is not a history pseudo-state.

  So a transition on an ancestor of an active state is in the vocabulary, a
  descriptor on a state no path enters is not, a history's default target
  counts as entered, and every region of a reachable parallel state is
  reachable. The rule over-counts and never under-counts: a descriptor
  missing from the answer is one the chart can never select on.

  Pure and total over a `%Statifier.Machine{}`; it reads no source text and
  needs no `identity` or `source` on the machine.
  """
  @spec events(machine :: Machine.t()) :: [String.t()]
  def events(%Machine{} = machine) do
    machine
    |> entered_states()
    |> Enum.reject(&(Machine.at(machine, &1).kind == :history))
    |> Enum.flat_map(&Machine.at(machine, &1).transitions)
    |> Enum.sort()
    |> Enum.flat_map(&Machine.transition(machine, &1).events)
    |> Enum.map(&Enum.join(&1, "."))
    |> Enum.uniq()
  end

  @typedoc """
  What `check_accepts/2` answers: the declared names no descriptor in the
  vocabulary matches, and the vocabulary's descriptors that match no declared
  name.
  """
  @type accepts_check :: %{unreachable: [String.t()], undeclared: [String.t()]}

  @doc """
  Compares `declared`, the event names a chart is declared to accept, with
  the chart's event vocabulary (`events/1`).

  A descriptor *matches* a declared name under the descriptor semantics
  transition selection uses: `Statifier.Interpreter.NameMatch.name_match?/2`
  over the descriptor's tokens and the name's `tokenize/1` tokens, on token
  boundaries. A declared `loan.renew` is matched by the descriptor
  `loan.renew`, by `loan.*`, by `loan.`, by `loan` and by `*`, and not by
  `loan.renewal` or `loan.renew.late`. One relation answers both lists:

  - `unreachable` - each declared name that no descriptor in the vocabulary
    matches, in the declaration's order and without duplicates: a name the
    declaration promises and the chart can never select on.
  - `undeclared` - each descriptor in the vocabulary that matches no
    declared name, in `events/1`'s order: a name the chart listens for that
    the declaration does not state.

  A declared entry is a name, not a descriptor: a `*` in it is an ordinary
  token and never a pattern, so a declared `loan.*` is matched by the
  descriptor `loan` but not by `loan.renew`. An empty list is a declaration
  that the chart accepts nothing: `unreachable` is `[]` and `undeclared` is
  the whole vocabulary.

  With `nil` - no declaration - the computed vocabulary is the contract,
  which cannot disagree with itself, so both lists are empty. A host asking
  whether one name `n` is in a chart's computed vocabulary calls
  `check_accepts(machine, [n])` and reads `unreachable`: `[]` means some
  reachable descriptor matches `n`, and `[n]` means none does.

  The function reports and refuses nothing; which list a host refuses a
  publish on, if either, is the host's decision. Pure and total over a
  `%Statifier.Machine{}` and a list of strings or `nil`; like `events/1` it
  reads no source text and needs no `identity` or `source` on the machine.
  """
  @spec check_accepts(machine :: Machine.t(), declared :: [String.t()] | nil) :: accepts_check()
  def check_accepts(%Machine{}, nil), do: %{unreachable: [], undeclared: []}

  def check_accepts(%Machine{} = machine, declared) when is_list(declared) do
    descriptors = Enum.map(events(machine), &{&1, NameMatch.tokenize(&1)})
    names = declared |> Enum.uniq() |> Enum.map(&{&1, NameMatch.tokenize(&1)})
    descriptor_tokens = Enum.map(descriptors, &elem(&1, 1))

    %{
      unreachable:
        for(
          {name, name_tokens} <- names,
          not NameMatch.name_match?(descriptor_tokens, name_tokens),
          do: name
        ),
      undeclared:
        for(
          {descriptor, tokens} <- descriptors,
          not Enum.any?(names, fn {_name, name_tokens} ->
            NameMatch.name_match?([tokens], name_tokens)
          end),
          do: descriptor
        )
    }
  end

  # The least set of state indexes closed under `events/1`'s entry rule, as a
  # worklist: `{:default, index}` enters a state by its default and
  # `{:targets, indexes}` enters one transition's (or one `initial`'s)
  # targets as targets. `defaulted` bounds the default expansions and
  # `entered` bounds the per-state transition walk, so each state's work is
  # queued once and the walk terminates on any chart, cycles included.
  @spec entered_states(machine :: Machine.t()) :: [non_neg_integer()]
  defp entered_states(machine) do
    machine
    |> walk_entry([{:default, 0}], MapSet.new(), MapSet.new())
    |> MapSet.to_list()
  end

  @spec walk_entry(
          machine :: Machine.t(),
          work :: [{:default, non_neg_integer()} | {:targets, [non_neg_integer()]}],
          entered :: MapSet.t(non_neg_integer()),
          defaulted :: MapSet.t(non_neg_integer())
        ) :: MapSet.t(non_neg_integer())
  defp walk_entry(_machine, [], entered, _defaulted), do: entered

  defp walk_entry(machine, [{:default, index} | rest], entered, defaulted) do
    if MapSet.member?(defaulted, index) do
      walk_entry(machine, rest, entered, defaulted)
    else
      {own_work, entered} = mark_entered(machine, index, entered)
      work = default_entry(machine, index) ++ own_work ++ rest
      walk_entry(machine, work, entered, MapSet.put(defaulted, index))
    end
  end

  defp walk_entry(machine, [{:targets, targets} | rest], entered, defaulted) do
    {ancestor_work, entered} =
      targets
      |> Enum.flat_map(&Machine.proper_ancestors(machine, &1))
      |> Enum.uniq()
      |> Enum.flat_map_reduce(entered, fn ancestor, acc ->
        {own_work, acc} = mark_entered(machine, ancestor, acc)
        {own_work ++ untargeted_regions(machine, ancestor, targets), acc}
      end)

    work = Enum.map(targets, &{:default, &1}) ++ ancestor_work ++ rest
    walk_entry(machine, work, entered, defaulted)
  end

  # What entering `index` by its default enters next, by kind: a parallel
  # state's non-history children by their defaults, a history's default
  # transition's targets as targets, and otherwise the compiler-resolved
  # `initial` (the `initial` attribute, the `<initial>` element, or the first
  # child) as targets - `[]` on an atomic state.
  @spec default_entry(machine :: Machine.t(), index :: non_neg_integer()) ::
          [{:default, non_neg_integer()} | {:targets, [non_neg_integer()]}]
  defp default_entry(machine, index) do
    case Machine.at(machine, index) do
      %State{kind: :parallel} ->
        Enum.map(Machine.child_states(machine, index), &{:default, &1})

      %State{kind: :history, history_default: nil} ->
        []

      %State{kind: :history, history_default: t_index} ->
        [{:targets, Machine.transition(machine, t_index).targets}]

      %State{initial: []} ->
        []

      %State{initial: initial} ->
        [{:targets, initial}]
    end
  end

  # A parallel ancestor's child regions that hold none of `targets`, each to
  # be entered by its default; `[]` for any other ancestor.
  @spec untargeted_regions(
          machine :: Machine.t(),
          ancestor :: non_neg_integer(),
          targets :: [non_neg_integer()]
        ) :: [{:default, non_neg_integer()}]
  defp untargeted_regions(machine, ancestor, targets) do
    if Machine.parallel?(machine, ancestor) do
      for region <- Machine.child_states(machine, ancestor),
          not Enum.any?(targets, &(&1 == region or Machine.descendant?(machine, &1, region))),
          do: {:default, region}
    else
      []
    end
  end

  # Marks `index` entered. The first time only, returns the work its own
  # transitions add: each targeted transition's targets, as targets.
  @spec mark_entered(
          machine :: Machine.t(),
          index :: non_neg_integer(),
          entered :: MapSet.t(non_neg_integer())
        ) :: {[{:targets, [non_neg_integer()]}], MapSet.t(non_neg_integer())}
  defp mark_entered(machine, index, entered) do
    if MapSet.member?(entered, index) do
      {[], entered}
    else
      work =
        for t_index <- Machine.at(machine, index).transitions,
            targets = Machine.transition(machine, t_index).targets,
            targets != [],
            do: {:targets, targets}

      {work, MapSet.put(entered, index)}
    end
  end

  @spec check_version(version :: term()) :: :ok | {:error, {:unsupported_format_version, term()}}
  defp check_version(@format_version), do: :ok
  defp check_version(version), do: {:error, {:unsupported_format_version, version}}

  @spec recompile(source :: binary(), opts :: keyword()) ::
          {:ok, Machine.t()} | {:error, {:compile_failed, [Statifier.error()]}}
  defp recompile(source, opts) do
    case Statifier.compile(source, opts) do
      {:ok, machine} -> {:ok, machine}
      {:error, errors} -> {:error, {:compile_failed, errors}}
    end
  end

  @spec check_identity(blob_identity :: Identity.t(), machine :: Machine.t()) ::
          {:ok, Machine.t()}
          | {:error, {:identity_mismatch, Identity.t(), Identity.t() | nil}}
  defp check_identity(blob_identity, %Machine{identity: machine_identity} = machine) do
    if Identity.matches?(blob_identity, machine_identity) do
      {:ok, machine}
    else
      {:error, {:identity_mismatch, blob_identity, machine_identity}}
    end
  end

  # Same rationale as `Statifier.Position`'s own `safe_decode/1` (see that
  # module and `Statifier.Machine.Identity` for the full ADR-0052 argument):
  # `:safe` refuses to create atoms a blob names, so a hostile or corrupt
  # blob cannot grow the atom table, and `:erlang.binary_to_term/2` raises
  # `ArgumentError` on a blob it cannot decode at all, which collapses to
  # `:error` here rather than escaping as an exception.
  #
  # Sobelow's Misc.BinToTerm fires on every `binary_to_term` call site,
  # `:safe` or not, because `:safe` still decodes a fun term. Nothing here
  # ever calls what it decodes: the result is matched against one literal
  # five-tuple shape and used only as data, and anything else becomes
  # `:not_a_statifier_blob`. The skip is per-function and named, so the rest
  # of this module stays scanned - see .sobelow-conf for why the file is not
  # excluded by path instead.
  @sobelow_skip ["Misc.BinToTerm"]
  defp safe_decode(blob) do
    {:ok, :erlang.binary_to_term(blob, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
