---
date: 2026-08-19
issue: st-hbdr
title: Ships the chart-author test helpers as a public API
status: draft
---

# Chart-author test helpers as public API - Implementation Plan

## Overview

Promote `Statifier.Case` and `Statifier.FeatureDetector` out of `test/support/`
and into `lib/` as `Statifier.Testing.Case` and
`Statifier.Testing.FeatureDetector`, so a downstream application that depends on
`statifier` can write declarative chart tests (initial configuration, then
`{event, expected_configuration}` steps) without copying harness files. Thin
`test/support` shims keep the 281 generated corpus files and the `tools/corpus`
generators working untouched. Direction is settled by
[ADR-0052](../adr/0052-chart-test-helpers-ship-in-lib-under-statifier-testing.md),
which amends [ADR-0006](../adr/0006-reuse-conformance-corpus-and-regression-ratchet.md)
in part. Bead: st-hbdr.

## Current State Analysis

**Where the helpers live today.**

- `test/support/case.ex` - `Statifier.Case`, an `ExUnit.CaseTemplate` whose
  `test_scxml/4` (case.ex:118) drives a document either synchronously through
  `Statifier`'s four-function API or through a `Statifier.Session`, and asserts
  the configuration after each step. `session_required?/1` (case.ex:139) is the
  routing predicate.
- `test/support/feature_detector.ex` - `Statifier.FeatureDetector`, three public
  functions: `detect_features/1` (:37), `feature_registry/0` (:52),
  `validate_features/1` (:129). All three carry `@doc` and `@spec`.
- `mix.exs:38` - `elixirc_paths(:test), do: ["lib", "test/support"]`;
  `elixirc_paths(_), do: ["lib"]`. Downstream gets `lib/` only.
- 281 generated corpus files under `test/scion_tests/` and `test/scxml_tests/`
  say `use Statifier.Case, async: true` and call `test_scxml/4` unqualified.
- `tools/corpus/scion/cases.exs:18` and `tools/corpus/scxml_w3/cases.exs:32`
  each `Code.require_file(".../test/support/feature_detector.ex")` and call
  `Statifier.FeatureDetector.detect_features/1`, because `mix run` is `:dev`
  and `test/support` is not compiled there.

**The rules that stand in the way**, both amended by ADR-0052 decision 3:

- `docs/testing.md:348-351` - "Feature detection lives in `test/support`, not
  `lib/` - it is harness code, not library surface."
- `test/support/feature_detector.ex:20` - "This is harness code, not library
  surface: nothing in `lib/` may reference it."

**Verified facts about the quality regime** (measured, not assumed):

- **Coverage.** With `coveralls.json`'s `skip_files` temporarily emptied,
  `MIX_ENV=test mix coveralls` reports `test/support/feature_detector.ex` at
  **100.0%** and `test/support/case.ex` at **90.1%** (81 relevant lines, 8
  uncovered), with a whole-project `[TOTAL]` of 96.3%. The 90% floor is a
  project total, not a per-file bar, so promotion does not put it at risk.
  The 8 uncovered lines in `case.ex` are:
  - 309-321 - the entire `validate_features!/2` flunk block and
    `format_features/1`.
  - 380 - the `flunk("Sent ... to a state chart that has terminated")` branch of
    `send_event/2`.
  - 256, 259 - `poll_until_settled/4`'s "stable twice in a row" and "deadline
    reached" exits.
- **The fail-not-skip guarantee is currently asserted vacuously.** This
  contradicts ADR-0052's Consequences claim that both modules "already have
  direct tests ... so this is pressure to keep, not a gap to open."
  `test/statifier/case_test.exs:16` is named "never skips - an unsupported
  document fails the test" and feeds a document using `cond=`. Measured:
  `detect_features/1` returns
  `[:eventless_transitions, :conditional_transitions, :basic_states, :event_transitions]`
  and `validate_features/1` returns `{:ok, _}` for that set - the flunk branch
  is never reached, and the `assert_raise ExUnit.AssertionError` passes for an
  unrelated reason. It is also unreachable *by construction* today:
  `case_test.exs:8` asserts that every atom in the registry is `:supported` or
  `:partial`, so no document can produce an `{:error, _}` from
  `validate_features/1`. Publishing fail-not-skip as a documented feature makes
  this gap material, so this plan fixes the misleading test rather than
  inheriting it.
- **Doctor.** `.doctor.exs` holds 100% on every axis. Doctor derives its
  denominator from the source AST and counts only `:def` -
  `deps/doctor/lib/module_information.ex:190-222` matches `:def` clauses only,
  never `:defp` and never `:defmacro`, and `module_report.ex:49,87,124` divides
  by `user_defined_functions`. The `__using__/1` injected by
  `use ExUnit.CaseTemplate` is macro-generated and never appears in the source
  AST, so it is not counted. Both promoted modules have `@moduledoc`, and every
  `def` in them has `@doc` and `@spec`. **Doctor passes without new work.**
- **`elixirc_paths` is genuinely untouched.** Confirmed by construction: after
  the move, `test/support` still holds five private modules plus two shims and
  still needs the `:test`-only entry; the promoted modules are reached through
  `lib/`, which every env compiles.
- **`use ExUnit.CaseTemplate` in `lib/` emits no compile warning.** Verified in
  a scratch Mix project on this toolchain (Elixir 1.18.3 / OTP 27): a module in
  `lib/` doing `use ExUnit.CaseTemplate` and calling `ExUnit.Assertions.flunk/1`
  compiles clean with `--warnings-as-errors` and no `:ex_unit` entry in
  `extra_applications`. Mix's application tracer
  (`mix/compilers/application_tracer.ex:117`) skips modules that are already
  loaded, which every Elixir-shipped application is in the compiler VM. A
  control call to `:public_key` in the same project *did* warn, so the check was
  live. **No `mix.exs` `application/0` change is needed.**

