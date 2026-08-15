# Predicator 8.0 Bump: Structured Compile Errors Implementation Plan

## Overview

Move the `predicator` pin from `~> 7.0` to `~> 8.0` and consume the two
breaking changes 8.0 ships, then settle the three questions the bead attaches
to the bump: whether `normalize: false` is adopted, whether
`Statifier.Evaluator.Functions.base_context/0`'s compile-time hoist survives
upstream's new memoization, and what ADR-0030's cited numbers read against
8.0.

Beads issue: `st-59d`. It absorbs `st-9k4`; `st-i9d` and `st-57w` both depend
on it and are out of scope here.

The center of the work is `lib/statifier/compiler/expressions.ex`: all six
predicator compile entry points now return
`{:error, %Predicator.Errors.ParseError{}}` instead of `{:error, binary()}`,
which deletes both of this module's failure-path re-parses and the moduledoc
paragraphs that explained why they existed.

## Current State Analysis

**The pin.** `mix.exs:41` is `{:predicator, "~> 7.0"}`; `mix.lock:21` resolves
`7.0.0`. `predicator` 8.0.0 was tagged and published on 2026-08-15.

**The consumption sites.** `Predicator`'s compile API is called from exactly
three places in `lib/`:

- `lib/statifier/compiler/expressions.ex:78` - `compile_with_spans/1`, whose
  `{:error, _formatted_message}` arm at `:82` discards the message and calls
  `parse_error/3` (`:187-190`), which **re-parses the source** with
  `Predicator.parse(source, spans: true)` purely to recover a structured
  `{line, column}`, then rebuilds a `ParseError` by hand with
  `ParseError.new/3`.
- `lib/statifier/compiler/expressions.ex:179` -
  `compile_program_with_positions/1`, whose failure arm calls
  `program_parse_error/3` (`:194-197`), the same re-parse through
  `Predicator.parse_program/2`.
- `lib/statifier/compiler/expressions.ex:143` and
  `lib/statifier/event_data.ex:75` - `compile_with_spans/1` inside a `with`
  whose `else` arm is `_failure`, so the error's shape is never inspected.

Both re-parse helpers strictly match predicator's **4-tuple** failure return,
`{:error, message, line, column}`. In 8.0 that tuple is a 5-tuple, so those
two lines would raise `MatchError` rather than mis-bind - the compiler and the
suite cannot hide the change.

**The error value's destination is already structured.**
`Statifier.Compiler.Error` (`lib/statifier/compiler/error.ex:30-32`) already
stores predicator's `%ParseError{}` verbatim in its `reason` tuple, matches on
`%ParseError{position: {line, column}}` at `:65`, and renders
`parse_error.message` plus the position into its own message string at
`:71-73`. **Nothing in that module changes**: 8.0's `ParseError` keeps
`:message` and `:position` with the same types and only adds `:span`.

**The context build path no longer runs `Context.new/2` over the datamodel.**
Since ADR-0030, `Statifier.Evaluator.context/1`
(`lib/statifier/evaluator.ex:160-165`) starts from the compile-time constant
`Statifier.Evaluator.Functions.base_context/0`
(`lib/statifier/evaluator/functions.ex:44-48`, a `%{}` data map), refreshes
`host` with `put_host/2`, and folds `Predicator.Context.bind/3` over the
datamodel roots. The only three `Predicator.Context.new/2` calls left in
`lib/` are over an empty map: `functions.ex:44`, `expressions.ex:141`,
`event_data.ex:73`.

**The benches.** `bench/context_build.exs` and `bench/macrostep.exs` are run
by hand (`mix run bench/<script>.exs`, `bench/README.md:7-21`), take no env
vars or flags, and live outside every gate stage by design
(`bench/README.md:36-58`) - the formatter, Credo, `elixirc_paths`, and the
gate guard all exclude `bench/`. ADR-0030 cites exactly one results file,
`bench/results/260814-st-l0t-provider-host-seam.md`, and every figure in
ADR-0030's Context section comes from it, measured against predicator 7.0.

### Key Discoveries:

- **The re-parse deletion is a straight simplification, and it gains a span.**
  `predicator.ex:913-915` builds every `_with_positions`/`_with_spans` failure
  as `ParseError.new(message, line, column, span)`, and
  `errors/parse_error.ex:29-32` states `:span` is `nil` **only** on an error a
  caller built through `new/3`. So the struct statifier receives at the bump
  carries a real span in every compile mode, where today's hand-built one
  never does - a direct gain for ADR-0014 item 4's "its `:span` (nil when
  predicator cannot attribute one)".
- **`compile_with_spans/1` and `compile_program_with_positions/1` can only
  fail with a `ParseError`.** Both route through `build_compiled_result/1`,
  whose only error clause is the parse 5-tuple
  (`predicator.ex:913-915`). The compiler-stage `{:error, struct()}` arm that
  makes the 8.0 spec say `struct()` rather than `ParseError.t()` exists only
  in `build_instructions_result/1` (`predicator.ex:924-933`), which serves
  `compile/1` and `compile_program/1` - neither of which statifier calls. A
  `%ParseError{}` pattern in the error arm is therefore exact today and stays
  loud if predicator ever widens it.
