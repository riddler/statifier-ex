# The end-to-end macrostep benchmark (Phase 2). Answers the other half of
# the pre-registered decision rule: what share of a real macrostep's time
# and memory context construction actually accounts for, at realistic and
# stress scale, with <foreach> measured separately because it is the one
# multiplicative case, and a hand-built cond document measured separately
# because no corpus document reaches it.
#
# Run with:
#
#     mix run bench/macrostep.exs
#
# See bench/README.md for why this directory is outside every gate stage,
# docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md Phase 2 for
# what this script has to produce, and
# docs/research/260814-st-sdh-context-rebuild-vs-bind-benchmark.md section 1
# for the call-site table the build-count derivation below reads off.
#
# The engine is driven only through its public boundary - Statifier.compile/1,
# Statifier.initialize/2, Statifier.send_event/2 - over hand-built documents,
# since the corpus cannot reach the cases that matter (D1). The share is
# computed by subtraction/derivation, never by instrumentation: no counters
# go into lib/.

Code.require_file("support/workload.exs", __DIR__)

alias Statifier.Evaluator

# --- Document builders --------------------------------------------------
#
# Every document shares the same 5-root flat datamodel (a..e), matching the
# corpus's own shape (D1: corpus <data> declarations are overwhelmingly flat
# scalars, maximum 5 roots per document - see
# bench/results/260814-context-build.md's corpus scan). The realistic and
# assign-heavy documents hold that datamodel's size constant so the only
# thing that varies is block/assign count (the additive case); the foreach
# documents add one more root (the array itself) whose size scales with N
# (the multiplicative case).

defmodule Documents do
  @moduledoc false

  @datamodel """
          <data id="a" expr="1"/>
          <data id="b" expr="2"/>
          <data id="c" expr="3"/>
          <data id="d" expr="4"/>
          <data id="e" expr="5"/>
  """

  @doc """
  Corpus-shaped: onentry/onexit blocks with a small number of <assign> and
  <log> children, a plain (uncond) transition. One `go` event drives one
  full macrostep: exit s1 (<onexit>), the transition's own content, enter
  s2 (<onentry>).
  """
  def realistic do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="ecmascript" initial="s1">
        <datamodel>
    #{@datamodel}
        </datamodel>
        <state id="s1">
            <onentry>
                <log label="enter s1" expr="a"/>
                <assign location="a" expr="a + 1"/>
            </onentry>
            <onexit>
                <log label="exit s1" expr="b"/>
                <assign location="b" expr="b + 1"/>
            </onexit>
            <transition event="go" target="s2">
                <log label="go" expr="c"/>
            </transition>
        </state>
        <state id="s2">
            <onentry>
                <log label="enter s2" expr="d"/>
                <assign location="d" expr="d + 1"/>
            </onentry>
        </state>
    </scxml>
    """
  end

  @doc """
  Same datamodel, a block of `n` <assign> nodes on the fired transition's
  own content - the additive case. No onentry/onexit content, so the fired
  macrostep's only content block is this one.
  """
  def assign_heavy(n) do
    assigns =
      for i <- 1..n, into: "" do
        "            <assign location=\"a\" expr=\"a + #{i}\"/>\n"
      end

    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="ecmascript" initial="s1">
        <datamodel>
    #{@datamodel}
        </datamodel>
        <state id="s1">
            <transition event="go" target="s2">
    #{assigns}        </transition>
        </state>
        <state id="s2"/>
    </scxml>
    """
  end

  @doc """
  Same datamodel plus one more root, `items`, an N-element array - the
  multiplicative case. The <foreach> body is empty (just declares `x`) so
  the build count is exactly declare/2's pre-loop rebuild plus one rebuild
  per iteration (`lib/statifier/machine/content/foreach.ex:276-285`), with
  no nested <assign> inflating it further.
  """
  def foreach(n) do
    items = Enum.map_join(1..n, ",", &Integer.to_string/1)

    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="ecmascript" initial="s1">
        <datamodel>
    #{@datamodel}
            <data id="items" expr="[#{items}]"/>
        </datamodel>
        <state id="s1">
            <transition event="go" target="s2">
                <foreach array="items" item="x"></foreach>
            </transition>
        </state>
        <state id="s2"/>
    </scxml>
    """
  end

  @doc """
  Hand-built: three cond-bearing candidate transitions on the same event,
  from the same atomic state, only one of which matches. `cond` on
  transitions is not reachable from the corpus
  (`lib/statifier/interpreter/selection.ex:277-280` - `FeatureDetector`
  marks `conditional_transitions` `:unsupported`), so this document is the
  only way to measure a selection round that actually evaluates `cond`.
  """
  def cond_selection do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="ecmascript" initial="s1">
        <datamodel>
    #{@datamodel}
        </datamodel>
        <state id="s1">
            <transition event="go" cond="a==99" target="s2"/>
            <transition event="go" cond="b==99" target="s3"/>
            <transition event="go" cond="c==3" target="s4"/>
        </state>
        <state id="s2"/>
        <state id="s3"/>
        <state id="s4"/>
    </scxml>
    """
  end
