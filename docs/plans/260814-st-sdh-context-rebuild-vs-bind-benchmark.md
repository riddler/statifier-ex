# Context rebuild vs `bind/3` Implementation Plan

## Overview

Build the benchmark st-sdh has been waiting for, then record the decision its
numbers support - and make the `bind/3`-threading change only if they support
it. The measurement comes first; neither branch is presupposed here.

Beads issue: `st-sdh`. Source research:
`docs/research/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`.

## Current State Analysis

`Statifier.Evaluator.context/1` (`lib/statifier/evaluator.ex:108-113`) is the
sole constructor of a `%Predicator.Context{}` over live machine data. Eleven
call sites reach it; `Predicator.Context.bind/3` and
`Predicator.Context.put_host/2` are called nowhere in `lib/`.

Threading is already the default. Within any one evaluation site - a selection
round, a content block, a `<datamodel>` binding pass, a `<param>` fold - one
context is built and threaded unchanged, carried in
`Statifier.ExecutableContent.Context`'s `datamodel_context` field
(`lib/statifier/executable_content/context.ex:64`). Exactly three nodes rebuild:

- `<assign>` - once per assign, after the write
  (`lib/statifier/machine/content/assign.ex:76-91`)
- `<script>` - once in `rebind/2` plus a second build inside
  `Evaluator.execute/2` (`lib/statifier/machine/content/script.ex:95-103`)
- `<foreach>` - once before the loop plus once per iteration, the one
  multiplicative case (`lib/statifier/machine/content/foreach.ex:276-285`)

A rebuild is not one cost but three, and only two of them scale with datamodel
size:

1. `Statifier.Evaluator.undefine_nils/1`, a statifier-side deep walk over the
   whole datamodel *before* the map is handed to predicator
   (`lib/statifier/evaluator.ex:136-143`).
2. `Predicator.Context.new/2`'s own `normalize_value/1`, a second deep walk
   (`deps/predicator/lib/predicator/context.ex:128-136`, `:335-344`).
3. `resolve_functions/1`, which re-resolves and re-validates the four builtin
   providers with a `Code.ensure_loaded?/1` per module and a
   `function_exported?/3` per named function, **on every call**
   (`deps/predicator/lib/predicator/context.ex:158-207`). Fixed cost,
   independent of datamodel size.

There is no benchmarking infrastructure of any kind: no `bench/` directory, no
benchee, no bench task in `mise.toml`, no `:timer.tc` or profiler anywhere in
`lib/`, `test/`, `tools/` or `docs/`. predicator ships none either.

The upstream seam is fully available. predicator is pinned `~> 7.0` and locked
at 7.0.0 (`mix.exs:41`, `mix.lock:19`) - the bead's note saying 5.0 is stale on
its face, though the seam it names landed in 5.0 and is unchanged through 7.0.
`bind/3` is `Map.put` plus normalizing the bound value only
(`deps/predicator/lib/predicator/context.ex:240-243`) and carries `functions`,
`on_unbound` and `host` over unchanged; `put_host/2` is a one-line struct
update (`:256-257`). `In/1` is still an inline `functions:` closure capturing
`machine_state.machine` and `machine_state.configuration`
(`lib/statifier/evaluator.ex:110`, `:304-313`).

## Desired End State

A committed, reproducible benchmark under `bench/`, a committed results file
recording what it measured, and an accepted ADR recording the decision those
numbers support - plus, if and only if the numbers support it, the
`bind/3`-threading change itself.

Verify by: `mix run bench/context_build.exs` and `mix run bench/macrostep.exs`
both complete and reproduce the committed results within their stated noise
band; `docs/adr/README.md` lists ADR-0028 as accepted; `docs/datamodel.md` seam
1 and `Statifier.Evaluator`'s "Why the built context is not a `MachineState`
field" section both cite ADR-0028 rather than "nothing evaluates in a hot path
yet"; a bare `mix quality` is green.

### Key Discoveries:

- One constructor, eleven live call sites: `lib/statifier/evaluator.ex:108-113`.
- Threading is already the default; only `<assign>`, `<script>` and
  `<foreach>` rebuild, and only `<foreach>` is multiplicative
  (`lib/statifier/machine/content/foreach.ex:276-285`).
- Three separable cost terms in one call, only two of which scale with
  datamodel size (`deps/predicator/lib/predicator/context.ex:158-207` is the
  fixed one).
- A `bench/` directory is invisible to every gate stage: absent from
  `.formatter.exs` inputs, absent from `.credo.exs` `included`, outside
  `elixirc_paths` (`mix.exs:36-37`) so Compile, Dialyzer, Doctor and coverage
  never see it, and outside the gate guard's `interesting?/1` scan
  (`lib/mix/statifier/gate_guard.ex:140-142`).
- The gate guard matches `mix.exs` by **line content**, not path
  (`lib/mix/statifier/gate_guard.ex:40-43`), over both added and removed diff
  lines. A new dep line matches none of its alternatives - but *appending*
  after `{:doctor, "~> 0.23", ...}` at `mix.exs:55` would rewrite that line to
  add a trailing comma, producing a `-`/`+` pair matching `:doctor` and
  demanding a ledger entry for punctuation. An `aliases:` entry would match
  outright.
- ADR-0012 constraint 1 (`docs/observability.md:26-49`) is what rules out
  storing a context on `MachineState`; the moduledoc's ground 1 is dissolvable
  by the provider seam and ground 2 is not
  (`lib/statifier/evaluator.ex:37-72`).
- ADR-0011 makes a ledger entry a human's call, and `docs/quality-gate-changes.md:1-14`
  says so in its own preamble.
- ADR-0018 forbids bead IDs in new comments, scoped to `lib/` and `test/`
  (`lib/mix/statifier/adr_guard.ex:263-283`). The existing mention at
  `lib/statifier/evaluator.ex:68` predates the guard and is prior art, not a
  licence.

## Decisions

The research document closed with five open questions. This plan resolves all
five rather than leaving them for the implementer.