**Two hazards ADR-0052 did not anticipate**, both found by reading
`lib/mix/statifier/adr_guard.ex`:

1. **ADR-0003 effects check.** `@effect_call_pattern` (adr_guard.ex:110) matches
   `\breceive\s+do\b`, and `effects_findings/1` (:276) scopes it to
   `lib/statifier/` minus three named effect-interpreter paths.
   `case.ex:294`'s `drain_done_effect/1` contains a `receive do`. Landing it at
   `lib/statifier/testing/case.ex` makes it a diff addition in scope, and the
   ADR guard stage goes red. The sanctioned escape is `@escape_pattern`
   (adr_guard.ex:124): an `ADR-0\d{3}` citation on the line or the line above.
2. **ADR-0018 bead-ID check.** `bead_id_findings/1` (:317) rejects bead IDs in
   comments and doc strings under `lib/` and `test/`. The promoted files carry
   them: `case.ex:336` ("st-k8d Phase 1") and `case.ex:372` ("st-af3"), and
   **23 lines** of `feature_detector.ex`'s registry provenance comments
   (`# st-wju.4`, `# st-af3.3`, ...). These are grandfathered today only because
   the guard reads a diff; a new file under `lib/` re-adds every line. Note the
   shims keep `test/support/case.ex` and `test/support/feature_detector.ex`
   alive at their old paths, so git cannot pair the new files as renames - they
   are wholly added.

**Gate-config exposure.** `lib/mix/statifier/gate_guard.ex:43` guards `mix.exs`
by line content: `~r/test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir|:sobelow|:doctor/`.
The `dialyzer: [plt_add_apps: [:mix]]` line matches. ADR-0052 anticipates
possibly adding `:ex_unit` to the PLT apps and calls it "implementation detail";
mechanically it is a guarded `mix.exs` edit that would demand an entry in
`docs/quality-gate-changes.md` with an `Approved-by:` line. See Phase 2's
explicit stop condition.

## Desired End State

A downstream application that has `{:statifier, "~> 2.0"}` in `deps` can write:

```elixir
defmodule MyApp.CheckoutChartTest do
  use Statifier.Testing.Case, async: true

  test "the cart advances to payment" do
    test_scxml(
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="cart">
          <state id="cart"><transition event="checkout" target="payment"/></state>
          <state id="payment"/>
      </scxml>
      """,
      "cart advances on checkout",
      ["cart"],
      [{%{"name" => "checkout"}, ["payment"]}]
    )
  end
end
```

with no file copied out of this repo, and a chart whose load-bearing delay
exceeds the corpus-tuned defaults can say so at the call site:

```elixir
    test_scxml(xml, "slow chart", ["idle"], steps,
      configuration_deadline_ms: 15_000,
      settle_window_ms: 400
    )
```

Verification that the end state holds:

- `lib/statifier/testing/case.ex` and `lib/statifier/testing/feature_detector.ex`
  exist; `grep -rn "Statifier.Testing" lib/ --include=*.ex` shows no reference
  from any module outside `lib/statifier/testing/`.
- `mix test --include scion --include scxml_w3` is green with the 281 generated
  files unedited (`git diff --stat test/scion_tests test/scxml_tests` empty
  across the whole branch).
- `mise run corpus` regenerates byte-identical output.
- Full `mix quality` green, and `mix gate.verify` attests the run was a full
  gate.
- `docs/testing.md` and both promoted moduledocs state the namespace rule, not
  the placement rule.
- `docs/testing-charts.md` documents the downstream flow;
  `changelog.d/st-hbdr.md` exists.

### Key Discoveries:

- ADR-0052 decision 5 pins the shim strategy; ADR-0006's nine-function coupling
  surface is untouched because promotion moves the module, not the coupling.
- `ExUnit.CaseTemplate.__proxy__/2`
  (`elixir/lib/ex_unit/lib/ex_unit/case_template.ex`) injects `use ExUnit.Case`
  into the *using* module. A shim that itself did `use ExUnit.CaseTemplate` and
  re-`use`d the promoted template would inject `use ExUnit.Case` twice and
  register the template callbacks twice. The shim must therefore be a plain
  module that forwards `__using__/1`, not a second case template.
- `adr_guard.ex:110,124,317` - the two guard hazards and the citation escape.
- `deps/doctor/lib/module_information.ex:190-222` - Doctor counts `:def` only.
- `deps/excoveralls/lib/excoveralls/settings.ex:89` - `skip_files` is what keeps
  `test/support/` off the coverage report today.
- `tools/corpus/*/cases.exs` `Code.require_file` the shim path, so a
  `defdelegate` shim keeps the generators working in `:dev` (the delegated-to
  module is compiled in `lib/`).

## What We're NOT Doing

- **No `statifier_test` hex package.** Rejected by ADR-0052 decision 2.
- **No corpus regeneration.** The 281 generated files keep saying
  `use Statifier.Case`. ADR-0052 decision 5 calls adopting the new names a later
  housekeeping call. Any diff under `test/scion_tests/` or `test/scxml_tests/`
  on this branch is a defect.
- **No change to `mix.exs`'s `elixirc_paths`, `version`, or `application/0`.**
  `2.0.0-dev` stays; `:ex_unit` is not added to `extra_applications` (measured
  unnecessary above).
- **`Statifier.StreamOrder` stays private.** ADR-0052 decision 4 and open
  question 3 put it out of scope; it asserts the ADR-0044/0046 subscriber-stream
  delivery contract, which is not a chart author's concern.