end

# --- Compile + initialize each document ----------------------------------
#
# machine_state is immutable, so one initialized machine_state per document
# is safe to hand to Benchee repeatedly: Statifier.send_event/2 returns a
# new machine_state and never mutates the one passed in.

defmodule Bench do
  @moduledoc false

  @spec build(String.t()) :: Statifier.MachineState.t()
  def build(source) do
    {:ok, machine} = Statifier.compile(source)
    {machine_state, _effects} = Statifier.initialize(machine)
    machine_state
  end

  @doc """
  Runs one macrostep benchmark (time + memory) over `label => machine_state`
  pairs, all firing the same `go` event, and returns the `%Benchee.Suite{}`
  so the caller can pull statistics out programmatically for the derivation
  math below.
  """
  @spec run_macrostep(%{String.t() => Statifier.MachineState.t()}) :: Benchee.Suite.t()
  def run_macrostep(inputs) do
    Benchee.run(
      %{"macrostep (send_event go)" => fn ms -> Statifier.send_event(ms, "go") end},
      inputs: inputs,
      # Reduced from time: 5, memory_time: 2, warmup: 2 in st-59d Phase 2:
      # this operation is microsecond-scale, so 2s of measurement still
      # yields on the order of a million samples per scenario; past that,
      # the error bars are set by machine noise rather than sample count.
      time: 2,
      memory_time: 1,
      warmup: 1,
      formatters: [Benchee.Formatters.Console]
    )
  end

  @doc """
  Runs `Evaluator.context/1` (T_full's own scenario, D2) directly on the
  given machine_states, giving the per-build cost at exactly this document's
  real datamodel size rather than one of Phase 1's four discrete buckets -
  needed here because the foreach documents' datamodel size scales with N,
  which none of Phase 1's fixed size points track.
  """
  @spec run_build_cost(%{String.t() => Statifier.MachineState.t()}) :: Benchee.Suite.t()
  def run_build_cost(inputs) do
    Benchee.run(
      %{"Evaluator.context/1" => fn ms -> Evaluator.context(ms) end},
      inputs: inputs,
      # Reduced from time: 3, memory_time: 1, warmup: 1 in st-59d Phase 2:
      # microsecond-scale operation, still on the order of a million samples
      # per scenario at 2s; beyond that the error bars are set by machine
      # noise rather than sample count.
      time: 2,
      memory_time: 1,
      warmup: 1,
      formatters: [Benchee.Formatters.Console]
    )
  end

  @spec stats(Benchee.Suite.t(), String.t()) :: {float(), float()}
  def stats(%Benchee.Suite{scenarios: scenarios}, input_name) do
    scenario = Enum.find(scenarios, &(&1.input_name == input_name))
    time_ns = scenario.run_time_data.statistics.average
    mem_bytes = scenario.memory_usage_data.statistics.average
    {time_ns, mem_bytes}
  end

  @doc """
  Prints the derivation for one document: build count (from the call-site
  table), per-build cost, estimated context-build share of the macrostep,
  and the measured macrostep cost it is a share of.
  """
  @spec derive(String.t(), non_neg_integer(), {float(), float()}, {float(), float()}) ::
          {float(), float()}
  def derive(label, build_count, {build_time_ns, build_mem_bytes}, {macro_time_ns, macro_mem_bytes}) do
    est_time_ns = build_count * build_time_ns
    est_mem_bytes = build_count * build_mem_bytes
    s_time = est_time_ns / macro_time_ns
    s_mem = est_mem_bytes / macro_mem_bytes

    IO.puts("""

    --- #{label} ---
    build count:        #{build_count}
    per-build cost:      #{Float.round(build_time_ns / 1000, 3)} us / #{Float.round(build_mem_bytes / 1000, 3)} KB
    estimated build cost: #{Float.round(est_time_ns / 1000, 3)} us / #{Float.round(est_mem_bytes / 1000, 3)} KB
    measured macrostep:  #{Float.round(macro_time_ns / 1000, 3)} us / #{Float.round(macro_mem_bytes / 1000, 3)} KB
    S_time:              #{Float.round(s_time * 100, 2)}%
    S_mem:                #{Float.round(s_mem * 100, 2)}%
    """)

    {s_time, s_mem}
  end