- **`:normalize` is a `Context.new/2` option only, and it does not persist on
  the struct.** `context.ex:193-198` applies it once at construction;
  `Context.bind/3` (`context.ex:380-383`) calls `normalize_value(value)`
  unconditionally, with no opt-out. Since `context/1` never calls `new/2` over
  the datamodel, `normalize: false` cannot remove statifier's per-root walk
  without abandoning the ADR-0030 build shape entirely.
- **The `px-rnc` memo does not make the hoist redundant.**
  `context.ex:261-284`: every `new/2` call still runs
  `Enum.map(providers, &module_stamp/1)`, and `module_stamp/1` is
  `Code.ensure_loaded?/1` plus `module_info(:md5)` per provider module (five
  modules for builtins plus one), then a `:persistent_term.get/2`, a map
  lookup keyed on the provider list, and a stamp-list comparison. Upstream
  says so itself at `context.ex:150-163`: "the memo removes re-validation, not
  the allocation and struct construction `new/2` does on every call", and
  names calling `new/2` per evaluation as "the anti-pattern this leaves". A
  compile-time module attribute is a literal read; the memoized path is
  strictly more work.
- **The one exact-coordinate assertion in the suite** is
  `test/statifier/compiler/expressions_test.exs:101`
  (`assert {line, column} == {2, 4}` for `"x = 1;\ny ="`). predicator's 8.0.0
  changelog states every message and position reachable from the six compile
  entry points is unchanged from 7.0.0, so this is expected to stay green.
- **Ledger-free.** `lib/mix/statifier/gate_guard.ex:43`'s `mix.exs` pattern
  matches gate-config lines (`test_coverage`, `dialyzer:`, `aliases`,
  `:ex_quality`, `:credo`, `:excoveralls`, `:dialyxir`, `:sobelow`,
  `:doctor`). A `{:predicator, ...}` line matches none of them, so this bump
  needs no `docs/quality-gate-changes.md` entry (ADR-0011).
- **No changelog fragment.** `changelog.d/README.md:40-50` narrows the rule
  while v2 is unreleased to "write a fragment when v2 differs from v1"; a
  dependency pin move that changes no answer for any document does not.

## Desired End State

`mix.exs` pins `~> 8.0`, `mix.lock` resolves `8.0.x`, and:

1. `Statifier.Compiler.Expressions` has no `parse_error/3` and no
   `program_parse_error/3`. Both public entry points match
   `{:error, %ParseError{} = parse_error}` and hand that struct straight to
   `Statifier.Compiler.Error.expression_compile_error/4`. The moduledoc
   paragraphs describing the formatted-string wart and the recovery asymmetry
   are gone, replaced by a statement of what 8.0 returns, version-stamped to
   8.0.0.
2. No site in `lib/` or `test/` matches predicator's old 4-tuple parse or
   tokenize failure.
3. `bench/results/260815-st-59d-predicator-8-0.md` records a full re-run of
   both benches against 8.0, in the same table shape as
   `bench/results/260814-st-l0t-provider-host-seam.md`, with a comparison
   against that file's After tables.
4. `base_context/0` and its hoist are unchanged in behavior, and the comment
   at `lib/statifier/evaluator/functions.ex:29-43` states the 8.0 reason it
   stays. ADR-0030's `px-rnc` consequence carries a dated amendment saying the
   memo landed and the hoist was kept, with the measured basis.
5. `normalize: false` is **not** adopted, and the reason is recorded where a
   future reader meets the question: `lib/statifier/evaluator.ex`'s cost
   paragraph and `docs/datamodel.md` item 1.
6. Full `mix quality` is green, both conformance suites run, and
   `test/passing_tests.json` is unchanged or extended - never shrunk.

Verify by: `mix quality` (full, unprofiled, unscoped) plus `mix gate.verify`;
`mix test --include scion --include scxml_w3`; `mix test.regression`;
`grep -rn "predicator" mix.exs mix.lock docs/datamodel.md` showing `8.0`; and
reading the new results file beside ADR-0030.

## What We're NOT Doing

- **`:protected_roots` on `execute/3`** - bead `st-i9d`, which depends on this
  one. The spec 5.10 gap at `lib/statifier/evaluator.ex:283-296`, the
  write-then-restore test, and the fate of the post-hoc diff check are all
  that bead's, not this one's. The gap itself is the "Known and accepted gap"
  paragraph in `run_program/2`'s `@doc`
  (`lib/statifier/evaluator.ex:366-379`), which already names "a
  protected-roots option on `Predicator.execute/3`" as the upstream shape
  that would close it. The bead's own citation of `:283-296` predates later
  edits to that file; read the paragraph, not the line range.
- **`compile_program_with_spans/1`** - bead `st-57w`, which depends on this
  one. `compile_program/3` keeps calling
  `Predicator.compile_program_with_positions/1` here; moving it to the new
  span entry point is ADR-0014 item 1's commitment and belongs with that
  bead's moduledoc rewrite. **This plan does delete the re-parse inside
  `program_parse_error/3`**, because that deletion is forced by the
  breaking change (the formatted string it re-parsed no longer exists), not by
  the spans work.