- **`Statifier.ContextRecorder`, `Statifier.TestContent`, `Statifier.TmpDir`,
  and `Mix.Statifier.AdrJudgeCorpus` stay private**, each for the reason
  ADR-0052 decision 4 gives.
- **No mechanical enforcement of the new namespace rule.** ADR-0052 states the
  rule in prose and in `docs/testing.md`; adding a fifth check to
  `lib/mix/statifier/adr_guard.ex` would be a widening of the gate and is
  welcome, but it is new scope this bead did not ask for. File a follow-up bead
  rather than folding it in here.
- **No `package:`/`docs:` block in `mix.exs`.** The project has neither today
  and is not being published on this branch; ex_doc grouping for
  `Statifier.Testing.*` belongs with the release bead.
- **No renaming of `test_scxml/4`** - see the decision record below.

### Decisions taken on ADR-0052's open questions

**Open question 1 - keep `test_scxml/4` or add a friendlier alias: keep it,
unaliased.** ADR-0052's stated default, adopted for three reasons. The name is
what 281 committed files and both generators already say, so a second spelling
would immediately have two populations of examples with no way to tell a reader
which is canonical. It doubles the documented surface at the exact moment the
surface becomes versioned and supported, which is the worst time to guess. And
nothing has actually reported friction with the name: the only evidence
available is this repo's own use, where it reads fine. If a downstream author
asks for `assert_chart/4` or similar, adding an alias later is additive and
cheap; removing one is not.

**Open question 2 - do `@settle_window_ms` and `@configuration_deadline_ms`
become caller options: yes, as an optional fifth argument with today's values as
defaults.** Names: `:settle_window_ms` and `:configuration_deadline_ms` - the
constants' own names, minus the `@`, unit suffix retained. `@poll_interval_ms`
stays a constant; nobody has a reason to tune the sampling rate, and exposing it
would invite tuning the wrong knob.

The mechanism is `def test_scxml(xml, description, expected_initial_config, events, opts \\ [])`.
A default argument defines both `test_scxml/4` and `test_scxml/5`, so the corpus
call shape and ADR-0006's enumerated coupling surface are literally unchanged,
and ADR-0052 decision 1's "keeping `test_scxml/4`'s shape" is honored. Rejected
alternatives: `use Statifier.Testing.Case, settle_window_ms: ...` (module-level
opts are invisible at the call site that actually needs them, and the `using`
block would have to shadow the imported `test_scxml/4`); and application
config (ambient, and `Application.put_env` races under `async: true`).

Three reasons to say yes rather than defer. The constants were sized to *this
corpus's* delay populations - `case.ex:108-116` says so explicitly, naming 1.5s
`mandatory/cancel/test208` as the longest load-bearing delay - so they are
private tuning being published as a hard limit. A downstream chart with a
20-second timer would fail with a configuration mismatch and no hint that a
constant caused it. And it buys a test: `poll_until_settled/4`'s deadline exit
(`case.ex:259`) is one of the 8 uncovered lines precisely because covering it
today costs a 4-second sleep; with a 50ms `:configuration_deadline_ms` it is a
fast, deterministic test.

## Implementation Approach

Five sequential phases. The order is forced at one point and chosen at the rest:
`FeatureDetector` must be promoted before `Case`, because a `Case` living in
`lib/` may not reference a `test/support` module - it would not even compile in
`:dev`. Everything after that is smallest-committable-unit sequencing.

Each phase moves exactly one thing and leaves the tree fully green, so each is
independently committable and each can be gated by a full `mix quality`. Every
phase carries the same shape of work for the module it moves:

1. Create the `lib/statifier/testing/` module with the new name.
2. Scrub it for the two guard hazards - bead IDs out of comments and doc
   strings, an ADR citation on the `receive do`.
3. Replace the old file with a shim that keeps the old name working.
4. Repoint the harness's own tests at the new name, and replace their
   `# sabotage: n/a` exemptions - which asserted "no `lib/` behavior" and stop
   being true the moment the module is `lib/` code - with real recorded
   mutations.
5. Full gate.

Step 4 is not optional bookkeeping. `docs/testing.md:207-216` allows a stated
`n/a` exemption only for harness plumbing that asserts no `lib/` behavior; after
promotion, every one of those tests asserts `lib/` behavior by definition. Counted:
`grep -c "sabotage: n/a"` returns **4** in `case_test.exs` and **15** in
`feature_detector_test.exs`. Treat the count as a floor, not a checklist target:
the rule is that *every* `n/a` exemption on a test covering a promoted module is
re-examined, and `mix quality`'s sabotage scan cannot catch a stale one - it only
checks that a `# sabotage:` line exists, never that its stated reason is still
true (`docs/testing.md:184-186`).

---

## Phase 1: Promote `FeatureDetector` into `Statifier.Testing`

### Overview

Move the feature registry and detector into `lib/`, leave a delegating shim, and
convert the detector's tests from exempt to sabotaged.

### Changes Required:

#### 1. The promoted module

**File**: `lib/statifier/testing/feature_detector.ex` (new)
**Changes**: `test/support/feature_detector.ex` verbatim, with:

- `defmodule Statifier.Testing.FeatureDetector do`
- The moduledoc's rule sentence restated in namespace terms:

```
  Test-side surface for chart authors, versioned with the engine: no module in
  `lib/` outside `Statifier.Testing.*` may reference anything inside it, so the
  engine never consults feature detection to decide behavior (ADR-0052,
  amending ADR-0006).
```

- The doctest at `:33` updated to `Statifier.Testing.FeatureDetector`.
- **Every bead ID removed from comments** (23 lines: `# st-wju.1 / st-wju.6`,
  `# st-af3.3`, ...). ADR-0018 says a bead ID is a process artifact, not a fact
  about the code, and `adr_guard.ex:317` enforces it under `lib/`. Do not
  silence these with `ADR-0018-exempt`; the provenance a reader needs is *what
  the entry means*, which the surrounding prose already carries. Where a
  comment says nothing but a bead ID, delete it; where it says something
  (`# st-wju.4 (also covers the initial attribute - the detector has no
  separate atom for it)`), keep the parenthetical and drop the ID.