end

# --- Run 1: realistic + assign-heavy (constant datamodel size) ----------
#
# Build count, per the current call graph and ADR-0028
# (docs/adr/0028-executable-content-blocks-thread-one-context.md) plus this
# plan (docs/plans/260814-st-l0t-provider-host-seam-for-in1.md, Phase 3).
# ADR-0028 threads one Evaluator.context/1 build through the whole block via
# Evaluator.bind/3: <assign> (lib/statifier/machine/content/assign.ex),
# <foreach> (lib/statifier/machine/content/foreach.ex) and <script>'s
# post-run context all bind into the block's existing context instead of
# rebuilding it, so there is no longer a rebuild per write inside a block.
# The surviving builds, confirmed against lib/statifier/interpreter/content.ex
# (execute_block/3, :140-145 - the empty-c_indexes clause at :136-138 skips
# the build entirely for an empty block) and
# lib/statifier/interpreter/selection.ex (:332, :364):
#
#   1 (Selection.select_transitions/2, the external-event round)
# + 1 (Selection.select_eventless_transitions/1, the terminal quiescence
#      probe every macrostep ends with - lib/statifier/interpreter.ex:521)
# + one execute_block/3 build per non-empty <onexit>/content/<onentry>
#   block the macrostep runs (regardless of how many nodes are inside it -
#   ADR-0028 removed the per-write rebuild)
#
# realistic: 2 (selection) + 3 (onexit block, transition-content block,
# onentry block, each non-empty) = 5.
#
# assign_heavy(n): 2 (selection) + 1 (the one non-empty transition-content
# block, which holds all n <assign> nodes and binds each one into that same
# block context) = 3, constant in n.

realistic_ms = Bench.build(Documents.realistic())
realistic_build_ms = realistic_ms

assign_inputs =
  for n <- [1, 5, 25, 100], into: %{} do
    {"n=#{n}", Bench.build(Documents.assign_heavy(n))}
  end

IO.puts("\n=== macrostep: realistic ===")
realistic_suite = Bench.run_macrostep(%{"realistic" => realistic_ms})

IO.puts("\n=== macrostep: assign-heavy ===")
assign_suite = Bench.run_macrostep(assign_inputs)

IO.puts("\n=== per-build cost: realistic + assign-heavy datamodel (constant size) ===")
build_suite_1 = Bench.run_build_cost(%{"realistic" => realistic_build_ms})

realistic_macro = Bench.stats(realistic_suite, "realistic")
realistic_build = Bench.stats(build_suite_1, "realistic")
{realistic_s_time, realistic_s_mem} = Bench.derive("realistic", 5, realistic_build, realistic_macro)

assign_results =
  for n <- [1, 5, 25, 100] do
    key = "n=#{n}"
    macro = Bench.stats(assign_suite, key)
    build_count = 3
    {s_time, s_mem} = Bench.derive("assign-heavy #{key}", build_count, realistic_build, macro)
    {n, s_time, s_mem}
  end