- **Adopting `normalize: false`.** Declined on the evidence above and recorded
  in Phase 3 rather than left silent. Adopting it would mean replacing
  `context/1`'s `base_context/0` + `bind/3`-per-root path with a
  `Context.new(undefine_nils(datamodel), normalize: false, ...)` per build -
  trading a size-scaling walk for `new/2`'s per-call stamp-and-allocate work
  and abandoning the hoist ADR-0030 decided. That is a design change with an
  ADR amendment attached, not a bump consumption, and nothing measured
  supports it.
- **A key guard on `MachineState.new/2`'s `:datamodel` option.** That option
  (`lib/statifier/machine_state.ex:259-263`, merged at `:276`) is the only
  unguarded key source in the system: a consumer passing `%{foo: 1}` gets a
  `FunctionClauseError` from `Context.bind/3` at build time rather than at the
  boundary. Worth its own bead; it is a public-API hardening decision, and it
  only becomes urgent if the `normalize: false` vouch is ever taken, which
  this plan declines.
- **Corpus regeneration.** 8.0 adds no reserved words (verified against the
  v8.0.0 tag on the bead), so no `mise run corpus` sweep is owed.
- **Repairing `docs/research/*` and older `docs/plans/*` pin citations.** They
  are dated snapshots and correct as written.
- **A changelog fragment**, per `changelog.d/README.md:40-50`. If Phase 1's
  conformance run shows any document answering differently under 8.0, that
  finding reverses this and a `changelog.d/st-59d.md` fragment is written in
  the same phase.

## Implementation Approach

Three phases, in dependency order. Phase 1 is the whole breaking-change
consumption and must be one commit: the pin move and the `expressions.ex`
rework do not compile apart from each other. Phase 2 measures 8.0 with the
Phase 1 tree in place, because the decisions in Phase 3 are stated against
those numbers. Phase 3 records both decisions and amends ADR-0030.

**The Appendix D criterion is declined explicitly, not omitted.**
`.claude/wurk/plan.md` asks every phase touching `lib/statifier/` for a manual
criterion that the touched functions match the W3C Appendix D pseudocode line
for line. No function this plan touches is an Appendix D procedure:
`Statifier.Compiler.Expressions` is a compile-time seam that runs before the
interpreter exists, and Phase 3 touches only comments and moduledocs in
`Statifier.Evaluator` and `Statifier.Evaluator.Functions`, changing no
behavior at all. The pseudocode has nothing to say about either, so each phase
carries the nearest criterion that does bite - ADR-0014 item 4's payload for
Phase 1, and a no-behavior-change reading for Phase 3 - rather than a
spec-conformance box that would be checked without being read. If Phase 1's
conformance run moves any result, that is the signal that interpreter behavior
did change after all, and the Appendix D reading is owed on whatever function
explains the move.

Phase 2 touches only `bench/` and `bench/results/`, neither of which the gate
compiles; its bar is therefore a green full gate plus the human reading of the
numbers. That is the same shape `docs/plans/260814-st-l0t-provider-host-seam-for-in1.md`
Phase 3 used.

---

## Phase 1: Move the pin and consume the structured compile errors

### Overview

Bump `~> 7.0` to `~> 8.0`, delete both failure-path re-parses, restamp the
version-stamped claims in the touched files, and prove the conformance
suites and the ratchet did not move.

### Changes Required:

#### 1. The pin

**File**: `mix.exs`
**Changes**: line 41, `{:predicator, "~> 7.0"}` becomes
`{:predicator, "~> 8.0"}`. Then `mix deps.get`, which rewrites `mix.lock:21`
to `8.0.x`. Confirm with `mix deps` that `predicator` is `8.0.0` or newer
before touching anything else - the rest of this phase reads
`deps/predicator/` for its line citations.

#### 2. The compile failure arms

**File**: `lib/statifier/compiler/expressions.ex`
**Changes**: both entry points take the struct predicator now returns;
`parse_error/3` (`:185-190`) and `program_parse_error/3` (`:192-197`) are
deleted outright. The `alias Predicator.Errors.ParseError` at `:17` stays -
the new error patterns below use it.

```elixir
def compile(source, owner, %Location{} = location)
    when is_binary(source) and is_tuple(owner) do
  case Predicator.compile_with_spans(source) do
    {:ok, %Predicator.Compiled{} = compiled} ->
      {:ok, {:compiled, compiled, source}}

    {:error, %ParseError{} = parse_error} ->
      {:error, Error.expression_compile_error(owner, source, parse_error, location)}
  end
end

def compile_program(source, owner, %Location{} = location)
    when is_binary(source) and is_tuple(owner) do
  case Predicator.compile_program_with_positions(source) do
    {:ok, %Predicator.Compiled{} = compiled} ->
      {:ok, {:program, compiled, source}}

    {:error, %ParseError{} = parse_error} ->
      {:error, Error.expression_compile_error(owner, source, parse_error, location)}
  end
end
```