#### 2. The shim

**File**: `test/support/feature_detector.ex` (rewritten)
**Changes**: three `defdelegate`s under the old name, so the two corpus
generators' `Code.require_file` + `Statifier.FeatureDetector.detect_features/1`
calls keep working in `:dev` (the delegate target is compiled in `lib/`).

```elixir
defmodule Statifier.FeatureDetector do
  @moduledoc """
  Compatibility shim: the real module is `Statifier.Testing.FeatureDetector`,
  in `lib/`. This name is kept so the 281 generated corpus files and the
  `tools/corpus` generators need no regeneration (ADR-0052 decision 5).
  """

  alias Statifier.Testing.FeatureDetector

  @spec detect_features(xml :: String.t()) :: MapSet.t(atom())
  defdelegate detect_features(xml), to: FeatureDetector

  @spec feature_registry() :: %{atom() => :supported | :unsupported | :partial}
  defdelegate feature_registry(), to: FeatureDetector

  @spec validate_features(detected_features :: MapSet.t(atom())) ::
          {:ok, MapSet.t(atom())} | {:error, MapSet.t(atom())}
  defdelegate validate_features(detected_features), to: FeatureDetector
end
```

`@spec` on each is required by `Credo.Check.Readability.Specs`, which
`.credo.exs:135-137` deliberately does not scope off `test/`.

#### 3. The detector's own tests

**File**: `test/statifier/feature_detector_test.exs`
**Changes**: `doctest Statifier.Testing.FeatureDetector`,
`alias Statifier.Testing.FeatureDetector`, module renamed to
`Statifier.Testing.FeatureDetectorTest`. Replace **every**
`# sabotage: n/a - FeatureDetector is test harness (test/support/), no lib/
behavior` note - there are 15 of them, and the reason each states stops being
true the moment the module is `lib/` code. Two categories:

- The tag-table test (`:293`) stays exempt but with an accurate reason - it
  asserts the sample table matches the registry, which is still no behavior:
  `# sabotage: n/a - asserts the sample table matches the registry, no behavior`.
- Every detection test gets a real mutation performed and recorded, e.g.
  `# sabotage: detect_compound_states/2 drops the nested-state clause -> red`.
  Follow `docs/testing.md:144-205` exactly, including the
  `MIX_ENV=test mix compile --force` step around each mutation
  (`docs/testing.md:218-224`, the stale-beam trap).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` green (use `mix quality --profile loop` while
      iterating; a loop run never satisfies this phase).
- [x] `mix gate.verify` confirms the run was a full, unscoped gate.
- [x] `mix test.regression` green - the ratchet's `internal_tests` glob
      `test/statifier/**/*_test.exs` covers the renamed test module.
- [x] ADR guard stage green - proves no bead ID survived into
      `lib/statifier/testing/feature_detector.ex`. Cross-check with
      `grep -rnE 'st-[a-z0-9]' lib/statifier/testing/` returning nothing.
      (`adr_guard.ex:130` uses a PCRE lookbehind to avoid matching "21st-century";
      BSD `grep -E` on this platform has no lookbehind, so the cross-check runs
      without it and may report a false positive worth eyeballing. The ADR guard
      stage, not this grep, is the decider.)
- [x] Gate guard stage green with no `docs/quality-gate-changes.md` entry - no
      guarded path is touched by this phase.
- [x] Doctor stage green (`lib/statifier/testing/feature_detector.ex` now
      counts: 3 `def`s, each with `@doc` and `@spec`, plus a `@moduledoc`).
- [x] `mix test --include scion --include scxml_w3` green.
- [x] `git diff --stat test/scion_tests test/scxml_tests` is empty.
- [x] `mix run tools/corpus/scion/cases.exs` still loads: verify with
      `MIX_ENV=dev mix run -e 'Code.require_file("test/support/feature_detector.ex"); IO.inspect(Statifier.FeatureDetector.detect_features("<scxml><state id=\"s\"/></scxml>"))'`.

#### Manual Verification:
- [ ] Each new sabotage note names a mutation that was actually performed and
      actually reddened the named test - the note is the artifact, and a note
      whose mutation never fired is the failure `docs/testing.md:180-205`
      describes.
- [ ] No Appendix D procedure is touched. The promoted module implements none of
      the pseudocode; confirm by reading the diff that nothing under
      `lib/statifier/interpreter/` changed and engine behavior is untouched.
- [ ] The registry comments still tell a reader what each entry means after the
      bead IDs come out - the scrub removed provenance, not meaning.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full gate is the phase gate. In interactive execution, pause here for the human
to confirm the manual items. Under `--loop`, the Automated list gates
advancement and the Manual items are deferred to the end.

---

## Phase 2: Promote `Case` into `Statifier.Testing`

### Overview

Move the declarative runner into `lib/`, leave a `__using__`-forwarding shim,
clear the ADR-0003 and ADR-0018 guard hazards, and fix the vacuous
fail-not-skip test.

### Changes Required:

#### 1. The promoted module

**File**: `lib/statifier/testing/case.ex` (new)
**Changes**: `test/support/case.ex` verbatim, with:

- `defmodule Statifier.Testing.Case do`
- `alias Statifier.{MachineState, Session}` plus
  `alias Statifier.Testing.FeatureDetector` (grouped per
  `Credo.Check.Consistency.MultiAliasImportRequireUse`, and ordered per
  `Credo.Check.Readability.StrictModuleLayout`).
- Moduledoc gains the same namespace-rule paragraph as Phase 1, and an
  audience sentence: this module is the supported entry point for chart authors
  downstream, not only the corpus's driver.
- Bead IDs removed from `:336` ("st-k8d Phase 1") and `:372` ("st-af3"). The
  facts they anchor stay: at `:336`, "the position it held at exit rides the
  core `:done` effect instead (`Effect.Done.configuration`)"; at `:372`,
  "nothing can observe event data until the datamodel lands".
- **An ADR citation above `drain_done_effect/1`'s `receive do`**, which is what
  `adr_guard.ex:124`'s `@escape_pattern` accepts and what keeps the ADR-0003
  effects check honest rather than narrowed:

```elixir
  # ADR-0003 scopes "no side effects in the pure core" to the engine. This
  # module is `Statifier.Testing`, the test-side surface the same `lib/` tree
  # now carries (ADR-0052), not the core: it drives a session from outside and
  # reads its own subscriber mailbox. Draining here rather than returning an
  # effect is the point - there is no interpreter above this frame to run one.
  defp drain_done_effect(_session) do
    receive do
