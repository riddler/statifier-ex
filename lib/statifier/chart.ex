defmodule Statifier.Chart do
  @moduledoc """
  The questions a host asks about a *chart* - a compiled
  `Statifier.Machine.t()` - without running it. Three are answered here: its
  versioned binary contract (`to_binary/1`, `from_binary/1`), its event
  vocabulary (`events/1`), with the check of a declaration against that
  vocabulary (`check_accepts/2`), and what changed between two charts
  (`diff/3`).

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

  ## The diff

  `diff/3` classifies a pair of compiled charts as identical, compatible,
  mapped or breaking, and names the reasons (ADR-0072). It is structural:
  it says what the two charts are, never what an execution will do, and it
  moves nothing. A rename the engine cannot see is supplied by the caller as
  a plain `mapping:` from old state ids to new ones. It shares `events/1`'s
  "can be active" rule, which stays private to this module (ADR-0072
  decision 5).

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

  @typedoc """
  One of the four classes `diff/3` answers (ADR-0072 decision 1).
  """
  @type diff_class :: :identical | :compatible | :mapped | :breaking

  @typedoc """
  One reason `diff/3` reports. The ones marked breaking in `diff/3`'s doc
  make a pair `:breaking`; the rest report without changing the class.
  """
  @type diff_reason ::
          {:state_nameless, non_neg_integer()}
          | {:state_unresolved, String.t()}
          | {:state_changed, String.t(), [:kind | :parent | :atomic | :regions | :history_type]}
          | {:state_mapped, String.t(), String.t()}
          | {:state_removed, String.t()}
          | {:state_added, String.t()}
          | {:transition_removed, String.t(), non_neg_integer()}
          | {:transition_added, String.t(), non_neg_integer()}
          | {:event_removed, String.t()}
          | {:event_added, String.t()}
          | {:data_removed, String.t()}
          | {:data_added, String.t()}
          | {:mapping_unused, String.t()}

  @typedoc """
  What `diff/3` answers: the pair's class and its reasons, in `diff/3`'s
  order.
  """
  @type diff :: %{class: diff_class(), reasons: [diff_reason()]}

  @doc """
  Classifies two compiled charts, `from` (the chart an execution is pinned
  to) and `to` (a candidate), into one of four classes and returns the
  reasons (ADR-0072 decision 1). `diff/2` is the head with `opts` defaulted
  to `[]`.

  - `:identical` - `Statifier.Machine.Identity.matches?/2` holds for the two
    identities, `name` and `version` included (ADR-0052 decision 1).
    Nothing structural is compared and `reasons` is `[]`. A machine with no
    identity is never identical to anything.
  - `:compatible` - the structural comparison found no breaking reason and
    no mapped state. Additions are allowed and reported.
  - `:mapped` - no breaking reason, and at least one state of `from` absent
    from `to` is resolved by `opts[:mapping]`.
  - `:breaking` - at least one breaking reason.

  ## The structural comparison

  Two states *correspond* when they carry the same id, or when the mapping
  resolves a `from` state to a `to` state; the roots always correspond. A
  state of `from` is *held* when it can be active under the rule `events/1`
  states, or it is a history pseudo-state whose parent can be active. The
  reasons:

  - `{:state_nameless, index}` (breaking) - a held state of `from`, not the
    root, with no id. A nameless state that is not held is ignored, and a
    nameless state of `to` is never reported.
  - `{:state_unresolved, id}` (breaking) - a held state of `from` with no
    corresponding state in `to`.
  - `{:state_changed, id, fields}` (breaking) - a held state of `from` whose
    corresponding state differs in any of `fields`, in this order: `:kind`;
    `:parent` (the parent's corresponding id); `:atomic`; `:regions` (both
    parallel, and the corresponding ids of their child states differ);
    `:history_type`.
  - `{:state_mapped, from_id, to_id}` - a state of `from`, held or not,
    resolved by the mapping and not reported as changed.
  - `{:state_removed, id}` - a state of `from` that is not held and has no
    corresponding state in `to`.
  - `{:state_added, id}` - a state of `to` with an id that corresponds to no
    state of `from`.
  - `{:transition_removed, source_id, t_index}` (breaking) - a selectable
    transition of a held state of `from` that matches no transition of the
    corresponding state. A transition of an unresolved or nameless state is
    covered by the state's own reason.
  - `{:transition_added, source_id, t_index}` - a selectable transition of a
    state of `to` that corresponds to a state of `from` and matches no
    transition of that state. A transition of an added state is covered by
    the state's own reason.
  - `{:event_removed, descriptor}` (breaking) and `{:event_added,
    descriptor}` - a descriptor in one side's `events/1` and not in the
    other's, compared as strings. A pattern replaced by a wider one still
    reports the removal: nothing reasons about which names a pattern stands
    for.
  - `{:data_removed, id}` (breaking) and `{:data_added, id}` - a `<data>`
    id declared anywhere in one chart and nowhere in the other. A `<data>`
    element's value is not compared.
  - `{:mapping_unused, from_id}` - a mapping entry the comparison did not
    read.

  **The equality per element is never struct equality and never a source
  slice.** A state compares by its id through correspondence, `kind`, its
  parent's corresponding id, whether it is atomic, its child states'
  corresponding ids when parallel, and `history_type`; its executable
  content, `initial`, `donedata` and `invoke` list are not compared. A
  transition matches another when its source's corresponding id, its
  `events` joined as `events/1` joins them, its targets' corresponding ids
  in the order written, its `type`, and its `cond` as authored (a static
  value, or a compiled expression's source text) are all equal; its
  content, `t_index` and locations are not compared, and a state's
  transitions match as a multiset, so a reordering is not reported. A
  datamodel key compares as the `<data>` element's `id`.

  **Order.** The `from`-side state reasons in `from`'s document order, one
  per state at most; then `:state_added` in `to`'s document order; then
  `:transition_removed` in `from`'s `t_index` order; then
  `:transition_added` in `to`'s `t_index` order; then `:event_removed` and
  `:event_added` in each side's `events/1` order; then `:data_removed` and
  `:data_added` in each side's `d_index` order; then `:mapping_unused`,
  sorted by id.

  ## The mapping (ADR-0072 decision 2)

  `opts[:mapping]` is a plain map from a `from` state id to a `to` state id.
  An entry is read only when its key is the id of a state of `from` that is
  absent from `to` and its value is the id of a state of `to`; that state
  then corresponds to the one the value names. Every other entry is
  reported as `:mapping_unused` and changes no class. A mapped pair is
  still compared, so a mapping onto a state of another kind or under
  another parent is `:state_changed` and breaking.

  Raises `ArgumentError` when `opts` holds anything but `mapping:`, when the
  mapping is not a map from strings to strings, or when it would make one
  state of `to` correspond to two states of `from`: two read entries naming
  the same value, or a read entry whose value is also the id of a state of
  `from`. Each is a caller's programming error, not data.

  ## What the classes do not say (ADR-0072 decision 3)

  The classes are structural: they say what the charts are, never what an
  execution will do. A compatible pair can still behave differently (a
  transition's content, an `<onentry>`, a condition's meaning, the document
  order between two enabled transitions), and a breaking pair can be
  harmless to every execution a host holds, since "held" over-approximates.
  Nothing here moves an execution.

  Pure over two `%Statifier.Machine{}`s: it reads no source text, needs no
  `source` on either machine, and runs nothing.
  """
  @spec diff(from :: Machine.t(), to :: Machine.t(), opts :: keyword()) :: diff()
  def diff(%Machine{} = from, %Machine{} = to, opts \\ []) do
    mapping = diff_mapping!(opts)

    if Identity.matches?(Machine.identity(from), Machine.identity(to)) do
      %{class: :identical, reasons: []}
    else
      reasons = compare(from, to, mapping)
      %{class: classify(reasons), reasons: reasons}
    end
  end

  @spec diff_mapping!(opts :: term()) :: %{optional(String.t()) => String.t()}
  defp diff_mapping!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "diff/3's opts must be a keyword list, got: #{inspect(opts)}"
    end

    case Keyword.split(opts, [:mapping]) do
      {_taken, [_first | _rest] = unknown} ->
        raise ArgumentError, "diff/3 accepts only :mapping, got: #{inspect(unknown)}"

      {taken, []} ->
        mapping = Keyword.get(taken, :mapping, %{})

        unless string_map?(mapping) do
          raise ArgumentError,
                "diff/3's :mapping must be a map from state ids to state ids, got: " <>
                  inspect(mapping)
        end

        mapping
    end
  end

  @spec string_map?(mapping :: term()) :: boolean()
  defp string_map?(mapping) when is_map(mapping) and not is_struct(mapping) do
    Enum.all?(mapping, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp string_map?(_mapping), do: false

  @spec classify(reasons :: [diff_reason()]) :: diff_class()
  defp classify(reasons) do
    cond do
      Enum.any?(reasons, &breaking?/1) -> :breaking
      Enum.any?(reasons, &match?({:state_mapped, _from_id, _to_id}, &1)) -> :mapped
      true -> :compatible
    end
  end

  @spec breaking?(reason :: diff_reason()) :: boolean()
  defp breaking?({tag, _subject}) when tag in [:state_nameless, :state_unresolved], do: true
  defp breaking?({tag, _subject}) when tag in [:event_removed, :data_removed], do: true
  defp breaking?({:state_changed, _id, _fields}), do: true
  defp breaking?({:transition_removed, _source_id, _t_index}), do: true
  defp breaking?(_reason), do: false

  # The structural comparison: every reason but the identity check, in the
  # record's order.
  @spec compare(from :: Machine.t(), to :: Machine.t(), mapping :: map()) :: [diff_reason()]
  defp compare(from, to, mapping) do
    {read, unused} = read_mapping(from, to, mapping)
    corr = correspondence(from, to, read)
    held = held_states(from)
    to_corresponded = corr |> Map.values() |> MapSet.new()

    Enum.concat([
      state_reasons(from, to, corr, held, read),
      for(
        index <- state_indexes(to),
        id = Machine.id(to, index),
        id != nil,
        not MapSet.member?(to_corresponded, index),
        do: {:state_added, id}
      ),
      transition_reasons(from, to, corr, held),
      list_delta(events(from), events(to), :event_removed, :event_added),
      list_delta(data_ids(from), data_ids(to), :data_removed, :data_added),
      Enum.map(Enum.sort(unused), &{:mapping_unused, &1})
    ])
  end

  # Splits the mapping into the entries the comparison reads (a key that is
  # a `from` state id absent from `to`, a value that is a `to` state id) and
  # the keys of every other entry, refusing an entry set that would make one
  # `to` state correspond to two `from` states.
  @spec read_mapping(from :: Machine.t(), to :: Machine.t(), mapping :: map()) ::
          {%{optional(String.t()) => String.t()}, [String.t()]}
  defp read_mapping(from, to, mapping) do
    {read, unused} =
      Enum.split_with(mapping, fn {key, value} ->
        Map.has_key?(from.id_to_index, key) and not Map.has_key?(to.id_to_index, key) and
          Map.has_key?(to.id_to_index, value)
      end)

    values = Enum.map(read, &elem(&1, 1))

    case {values -- Enum.uniq(values), Enum.filter(values, &Map.has_key?(from.id_to_index, &1))} do
      {[], []} ->
        {Map.new(read), Enum.map(unused, &elem(&1, 0))}

      {[twice | _more], _shared} ->
        raise ArgumentError,
              "diff/3's :mapping maps two states onto #{inspect(twice)}, which one state of " <>
                "the new chart cannot correspond to"

      {[], [shared | _more]} ->
        raise ArgumentError,
              "diff/3's :mapping maps a state onto #{inspect(shared)}, which the old chart " <>
                "also declares, so one state of the new chart would correspond to two"
    end
  end

  # `from` state index -> corresponding `to` state index, for every `from`
  # state that has one: the root, a shared id, or a read mapping entry.
  @spec correspondence(from :: Machine.t(), to :: Machine.t(), read :: map()) ::
          %{optional(non_neg_integer()) => non_neg_integer()}
  defp correspondence(from, to, read) do
    for {id, index} <- from.id_to_index,
        to_id = if(Map.has_key?(to.id_to_index, id), do: id, else: Map.get(read, id)),
        to_id != nil,
        into: %{0 => 0},
        do: {index, Map.fetch!(to.id_to_index, to_id)}
  end

  # A state an execution can hold: one `events/1`'s rule can enter, or a
  # history pseudo-state whose parent it can enter.
  @spec held_states(machine :: Machine.t()) :: MapSet.t(non_neg_integer())
  defp held_states(machine) do
    entered = machine |> entered_states() |> MapSet.new()

    machine
    |> state_indexes()
    |> Enum.filter(fn index ->
      case Machine.at(machine, index) do
        %State{kind: :history, parent: parent} -> MapSet.member?(entered, parent)
        %State{} -> MapSet.member?(entered, index)
      end
    end)
    |> MapSet.new()
  end

  @spec state_reasons(
          from :: Machine.t(),
          to :: Machine.t(),
          corr :: map(),
          held :: MapSet.t(non_neg_integer()),
          read :: map()
        ) :: [diff_reason()]
  defp state_reasons(from, to, corr, held, read) do
    Enum.flat_map(state_indexes(from), fn index ->
      id = Machine.id(from, index)

      from_state_reason(
        id,
        index,
        MapSet.member?(held, index),
        Map.fetch(corr, index),
        Map.fetch(read, id),
        {from, to, corr}
      )
    end)
  end

  # The one reason, at most, a `from` state takes. The root always
  # corresponds to the root and takes none.
  @spec from_state_reason(
          id :: String.t() | nil,
          index :: non_neg_integer(),
          held? :: boolean(),
          corresponding :: {:ok, non_neg_integer()} | :error,
          mapped_to :: {:ok, String.t()} | :error,
          charts :: {Machine.t(), Machine.t(), map()}
        ) :: [diff_reason()]
  defp from_state_reason(_id, 0, _held?, _corresponding, _mapped_to, _charts), do: []

  defp from_state_reason(nil, index, true, _corresponding, _mapped_to, _charts),
    do: [{:state_nameless, index}]

  defp from_state_reason(nil, _index, false, _corresponding, _mapped_to, _charts), do: []

  defp from_state_reason(id, _index, true, :error, _mapped_to, _charts),
    do: [{:state_unresolved, id}]

  defp from_state_reason(id, _index, false, :error, _mapped_to, _charts),
    do: [{:state_removed, id}]

  defp from_state_reason(id, index, held?, {:ok, to_index}, mapped_to, charts) do
    fields = if held?, do: changed_fields(index, to_index, charts), else: []

    cond do
      fields != [] -> [{:state_changed, id, fields}]
      match?({:ok, _to_id}, mapped_to) -> [{:state_mapped, id, elem(mapped_to, 1)}]
      true -> []
    end
  end

  # The normalized fields a held state compares by, in the record's order.
  @spec changed_fields(
          from_index :: non_neg_integer(),
          to_index :: non_neg_integer(),
          charts :: {Machine.t(), Machine.t(), map()}
        ) :: [:kind | :parent | :atomic | :regions | :history_type]
  defp changed_fields(from_index, to_index, {from, to, corr}) do
    a = Machine.at(from, from_index)
    b = Machine.at(to, to_index)

    [
      kind: a.kind != b.kind,
      parent: Map.get(corr, a.parent, :none) != b.parent,
      atomic: Machine.atomic?(from, from_index) != Machine.atomic?(to, to_index),
      regions:
        a.kind == :parallel and b.kind == :parallel and
          regions(from, from_index, corr) != MapSet.new(Machine.child_states(to, to_index)),
      history_type: a.history_type != b.history_type
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  # A parallel `from` state's child states, each as its corresponding `to`
  # index; a child with none stays distinct from every `to` index.
  @spec regions(machine :: Machine.t(), index :: non_neg_integer(), corr :: map()) ::
          MapSet.t(non_neg_integer() | {:unresolved, non_neg_integer()})
  defp regions(machine, index, corr) do
    machine
    |> Machine.child_states(index)
    |> MapSet.new(&Map.get(corr, &1, {:unresolved, &1}))
  end

  # Removed transitions of held, corresponding `from` states and added
  # transitions of corresponding `to` states, each side in `t_index` order.
  @spec transition_reasons(
          from :: Machine.t(),
          to :: Machine.t(),
          corr :: map(),
          held :: MapSet.t(non_neg_integer())
        ) :: [diff_reason()]
  defp transition_reasons(from, to, corr, held) do
    {removed, added} =
      corr
      |> Enum.map(fn {from_index, to_index} ->
        {unmatched_from, unmatched_to} = match_transitions(from, to, from_index, to_index, corr)

        removed =
          if MapSet.member?(held, from_index),
            do:
              Enum.map(unmatched_from, &{:transition_removed, Machine.id(from, from_index), &1}),
            else: []

        {removed, Enum.map(unmatched_to, &{:transition_added, Machine.id(to, to_index), &1})}
      end)
      |> Enum.unzip()

    Enum.sort_by(List.flatten(removed), &elem(&1, 2)) ++
      Enum.sort_by(List.flatten(added), &elem(&1, 2))
  end

  # Matches one state pair's selectable transitions as a multiset, each
  # `from` transition in `t_index` order taking the first equal `to` one;
  # answers the `t_index`es left unmatched on each side.
  @spec match_transitions(
          from :: Machine.t(),
          to :: Machine.t(),
          from_index :: non_neg_integer(),
          to_index :: non_neg_integer(),
          corr :: map()
        ) :: {[non_neg_integer()], [non_neg_integer()]}
  defp match_transitions(from, to, from_index, to_index, corr) do
    to_keys =
      for t_index <- Enum.sort(Machine.at(to, to_index).transitions),
          do: {t_index, transition_key(Machine.transition(to, t_index), & &1)}

    translate = &Map.get(corr, &1, {:unresolved, &1})

    {unmatched_from, unmatched_to} =
      from
      |> Machine.at(from_index)
      |> Map.get(:transitions, [])
      |> Enum.sort()
      |> Enum.reduce({[], to_keys}, fn t_index, {unmatched, remaining} ->
        key = transition_key(Machine.transition(from, t_index), translate)

        case Enum.split_while(remaining, &(elem(&1, 1) != key)) do
          {before, [_match | rest]} -> {unmatched, before ++ rest}
          {_all, []} -> {[t_index | unmatched], remaining}
        end
      end)

    {Enum.reverse(unmatched_from), Enum.map(unmatched_to, &elem(&1, 0))}
  end

  # A transition's normalized fields, its state indexes put through
  # `translate` into the `to` chart's index space.
  @spec transition_key(transition :: Statifier.Machine.Transition.t(), translate :: fun()) ::
          tuple()
  defp transition_key(transition, translate) do
    {translate.(transition.source), Enum.map(transition.events, &Enum.join(&1, ".")),
     Enum.map(transition.targets, translate), transition.type, cond_key(transition.cond)}
  end

  @spec cond_key(cond :: Machine.expr() | nil | term()) :: term()
  defp cond_key({:compiled, _compiled, source}), do: {:compiled, source}
  defp cond_key(other), do: other

  @spec list_delta(from :: [String.t()], to :: [String.t()], removed :: atom(), added :: atom()) ::
          [{atom(), String.t()}]
  defp list_delta(from, to, removed, added) do
    Enum.map(from -- to, &{removed, &1}) ++ Enum.map(to -- from, &{added, &1})
  end

  @spec data_ids(machine :: Machine.t()) :: [String.t()]
  defp data_ids(machine) do
    machine.data_elements |> Tuple.to_list() |> Enum.map(& &1.id) |> Enum.uniq()
  end

  @spec state_indexes(machine :: Machine.t()) :: Range.t()
  defp state_indexes(machine), do: 0..(tuple_size(machine.states) - 1)

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