Matching `%ParseError{}` rather than `_error` is deliberate and is the
phase's one judgment call: both of these entry points route through
predicator's `build_compiled_result/1`, whose sole error clause builds a
`ParseError`, so the narrow pattern is exact today and raises loudly rather
than silently re-shaping the error if a future predicator widens the arm.

#### 3. The moduledoc and `@doc` paragraphs that documented the wart

**File**: `lib/statifier/compiler/expressions.ex`
**Changes**:

- `compile/3`'s `@doc`, lines 68-72: delete the whole "On failure,
  `compile_with_spans/1` reports only a formatted string ... spans are a
  property of successfully parsed AST nodes, not of the error tuple"
  paragraph. Replace with a statement that the failure arm is
  `%Predicator.Errors.ParseError{}` carrying the parser's bare message in
  `:message`, `{line, column}` in `:position`, and the failing token's extent
  in `:span` - stamped to the installed 8.0.0 dependency
  (`deps/predicator/lib/predicator.ex`'s `build_compiled_result/1` and
  `deps/predicator/lib/predicator/errors/parse_error.ex`), with the line
  numbers read off the installed copy rather than copied from this plan.
- `compile_program/3`'s `@doc`, lines 166-173: delete the recovery paragraph
  and the "asymmetry with `compile/3`'s recovery path is deliberate" note.
  There is no asymmetry left: both entry points now take the struct
  predicator hands them. Say instead that the error is the same
  `%ParseError{}` shape, and that spans on a program **parse** failure come
  from the token stream, which is why one is present here even though this
  function compiles with positions rather than spans.
- The moduledoc's ADR-0014 paragraph (`:10-14`) is unchanged and still true:
  `compile/3` still calls `compile_with_spans/1`. Do not touch it - moving
  `compile_program/3` onto `compile_program_with_spans/1` is `st-57w`.

#### 4. Verify the 4-tuple and token-shape changes are no-ops

**Files**: none expected to change
**Changes**: after the deletions in item 2, confirm nothing is left:

```bash
grep -rn "Predicator.parse\|Predicator.parse_program\|Lexer.tokenize\|Predicator.Lexer" lib test bench
```

The expected result is no hits outside generated corpora. Record the empty
result in the commit body; this is the bead's breaking-change item 2,
consumed as a verified no-op.

#### 5. Tests

**File**: `test/statifier/compiler/expressions_test.exs`
**Changes**:

- The sabotage comment at `:85-90` names `Predicator.parse_program/2` and a
  "recovered `{line, column}`" that no longer exist. Rewrite it against the
  new code path - for example: `# sabotage: in compile_program/3's failure
  arm, replace parse_error with ParseError.new("x", 1, 1) -> the reported
  position stops matching predicator's actual failure site, and this test
  goes red`. Sabotage each rewritten line for real per `docs/testing.md`:
  break the code, watch it redden, revert.
- Keep `assert {line, column} == {2, 4}` at `:101`. If 8.0 reports a
  different coordinate for `"x = 1;\ny ="`, that contradicts predicator's own
  changelog claim that compile-reachable positions are unchanged; update the
  expected value **and** note the discrepancy in the commit body rather than
  silently adjusting it.
- Add one new test binding the span the bump gains, with its own sabotage
  line: `compile/3`'s and `compile_program/3`'s collected `%ParseError{}` has
  a non-nil `:span` of shape `{{sl, sc}, {el, ec}}` with `position` equal to
  the span's start. This is the observable difference between the hand-built
  `ParseError.new/3` value and predicator's own, and it is what keeps the
  deleted re-parse from creeping back.

**File**: `test/statifier/compiler/acceptance_test.exs`
**Changes**: expected to need none. Its `~r/predicator line \d+, column \d+/`
at `:183` matches statifier's own `Compiler.Error` message format
(`lib/statifier/compiler/error.ex:71-73`), not predicator's, and that format
does not change here. Confirm by running it.

#### 6. Pin citations in prose