**D1 - what "realistic" means (research OQ 1).** Both scales get measured, and
they answer different halves of the acceptance criterion. The *realistic* point
is corpus-shaped: a handful of `<data>` roots, shallow nesting, the block
counts a corpus document actually produces - this is what decides the bead.

A correction to the research document, established while writing this plan and
worth carrying forward: its section 9 says "24 files under
`test/scxml_tests/mandatory/` and 28 under `test/scion_tests/`". Those are
**directory** counts. The actual file counts are 159 and 119 generated test
files respectively. The corpus is roughly five times larger in file count than
the research document states.

That does not change D1's answer, because the claim D1 rests on is about
datamodel *shape*, not corpus size, and the shape claim holds on measurement:
no corpus document declares more than **5** `<data>` roots
(`test504_test.exs`, `test152_test.exs` and scion `foreach/test1_test.exs` tie
at the maximum), and the declarations are overwhelmingly flat scalars of the
`<data id="Var1" expr="0" />` form. "A handful of roots, shallow nesting" is
therefore a measured description of the corpus population, not a hand-picked
subset - which is exactly what the correction might otherwise have put in
doubt.
The *stress* curve is a parameter sweep over datamodel size and block count
independently, and exists to show where the realistic point sits on the curve,
so a future document ten times larger does not silently invalidate the answer.
Reporting only the realistic point would make the answer unfalsifiable at any
other scale; reporting only the stress curve would answer a question nobody
asked. `cond` on transitions is not reachable from the corpus
(`lib/statifier/interpreter/selection.ex:277-280`: `FeatureDetector` marks
`conditional_transitions` `:unsupported`), so the per-selection-round rebuild
is measured from hand-built documents and reported separately, labelled as
not-yet-reachable rather than folded into the realistic number.

**D2 - separating the three cost terms (research OQ 2).** Yes, and by
subtraction over public API only, so nothing private has to be exposed for a
benchmark. Four measurements, three terms:

- `T_full` = `Statifier.Evaluator.context/1` on a machine_state whose datamodel
  contains `nil`s (the real path).
- `T_new` = `Predicator.Context.new(data, functions: ..., on_unbound: :error)`
  on the same datamodel with `nil`s already removed - skips `undefine_nils/1`.
- `T_fixed` = the same `Context.new/2` call over an **empty** datamodel -
  isolates `resolve_functions/1`, which does not scale with data.
- `T_bind` = `Predicator.Context.bind(ctx, root, value)` - the alternative.

Then fixed cost = `T_fixed`, predicator's normalize = `T_new - T_fixed`,
statifier's `undefine_nils/1` = `T_full - T_new`. Reported on both time and
allocated memory.

**D3 - where a stored context would live (research OQ 3).** Out of scope, and
deliberately so. Every rebuild the research identified - `<assign>`,
`<script>`, `<foreach>` - happens *inside a single executable-content block*,
where the configuration does not move and `In/1`'s captured position is still
correct. So the `bind/3` change this plan contemplates threads within a block
that `Interpreter.Content.execute_block/3` already builds once
(`lib/statifier/interpreter/content.ex:140-162`), stores nothing on
`MachineState`, and leaves `docs/datamodel.md`'s "built once per evaluation
site" commitment (`docs/datamodel.md:54-59`) exactly as written. Widening the
interval *across* blocks is the `MachineState`-field question, it needs the
provider/`put_host` conversion to satisfy ADR-0012 constraint 1, and it is not
this bead. See "What We're NOT Doing".

**D4 - `bench/` being invisible to the gate (research OQ 4).** Accepted, not
addressed. Benchmark code is not test code and not shipped code: it asserts
nothing, no `lib/` behavior depends on it, and it is run by a human reading
numbers. Bringing it under the formatter or Credo would mean editing
`.formatter.exs` or `.credo.exs` - both guarded paths under ADR-0011, both
needing a ledger entry a human writes - to lint a directory that cannot break
anything. `bench/` is therefore ungated on purpose, and Phase 1 records that
in `bench/README.md` so the next reader does not mistake it for an oversight.
The `mix bench` alias is likewise out of scope: an `aliases:` key matches the
guard pattern outright, so the entry point stays `mix run bench/<file>.exs`.

**D5 - the stale "predicator 5.0" note (research OQ 5).** The bead's note is
wrong about the pin and right about the seam. Fixed with a `bd update` note in
Phase 3, not with a code or doc change - nothing in `lib/` or `docs/` claims
the wrong version. `Statifier.Evaluator`'s moduledoc line saying the seam
"landed in predicator 5.0.0" (`lib/statifier/evaluator.ex:70`) is correct as
written and is not touched for this reason.

## The pre-registered decision rule

**This rule is fixed before any number exists.** It is written here, in the
plan, precisely so the branch cannot be chosen after seeing the data and
justified backwards.

Let `S_time` and `S_mem` be the share of one macrostep's wall time and
allocated memory attributable to context construction, at the **realistic**
scale of D1.

- **Branch A - rebuilding is fine.** `S_time < 5%` **and** `S_mem < 5%` at
  realistic scale, **and** the `<foreach>` stress case stays under 5% on both
  axes for N <= 100 iterations.
- **Branch B - the change is justified.** `S_time >= 5%` or `S_mem >= 5%` at
  realistic scale, **or** the `<foreach>` case crosses 5% on either axis at
  N <= 100.
- **Modifier C, independent of A/B.** If `T_fixed` is >= 50% of `T_full` at
  the realistic datamodel size, the fixed per-call provider re-validation
  dominates and the root fix is upstream memoization in predicator, not
  statifier glue. Phase 3 then also files a predicator-ex bead and cross-links
  it per ADR-0025's `mirrors:` protocol. This fires or does not fire on its own
  evidence; it does not change which of A or B is taken.

Why these numbers: 5% is about the noise floor of a benchee run on a developer
laptop, and below it no user observes a difference - a smaller threshold would
be measuring the machine rather than the engine. N <= 100 because a `<foreach>`
over more than a hundred elements is beyond anything the corpus contains or a
plausible statechart does, so a cost that only appears past it is not a cost
this engine pays.

