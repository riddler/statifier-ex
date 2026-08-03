# Corpus Name Normalization Implementation Plan

## Overview

The corpus emitters (`tools/corpus/scion/cases.exs`, `tools/corpus/scxml_w3/cases.exs`)
inherit directory, file, and module names straight from the upstream SCION and
W3C IRP trees. Upstream names are not Elixir-idiomatic (`actionSend`,
`SCXMLEventProcessor`, `onentry`), and the SCXML emitter does not normalize at
all today - only the SCION emitter replaces non-identifier separators, and
neither splits camelCase/acronym runs into snake_case. This plan adds a shared
normalization rule used by both emitters so generated paths are snake_case and
generated module names are the matching PascalCase, then regenerates the
corpus so the committed test tree reflects it. Beads issue: st2-yo4.

## Current State Analysis

- `tools/corpus/scion/cases.exs:15-25` defines `Cases.Normalize.identifier/1`,
  which only replaces runs of non-alphanumeric characters with `_`
  (`more-parallel` -> `more_parallel`, `hierarchy+documentOrder` ->
  `hierarchy_documentOrder`). It does not split camelCase, so `actionSend`,
  `documentOrder`, and `TestConditionalTransition` pass through unsplit at the
  word boundary.
- `tools/corpus/scxml_w3/cases.exs:112-166` has no normalization step at all -
  `spec` and `name` (from `Path.split/1` on the transformed `.scxml` path) are
  used verbatim for both the output path (`cases.exs:164`) and the module name
  (`Macro.camelize(spec)`, `cases.exs:144`). This is why
  `test/scxml_tests/mandatory/SCXMLEventProcessor/`,
  `.../EvaluationofExecutableContent/`, `.../onentry/`, and
  `test/scxml_tests/optional/ecma-profile/` exist verbatim today.
- Surveyed every upstream spec-level name already committed under
  `test/scion_tests/` and `test/scxml_tests/` (the only local record, since
  `scratch/` is gitignored and currently empty) to scope the naming rule:
  - SCION spec dirs: all camelCase-or-symbol-separated with a normal case
    boundary to split on (`actionSend`, `documentOrder`, `cond_js`,
    `atom3_basic_tests`, `hierarchy_documentOrder`, ...). File basenames follow
    the same pattern, plus two PascalCase outliers:
    `cond_js/TestConditionalTransition_test.exs`,
    `in/TestInPredicate_test.exs`.
  - W3C spec dirs: mostly PascalCase/acronym (`SCXMLEventProcessor`,
    `SelectingTransitions`, `SystemVariables`, `Expressions`,
    `EvaluationofExecutableContent`), one hyphenated (`ecma-profile`), and two
    with **no case boundary at all**: `onentry`, `onexit` - these are
    concatenated words in all-lowercase, which no algorithmic camelCase split
    can separate. File basenames are uniformly `testNNN[a-z]?`, already
    Elixir-idiomatic.
  - No other file/dir names in either tree need special-casing beyond a
    generic camelCase/acronym splitter plus the two lookups above.
  - No other files in the repo reference these upstream names (`grep` for
    `actionSend`, `onentry`, `SCXMLEventProcessor`, etc. only matches inside
    `test/scion_tests/` and `test/scxml_tests/`), so renaming is safe.
- `Macro.underscore/1` (stdlib) already implements exactly the camelCase- and
  acronym-boundary splitting needed (`SCXMLEventProcessor` ->
  `scxml_event_processor`, `documentOrder` -> `document_order`,
  `EvaluationofExecutableContent` -> `evaluationof_executable_content` - the
  latter matches the upstream name's own missing separator between
  "Evaluation" and "of", which is an acceptable "good enough" outcome per the
  issue). It leaves already-non-identifier separators (`-`, `+`) untouched, so
  it must run after the existing symbol-to-underscore replacement, not
  instead of it. Verified against every name in the survey above via a
  throwaway `elixir` script (see Key Discoveries).
- `mise.toml`'s `corpus:emit` task (`mise.toml:130-144`) never cleans
  `test/scion_tests`/`test/scxml_tests` before writing - it only `mkdir -p`s
  them. Renaming the emitted names means old-named files will not be removed
  by regeneration; they will sit alongside the new ones as stale duplicates
  unless the task removes the output dirs first.
- `test/passing_tests.json`'s `scion_tests` and `w3c_tests` arrays are both
  still empty ("v2 has no engine yet - the ratchet moves forward from zero"),
  so this rename has no ratchet entries to update.