**Files**: `docs/datamodel.md:4`,
`docs/adr/0004-predicator-as-the-datamodel.md:8`,
`docs/adr/0026-script-as-predicator-statement-programs.md:16`
**Changes**: `~> 7.0` becomes `~> 8.0`, and ADR-0004's "pinned `~> 7.0` since
st-5ma" becomes "pinned `~> 8.0` since st-59d". These are factual pin
citations that each prior bump has updated in place; nothing about the
decisions they record changes.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` used between edits while iterating (never
      as this phase's bar).
- [x] Full `mix quality` is green, unprofiled and unscoped.
- [x] `mix gate.verify` exits zero, proving the green above was a full gate.
- [x] `mix deps` reports `predicator 8.0.x`; `grep -n predicator mix.lock`
      shows `8.0`.
- [x] `grep -rn "Predicator.parse\|Predicator.Lexer" lib test bench` returns
      nothing outside generated corpora.
- [x] `mix test --include scion --include scxml_w3` run, and the pass set
      compared against the run on the pre-bump tree.
- [x] `mix test.regression` is green; `test/passing_tests.json` is byte
      identical or extended via `mix test.baseline add`, never shrunk.
- [x] `mix quality --format json --report -` captured if `/wurk:implement`
      needs to route on stage results.

#### Manual Verification:

- [ ] The version-stamped claims in the rewritten `@doc` paragraphs are read
      off the installed `deps/predicator/` at 8.0.0, line numbers included -
      not recalled and not copied from this plan.
- [ ] `Statifier.Compiler.Expressions.compile/3` and `compile_program/3` are
      read against what the caller needs from an expression failure per
      ADR-0014 item 4 (owner identity, source, error struct, span): all four
      are present, and `:span` is now non-nil where it used to be nil.
- [ ] Any conformance test whose result moved between the pre-bump and
      post-bump runs is explained, not just ratcheted - a document answering
      differently under 8.0 is a user-visible behavior change and reverses
      this plan's no-fragment decision.
- [ ] No regressions in related features: expression compilation, `<script>`
      program compilation, and `<data>` inline-value folding all still behave
      as their tests describe.
- [ ] The Appendix D spec-conformance criterion is declined for this phase for
      the reason given under "Implementation Approach": no function touched
      here is an Appendix D procedure. If the conformance diff in the criterion
      above is non-empty, this declination lapses and the Appendix D reading is
      owed on the function that explains the move.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Re-run both benches against 8.0 and record the numbers

### Overview

ADR-0030's cited figures were measured against predicator 7.0, before
`px-rnc` memoized `resolve_functions/1`. Re-run both benches on the Phase 1
tree and record an 8.0 capture, plus one new scenario that measures the
`normalize: false` path Phase 3 declines, so the refusal rests on a number
rather than on reasoning alone.

### Changes Required:

#### 1. One new scenario in the context-build bench

**File**: `bench/context_build.exs`
**Changes**: add a fifth term to Run 1's map, beside `T_new`, measuring the
build shape a `normalize: false` adoption would use. The workload already
supplies the nil-free twin (`clean`) and the resolved functions map (`fns`).

```elixir
"T_new_nf Context.new/2, no nils, normalize: false" => fn %{clean: d, fns: f} ->
  Context.new(d, functions: f, on_unbound: :error, normalize: false)
end,
```

Extend the comment block at `:16-40` with a line naming what the new row is
evidence for: `T_new` minus `T_new_nf` is the size-scaling normalization walk
`normalize: false` removes, and `T_new_nf` against `T_full` is the whole
candidate path against the shipped one. Nothing in `lib/` changes.

The comparison is fair without any workload edit: `Workload.datamodel/3`
(`bench/support/workload.exs:33-45`) keys every level with `"root#{i}"` and
`"child#{j}"`, so `clean` already satisfies the invariant `normalize: false`
asks a caller to vouch for, and the two rows differ only in whether the walk
runs.

#### 2. Run both scripts and record

**Files**: new `bench/results/260815-st-59d-predicator-8-0.md`
**Changes**: run

```bash
mix run bench/context_build.exs
mix run bench/macrostep.exs
```

on the same machine, back to back, and write the results file in the shape of
`bench/results/260814-st-l0t-provider-host-seam.md`: a `## Machine` block
(OS, CPU, cores, RAM, Elixir, OTP, benchee versions), a table per benchee run,
and a `## Comparison` section against that file's **After** tables - which are
the 7.0 numbers for the identical code path, so the delta isolates the
dependency. Report time deltas against each run's own deviation band and say
so when a delta is inside it, exactly as the l0t file does; do not smooth an
apparent regression away.

The file must state which of ADR-0030's five cited figures it confirms and
which it restates:

- `put_host/2` at `:corpus` (was 0.0330 us / 0.0859 KB)
- `resolve_functions/1` provider versus closure (was 1.36 versus 1.40 us) -
  note that upstream now memoizes this call, so both rows may drop together;
  ADR-0030's claim is that they match each other, not that they are slow
- `T_fixed / T_full` at `:corpus` (was 56.6%)
- `T_full` at `:corpus` (was 2.30 us / 10.92 KB before the hoist, 1.13 us /
  4.77 KB after)
- `measured macrostep`, `realistic` (was 17.39 -> 13.58 us, 74.19 -> 43.18 KB)

#### 3. Point the bench index at the new file