Ties and ambiguity resolve to **Branch A**. Rebuilding is the status quo, it is
the shape three prior plans already chose deliberately
(`docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md:782-795`), and
an unclear measurement is not a justification for a change.

## What We're NOT Doing

- **Not converting `In/1` to a `FunctionProvider`, and not touching
  `Context.put_host/2`.** That conversion realizes nothing on its own - the
  research's own prior art says so
  (`docs/research/260812-st-p3t-predicator-5-bump.md:265-274`) - and it is only
  needed to store a context *across* blocks, which D3 puts out of scope.
- **Not storing a context on `MachineState`.** That is the ADR-0012
  constraint-1 question. Under Branch B this plan's change does not need it,
  and under Branch A it is moot. A future bead may revisit it; ADR-0028 will
  say what would have to change first.
- **Not widening `docs/datamodel.md`'s "once per evaluation site" commitment**
  (`docs/datamodel.md:54-59`). Both branches leave it standing.
- **Not adding a `mix bench` alias, and not writing a
  `docs/quality-gate-changes.md` entry.** Per D4 and ADR-0011, a ledger entry
  is a human's call. If a future maintainer wants the alias, the entry is
  theirs to write; no phase here creates a situation that requires one.
- **Not bringing `bench/` under the formatter, Credo, Dialyzer, or coverage.**
  Per D4.
- **Not regenerating the corpus and not ratcheting.** Under Branch A nothing
  in `lib/` changes at all; under Branch B the change is
  allocation-level and must leave conformance exactly where it is, which is a
  criterion rather than a goal.
- **Not changing any selection-path signature.** `Selection.condition_match/2`
  builds its own context (`lib/statifier/interpreter/selection.ex:285`)
  precisely so it stays callable from a machine_state alone - ADR-0012
  constraint 5 (`docs/observability.md:124-134`) makes "these functions take
  and return plain values, no hidden context" a commitment. Threading a
  prebuilt context *into* a selection function would trade that away for an
  allocation, so Branch B stops at executable content and the selection round
  keeps its per-round build.
- **Not benchmarking the parser, compiler, or validator.** st-sdh is about
  context construction on the evaluation path.

A note the plan critic raised and this plan declines: that Phase 4's
conditionality makes the plan's length unpredictable. It does, and that is the
bead's own shape - "either a change justified by it, or a recorded decision
that rebuilding is fine" is a fork, and a plan that collapsed it would be
presupposing the answer.

## Implementation Approach

Four phases, each independently committable and gate-verifiable. Phases 1 and 2
touch nothing the gate compiles, so their gate is green by construction and
their real bar is that the benchmark runs and its output is reproducible.
Phase 3 records the decision and is committable under either branch. Phase 4
exists only under Branch B and is not executed at all under Branch A.

The A/B comparison lives in `bench/`, not in `lib/`: the candidate
`bind/3`-threaded block shape is written as a script-local function that
replicates what `<assign>` and `<foreach>` do, so the measurement that decides
whether to change `lib/` does not require changing `lib/` first.

---

## Phase 1: Benchmark harness and the three-term decomposition

### Overview

Add benchee, create `bench/`, and answer D2: what a context build actually
costs, split into its three terms, plus a direct A/B of a rebuilding block
against a `bind/3`-threaded one.

### Changes Required:

#### 1. The benchee dependency

**File**: `mix.exs`

**Changes**: Add one dep line. **Insert it between the `{:ex_doc, ...}` line
(`mix.exs:54`) and the `{:doctor, ...}` line (`mix.exs:55`)**, so the diff is a
single added line and no existing line is rewritten. Appending after `:doctor`
would add a trailing comma to that line and trip the gate guard's `:doctor`
alternative (`lib/mix/statifier/gate_guard.ex:40-43`) for pure punctuation.

```elixir
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev},
      {:doctor, "~> 0.23", only: :dev, runtime: false}
```

`runtime: false` is deliberately **not** set: `mix run bench/*.exs` needs
benchee's application started. `only: :dev` keeps it out of the test and prod
builds. Expect one slower gate run afterwards while Dialyzer rebuilds its PLT.

#### 2. Benchmark directory and its README

**File**: `bench/README.md` (new)

**Changes**: How to run (`mix run bench/<file>.exs`), what each script
measures, and - per D4 - an explicit statement that `bench/` is outside every
gate stage on purpose, with the reason, so it is not mistaken for an oversight.
No bead IDs (ADR-0018 is scoped to `lib/` and `test/`, but the convention is
worth keeping).

#### 3. Shared workload builder

**File**: `bench/support/workload.exs` (new)

**Changes**: Loaded by both benchmark scripts via `Code.require_file/2`. Builds:

- `datamodel(roots, depth, breadth)` - a plain map of the shape
  `MachineState.datamodel` holds, with some `nil` leaves so `undefine_nils/1`
  has work to do, and a `nil`-free twin for the `T_new` measurement.
- `machine_state(datamodel)` - a real `%MachineState{}` via
  `Statifier.compile/1` then `Statifier.initialize/2` on a minimal document,
  with the datamodel swapped in, so `Evaluator.context/1` is exercised on the
  real path including the `In/1` closure capture.
- Named size points: `:corpus` (the realistic point) and a `:stress` sweep.

The `:corpus` point is **derived, not guessed**. Before writing it, run a scan
of the real corpus and use what it reports:

```bash
grep -rho '<data [^>]*>' test/scxml_tests/ test/scion_tests/ | wc -l
grep -rc '<data ' test/scxml_tests/ test/scion_tests/ | sort -t: -k2 -rn | head
```

The distribution as measured today is 1-5 roots per document, maximum 5, mostly
flat scalars. Set `:corpus` to the **maximum** observed rather than the mean -
5 roots with a couple of nested values - so the realistic point is the
corpus's worst case and Branch A, if selected, is selected against the hardest
document the corpus actually contains rather than the average one. Record the
scan's output in the results file so a later reader can tell whether the corpus
has since moved.