```

Do **not** instead add `lib/statifier/testing/` to `adr_guard.ex`'s
`@effect_interpreter_paths`. That narrows a check's scope for a whole directory,
which is the human call ADR-0011 reserves; a cited escape on the one line that
needs it is the mechanism the guard already provides.

#### 2. The shim

**File**: `test/support/case.ex` (rewritten)
**Changes**: a plain module - **not** a second `ExUnit.CaseTemplate` - that
forwards `__using__/1`. `ExUnit.CaseTemplate.__proxy__/2` injects
`use ExUnit.Case` into the using module, so a template-on-template shim would
inject it twice and register the setup callbacks twice.

```elixir
defmodule Statifier.Case do
  @moduledoc """
  Compatibility shim: the real case template is `Statifier.Testing.Case`, in
  `lib/`. This name is kept so the 281 generated corpus files need no
  regeneration (ADR-0052 decision 5).
  """

  @doc false
  @spec __using__(opts :: keyword()) :: Macro.t()
  defmacro __using__(opts) do
    quote do
      use Statifier.Testing.Case, unquote(opts)
    end
  end
end
```

No `defdelegate` for `test_scxml/4` is needed: `use Statifier.Testing.Case`
injects `import Statifier.Testing.Case`, which is how the corpus reaches
`test_scxml/4` unqualified.

#### 3. The runner's own tests

**File**: `test/statifier/case_test.exs`
**Changes**: module renamed to `Statifier.Testing.CaseTest`; qualified calls
repointed to `Statifier.Testing.Case` / `Statifier.Testing.FeatureDetector`.
Then:

- **Fix the vacuous test at `:16`.** It claims to prove fail-not-skip and does
  not: `cond=` detects as `:conditional_transitions`, which the registry marks
  `:supported`, so `validate_features/1` returns `{:ok, _}` and the flunk branch
  never runs. Split it into what is actually true today:
  - Keep `:8`'s "every feature the detector can emit is supported or partial",
    renamed to say what it means: **the feature gate is vacuous by
    construction** - no document can currently reach the flunk. Its `n/a`
    exemption becomes false (it now asserts `lib/` behavior), so give it a real
    mutation: `# sabotage: validate_features/1 treats an unknown atom as
    :supported -> red`, driven by asserting `{:error, _}` for a synthetic
    unsupported atom in the same test.
  - Replace the misnamed test with one that asserts the guarantee at the level
    it can be asserted: `Statifier.Testing.FeatureDetector.validate_features/1`
    returns `{:error, set}` naming the unsupported feature, and the runner's
    gate consumes exactly that result. Record the mutation.
  - The remaining two `n/a` notes at `:261` and `:277` ("asserts the routing
    predicate itself, not lib/") also stop being true: `session_required?/1` is
    now `lib/` code. Sabotage them for real, e.g.
    `# sabotage: session_required?/1 drops :invoke_elements from @session_features -> red`.