**File**: `bench/README.md`
**Changes**: one line in "What each script measures" naming
`bench/results/260815-st-59d-predicator-8-0.md` as the current capture, beside
the existing pointers to the 260814 files. The older files stay - they are the
7.0 record.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` used between edits while iterating.
- [x] Full `mix quality` is green, and `mix gate.verify` exits zero. `bench/`
      is outside every stage (`bench/README.md:36-58`), so this proves only
      that nothing else moved - which is the point of committing the phase
      alone.
- [x] `mix run bench/context_build.exs` and `mix run bench/macrostep.exs`
      both complete without raising, with `predicator 8.0.x` in `mix.lock`.
- [x] `bench/results/260815-st-59d-predicator-8-0.md` exists and names every
      scenario both scripts printed.

#### Manual Verification:

- [ ] Both scripts were run on one machine, back to back, and the machine
      block in the results file describes that machine.
- [ ] Each of ADR-0030's five cited figures is explicitly confirmed or
      restated in the results file, with the 7.0 value beside the 8.0 one.
- [ ] Every time delta is read against its own deviation band, and any delta
      inside the band is reported as noise rather than as a win or a
      regression.
- [ ] `T_new_nf` is present at all four size points, so Phase 3's refusal has
      a corpus-scale number and a stress-scale one.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Record both decisions and amend ADR-0030

### Overview

Two questions the bead attaches to the bump are decided here, both in the
keep-what-we-have direction, and both written where the next reader meets
them rather than only in this plan. No behavior changes in this phase; every
edit is a comment, a doc paragraph, or an ADR amendment.

### Changes Required:

#### 1. The hoist stays, and says why

**File**: `lib/statifier/evaluator/functions.ex`
**Changes**: extend the comment above `@base_context` (`:29-43`) with the 8.0
reason it survives upstream's memoization. The substance, in this project's
comment voice and with the line numbers read off the installed 8.0.0 copy:

`Context.resolve_functions/1`'s provider validation is memoized in
`:persistent_term` as of predicator 8.0, so a `Context.new/2` call no longer
re-pays `Code.ensure_loaded?/1` plus `function_exported?/3` per entry. It
still pays, on every call, one `Code.ensure_loaded?/1` and one
`module_info(:md5)` per provider module to compute the cache stamp, plus a
`:persistent_term.get/2`, a map lookup keyed on the provider list, and a
stamp-list comparison - and then allocates the struct. A module attribute is a
compile-time literal read and costs none of that; predicator's own docs
(`deps/predicator/lib/predicator/context.ex`, the `## Performance` section)
say the memo "removes re-validation, not the allocation and struct
construction `new/2` does on every call" and still name per-evaluation `new/2`
as the anti-pattern. So the hoist is kept: ADR-0030's Decision stands
unamended in substance.

No ADR-0018 process jargon in this comment: no bead ids, no phase numbers, no
"we decided". State the mechanism and the measurement.

#### 2. `normalize: false` is declined, and says why

**File**: `lib/statifier/evaluator.ex`
**Changes**: in the moduledoc cost paragraph (`:82-104`), add the refusal to
the existing explanation of why `context/1` never calls `Context.new/2`.
Substance: predicator 8.0 offers a `normalize: false` option on
`Context.new/2` that skips the deep `normalize_value/1` walk on a caller's
vouch that `data` is string-keyed at every level. It buys this path nothing,
because this path does not call `new/2`: the constant it starts from holds an
empty `data`, and each root arrives through `Context.bind/3`, which
normalizes its value unconditionally with no opt-out. Taking the vouch would
mean rebuilding the whole context per site with `new/2` to get one walk
instead of two - trading a size-scaling term for `new/2`'s per-call
stamp-and-allocate work, and giving up the compile-time constant. Cite the
`T_new_nf` and `T_full` rows from the Phase 2 results file for what that trade
measures.

**File**: `docs/datamodel.md`
**Changes**: item 1 of the upstream-seams list (`:122-148`) gains two
sentences: the fixed-term resolution is memoized upstream as of predicator
8.0 and the compile-time hoist is kept anyway for the reason above; and the
`normalize: false` seam exists but is not taken here, because this path binds
per root rather than constructing per build. Keep the file's existing voice
and its ADR cross-references.

#### 3. One stale normalization claim, repaired

**File**: `lib/statifier/evaluator/system_variables.ex`
**Changes**: the moduledoc (`:9-14`) says a `nil` written here "becomes the
spec-correct 'not bound' answer" because "`Predicator.Context.new/2`
normalizes `nil` to `:undefined` recursively". That stopped being true in
predicator 6.0, which made `nil` the null literal's own value - the recursion
that saves these fields is now statifier's own `undefine_nils/1`
(`lib/statifier/evaluator.ex:201-209`), as that function's comment already
records. Repoint the claim at `undefine_nils/1` and drop the dead
`context.ex:190-237` citation. The conclusion is unchanged; only its reason
is wrong today.

This is a pre-existing staleness rather than something 8.0 introduced, and it
is repaired here because the bump is when this project re-verifies its
version-stamped claims about predicator's normalization - and because leaving
it beside Phase 3's new, correct paragraph about the same walk would leave two
contradictory statements in `lib/`.

#### 4. `ADR-0030` gains a dated amendment

**File**: `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md`
**Changes**: two edits, both additive - the Decision is not reopened.