#### 4. The decomposition benchmark

**File**: `bench/context_build.exs` (new)

**Changes**: A benchee run with `memory_time:` set as well as `time:` -
allocation is the cost under discussion, so a time-only run would miss the
point. Four scenarios per size point, exactly the four in D2:

```elixir
Benchee.run(
  %{
    "T_full  Evaluator.context/1" => fn %{ms: ms} -> Statifier.Evaluator.context(ms) end,
    "T_new   Context.new/2, no nils" => fn %{clean: d, fns: f} ->
      Predicator.Context.new(d, functions: f, on_unbound: :error)
    end,
    "T_fixed Context.new/2, empty data" => fn %{fns: f} ->
      Predicator.Context.new(%{}, functions: f, on_unbound: :error)
    end,
    "T_bind  Context.bind/3 one root" => fn %{ctx: ctx, root: r, val: v} ->
      Predicator.Context.bind(ctx, r, v)
    end
  },
  inputs: Workload.size_points(),
  time: 5, memory_time: 2, warmup: 2
)
```

Plus a second `Benchee.run` doing the block-level A/B: `n` sequential
single-root writes, once in today's rebuild-per-write shape and once threading
one context through `bind/3`, over each size point and over `n` in
`[1, 5, 25, 100]`. Both arms are script-local functions here - **nothing in
`lib/` changes in this phase.**

#### 5. Committed results

**File**: `bench/results/260814-context-build.md` (new)

**Changes**: The benchee output verbatim, the machine and OTP/Elixir versions
it ran on, and the three derived terms computed by the subtraction in D2. This
is the evidence Phase 3's ADR cites.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (use `mix quality --profile loop` while
      iterating; a loop run alone never satisfies this phase).
- [x] `mix gate.verify` confirms the run was a full, unprofiled, unscoped gate.
- [x] The Gate guard stage does not demand a ledger entry - i.e. `mix quality`
      is green with no `docs/quality-gate-changes.md` change in the diff. If it
      does demand one, the `mix.exs` insertion point was wrong; fix the
      placement rather than writing an entry.
- [x] `git diff origin/main -- mix.exs` shows exactly one added line and zero
      removed lines.
- [x] `mix run bench/context_build.exs` exits 0 and prints both benchee runs.
- [x] `bench/results/260814-context-build.md` exists and is non-empty.
- [x] `mix deps.unlock --check-unused` reports nothing (covered by the
      Dependencies stage).

#### Manual Verification:

- [ ] The three derived terms are internally consistent: `T_fixed <= T_new <=
      T_full` at every size point. An inversion means the scenarios are not
      measuring what they claim and the decomposition is void.
- [ ] The `:corpus` size point matches what the scan in §3 actually reported,
      and is set to the observed maximum rather than the mean. Spot-check it
      against `test/scxml_tests/mandatory/selecting_transitions/test504_test.exs`
      and `test/scion_tests/foreach/test1_test.exs`, both at the 5-root
      maximum.
- [ ] Benchee's reported deviation is small enough that a 5% difference is
      distinguishable from noise; if it is not, raise `time:`/`memory_time:`
      and re-run before trusting anything.
- [ ] No regressions in related features - nothing in `lib/` or `test/` changed,
      so this is a diff review confirming that.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full gate is the phase gate. In interactive execution, pause here for the human
to confirm the manual testing. In looped (`--loop`) execution, Automated
Verification gates advancement via `/wurk:commit --auto` and Manual
Verification is deferred and surfaced at the end.

---

## Phase 2: End-to-end workload benchmark

### Overview

Answer the other half of the decision rule: what share of a real macrostep
context construction actually accounts for, at realistic and at stress scale,
with `<foreach>` measured separately because it is the one multiplicative case.

### Changes Required:

#### 1. The macrostep benchmark

**File**: `bench/macrostep.exs` (new)

**Changes**: Drives the real engine through its public boundary -
`Statifier.compile/1`, `Statifier.initialize/2`, `Statifier.send_event/2` -
over hand-built documents, since the corpus cannot reach the cases that matter
(D1). Documents, as triple-quoted heredocs at 4-space base indentation:

- **Realistic**: corpus-shaped datamodel, `<onentry>`/`<onexit>` blocks with a
  small number of `<assign>` and `<log>` children, plain transitions.
- **Assign-heavy**: same datamodel, block of `n` `<assign>` nodes for `n` in
  `[1, 5, 25, 100]` - the additive case.
- **Foreach**: a `<foreach>` over N elements for N in `[1, 10, 100, 1000]` -
  the multiplicative case. N=1000 is past the decision rule's N<=100 bar on
  purpose, to show the curve's shape beyond the point that decides.
- **Selection with `cond`**: hand-built `cond`-bearing transitions, reported
  **separately and labelled not currently reachable from the corpus**
  (`lib/statifier/interpreter/selection.ex:277-280`), so it informs the future
  without contaminating the realistic number.

#### 2. Deriving the share

**Changes**: The share is computed, not instrumented - no counters go into
`lib/`, which would change the thing being measured and would owe tests. For
each document: count the context builds one macrostep triggers by reading the
document against the call-site table in the research document (section 1),
multiply by the per-build cost Phase 1 measured at that datamodel size, and
divide by the measured end-to-end macrostep cost. Both time and memory.

The derivation is written out in the results file so a reader can check the
arithmetic. Cross-check it: an `<assign>`-heavy document's derived share should
grow roughly linearly in `n`; if it does not, the build count is wrong.

#### 3. Committed results

**File**: `bench/results/260814-macrostep.md` (new)

**Changes**: Benchee output, the build-count derivation per document, `S_time`
and `S_mem` at the realistic point, and the `<foreach>` curve. Ends with a
plain statement of which branch of the pre-registered rule the numbers select -
stated as an outcome of the rule, with the rule quoted, not as a fresh
judgment.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating).
- [x] `mix gate.verify` confirms a full unscoped run.
- [x] `mix run bench/macrostep.exs` exits 0.
- [x] `bench/results/260814-macrostep.md` exists and states `S_time`, `S_mem`,
      the `<foreach>` curve, and the selected branch.