- **Add a test for `send_event/2`'s terminated-chart flunk** (`case.ex:380`,
  uncovered): drive a chart to a `<final>`, then send an event, and assert the
  flunk message. Sabotage: `send_event/2 returns the unchanged state chart on
  {:error, :not_running} instead of flunking -> red`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` green; `mix gate.verify` attests it was unscoped.
- [x] **ADR guard stage green.** This is the phase's sharpest automated signal:
      it fails unless the `receive do` carries its ADR citation and every bead
      ID is out of the promoted file.
- [x] **Gate guard stage green with no ledger entry**, confirming no guarded
      path moved. **STOP CONDITION**: if the Dialyzer stage reports unknown
      `ExUnit.*` functions and the fix is `dialyzer: [plt_add_apps: [:mix, :ex_unit]]`
      in `mix.exs`, that line matches `gate_guard.ex:43`'s pattern and needs an
      `Approved-by:` entry in `docs/quality-gate-changes.md`. **That entry is a
      human's call and an agent must not write it.** Stop, report, and wait.
      ADR-0052 anticipated the PLT change and called it implementation detail;
      mechanically it is a guarded edit either way.
- [x] Coverage: `test/statifier/case_test.exs`'s new tests raise
      `lib/statifier/testing/case.ex` above its measured 90.1% baseline; project
      total stays above the 90% floor (it was 96.3% with `test/support`
      included).
- [x] `mix test --include scion --include scxml_w3` green -
      `use Statifier.Case, async: true` still works through the shim across all
      281 files.
- [x] `git diff --stat test/scion_tests test/scxml_tests` is empty.
- [x] `mix test.regression` green.

#### Manual Verification:
- [ ] Every replaced `n/a` note names a mutation that was performed and
      reddened its test.
- [ ] No Appendix D procedure is touched - the promoted module drives the
      engine from outside and implements none of the pseudocode; confirm nothing
      under `lib/statifier/interpreter/` changed.
- [ ] The ADR-0003 escape comment argues the case rather than asserting an
      exemption: a reader who knows only ADR-0003 should finish it agreeing.
- [ ] Read the corpus shim path once by hand: pick one `test/scion_tests` file
      and one `test/scxml_tests` file and run each alone with
      `mix test <path> --include scion` / `--include scxml_w3`.

**Implementation Note**: as Phase 1.

---

## Phase 3: Make the corpus-tuned timing constants caller options

### Overview

Turn `@settle_window_ms` and `@configuration_deadline_ms` into per-call options
with today's values as defaults, and use the new knob to cover
`poll_until_settled/4`'s deadline exit.

### Changes Required:

#### 1. The optional fifth argument

**File**: `lib/statifier/testing/case.ex`
**Changes**:

```elixir
  @default_settle_window_ms 100
  @default_configuration_deadline_ms 4_000

  @doc """
  ...existing doc...

  ## Options

  Both default to values tuned for this repo's conformance corpus. A downstream
  chart whose load-bearing delay is longer than the corpus's needs the knob.

  - `:settle_window_ms` (default `#{@default_settle_window_ms}`) - how long to
    wait for pending timers to drain before sending the next event. Long enough
    to drain load-bearing intermediate delays, short enough never to let a guard
    send fire.
  - `:configuration_deadline_ms` (default
    `#{@default_configuration_deadline_ms}`) - upper bound on waiting for a
    session to reach an expected configuration. Bounds only the wrong answer: a
    chart that cannot change again exits the poll immediately.
  """
  @spec test_scxml(
          xml :: String.t(),
          description :: String.t(),
          expected_initial_config :: [String.t()],
          events :: [{map(), [String.t()]}],
          opts :: keyword()
        ) :: :ok
  def test_scxml(xml, description, expected_initial_config, events, opts \\ [])
```

Thread `opts` through `drive_through_session/4`, `assert_configuration_eventually/3`,
`poll_until_settled/3`, and `settle_short_timers/1`, reading each value with
`Keyword.get(opts, :settle_window_ms, @default_settle_window_ms)` and the
deadline equivalent. `@poll_interval_ms` stays a constant. `drive_synchronously/3`
ignores `opts` entirely - the synchronous path has no timing.

Keep the existing explanatory comments at `case.ex:100-116` attached to the new
`@default_*` attributes: they are the record of why these numbers are what they
are, and they are the argument for making them tunable.

#### 2. Coverage for the deadline exit

**File**: `test/statifier/case_test.exs`
**Changes**: a test that drives a session-path document which cannot reach the
asserted configuration, with `configuration_deadline_ms: 50`, and asserts the
resulting `ExUnit.AssertionError` reports the mismatch rather than hanging. This
is the first test to reach `case.ex:259`.
Sabotage: `poll_until_settled/4 ignores its deadline and recurses forever -> red`
(the test then times out rather than failing cleanly, which is the red).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` green; `mix gate.verify` attests it was unscoped.
- [x] `mix test --include scion --include scxml_w3` green - the corpus calls
      `test_scxml/4` and must be entirely unaffected by the new default
      argument.
- [x] `git diff --stat test/scion_tests test/scxml_tests` is empty.
- [x] Coverage for `lib/statifier/testing/case.ex` improves again; project total
      stays above 90%.
- [x] Doctor green - the `## Options` section lives in the existing `@doc`, and
      the default argument adds no new `def` head Doctor would count separately.
- [x] `mix test.regression` green.

#### Manual Verification:
- [ ] Run the new deadline test alone and confirm it completes in well under a
      second - proving the option is actually read and not shadowed by the
      4-second default.
- [ ] Confirm no Appendix D procedure is touched.
- [ ] Read the `## Options` doc as a downstream author: does it say enough to
      pick a value, or only that a value exists?

**Implementation Note**: as Phase 1.

---

## Phase 4: Rewrite the placement rule as a namespace rule

### Overview

The repo-facing half of the documentation: `docs/testing.md`'s
FeatureDetector-forbidden-from-`lib/` paragraph and its coverage note, plus the
corpus tooling README's mention of the shims.

### Changes Required:

#### 1. `docs/testing.md`

**File**: `docs/testing.md`
**Changes**:

- `:348-351` - replace the placement half, keep the reference-direction half:

```
Unsupported-feature tests **fail, not skip** (v1's FeatureDetector rule, kept): a
test that depends on an unsupported feature flunks with the feature named, so it can
never masquerade as passing. Feature detection lives in `lib/` under
`Statifier.Testing`, where it is test-side surface for chart authors rather than
engine (ADR-0052, amending ADR-0006). The load-bearing half of the old rule is
kept in namespace terms: **no module in `lib/` outside `Statifier.Testing.*` may
reference anything inside it.** The engine's semantics come from the Appendix D
port (ADR-0002); an unsupported feature surfaces as a real error or a real
conformance failure, never as a detection-gated branch.
```

- `:5` and `:22` - `Statifier.Case` becomes `Statifier.Testing.Case`, with a
  parenthetical that the generated files still say `Statifier.Case` through a
  shim.
- `:372-378` - the coverage note is now wrong in its premise. Rewrite: coverage
  measures `lib/`, which now includes `Statifier.Testing`; `coveralls.json`
  still skips `test/support/`, which now holds the shims and the five private
  harness modules.
- The sabotage section's "Exempt" paragraph (`:207-216`) gains one sentence:
  a test covering `Statifier.Testing.*` asserts `lib/` behavior and is **not**
  exempt, no matter that it reads like harness plumbing.