- The `px-rnc` consequence (`:143-153`) currently reads as a forecast ("If
  `px-rnc` lands, it would make this record's compile-time hoist redundant
  rather than wrong"). Append a dated amendment in the style ADR-0014 item 2
  uses (`*(Amended 2026-08-15: ...)*`): the memo shipped in predicator 8.0.0,
  the hoist was kept, and the reason is the residual per-call cost named in
  item 1 above. Say plainly that "redundant" turned out to be too strong: the
  memo removes re-validation, not the per-call stamp computation and
  allocation, so the constant is still the cheaper way to get the value.
- The three measured facts in Context (`:27-48`) are 7.0 measurements. Add one
  dated sentence saying so and pointing at
  `bench/results/260815-st-59d-predicator-8-0.md` for the 8.0 restatement.
  Do not overwrite the 7.0 figures: they are the evidence the decision was
  taken on.

**File**: `docs/adr/README.md`
**Changes**: ADR-0030's Status cell becomes
`accepted (amended 2026-08-15: predicator 8.0 memoization; hoist kept)`,
matching the convention rows 0002, 0004, 0016, 0019 and 0026 already use.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` used between edits while iterating.
- [x] Full `mix quality` is green, and `mix gate.verify` exits zero. This
      phase's ADR edits put `mix adr.check` on the critical path, so its
      passing is a real check here rather than a formality.
- [x] `grep -rn "Context.new(" lib` shows the same three call sites as before
      this plan, all over an empty map and none passing `:normalize` - the
      option is declined in code, whatever the prose says about it.
- [x] `grep -rn "base_context" lib docs` shows the hoist still present and
      described consistently in both places.
- [x] `grep -rn "context.ex:190-237" lib` returns nothing - the dead citation
      in `system_variables.ex` is gone.

#### Manual Verification:

- [ ] Every number quoted in the new comments and doc paragraphs matches the
      Phase 2 results file exactly.
- [ ] The ADR-0030 amendment adds and dates; it does not rewrite the 7.0
      figures or reopen the Decision.
- [ ] The new comments carry no process jargon (ADR-0018): no bead ids, no
      phase numbers, no plan references in `lib/`.
- [ ] `lib/statifier/evaluator/functions.ex`'s `in_state/2` and
      `lib/statifier/evaluator.ex`'s `context/1` still read as the ADR-0030
      shape they document, with no behavior edit smuggled into a comment
      phase.
- [ ] `system_variables.ex`'s repaired paragraph and `undefine_nils/1`'s own
      comment now say the same thing about where `nil` becomes `:undefined`,
      and neither claims `Predicator.Context.new/2` does it.
- [ ] The Appendix D spec-conformance criterion is declined for this phase for
      the reason given under "Implementation Approach": this phase changes no
      behavior, and none of the three modules it comments is an Appendix D
      procedure. `git diff` showing only comment, moduledoc, and `docs/` lines
      is what makes that declination true rather than assumed.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/compiler/expressions_test.exs` - the existing failure tests
  keep asserting owner, source, and `%ParseError{position: {line, column}}`;
  their sabotage lines are rewritten against the new code path and re-proven
  by actually breaking the code. One new test binds the `:span` the bump
  gains, which is the only externally visible difference between the deleted
  hand-built error and predicator's own.
- `test/statifier/compiler/acceptance_test.exs` - unchanged, and its passing
  is the check that `Statifier.Compiler.Error`'s message format survived the
  bump untouched.
- `test/statifier/evaluator_test.exs` - the `context/1` equivalence test
  (`:493-518`) asserts the bind-per-root path produces what a whole-map
  `Context.new/2` would. It is untouched by this plan and is exactly the test
  that would have to be rewritten if `normalize: false` were ever adopted;
  its continued passing under 8.0 is a check that `bind/3`'s normalization
  semantics did not move.
- Edge cases worth an eye during Phase 1: a program failing on line 2 (the
  `{2, 4}` assertion), a failure at end of input (8.0 reports a zero-width
  span there), and a source containing a multi-line string literal, whose
  span values moved in 8.0.

### Manual Testing Steps:

1. On the pre-bump tree, run `mix test --include scion --include scxml_w3` and
   save the summary line and the failure list.
2. Apply Phase 1, run the same command, and diff the two pass sets. Explain
   every move in either direction before ratcheting anything.
3. Run `mix test.regression` and confirm `test/passing_tests.json` is
   unchanged or extended.
4. Run both bench scripts (Phase 2) and read the `:corpus` rows against
   ADR-0030's cited values.
5. Read the rewritten `expressions.ex` docs beside
   `deps/predicator/lib/predicator.ex` at 8.0.0 and confirm every citation
   resolves to the line it names.

## Corpus/Ratchet Notes

No corpus regeneration is owed: predicator 8.0 adds no reserved words
(verified against the v8.0.0 tag and recorded on the bead), so the
`conf_predicator.xsl` rewrite rules that a reserved word would break are
untouched, and `mise run corpus` is not run in this plan.

The ratchet can only move in one direction here. Two 8.0 fixes turn parser
crashes into error values (a bare `.` and a string token in a rejected
position), which can only turn a raising compile into a collected
`Compiler.Error` - so a corpus file that failed on a crash may now fail
cleanly, or pass. If any test newly passes, add it with
`mix test.baseline add` and name it in the commit body. If any test newly
fails, stop: that is a real regression from the bump, not a ratchet question.
`test/passing_tests.json` is never shrunk (`docs/testing.md`), and shrinking
it would demand a `docs/quality-gate-changes.md` entry only a human may write
(ADR-0011).

## Performance Considerations

The bump moves two costs on the context-build path and this plan takes
neither of the moves as a design change:

- **The fixed term shrinks.** `resolve_functions/1`'s provider validation is
  memoized in `:persistent_term` upstream. `context/1` does not call it at
  all (the resolved map is a compile-time constant), so the shrink shows up
  only in the `T_fixed` and `T_resolve_*` bench rows, not in `T_full`.
  ADR-0030's 56.6% `T_fixed / T_full` share was measured before the memo and
  is restated, not re-decided, in Phase 2.
- **The size-scaling term does not move.** `normalize: false` is a
  `Context.new/2` option; `bind/3` normalizes unconditionally
  (`deps/predicator/lib/predicator/context.ex`, `bind/3`), and `context/1`
  binds per root. Statifier's own `undefine_nils/1` walk plus `bind/3`'s
  `normalize_value/1` walk therefore both remain. Collapsing them to one walk
  is possible only by rebuilding with `new/2` per site, which reintroduces
  the per-call cost the hoist exists to avoid; Phase 2's `T_new_nf` row
  measures that trade and Phase 3 records the refusal.

Expected net effect on a macrostep: nothing measurable, because the path the
bump makes cheaper is a path this library already avoided. Phase 2 exists to
confirm that rather than to assume it.

## References

- Bead: `st-59d` (absorbs `st-9k4`; blocks `st-i9d` and `st-57w`)
- `docs/adr/0014-expression-spans-in-cond-diagnostics.md` - items 1, 2 and 4:
  spans not point positions, the `%Predicator.Compiled{}` envelope, and what
  an expression failure names
- `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md` -
  the hoist, the `px-rnc` forecast this plan amends, and every 7.0 figure
- `docs/adr/0011-quality-gate-config-not-agent-editable.md` - why the ratchet
  is never shrunk here
- `docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md` rule 1 -
  predicator owns the shape of its own memoization and of `:normalize`; this
  repo owns when the pin moves
- `docs/datamodel.md` - the pin citation and the upstream-seams list
- `bench/results/260814-st-l0t-provider-host-seam.md` - the 7.0 capture the
  Phase 2 file compares against
- `docs/plans/260814-st-l0t-provider-host-seam-for-in1.md` - the plan that
  built the shape this one measures again
- `lib/statifier/compiler/expressions.ex`, `lib/statifier/compiler/error.ex`,
  `lib/statifier/evaluator.ex`, `lib/statifier/evaluator/functions.ex` - the
  four files this plan reads and the two it edits
- predicator 8.0.0 `CHANGELOG.md`, the `8.0.0` section - the two BREAKING
  bullets and the memoization bullet

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The version-stamped claims in the rewritten `@doc` paragraphs are read
      off the installed `deps/predicator/` at 8.0.0, line numbers included -
      not recalled and not copied from this plan.
- [ ] `Statifier.Compiler.Expressions.compile/3` and `compile_program/3` are
      read against what the caller needs from an expression failure per
      ADR-0014 item 4 (owner identity, source, error struct, span): all four
      are present, and `:span` is now non-nil where it used to be nil.
- [ ] Any conformance test whose result moved between the pre-bump and
      post-bump runs is explained, not just ratcheted - a document answering
      differently under 8.0 is a user-visible behavior change and reverses
      this plan's no-fragment decision.
- [ ] No regressions in related features: expression compilation, `<script>`
      program compilation, and `<data>` inline-value folding all still behave
      as their tests describe.
- [ ] The Appendix D spec-conformance criterion is declined for this phase for
      the reason given under "Implementation Approach": no function touched
      here is an Appendix D procedure. If the conformance diff in the criterion
      above is non-empty, this declination lapses and the Appendix D reading is
      owed on the function that explains the move.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] Both scripts were run on one machine, back to back, and the machine
      block in the results file describes that machine.