- [x] `git diff origin/main --stat` shows changes confined to `bench/`.

#### Manual Verification:

- [ ] The build-count derivation is right: hand-check one document against the
      call-site table in `docs/research/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`
      section 1, in particular that `execute_block/3` runs once per exited
      state's `<onexit>`, once per entered state's `<onentry>`, and once per
      fired transition's inline content.
- [ ] The `<assign>`-heavy share grows about linearly in `n` and the
      `<foreach>` share about linearly in N; a flat or erratic curve means the
      documents are not exercising what they are meant to.
- [ ] The realistic document is one a reviewer agrees is realistic - this is
      the judgment D1 makes and the one most likely to be argued with.
- [ ] The branch named in the results file follows from the quoted rule
      mechanically, with no discretion exercised.
- [ ] No regressions in related features - `lib/` and `test/` are untouched.

**Implementation Note**: Same as Phase 1.

---

## Phase 3: Record the decision

### Overview

Write down what the numbers decided, in the places that currently say the
question is open. This phase runs and commits under **either** branch; only its
content differs.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0027-<slug>.md` (new)

**Changes**: Next number is 0027 (`docs/adr/README.md` ends at 0026), same
three-section format - Context, Decision, Consequences - per that file's own
closing note. The slug and title follow the branch:

- **Branch A**: "Context is rebuilt per evaluation site; measurement says that
  is fine." Decision: the rebuild stands. Consequences must name the two things
  that would reopen it - a datamodel materially larger than the realistic point,
  or `cond` becoming reachable from the corpus and putting a build on every
  selection round - and point at `bench/` as the way to re-decide rather than
  re-argue.
- **Branch B**: "Executable-content blocks thread one context and `bind/3` each
  write." Decision: within-block threading, explicitly *not* a stored context
  on `MachineState`. Consequences must state that `docs/datamodel.md`'s "once
  per evaluation site" commitment is unchanged and that ADR-0012 constraint 1
  is untouched because nothing is stored.

Either way the ADR cites the two `bench/results/` files by path and quotes the
decision rule from this plan, so the rule's pre-registration survives.

**The `## Decision` section must contain the literal string `Branch A` or
`Branch B`**, exactly one of them. Phase 4 greps for it as its entry check, so
this is a machine-readable handoff and not just prose - an ADR that describes
the outcome without naming the branch leaves Phase 4 unable to start.

#### 2. ADR index

**File**: `docs/adr/README.md`

**Changes**: One table row for 0027, status `accepted`.

#### 3. The moduledoc

**File**: `lib/statifier/evaluator.ex` (moduledoc only, lines 37-72)

**Changes**: The sentence "Nothing evaluates in a hot path yet, so there is
nothing to measure; st-sdh tracks that question" (`:68-69`) is now false and
must go. Replace with a citation of ADR-0028 and the measured outcome.

Two constraints on this edit. First, ADR-0018 forbids bead IDs in new comment
text and the guard is scoped to `lib/` (`lib/mix/statifier/adr_guard.ex:263-283`)
- so the replacement cites **ADR-0028**, never `st-sdh`, and the existing
`st-sdh` mention at `:68` is removed rather than preserved. Second, this file's
moduledoc uses em dashes throughout; match that house style rather than
converting.

Under Branch A the two grounds stay as written and gain a third sentence: the
cost is measured and small. Under Branch B they stay too - within-block
threading does not store anything, so neither ground is contradicted - and the
"The cost that buys is real" paragraph gains the measured figure and the
pointer to what changed.

#### 4. The datamodel seam

**File**: `docs/datamodel.md` (seam 1, lines 120-132)

**Changes**: "Taking this seam is st-sdh's call, deferred until something
evaluates in a hot path worth benchmarking" is now resolved. Under Branch A:
measured, not taken, ADR-0028. Under Branch B: taken in the within-block form,
ADR-0028, with the "once per evaluation site" line at `:54-59` explicitly
noted as unchanged. This is a doc file - no ADR-0018 guard - but keep the bead
ID out anyway and cite the ADR.

#### 5. The bead note (D5)

**Changes**: `bd update st-sdh --notes` adding a dated note that the
description's "predicator 5.0" is stale - the pin is `~> 7.0`, locked 7.0.0
(`mix.exs:41`, `mix.lock:19`) - and that the seam is unchanged between them.
Also record the selected branch and the results-file paths.

#### 6. Modifier C, if it fired

**Changes**: If `T_fixed >= 50%` of `T_full` at the realistic size, file a
predicator-ex bead for memoizing `resolve_functions/1`'s per-call
`Code.ensure_loaded?/1` and `function_exported?/3` validation
(`deps/predicator/lib/predicator/context.ex:158-207`), and cross-link both
halves with a `mirrors:` first line per ADR-0025 and this repo's CLAUDE.md
cross-repo table. Predicator owns that decision; this repo's bead defers to it.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes; `mix gate.verify` confirms a full unscoped run.
- [x] The ADR guard stage is green - specifically no ADR-0018 bead-ID finding
      from the `lib/statifier/evaluator.ex` moduledoc edit.
- [x] `mix quality --profile merge` is green, which is the only run that
      enables the ADR judge (`.quality.exs:34` disables it, `:42` re-enables
      it in the `merge` profile). This phase rewrites the
      exact moduledoc section that encodes ADR-0012's reasoning, and the judge
      scopes to ADR-0012, so it is this plan's highest-risk judge trigger and
      is worth running here rather than discovering at push time.
- [x] `grep -n "st-sdh" lib/statifier/evaluator.ex` returns nothing.
- [x] `grep -rn "nothing evaluates in a hot path" lib/ docs/` returns nothing.
- [x] `docs/adr/0027-*.md` exists and contains `## Context`, `## Decision` and
      `## Consequences` headings.