#### 2. `tools/corpus/README.md`

**File**: `tools/corpus/README.md`
**Changes**: at `:85-96`, note that `use Statifier.Case` and
`Statifier.FeatureDetector` in generated output are the `test/support` shims
over `Statifier.Testing.*`, that this is deliberate (ADR-0052 decision 5), and
that adopting the new names is a future regeneration's call.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` green. This phase touches no Elixir; the gate still
      runs and must still be green, and per CLAUDE.md a no-Elixir change may
      commit on review of the diff alone if the gate has nothing to say.
- [ ] `grep -rn "lives in .test/support., not .lib/." docs/` returns nothing.
- [ ] `grep -rn "Statifier.Testing" docs/testing.md` returns the new rule.

#### Manual Verification:
- [ ] A reader who knows only `docs/testing.md` can state the new rule
      correctly, including which direction it forbids.
- [ ] The amendment marker on ADR-0006 and ADR-0052's decision 3 agree with the
      new prose word for word in substance.
- [ ] No Appendix D procedure is touched (documentation only).

**Implementation Note**: as Phase 1.

---

## Phase 5: Downstream documentation and the changelog fragment

### Overview

The user-facing half: a how-to for a chart author outside this repo, a README
pointer, and the changelog fragment the acceptance criteria name.

### Changes Required:

#### 1. The downstream guide

**File**: `docs/testing-charts.md` (new)
**Changes**: a Diataxis how-to, modelled on `docs/extending.md`'s shape - it is
the closest existing document addressed to a host application author, and it
opens by naming the seam and pointing elsewhere for architecture. Sections:

- What this gives you: the engine tests itself this way, and now so can you.
- Add the dep. No `only: :test` companion is needed:
  `Statifier.Testing.Case` ships in `lib/` (ADR-0052 decision 6), the same shape
  as `Plug.Test` and `Phoenix.ConnTest`, and ExUnit ships with Elixir.
- Write a test: `use Statifier.Testing.Case, async: true` plus the
  `test_scxml/4` example from "Desired End State" above.
- What `test_scxml/4` asserts: the initial configuration after initialize, then
  one configuration per event step, by active leaf-state id. A terminated chart
  is asserted against the configuration it held at exit.
- Fail, never skip: a document using a feature the engine does not support flunks
  naming the feature, so an unimplemented feature can never look like a pass.
  Point at `Statifier.Testing.FeatureDetector.feature_registry/0` for the
  authoritative list. State plainly that today every detectable feature is
  `:supported` or `:partial`, so this path is a guarantee for the future rather
  than a thing you will hit now.
- Charts that need timers, delayed or external `<send>`, or `<invoke>`: the
  runner routes these through a live `Statifier.Session` automatically
  (`session_required?/1`), and this is where `:settle_window_ms` and
  `:configuration_deadline_ms` come in, with the corpus-tuned defaults named.
- Where the fixture format comes from: ADR-0006's corpus shape, so a fixture in
  that shape is executable downstream.

#### 2. README pointer

**File**: `README.md`
**Changes**: extend the Development section's closing pointer list, beside the
existing `docs/extending.md` link: "Testing your own charts:
[docs/testing-charts.md](docs/testing-charts.md)".

#### 3. Changelog fragment

**File**: `changelog.d/st-hbdr.md` (new)
**Changes**: this qualifies squarely - `changelog.d/README.md` lists "a public
API addition" first, and this is one. Harness-and-corpus work would not, but the
whole point of the bead is that these modules stop being harness.

```markdown
### Added

- `Statifier.Testing.Case` and `Statifier.Testing.FeatureDetector` are now
  public API. A downstream application can write declarative chart tests -
  an expected initial configuration, then `{event, expected_configuration}`
  steps - with `use Statifier.Testing.Case`, without copying files out of this
  repository. Documents using an unsupported SCXML feature flunk naming the
  feature rather than skipping. `test_scxml/4` accepts optional
  `:settle_window_ms` and `:configuration_deadline_ms` for charts whose
  load-bearing delays exceed the defaults. See `docs/testing-charts.md`.
```

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` green.
- [ ] `changelog.d/st-hbdr.md` exists and is non-empty.
- [ ] Every module and function named in `docs/testing-charts.md` resolves:
      `mix run -e 'Code.ensure_loaded!(Statifier.Testing.Case); Code.ensure_loaded!(Statifier.Testing.FeatureDetector)'`
      in `MIX_ENV=dev`, which also proves the promoted modules are reachable
      outside `:test` - the whole point of the bead.
- [ ] Any code block in the guide that is meant to run does run: paste the
      example into a scratch test file under `test/statifier/` temporarily,
      confirm it passes, and delete it (do not commit it - `case_test.exs`
      already covers the behavior).

#### Manual Verification:
- [ ] **The acceptance criterion, exercised end to end.** In a scratch Mix
      project outside this repo, add `{:statifier, path: "<this worktree>"}`,
      write the guide's example verbatim into `test/`, and run `mix test`. It
      must pass with nothing copied from `test/support`. This is the one check
      that proves the bead, and no in-repo test can stand in for it: in-repo,
      `test/support` is on the compile path.
- [ ] Repeat the scratch-project check with `MIX_ENV=prod mix compile` on the
      dependency to confirm the promoted modules compile outside `:test`.
- [ ] The guide reads as a how-to, not an explanation: a chart author gets to a
      passing test without needing `docs/architecture.md`.
- [ ] No Appendix D procedure is touched (documentation only).

**Implementation Note**: as Phase 1.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/feature_detector_test.exs` - repointed at
  `Statifier.Testing.FeatureDetector`, with 10 `n/a` exemptions replaced by real
  recorded mutations except the sample-table test, whose exemption is restated
  accurately.