- [ ] Each of ADR-0030's five cited figures is explicitly confirmed or
      restated in the results file, with the 7.0 value beside the 8.0 one.
- [ ] Every time delta is read against its own deviation band, and any delta
      inside the band is reported as noise rather than as a win or a
      regression.
- [ ] `T_new_nf` is present at all four size points, so Phase 3's refusal has
      a corpus-scale number and a stress-scale one.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 3

- [ ] Every number quoted in the new comments and doc paragraphs matches the
      Phase 2 results file exactly.
- [ ] The ADR-0030 amendment adds and dates; it does not rewrite the 7.0
      figures or reopen the Decision.
- [ ] The new comments carry no process jargon (ADR-0018): no bead ids, no
      phase numbers, no plan references in `lib/`.
- [ ] `lib/statifier/evaluator/functions.ex`'s `in_state/2` and
      `lib/statifier/evaluator.ex`'s `context/1` still read as the ADR-0030
      shape they document, with no behavior edit smuggled into a comment
      phase.
- [ ] `system_variables.ex`'s repaired paragraph and `undefine_nils/1`'s own
      comment now say the same thing about where `nil` becomes `:undefined`,
      and neither claims `Predicator.Context.new/2` does it.
- [ ] The Appendix D spec-conformance criterion is declined for this phase for
      the reason given under "Implementation Approach": this phase changes no
      behavior, and none of the three modules it comments is an Appendix D
      procedure. `git diff` showing only comment, moduledoc, and `docs/` lines
      is what makes that declination true rather than assumed.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---