- [x] `grep -c "Branch A\|Branch B" docs/adr/0027-*.md` is non-zero and the
      Decision section names exactly one of the two. This is Phase 4's entry
      check, so a Decision section that names neither - or both - blocks the
      next phase.
- [x] `grep -n "0027" docs/adr/README.md` matches the new table row.
- [x] `grep -n "0027" docs/datamodel.md lib/statifier/evaluator.ex` matches
      both.
- [x] `mix test.regression` passes - nothing here should move conformance, and
      this is the check that it did not.
- [x] `bd show st-sdh --json` shows the new note.

#### Manual Verification:

- [ ] The ADR's Decision section states the branch the pre-registered rule
      selected, and the Context section shows the numbers that selected it.
      A Decision that does not follow from its own Context is the failure mode
      this phase exists to avoid.
- [ ] The moduledoc's two grounds are still true as edited. In particular, if
      Branch B was taken, confirm ground 2 (staleness) is untouched - within-block
      threading never outlives a configuration change, because a block runs
      inside one microstep.
- [ ] `docs/datamodel.md` seam 1 and the moduledoc do not now contradict each
      other, and neither contradicts `docs/datamodel.md:54-59`.
- [ ] Em-dash house style preserved in `lib/statifier/evaluator.ex` and
      `docs/datamodel.md`; the diff shows no incidental punctuation churn.
- [ ] The ADR is a direction-level decision a reviewer would accept as such
      (`docs/workflow.md`), not a note that should have been a comment.
- [ ] Modifier C fired or did not, on its own measured evidence, and if it
      fired both halves of the mirror resolve.
- [ ] No regressions in related features.

**Implementation Note**: Same as Phase 1. Under Branch A the bead's acceptance
criterion is fully satisfied at the end of this phase and Phase 4 is not
executed.

---

## Phase 4: The `bind/3` threading change - Branch B only

### Overview

**Executed only if Phase 3 recorded Branch B.** Under Branch A this phase does
not run and the plan ends at Phase 3; that is the fork the bead asks for, and
skipping this phase is a successful outcome, not an incomplete one.

**How to tell which branch fired, before starting any work here.** Phase 3
committed the answer to a grep-able place; do not infer it from prose or from
memory of the numbers:

```bash
grep -l "Branch B" docs/adr/0027-*.md
```

Proceed only if ADR-0028's `## Decision` section names **Branch B**. If it
names Branch A, this phase is complete by not being done - report that and
stop. If the ADR names neither string verbatim, Phase 3 is not finished
correctly and the fix belongs there, not here.

Replace the three rebuild sites with `bind/3` on the block's existing threaded
context. Nothing is stored on `MachineState`; the block still builds exactly
one context at `Interpreter.Content.execute_block/3`
(`lib/statifier/interpreter/content.ex:140-162`).

### Changes Required:

#### 1. A bind helper on the Evaluator

**File**: `lib/statifier/evaluator.ex`

**Changes**: A public `bind/3` that binds one datamodel root into an existing
context, applying the same `nil` -> `:undefined` normalization `context/1`
applies through `undefine_nils/1` - otherwise a bound `nil` reads differently
from a rebuilt one and W3C test319/335/337/339 change answer.

```elixir
@spec bind(context :: Predicator.Context.t(), root :: String.t(), value :: term()) ::
        Predicator.Context.t()
def bind(%Predicator.Context{} = context, root, value) when is_binary(root) do
  Predicator.Context.bind(context, root, undefine_nils(value))
end
```

`Predicator.Context.assign/3` is **not** used: it writes at a path but does not
normalize the value (`deps/predicator/lib/predicator/context.ex:313-318`), so
it would skip predicator's own `normalize_value/1` as well as ours. Binding the
whole root is O(size of that root), not O(size of the datamodel), which is the
win.

The `@doc` states why this is safe within a block and unsafe across one:
`functions` carries over unchanged (`deps/predicator/lib/predicator/context.ex:240-243`),
so `In/1`'s captured configuration carries over too - correct while a block
runs inside one microstep, wrong the moment it outlives one.

#### 2. `<assign>`

**File**: `lib/statifier/machine/content/assign.ex` (around `:76-91`)

**Changes**: Replace `datamodel_context: Evaluator.context(machine_state)` with
a `Evaluator.bind/3` of the written root, taken from the updated
`machine_state.datamodel`. The root is the first segment of the resolved
location path, so a deep vivifying write still binds the whole root it landed
in - correct, and still cheaper than the full datamodel.

#### 3. `<foreach>`

**File**: `lib/statifier/machine/content/foreach.ex` (around `:276-285`)

**Changes**: `write_iteration/4` binds `item` and, when declared, `index` -
two single-root writes, the canonical `bind/3` shape. `declare/2`'s pre-loop
rebuild becomes binds of the declared names. This is the multiplicative case
and the largest share of the win.

#### 4. `<script>`

**File**: `lib/statifier/machine/content/script.ex` (around `:95-103`)

**Changes**: A program can write anywhere, so there is no single root to bind.
Instead use the context `Predicator.execute/3` already returns, whose
`functions`/`host`/`on_unbound` survived the run
(`deps/predicator/lib/predicator.ex:559`) - the post-run context already exists
and is currently discarded in favour of a fresh build. If threading it out of
`Evaluator.execute/2` proves to change observable behavior, leave `<script>`
rebuilding and say so in the ADR's Consequences; `<script>` is additive, not
multiplicative, and is the least of the three.

#### 5. Tests

**Files**: `test/statifier/evaluator_test.exs`,
`test/statifier/machine/content/assign_test.exs`,
`test/statifier/machine/content/foreach_test.exs`

**Changes**: Tests that a bound value reads identically to a rebuilt one -
including `nil` reading as undefined - and that `In/1` still answers correctly
inside a block after a bind. Each new test asserting `lib/` behavior carries a
one-line sabotage note above it per `docs/testing.md:87-122`, in that file's
exact format `# sabotage: <what was broken> -> red` - e.g.
`# sabotage: Evaluator.bind/3 skips undefine_nils -> red`. Break the code,
confirm red, revert, write the line. Per `docs/testing.md:114`, deleting a
function body or raising does not count as sabotage; the mutation must be
specific enough that only the test naming it goes red.