# --- Run 2: foreach (datamodel size scales with N) -----------------------
#
# foreach(n): 2 (selection) + 1 (the one non-empty transition-content block
# wrapping the <foreach> node) = 3, constant in n. ADR-0028 threads
# declare/2's item/index declaration and every write_iteration/4 call into
# that same block context with Evaluator.bind/3
# (lib/statifier/machine/content/foreach.ex's write_iteration/4 and
# bind_names/4) instead of rebuilding per iteration, so there is no longer a
# `+ n` term here.
#
# Unlike realistic/assign-heavy, the datamodel itself grows with n (the
# `items` array), so the per-build cost is measured separately at each n
# rather than reused from one constant-size figure.

foreach_ns = [1, 10, 100, 1000]

foreach_inputs =
  for n <- foreach_ns, into: %{} do
    {"n=#{n}", Bench.build(Documents.foreach(n))}
  end

IO.puts("\n=== macrostep: foreach ===")
foreach_suite = Bench.run_macrostep(foreach_inputs)

IO.puts("\n=== per-build cost: foreach datamodel at each N ===")
foreach_build_suite = Bench.run_build_cost(foreach_inputs)

foreach_results =
  for n <- foreach_ns do
    key = "n=#{n}"
    macro = Bench.stats(foreach_suite, key)
    build = Bench.stats(foreach_build_suite, key)
    build_count = 3
    {s_time, s_mem} = Bench.derive("foreach #{key}", build_count, build, macro)
    {n, s_time, s_mem}
  end

# --- Run 3: cond-bearing selection, reported separately -------------------
#
# Not folded into the realistic share (D1): no corpus document reaches a
# cond-bearing transition. Build count is identical to the realistic
# document's selection halves - select_transitions/2 builds exactly one
# context per round regardless of how many candidate transitions carry
# `cond` (lib/statifier/interpreter/selection.ex:332) - plus the terminal
# eventless probe. No content blocks run (the matching transition is
# targetless of content and its target states have no onentry), so this
# constant is unaffected by ADR-0028
# (docs/adr/0028-executable-content-blocks-thread-one-context.md) - it never
# had a per-write rebuild to remove - and is unchanged from before this plan
# (docs/plans/260814-st-l0t-provider-host-seam-for-in1.md, Phase 3):
#
#   1 (select_transitions, now evaluating 3 cond expressions against the
#      one context it built) + 1 (eventless probe) = 2.

cond_ms = Bench.build(Documents.cond_selection())

IO.puts("\n=== macrostep: cond-bearing selection (not corpus-reachable) ===")
cond_suite = Bench.run_macrostep(%{"cond" => cond_ms})

IO.puts("\n=== per-build cost: cond document's datamodel ===")
cond_build_suite = Bench.run_build_cost(%{"cond" => cond_ms})

cond_macro = Bench.stats(cond_suite, "cond")
cond_build = Bench.stats(cond_build_suite, "cond")
{cond_s_time, cond_s_mem} = Bench.derive("cond-bearing selection", 2, cond_build, cond_macro)

# --- Summary ---------------------------------------------------------------

IO.puts("\n=== SUMMARY ===")
IO.puts("realistic: S_time=#{Float.round(realistic_s_time * 100, 2)}% S_mem=#{Float.round(realistic_s_mem * 100, 2)}%")

for {n, s_time, s_mem} <- assign_results do
  IO.puts("assign-heavy n=#{n}: S_time=#{Float.round(s_time * 100, 2)}% S_mem=#{Float.round(s_mem * 100, 2)}%")
end

for {n, s_time, s_mem} <- foreach_results do
  IO.puts("foreach n=#{n}: S_time=#{Float.round(s_time * 100, 2)}% S_mem=#{Float.round(s_mem * 100, 2)}%")
end

IO.puts("cond-bearing selection (not corpus-reachable): S_time=#{Float.round(cond_s_time * 100, 2)}% S_mem=#{Float.round(cond_s_mem * 100, 2)}%")

foreach_leq_100 = Enum.filter(foreach_results, fn {n, _, _} -> n <= 100 end)
foreach_over_5 = Enum.any?(foreach_leq_100, fn {_, s_time, s_mem} -> s_time >= 0.05 or s_mem >= 0.05 end)

branch =
  if realistic_s_time < 0.05 and realistic_s_mem < 0.05 and not foreach_over_5 do
    "A"
  else
    "B"
  end

IO.puts("\nPre-registered rule selects: Branch #{branch}")