- `changelog.d/README.md` explicitly excludes "test harness, corpus tooling,
  or conformance fixtures" from changelog fragments - none needed here.

## Desired End State

- A single shared normalization rule, used by both emitters, that:
  - snake_cases every generated directory and file-stem segment (camelCase
    and acronym boundaries split, non-identifier separators collapsed to
    `_`), and
  - produces the matching PascalCase module segment by camelizing that
    snake_case form, so the module name derives cleanly from the file path.
- `test/scion_tests/` and `test/scxml_tests/` regenerated end-to-end so every
  path segment is snake_case and every generated module name is PascalCase,
  with no stale old-named files left over.
- Regenerating again (`mise run corpus`) reproduces byte-identical output
  (determinism preserved).

Verify with:
- `find test/scion_tests test/scxml_tests -mindepth 1 | grep -E '[A-Z]|[^a-zA-Z0-9_./]'` prints nothing (no uppercase, no stray separators anywhere in the tree).
- `mix quality` is green (compiles the regenerated test files, even though
  their `:scion`/`:scxml_w3` tags exclude them from the default run).
- `mix test --include scion --include scxml_w3` runs without compile errors
  (pass/fail counts are expected to be mostly red - no interpreter yet - this
  only confirms the rename didn't break anything structural).

### Key Discoveries

- `Macro.underscore/1` handles the general case for free; only the
  no-case-boundary outliers (`onentry`, `onexit`) need an explicit lookup.
  Confirmed against the full survey list with the pipeline `String.replace
  non-identifier runs -> _` -> lookup table -> `Macro.underscore/1` ->
  collapse repeated `_` -> trim `_`.
- The SCION emitter already keeps the raw upstream string for `@tag spec:` and
  the test description (`tools/corpus/scion/cases.exs:74-75`); only the path
  and module segments go through normalization. The W3C emitter follows the
  same pattern for `@tag conformance:`/`@tag spec:` and the test name
  (`tools/corpus/scxml_w3/cases.exs:152-153`). This plan preserves that split
  in both emitters - normalize path/module only, keep tags/descriptions raw.

## What We're NOT Doing

- Not building a dictionary-based word segmenter for arbitrary concatenated
  lowercase names. `onentry`/`onexit` are handled via an explicit two-entry
  lookup table because they are the only upstream names in the corpus with no
  case boundary; if a future upstream sync introduces another one, it gets
  added to the same table (documented in the module).
- Not changing the `@tag spec:`, `@tag conformance:`, test description, or
  `test "<name>"` strings - those keep the raw upstream text, unaffected by
  this normalization (matches existing SCION emitter behavior).
- Not touching `tools/corpus/scxml_w3/exclusions.exs` keys (they're upstream
  `.txml` basenames used for lookup before normalization runs, not output
  names).
- Not adding module-name acronym preservation (e.g. keeping `SCXML` fully
  capitalized in `SCXMLEventProcessor` -> `ScxmlEventProcessor` instead).
  Camelizing the snake_case form is the standard Elixir path<->module
  derivation and is what "derives cleanly from its file path per Elixir
  convention" (the issue's own wording) means here.
- Not writing a changelog fragment - corpus tooling changes are explicitly
  excluded by `changelog.d/README.md`.
- Not updating `test/passing_tests.json` - both conformance arrays are empty,
  so there is nothing to re-key.

## Implementation Approach

Extract the normalization rule into one shared script both emitters
`Code.require_file/1` (the same pattern already used for
`test/support/feature_detector.ex`), so the two generators can't drift. Fix
`corpus:emit`'s missing cleanup so regeneration is idempotent under renames.
Then run a full `mise run corpus` regeneration and verify the committed tree.

## Phase 1: Shared normalization rule

### Overview

Add `tools/corpus/normalize.exs` with the combined snake_case rule, point both
emitters at it, and cover it with unit tests using the real upstream names
surveyed above. Also fix `corpus:emit` to clean its output dirs first.

### Changes Required

#### 1. Shared normalization module

**File**: `tools/corpus/normalize.exs` (new)
**Changes**: Extract and extend `Cases.Normalize` from
`tools/corpus/scion/cases.exs`:

```elixir
defmodule Cases.Normalize do
  @moduledoc """
  Upstream spec/name path segments are not Elixir-idiomatic - concatenated
  camelCase and acronyms (`actionSend`, `SCXMLEventProcessor`), a couple of
  concatenated lowercase words with no case boundary to split on
  (`onentry`), and non-identifier separators (`more-parallel`,
  `hierarchy+documentOrder`). `identifier/1` normalizes a single path segment
  to snake_case; camelizing that result gives the matching Elixir module
  segment, so module names derive cleanly from generated file paths. Shared
  by tools/corpus/scion/cases.exs and tools/corpus/scxml_w3/cases.exs so the
  two generators can't drift.
  """

  # Upstream segments with no case boundary for Macro.underscore/1 to split
  # on. Add an entry here only when a new upstream name needs it - everything
  # else splits algorithmically.
  @word_splits %{
    "onentry" => "on_entry",
    "onexit" => "on_exit"
  }

  @spec identifier(String.t()) :: String.t()
  def identifier(segment) do
    segment
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> then(&Map.get(@word_splits, &1, &1))
    |> Macro.underscore()
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end
end
```

#### 2. SCION emitter

**File**: `tools/corpus/scion/cases.exs`
**Changes**: Remove the inline `Cases.Normalize` module (lines 15-25);
`Code.require_file` the shared one instead. Behavior is unchanged for every
name that already worked (symbol replacement), and now also splits
camelCase/acronym runs:

```elixir
Code.require_file(Path.join([__DIR__, "..", "..", "..", "test/support/feature_detector.ex"]))
Code.require_file(Path.join([__DIR__, "..", "normalize.exs"]))
```

(delete the `defmodule Cases.Normalize do ... end` block that followed)

#### 3. W3C emitter

**File**: `tools/corpus/scxml_w3/cases.exs`
**Changes**: Require the shared module, and actually normalize `spec`/`name`
before building the output path and module name (today it uses them raw):

```elixir
Code.require_file(Path.join([__DIR__, "..", "..", "..", "test/support/feature_detector.ex"]))
Code.require_file(Path.join([__DIR__, "..", "normalize.exs"]))
```

```elixir
  [conformance, spec | _rest] = Path.split(rel)
  name = Path.basename(rel, ".scxml")

  normalized_spec = Cases.Normalize.identifier(spec)
  normalized_name = Cases.Normalize.identifier(name)
```

...and use `normalized_spec`/`normalized_name` in place of the raw `spec`/
`name` at the two use sites (`cases.exs:144` module build,
`cases.exs:164` output path build). Leave `@tag conformance:`, `@tag spec:`,
and `test #{inspect(name)}` using the raw `spec`/`name` values, matching the
SCION emitter's existing split between raw (tags/descriptions) and
normalized (path/module).

#### 4. Idempotent regeneration

**File**: `mise.toml`
**Changes**: `corpus:emit` task (~`mise.toml:130-144`) must clean its output
dirs before writing, so a rename (like this one) or an upstream case removal
doesn't leave stale files behind:

```bash
run = '''
set -euo pipefail
rm -rf "$CORPUS_W3_OUT" "$CORPUS_SCION_OUT"
mkdir -p "$CORPUS_W3_OUT" "$CORPUS_SCION_OUT"
...
```

#### 5. Unit tests

**File**: `test/corpus/normalize_test.exs` (new)
**Changes**: `Code.require_file` the shared script and assert on
`Cases.Normalize.identifier/1` against the real upstream names from the
survey (both directions: symbol names and camelCase/acronym names), plus
idempotency (`identifier(identifier(x)) == identifier(x)`) since the rule
runs once per emit but should be stable if re-applied.

```elixir
defmodule Corpus.NormalizeTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "tools/corpus/normalize.exs"]))

  # sabotage: n/a - generator tooling (tools/corpus/), not lib/ behavior

  describe "identifier/1" do
    test "splits camelCase and acronym boundaries" do
      assert Cases.Normalize.identifier("actionSend") == "action_send"
      assert Cases.Normalize.identifier("documentOrder") == "document_order"
      assert Cases.Normalize.identifier("SCXMLEventProcessor") == "scxml_event_processor"
      assert Cases.Normalize.identifier("SelectingTransitions") == "selecting_transitions"
      assert Cases.Normalize.identifier("TestConditionalTransition") == "test_conditional_transition"
    end

    test "collapses non-identifier separators" do
      assert Cases.Normalize.identifier("more-parallel") == "more_parallel"
      assert Cases.Normalize.identifier("hierarchy+documentOrder") == "hierarchy_document_order"
      assert Cases.Normalize.identifier("ecma-profile") == "ecma_profile"
    end

    test "leaves already-idiomatic names alone" do
      assert Cases.Normalize.identifier("atom3_basic_tests") == "atom3_basic_tests"
      assert Cases.Normalize.identifier("cond_js") == "cond_js"
      assert Cases.Normalize.identifier("test403a") == "test403a"
    end

    test "splits the known no-case-boundary upstream names" do
      assert Cases.Normalize.identifier("onentry") == "on_entry"
      assert Cases.Normalize.identifier("onexit") == "on_exit"
    end

    test "is idempotent" do
      for name <- ["actionSend", "onentry", "hierarchy+documentOrder", "atom3_basic_tests"] do
        once = Cases.Normalize.identifier(name)
        assert Cases.Normalize.identifier(once) == once
      end
    end
  end
end
```

### Success Criteria

#### Automated Verification
- [x] Full quality gate passes: `mix quality`

#### Manual Verification
- [ ] Spot-check `Macro.camelize(Cases.Normalize.identifier(x))` for a few
      names (`SCXMLEventProcessor`, `onentry`, `more-parallel`) produces a
      module segment that reads as an intentional Elixir name, not garbled.

---

## Phase 2: Regenerate and verify the corpus

### Overview

Run the full corpus pipeline with the new normalization and confirm the
committed tree is fully snake_case/PascalCase with no leftovers, then update
`tools/corpus/README.md`'s status section.

### Changes Required

#### 1. Regenerate

Run (network access required for `corpus:fetch`; a local W3C mirror is
available per `tools/corpus/README.md`'s `CORPUS_W3_MIRROR` if the live fetch
is rate-limited):

```bash
mise run corpus
```

This fetches into `scratch/` (gitignored), transforms, and re-emits
`test/scion_tests/` and `test/scxml_tests/` - now cleaned first per Phase 1's
`corpus:emit` fix, so old-named files are removed before the new ones land.

#### 2. Status doc update

**File**: `tools/corpus/README.md`
**Changes**: Remove the "st2-yo4 - normalize corpus emit output..." line from
the "Remaining work" list in the Status section, and add one sentence noting
emit now normalizes names to snake_case/PascalCase via
`tools/corpus/normalize.exs`.

### Success Criteria

#### Automated Verification
- [x] No stray casing/separators anywhere in the emitted tree:
      `find test/scion_tests test/scxml_tests -mindepth 1 | grep -E '[A-Z]|[^a-zA-Z0-9_./]'` prints nothing
- [x] Full quality gate passes (compiles the regenerated test files):
      `mix quality`
- [x] Regenerated corpus test files compile and run under their tags:
      `mix test --include scion --include scxml_w3` (structural pass, red
      results expected - no interpreter yet)
- [x] Re-running `mise run corpus:emit` alone reproduces byte-identical output
      (`git status` shows no diff after a second emit)

#### Manual Verification
- [ ] Skim a sample of regenerated files
      (`test/scion_tests/action_send/send1_test.exs`,
      `test/scxml_tests/mandatory/scxml_event_processor/test189_test.exs`,
      `test/scxml_tests/mandatory/on_entry/test375_test.exs`) - module names
      and content otherwise match the pre-rename version (only names changed).
- [ ] `git status`/`git diff --stat` shows only renames within
      `test/scion_tests/` and `test/scxml_tests/`, plus the Phase 1 files -
      nothing else moved.

---

## Testing Strategy

### Unit Tests
- `test/corpus/normalize_test.exs` (Phase 1): the naming rule itself, pattern
  matching each surveyed case category (camelCase, acronym, symbol, already-clean,
  no-case-boundary lookup, idempotency).

### Conformance Tests
- No new SCION/W3C tests start passing from this change - it's a pure rename.
  `test/passing_tests.json`'s conformance arrays stay empty; nothing to
  ratchet.

### Manual Testing Steps
1. After Phase 2's regeneration, browse `test/scion_tests/` and
   `test/scxml_tests/` in an editor to confirm the directory tree reads as
   idiomatic Elixir.
2. Open a handful of regenerated files and confirm the `defmodule` line's
   module name matches its file path exactly (mechanical spot check of the
   path<->module convention).

## Corpus/Ratchet Notes

Regeneration only renames already-emitted files; it does not change which
SCION/W3C cases are included or excluded (Phase 1's `corpus:emit` fix cleans
stale files but the same input set from `corpus:transform`/`corpus:fetch:scion`
is re-emitted). `test/passing_tests.json` needs no changes since both
conformance arrays are currently empty.

## References

- Beads issue: `st2-yo4`
- Corpus tooling: `tools/corpus/README.md`, `mise.toml:41-157`
- Current (incomplete) normalization: `tools/corpus/scion/cases.exs:15-25`
- Unnormalized W3C emitter: `tools/corpus/scxml_w3/cases.exs:112-166`
- Ratchet state: `test/passing_tests.json`
- Related ADR: `docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md`