#### 6. Changelog

**Changes**: None, on any phase, and this is a decision rather than an
oversight. `changelog.d/README.md:30-50` excludes documentation, ADRs, plans,
and internal refactors with no visible effect, and narrows the rule further
while v2 is unreleased to "write a fragment when v2 differs from v1". Phases
1-3 are benchmark code, an ADR and doc edits. Phase 4 is semantically
invisible by construction - that is its own success criterion. The one
arguable item is the new public `Evaluator.bind/3`, and it does not qualify
either: it is a helper on an internal seam that no v1 user called and that
changes no observable behavior. If a reviewer disagrees, the fragment is one
file at `changelog.d/st-sdh.md`.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes; `mix gate.verify` confirms a full unscoped run.
- [x] `mix test.regression` passes - the ratchet is the check that conformance
      did not move.
- [x] `mix test --include scion --include scxml_w3` passes at exactly the same
      counts as before the change; no `mix test.baseline add` is expected,
      and if a test newly passes that is a signal something semantic changed,
      not a win to ratchet.
- [x] `grep -rn "Evaluator.context(machine_state)" lib/statifier/machine/content/`
      returns nothing (or only `script.ex`, if #4 was left rebuilding).
- [x] Every new `test "` in the diff has a sabotage line above it.
- [x] The Doctor stage stays at 100% - `.doctor.exs` holds 100% on every axis
      with empty `ignore_paths`, so the new public `Evaluator.bind/3` needs
      both a `@doc` and a `@spec` or the gate goes red. `.doctor.exs` is a
      guarded path and is never edited to accommodate this.
- [x] Coverage stays at or above `coveralls.json`'s minimum; the new public
      function must be exercised by the Phase 4 tests, not merely documented.
- [x] `mix run bench/macrostep.exs` reproduces the predicted improvement; the
      new numbers land in `bench/results/` beside the originals.

#### Manual Verification:

- [ ] Spec-conformance judgment, per this project's plan extension: the touched
      code is spec section 4 executable content, **not** Appendix D - no
      Appendix D function is modified by this phase, and confirming that is the
      check. `git diff --stat lib/statifier/interpreter/` should be empty.
- [ ] A bound context is observationally identical to a rebuilt one at every
      touched site - the change is allocation, never semantics. Walk one
      `<assign>` and one `<foreach>` by hand in IEx and diff the two contexts.
- [ ] `In/1` inside a block still answers against the configuration the block
      started with, which is what it did before; a block does not span a
      microstep, so nothing here can make it stale.
- [ ] The sabotage mutations were genuinely run and genuinely went red.
- [ ] ADR-0028's Consequences match what actually shipped, including the
      `<script>` fallback if it was taken.
- [ ] No regressions in related features.

**Implementation Note**: Same as Phase 1. This phase is the one that touches
`lib/`, so its full gate and the ratchet are both load-bearing.

---

## Performance Considerations

The whole plan is about performance, so the risk worth naming is measuring the
wrong thing:

- **Allocation, not just wall time.** The rebuild's cost is two deep walks
  producing garbage. A time-only benchee run understates it on a machine with
  headroom and overstates it under GC pressure, which is why `memory_time:` is
  mandatory in both scripts.
- **The fixed term does not scale.** `resolve_functions/1` runs
  `Code.ensure_loaded?/1` and `function_exported?/3` on every `Context.new/2`
  call (`deps/predicator/lib/predicator/context.ex:158-207`). At small
  datamodel sizes it can dominate, which is exactly the case where "rebuilding
  is expensive" would be true and "`bind/3` fixes it" only partly true -
  `bind/3` does skip it, but the root fix is upstream. Modifier C exists for
  this.
- **A prebuilt context is already the fast path.** Passing a bare map to
  `Predicator.evaluate/3` re-pays the whole `Context.new/2` cost per call
  (`deps/predicator/lib/predicator.ex:265-267`); this repo always passes a
  prebuilt `%Context{}` (`lib/statifier/evaluator.ex:169`). A benchmark that
  accidentally passes a map would measure a bug this codebase does not have.
- **`<foreach>` is the only multiplicative construct**
  (`docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md:1005-1023`), so
  it is the case most likely to select Branch B and the one measured across
  the widest range.
- **`cond` on selection is future cost, not current cost.** It would add a
  build per selection round, but no corpus document reaches it today
  (`lib/statifier/interpreter/selection.ex:277-280`). Measured and reported
  separately; explicitly excluded from the realistic share, and named in
  ADR-0028's Consequences as a reopening trigger.

## Corpus/Ratchet Notes

No corpus regeneration, and no `test/passing_tests.json` change is expected on
any phase. Phases 1-3 do not touch `lib/`. Phase 4 is an allocation change that
must be semantically invisible, so `mix test.regression` and a full
`mix test --include scion --include scxml_w3` at unchanged counts are the proof
that it was. A newly passing conformance test in Phase 4 is a red flag to
investigate, not a win to ratchet with `mix test.baseline add`. Shrinking
`test/passing_tests.json` is a guarded change needing a human's ledger entry
(ADR-0011) and nothing in this plan should ever produce one.

## Testing Strategy

### Unit Tests:

Phases 1-3 add none: benchmark code asserts nothing, and a results file and an
ADR are prose. This is deliberate, not an omission - the sabotage convention
applies to tests asserting `lib/` behavior, and there are none until Phase 4.

Phase 4's tests, all with sabotage lines:

- `Evaluator.bind/3` normalizes `nil` to `:undefined` exactly as `context/1`
  does, at the root and nested inside the bound value.
- A context after `bind/3` is observationally identical to a rebuilt one for
  every key, not only the bound one.
- `In/1` still resolves after a bind - `functions` carried over.
- `<assign>` at a deep path binds the whole root and the read-back matches.
- `<foreach>` over N elements leaves the same final datamodel as before.
- Edge cases: binding over an unset root; binding a value containing `nil`;
  `on_unbound: :error` survives the bind.

### Manual Testing Steps:

1. `mix run bench/context_build.exs` and check `T_fixed <= T_new <= T_full`
   holds at every size point.
2. `mix run bench/macrostep.exs` and hand-check one document's build count
   against the research document's call-site table.
3. Apply the pre-registered rule to the printed numbers and confirm it selects
   a branch with no discretion left over.
4. Read ADR-0028 cold and confirm its Decision follows from its Context.
5. Under Branch B: in IEx, build a context by rebuild and by bind after the
   same `<assign>`, and diff the two structs field by field.
6. Under Branch B: run the full conformance suite before and after and diff the
   counts.

## References

- Source document: `docs/research/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`
- Related ADRs: `docs/adr/0004-predicator-as-the-datamodel.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`,
  `docs/adr/0014-expression-spans-in-cond-diagnostics.md`,
  `docs/adr/0018-no-process-jargon-in-code-comments.md`,
  `docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md`,
  `docs/adr/0026-script-as-predicator-statement-programs.md`
- The sole constructor: `lib/statifier/evaluator.ex:108-113`
- The three rebuild sites: `lib/statifier/machine/content/assign.ex:76-91`,
  `lib/statifier/machine/content/script.ex:95-103`,
  `lib/statifier/machine/content/foreach.ex:276-285`
- The upstream seam: `deps/predicator/lib/predicator/context.ex:240-243`,
  `:256-257`
- The gate guard's `mix.exs` pattern: `lib/mix/statifier/gate_guard.ex:40-43`
- Prior treatment: `docs/research/260812-st-p3t-predicator-5-bump.md:157-298`
- Prior deferrals: `docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md:782-795`,
  `docs/plans/260813-st-af3.4-assign-deep-path-vivification.md:768-780`,
  `docs/plans/260813-st-af3.6-foreach-datamodel-iteration.md:1005-1023`
- Bead: st-sdh

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The three derived terms are internally consistent: `T_fixed <= T_new <=
      T_full` at every size point. An inversion means the scenarios are not
      measuring what they claim and the decomposition is void.
- [ ] The `:corpus` size point matches what the scan in §3 actually reported,
      and is set to the observed maximum rather than the mean. Spot-check it
      against `test/scxml_tests/mandatory/selecting_transitions/test504_test.exs`
      and `test/scion_tests/foreach/test1_test.exs`, both at the 5-root
      maximum.
- [ ] Benchee's reported deviation is small enough that a 5% difference is
      distinguishable from noise; if it is not, raise `time:`/`memory_time:`
      and re-run before trusting anything.
- [ ] No regressions in related features - nothing in `lib/` or `test/` changed,
      so this is a diff review confirming that.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full gate is the phase gate. In interactive execution, pause here for the human
to confirm the manual testing. In looped (`--loop`) execution, Automated
Verification gates advancement via `/wurk:commit --auto` and Manual
Verification is deferred and surfaced at the end.

---

### Phase 2

- [ ] The build-count derivation is right: hand-check one document against the
      call-site table in `docs/research/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`
      section 1, in particular that `execute_block/3` runs once per exited
      state's `<onexit>`, once per entered state's `<onentry>`, and once per
      fired transition's inline content.
- [ ] The `<assign>`-heavy share grows about linearly in `n` and the
      `<foreach>` share about linearly in N; a flat or erratic curve means the
      documents are not exercising what they are meant to.
- [ ] The realistic document is one a reviewer agrees is realistic - this is
      the judgment D1 makes and the one most likely to be argued with.
- [ ] The branch named in the results file follows from the quoted rule
      mechanically, with no discretion exercised.
- [ ] No regressions in related features - `lib/` and `test/` are untouched.

**Implementation Note**: Same as Phase 1.

---

### Phase 3

- [ ] The ADR's Decision section states the branch the pre-registered rule
      selected, and the Context section shows the numbers that selected it.
      A Decision that does not follow from its own Context is the failure mode
      this phase exists to avoid.
- [ ] The moduledoc's two grounds are still true as edited. In particular, if
      Branch B was taken, confirm ground 2 (staleness) is untouched - within-block
      threading never outlives a configuration change, because a block runs
      inside one microstep.
- [ ] `docs/datamodel.md` seam 1 and the moduledoc do not now contradict each
      other, and neither contradicts `docs/datamodel.md:54-59`.
- [ ] Em-dash house style preserved in `lib/statifier/evaluator.ex` and
      `docs/datamodel.md`; the diff shows no incidental punctuation churn.
- [ ] The ADR is a direction-level decision a reviewer would accept as such
      (`docs/workflow.md`), not a note that should have been a comment.
- [ ] Modifier C fired or did not, on its own measured evidence, and if it
      fired both halves of the mirror resolve.
- [ ] No regressions in related features.

**Implementation Note**: Same as Phase 1. Under Branch A the bead's acceptance
criterion is fully satisfied at the end of this phase and Phase 4 is not
executed.

---

### Phase 4

- [ ] Spec-conformance judgment, per this project's plan extension: the touched
      code is spec section 4 executable content, **not** Appendix D - no
      Appendix D function is modified by this phase, and confirming that is the
      check. `git diff --stat lib/statifier/interpreter/` should be empty.
- [ ] A bound context is observationally identical to a rebuilt one at every
      touched site - the change is allocation, never semantics. Walk one
      `<assign>` and one `<foreach>` by hand in IEx and diff the two contexts.
- [ ] `In/1` inside a block still answers against the configuration the block
      started with, which is what it did before; a block does not span a
      microstep, so nothing here can make it stale.
- [ ] The sabotage mutations were genuinely run and genuinely went red.
- [ ] ADR-0028's Consequences match what actually shipped, including the
      `<script>` fallback if it was taken.
- [ ] No regressions in related features.

**Implementation Note**: Same as Phase 1. This phase is the one that touches
`lib/`, so its full gate and the ratchet are both load-bearing.

---