- `test/statifier/case_test.exs` - repointed at `Statifier.Testing.Case`, with:
  the vacuous fail-not-skip test replaced by one that asserts what is actually
  assertable; the 4 `n/a` exemptions replaced by real mutations; a new
  terminated-chart flunk test (`case.ex:380`); a new deadline-exit test using
  `configuration_deadline_ms: 50` (`case.ex:259`).
- Edge cases worth naming: `use Statifier.Case` through the shim must produce
  exactly one `use ExUnit.Case` (a template-on-template shim would double it);
  `test_scxml/4` and `test_scxml/5` must both exist after Phase 3; the corpus
  generators must still resolve `Statifier.FeatureDetector` in `:dev` through
  `Code.require_file` on the shim.
- Known-and-accepted uncovered code: `case.ex:309-321`, the
  `validate_features!/2` flunk block, stays uncovered. It is unreachable by
  construction while every atom in the registry is `:supported` or `:partial`,
  and the honest fix is a registry that has an `:unsupported` entry, not a seam
  invented to reach it. Phase 2 makes that vacuity an explicit, tested assertion
  instead of an accident. The 90% floor is a project total (96.3% measured) and
  is not at risk.

### Manual Testing Steps:

1. Stand up a scratch Mix project outside this repo with
   `{:statifier, path: "<this worktree>"}`; write the `docs/testing-charts.md`
   example into its `test/`; run `mix test`. Green, with nothing copied from
   `test/support/`.
2. In the same scratch project, `MIX_ENV=prod mix compile` the dependency and
   confirm `Statifier.Testing.Case` is present in `_build/prod`.
3. Add a chart with a 6-second delay to the scratch project and confirm it fails
   against the 4-second default, then passes with
   `configuration_deadline_ms: 15_000`. This is the concrete argument for
   resolving open question 2 the way it was resolved.
4. `mise run corpus` and confirm `git status` is clean afterwards - the
   generators produce byte-identical output through the shims.
5. Read the ADR-0003 escape comment on `drain_done_effect/1` cold and decide
   whether it argues its case.

## Corpus/Ratchet Notes

- **No corpus regeneration on this branch.** All 281 files under
  `test/scion_tests/` and `test/scxml_tests/` stay byte-identical; check with
  `git diff --stat test/scion_tests test/scxml_tests` at every phase gate. The
  shims exist precisely to buy this (ADR-0052 decision 5).
- **No `test/passing_tests.json` change.** Its `internal_tests` globs are
  `test/mix/**/*_test.exs` and `test/statifier/**/*_test.exs`; both repointed
  test files stay at their existing paths under `test/statifier/`, so the
  registry needs no edit and nothing shrinks. A shrink would be a guarded change
  under ADR-0011.
- **No conformance results move.** This bead adds no engine behavior, so no
  previously-failing conformance test becomes passing and `mix test.baseline add`
  is not called. If a conformance test's status *does* change, that is a signal
  the promotion changed behavior - stop and investigate rather than ratcheting
  it in.
- `mix test.regression` runs at every phase gate as the named check that the
  ratchet still holds.

## References

- Governing decision: `docs/adr/0052-chart-test-helpers-ship-in-lib-under-statifier-testing.md`
- Amended record: `docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md`
- Rules being rewritten: `docs/testing.md:207-216,348-351,372-378`
- Guard mechanics: `lib/mix/statifier/adr_guard.ex:110,124,276,317`;
  `lib/mix/statifier/gate_guard.ex:43`
- Gate ledger (only if the Phase 2 stop condition fires):
  `docs/quality-gate-changes.md`
- Sources moved: `test/support/case.ex`, `test/support/feature_detector.ex`
- Corpus coupling: `tools/corpus/scion/cases.exs:18,43,63`;
  `tools/corpus/scxml_w3/cases.exs:32,135,153`
- Model for the downstream guide: `docs/extending.md`
- Changelog rules: `changelog.d/README.md`
- Bead: `st-hbdr`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Each new sabotage note names a mutation that was actually performed and
      actually reddened the named test - the note is the artifact, and a note
      whose mutation never fired is the failure `docs/testing.md:180-205`
      describes.
- [ ] No Appendix D procedure is touched. The promoted module implements none of
      the pseudocode; confirm by reading the diff that nothing under
      `lib/statifier/interpreter/` changed and engine behavior is untouched.
- [ ] The registry comments still tell a reader what each entry means after the
      bead IDs come out - the scrub removed provenance, not meaning.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full gate is the phase gate. In interactive execution, pause here for the human
to confirm the manual items. Under `--loop`, the Automated list gates
advancement and the Manual items are deferred to the end.

---

### Phase 2

- [ ] Every replaced `n/a` note names a mutation that was performed and
      reddened its test.
- [ ] No Appendix D procedure is touched - the promoted module drives the
      engine from outside and implements none of the pseudocode; confirm nothing
      under `lib/statifier/interpreter/` changed.
- [ ] The ADR-0003 escape comment argues the case rather than asserting an
      exemption: a reader who knows only ADR-0003 should finish it agreeing.
- [ ] Read the corpus shim path once by hand: pick one `test/scion_tests` file
      and one `test/scxml_tests` file and run each alone with
      `mix test <path> --include scion` / `--include scxml_w3`.

**Implementation Note**: as Phase 1.

---

### Phase 3

- [ ] Run the new deadline test alone and confirm it completes in well under a
      second - proving the option is actually read and not shadowed by the
      4-second default.
- [ ] Confirm no Appendix D procedure is touched.
- [ ] Read the `## Options` doc as a downstream author: does it say enough to
      pick a value, or only that a value exists?

**Implementation Note**: as Phase 1.

---
