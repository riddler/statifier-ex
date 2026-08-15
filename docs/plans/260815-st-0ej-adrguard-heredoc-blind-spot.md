---
date: 2026-08-15
planner: Claude
git_commit: baedffc10d695da3f682b4c9a65b188d13c78fff
branch: st-0ej-adrguard-heredoc
repository: statifier-ex
beads_issue: st-0ej
topic: "Closing Mix.Statifier.AdrGuard's mid-heredoc blind spot in the ADR-0018 bead-ID check"
tags: [plan, gate-tooling, adr-0018]
status: ready
---

# AdrGuard heredoc blind spot Implementation Plan

## Overview

`Mix.Statifier.AdrGuard`'s ADR-0018 bead-ID check cannot see a line added into
the middle of a doc heredoc whose opening `"""` is unchanged context, because
that opener never appears in a `--unified=0` diff. This plan closes that hole by
carrying the post-image text of the diffed `lib/` and `test/` files alongside the
diff in `source`, classifying doc context from the file rather than from the hunk,
and reaches the branch's own compliance first by rewording the two
`lib/statifier/evaluator.ex` moduledoc citations the direction stage settled.
Bead: st-0ej.

## Current State Analysis

- `lib/mix/statifier/adr_guard.ex:118` pins
  `@diff_flags = ["--unified=0", "--src-prefix=a/", "--dst-prefix=b/"]`, so a
  hunk carries added lines and nothing else.
- `doc_context_texts/1` (`lib/mix/statifier/adr_guard.ex:298`) reduces a file's
  added entries with an `in_heredoc?` flag that only turns on when
  `doc_context_step/2` (`:307`, `:312`) sees an added line matching
  `@doc_heredoc_open_pattern` (`:112`). An entry added mid-body into an existing
  `@moduledoc` therefore falls through the `true ->` branch at `:328` and is
  dropped as plain code, so `bead_id_findings/1` (`:267`) never checks it.
- The `entry.previous != nil` term at `:301` resets the flag at each hunk
  boundary, which is correct today and stays correct after this change.
- The moduledoc states the hole as intended: `:28-30`, "A bead ID added mid-body
  into a heredoc whose opening delimiter is unchanged context ... is a known
  blind spot, not a design goal." The inline comment at `:291-297` repeats it.
- `test/mix/statifier/adr_guard_test.exs:304` currently *binds* the blind spot -
  `test "a bead ID added into a heredoc whose opener is not in the diff is not
  caught"` asserts `analyze(%{diff: diff}) == []`. That test is the one this
  plan inverts.
- `analyze/1` (`:132`) is pure: `source :: %{diff: String.t()}` in, findings out.
  `collect/1` (`:154`) is the only git-talking part and takes `opts[:runner]`
  (`:155`), which is why the 550-line test file needs no fixture repository.
- Empirically confirmed on this branch: a synthetic `--unified=0` diff whose only
  hunk is `@@ -115,0 +116,1 @@` adding a copy of the existing line-115 text
  (`` (`bench/results/260815-st-59d-predicator-8-0.md`): at `:corpus`, ``) into
  `lib/statifier/evaluator.ex`'s moduledoc returns `[]` from `analyze/1` today.
  The citation being reworded lives at line 115; 116 is only where the probe
  inserted its copy.
- The branch is level with `origin/main` (`git merge-base origin/main HEAD ==
  HEAD`, empty diff), so nothing is red right now and the two evaluator
  citations at `:93` and `:115` are unchanged context, not added lines.

## Desired End State

`Mix.Statifier.AdrGuard.analyze/1`, given a `--unified=0` diff whose hunk
contains only a mid-body doc-heredoc line plus the post-image text of that file,
classifies the line as doc text and reports an `adr-0018-bead-id` finding at that
line. `collect/1` supplies that text for every `lib/` and `test/` path in the
diff, through a `opts[:reader]` seam shaped like the existing `opts[:runner]`.
The guard's moduledoc and the comment above `doc_context_texts/*` no longer
describe the blind spot as known. The two evaluator moduledoc citations carry no
bead-id-bearing filename. `mix quality` is green and `mix adr.check --base
origin/main` exits 0 against the branch's own diff.

### Key Discoveries:

- `analyze/1` takes a map, so the fix can be data-in/data-out: adding an optional
  `files` key keeps purity intact and keeps every existing test constructing its
  input by hand (`lib/mix/statifier/adr_guard.ex:59`, `:131`).
- Existing `collect/1` tests match with `=` on `{:ok, %{diff: ...}}`
  (`test/mix/statifier/adr_guard_test.exs:439`, `:497`, `:530`), so a new `:files`
  key in the returned map breaks none of them.
- `bead_id_in_scope?/1` (`:283`) already restricts the check to `lib/` and
  `test/`, which is the exact set of paths worth reading.
- Entry line numbers are post-image line numbers (`hunk_start/1`, `:453`, parsing
  `@@ -x +y`), and `git diff <base>` compares the base tree to the working tree,
  so `entry.line` indexes directly into the working-tree file. Untracked files
  are diffed `--no-index /dev/null <path>` (`:189`), so their post-image is the
  working-tree file too.
- Doctor runs at 100% on every axis (`.doctor.exs`), so any new function must be
  private, or carry both `@doc` and `@spec`.
- `changelog.d/README.md` lists "quality gate, CI, or agent tooling changes"
  under *do not write a fragment*, so this bead gets none.
- The direction decision is settled in
  `docs/research/260815-st-0ej-bench-results-under-adr-0018.md`: no ADR-0018
  amendment, no ledger entry, no `ADR-0018-exempt` markers, reword the two
  evaluator lines instead. ADR-0011 is satisfied because this strengthens the
  gate rather than weakening it, and `lib/mix/statifier/adr_guard.ex` is not in
  the manifest's `gate.moving_files`.

## What We're NOT Doing

- **Not amending ADR-0018** and not adding any `ADR-0018-exempt` marker. Settled
  by the direction stage.
  *(Amended during Phase 2: this bullet also said "not writing a
  `docs/quality-gate-changes.md` entry", which held for ADR-0018's sake but was
  overtaken by the mechanism. `collect/1`'s new `File.read/1` default reader
  trips Sobelow's `Traversal.FileModule`, which blocks under this project's
  deliberate `exit: "low"`, and no code-level fix clears it. `.sobelow-conf` is
  a guarded path, so `adr_guard.ex` joining the two dev-only Mix support modules
  already excluded there needed a human-approved ledger entry - written and
  approved on 2026-08-15. It excludes one path with its reason stated and moves
  no threshold.)*
- **Not touching `lib/statifier/machine/content/foreach.ex:255`.** Its
  `bench/results/260814-macrostep.md` citation carries no bead id, so it is legal
  before and after this change. The research note's recorded open question about
  bead-id-free dated filenames stays a human review matter.
- **Not sweeping the tree for pre-existing bead ids in doc heredocs.** There are
  roughly forty such lines today (`lib/statifier/interpreter.ex`'s `st-cmq`
  seams, the `docs/plans/...-st-af3.x-...` citations in `compiler.ex`,
  `executable_content.ex`, `validator/checks/*`, `lowering/builders.ex`, and
  `validator/checks/donedata.ex`'s `st-hyx`). The guard only ever checks lines a
  diff *adds*, so none of them is red on this branch. See "Risks" for what this
  costs future branches; fixing them is separate work, and this plan deliberately
  leaves them alone rather than smuggling a forty-line doc edit into a
  gate-tooling change.
- **Not changing `@diff_flags`.** It is pinned on purpose against
  `diff.mnemonicPrefix`, and the alternatives that would widen it are rejected
  below.
- **Not widening the ADR-0018 check beyond bead IDs.** Phase numbers and plan
  filenames stay a review matter, per the moduledoc at `:16-19`.

## Implementation Approach

### The mechanism, and why not the others

The check needs one fact a `--unified=0` diff cannot carry: whether post-image
line N of a file sits inside a doc heredoc. Four ways to get it:

1. **Widen the diff context (`--unified=N`).** Rejected: no finite N is sound,
   because a moduledoc is arbitrarily long, and a mid-body line 200 lines below
   its opener is exactly the case that motivated the bead. It also un-pins
   `@diff_flags`.
2. **`--function-context` (`-W`).** Rejected: it depends on git having a
   `.ex` userdiff driver wired through `.gitattributes`, so the guard's answer
   would vary with a developer's git version and repo attributes - the precise
   failure `@diff_flags` is pinned to prevent. It is also unreachable from the
   test suite, which builds every diff by hand rather than from a repository, so
   the new behavior could not be bound by a test.
3. **Drop the doc-versus-code distinction for the bead check.** Rejected: it
   contradicts the existing binding at
   `test/mix/statifier/adr_guard_test.exs:338` ("a bead ID inside ordinary code
   is not a comment or doc string") and would flag every bead-id-shaped fixture
   string in `test/`, including this guard's own test file.
4. **Carry the post-image file text alongside the diff in `source`.** Chosen.

Option 4 costs `analyze/1` nothing in purity: it is still a function of its
argument, with a larger argument. The I/O stays where the module already puts it,
in `collect/1`, behind a second injectable seam of the same shape as
`opts[:runner]`, so tests still never need a fixture repository. It is also the
only option whose new behavior a hand-built test can bind, which the acceptance
criteria require.

### The classification change

Rather than replace the hunk-local heredoc tracking, seed it. Derive from the
file text a set of post-image line numbers that lie inside a doc heredoc body,
and treat an entry as heredoc text when *either* the hunk-local flag is on
(today's behavior, still the fallback when no text is available) *or* its line is
in that set. This is the smallest change that closes the hole, preserves every
existing assertion in the 550-line test file, and keeps the hunk-boundary reset
at `:301` meaningful for the fallback path.

### Ordering

Phase 1 (the evaluator rewording) lands before Phase 2 (the guard) so that the
guard never gains sight of a line the branch itself added in violation. Both
phases are green on their own: Phase 1's reworded lines carry no bead id under
either the old or the new guard, and Phase 2 adds no bead-id-bearing doc text.

---

## Phase 1: Reword the evaluator's bench-capture citations

### Overview

Drop the two bead-id-bearing `bench/results/` filenames from
`lib/statifier/evaluator.ex`'s moduledoc, citing the durable homes that already
name those captures instead. This is the direction stage's settled outcome, and
it makes the branch compliant before the guard can see these lines.

### Changes Required:

#### 1. The provider/host seam paragraph

**File**: `lib/statifier/evaluator.ex` (around line 92-93)
**Changes**: Drop the filename from the parenthetical, keep the ADR pointer. The
paragraph's quoted numbers all stay.

```
  # from:
  ... binds each datamodel root with `bind/3`. Measured (ADR-0030,
  `bench/results/260814-st-l0t-provider-host-seam.md`): at a realistic
  # to:
  ... binds each datamodel root with `bind/3`. Measured (ADR-0030): at a
  realistic
```

Rewrap the paragraph to the file's existing width after the edit.

#### 2. The predicator 8.0 `normalize: false` paragraph

**File**: `lib/statifier/evaluator.ex` (around line 114-115)
**Changes**: Replace the dated filename with a pointer through ADR-0030's
amendment note and `bench/README.md`. Exact wording is the implementer's; the
constraints are **no bead id and no dated filename**, and every quoted number
stays.

```
  # from:
  ... whole context per site with `new/2` ... Measured
  (`bench/results/260815-st-59d-predicator-8-0.md`): at `:corpus`,
  # to (shape, not mandated wording):
  ... Measured (the predicator 8.0 capture ADR-0030's amendment note and
  `bench/README.md` cite): at `:corpus`,
```

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (use `mix quality --profile loop` while
      iterating; a loop run alone never satisfies this phase).
- [x] `grep -nE '(?<![a-zA-Z0-9])st-[a-z0-9]+' -P lib/statifier/evaluator.ex`
      returns only the two pre-existing `# ` comment lines at `:215-216`
      (`docs/research/260812-st-unt-*`, `docs/research/260812-st-af3.3-*`), and no
      match inside the moduledoc heredoc.
- [x] `mix adr.check --base origin/main` exits 0.

#### Manual Verification:

- [x] The paragraphs still read as prose after rewrapping, and no measured number,
      unit, or comparison was lost or altered.
- [x] `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md` and
      `bench/README.md` genuinely name the captures the reworded text points at,
      so a reader can still reach the numbers' provenance in one hop.
- [x] Doc text only: no function body in `lib/statifier/` changed, so no Appendix D
      function's correspondence to the pseudocode is affected by this phase.

**Implementation Note**: Use `mix quality --profile loop` between edits; run full
`mix quality` as the phase gate. In interactive execution, pause here for the
human to confirm the manual items before Phase 2. In `--loop` execution the
automated list gates advancement and the manual items are surfaced at the end.

---

## Phase 2: Close the blind spot in the guard

### Overview

Give `analyze/1` the post-image text of the diffed `lib/` and `test/` files,
classify doc-heredoc membership from that text, populate it in `collect/1` behind
an injectable reader, invert the test that binds the blind spot, and delete the
two places the moduledoc and comments still call it known.

### Changes Required:

#### 1. The source type and `analyze/1`

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: `source` gains an optional `files` map from post-image path to file
content. `analyze/1` reads it defensively so a hand-built `%{diff: ...}` keeps
working.

```elixir
@type source :: %{:diff => String.t(), optional(:files) => %{String.t() => String.t()}}

def analyze(source) do
  files = parse_diff(source.diff)
  texts = Map.get(source, :files, %{})

  naming_findings(files) ++
    effects_findings(files) ++
    eval_findings(files) ++
    uxid_findings(files) ++
    bead_id_findings(files, texts)
end
```

#### 2. Doc-context classification seeded from the file text

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: `bead_id_findings/2` passes the file's text through;
`doc_context_texts/2` derives the heredoc-body line set once per file and ORs it
into the hunk-local flag. `doc_context_step/2` is unchanged.

```elixir
defp bead_id_findings(files, texts) do
  for {path, entries} <- files,
      bead_id_in_scope?(path),
      {entry, text} <- doc_context_texts(entries, Map.get(texts, path)),
      ...
end

defp doc_context_texts(entries, file_text) do
  body_lines = doc_heredoc_body_lines(file_text)

  entries
  |> Enum.reduce({false, []}, fn entry, {in_heredoc?, acc} ->
    carried? = in_heredoc? and entry.previous != nil
    doc_context_step(entry, {carried? or MapSet.member?(body_lines, entry.line), acc})
  end)
  |> elem(1)
  |> Enum.reverse()
end
```

`doc_heredoc_body_lines/1` returns an empty `MapSet` for `nil`, and otherwise
walks the file's lines with a 1-based index, opening on
`@doc_heredoc_open_pattern` and closing on a trimmed `"""`, collecting the line
numbers strictly between the delimiters. It reuses the module's existing patterns
rather than introducing new ones. Keep it private (Doctor runs at 100%).

#### 3. `collect/1` populates the text

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: a `opts[:reader]` seam defaulting to `&File.read/1`, mirroring
`opts[:runner]`; `collect_from/3` reads the post-image paths the diff names,
filtered to `lib/` and `test/`, and drops any path the reader cannot read (a
deleted file, a race). Paths come from the `+++ b/<path>` lines of the assembled
diff, skipping `+++ /dev/null`.

```elixir
{:ok, %{diff: full_diff, files: file_texts(full_diff, reader)}}
```

Update `collect/1`'s `@doc` to name `opts[:reader]` beside `opts[:runner]`, and
its `@spec` is unchanged because `source` already carries the new key.

#### 4. Moduledoc and comment truth

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: two edits, both deletions-plus-restatement rather than additions.

- Moduledoc `:24-30`: keep the "line-based rather than AST-based" framing and the
  list of shapes it recognizes, and replace the final sentence ("A bead ID added
  mid-body ... is a known blind spot, not a design goal") with a statement that a
  doc heredoc's extent is read from the file's post-image text carried on
  `source`, so a body line added below an unchanged opener is still doc text. Add
  a sentence to the `analyze/1`-is-pure paragraph at `:46-48` noting that the
  file text arrives as data on `source` and `collect/1` is what reads it.
- The comment at `:291-297`: drop the "known blind spot" sentence and describe
  the seeded flag instead - `in_heredoc?` turns on from the hunk's own opening
  `"""` or from the file's heredoc-body line set, and the `previous == nil` reset
  still bounds the hunk-local half.
- **No bead id may appear in either edit**, in any new comment, or in any new
  test name - these are `lib/` and `test/` doc text, and the fixed guard checks
  them.

#### 5. Tests

**File**: `test/mix/statifier/adr_guard_test.exs`
**Changes**: replace the blind-spot test at `:298-313` and add the seam coverage.

- **Replace** `test "a bead ID added into a heredoc whose opener is not in the
  diff is not caught"` with the binding test the acceptance criteria name: a
  `--unified=0` diff whose single hunk is `@@ -11,0 +11,1 @@` plus one added body
  line, **no opening `"""` anywhere in the hunk**, together with `files: %{...}`
  carrying a post-image file whose `@moduledoc """` sits above that line and whose
  closing `"""` sits below it. Assert
  `[%{check: "adr-0018-bead-id", line: 11}] = AdrGuard.analyze(...)`.
  Sabotage note above it, per CLAUDE.md: `# sabotage: have doc_context_texts/2
  ignore the file-derived body-line set -> red`.
- **Add** a fallback test: the same diff with no `files` key returns `[]` and does
  not raise, documenting the degradation when a source carries no text rather
  than leaving it implicit. Sabotage note: `# sabotage: have
  doc_heredoc_body_lines/1 raise on nil instead of returning an empty set -> red`.
- **Add** a `collect/1` test with a reader spy asserting the returned source's
  `files` covers the `lib/` and `test/` paths the diff names and omits paths
  outside them. Sabotage note: `# sabotage: drop the lib/ + test/ filter from
  file_texts/2, so every diffed path is read -> red`.
- Keep the existing hunk-boundary test at `:319` as-is; it still binds the
  fallback path's reset.
- Verify the pre-existing test at `:284` (opener in the same hunk) still passes
  unchanged - that is the proof the fallback path was preserved.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating).
- [x] `mix gate.verify` confirms the run was a full, unscoped gate.
- [x] `mix test test/mix/statifier/adr_guard_test.exs` passes.
- [x] `mix adr.check --base origin/main` exits 0 on the branch's own diff - the
      guard, now able to see mid-heredoc additions, is clean against the very
      change that gave it sight (this covers the reworded evaluator lines from
      Phase 1, the guard's own rewritten moduledoc, and the new test names).

#### Manual Verification:

- [x] `git diff` over `test/mix/statifier/adr_guard_test.exs` shows every
      pre-existing assertion unchanged except the deliberately replaced
      blind-spot test at `:298-313` - the suite passing does not by itself prove
      no other test body moved.
- [x] Each new test's sabotage note is verified the way CLAUDE.md's convention
      asks: apply the mutation it names, confirm red, revert. This is an
      implementer action with eyes on the result, not something a single command
      decides.
- [x] The moduledoc no longer claims a blind spot anywhere, and what replaces it
      describes the mechanism that now exists rather than the one that was
      planned.
- [x] The comment above `doc_context_texts/2` and the moduledoc agree with each
      other and with the code.
- [x] Spot-check on a real repository state: stage a scratch edit that adds a
      bead-id-bearing line into the middle of an existing `@moduledoc` in
      `lib/`, run `mix adr.check`, confirm it fires at the right file and line,
      then revert the scratch edit.
- [x] Doc text and gate tooling only: nothing under `lib/statifier/` changes in
      this phase, so no Appendix D function's correspondence to the pseudocode is
      affected.

**Implementation Note**: Use `mix quality --profile loop` between edits; run full
`mix quality` as the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In `--loop` execution the automated list gates
advancement and the manual items are surfaced at the end.

---

## Risks

1. **Future branches inherit red where this one does not.** Around forty
   pre-existing lines in `lib/` carry bead ids inside doc heredocs - the `st-cmq`
   seam notes throughout `lib/statifier/interpreter.ex`, the
   `docs/plans/...-st-af3.x-...` citations in `compiler.ex`,
   `executable_content.ex`, `event_data.ex`, `machine.ex`,
   `interpreter/datamodel.ex`, `interpreter/content.ex`, `document/foreach.ex`,
   `lowering/builders.ex` and `validator/checks/*`, and `donedata.ex`'s `st-hyx`.
   None is red today, because the guard only checks added lines and this branch
   adds none of them. But once the blind spot closes, any future branch that
   reflows or re-indents one of those paragraphs re-adds the line and goes red.
   That is the strengthening working as intended, and the remedy is per line
   (reword, or `ADR-0018-exempt` where the citation is load-bearing) - but it is
   a real, newly-payable cost and whoever hits it first should not read it as a
   regression. Not fixed here, on purpose: see "What We're NOT Doing".
2. **The guard now reads its own test file's fixtures.** `adr_guard_test.exs`
   embeds diff fixtures containing `@moduledoc \"\"\"` lines. Checked: in the raw
   file those lines begin with a `+` and the delimiter is backslash-escaped, so
   they do not match `@doc_heredoc_open_pattern` (which anchors `^@` after
   trimming and requires a literal `"""` at end of line), and no phantom heredoc
   opens. The `mix adr.check --base origin/main` criterion in Phase 2 is what
   keeps this verified rather than assumed.
3. **Line-number alignment.** The approach depends on `entry.line` indexing into
   the working-tree file. That holds for `git diff <base>` (base tree versus
   working tree) and for the untracked `--no-index /dev/null <path>` form. It
   would not hold for `--cached`; the guard never passes it, and nothing in this
   plan adds it.

## Testing Strategy

### Unit Tests:

- `test/mix/statifier/adr_guard_test.exs`, `describe "analyze/1"`: the new
  mid-heredoc binding test (hunk without the opener, file text supplied), and the
  no-file-text fallback test.
- Same file, `describe "collect/1"`: the reader-spy test proving `files` is
  populated for `lib/` and `test/` paths and only those.
- Regression surface: the existing heredoc-opener-in-hunk test, the hunk-boundary
  test, the ordinary-code test, and the two escape-marker tests must all pass
  unchanged.
- Edge cases worth a line each in the new fixtures: a body line that is itself the
  closing `"""` (not doc text to check, and it carries no bead id anyway), and a
  file whose `@moduledoc` never closes (the derived set simply runs to end of
  file, which is what the reduce already tolerates).

### Manual Testing Steps:

1. `mix adr.check --base origin/main` on the finished branch: expect exit 0.
2. Add a scratch line containing a bead id into the middle of an existing
   `@moduledoc` under `lib/statifier/`, run `mix adr.check`, confirm one
   `adr-0018-bead-id` finding at that exact file and line, then revert.
3. Repeat step 2 with `ADR-0018-exempt` on the line above, confirm it clears.
4. Repeat step 2 inside a plain (non-`@doc`) heredoc in `test/`, confirm it does
   *not* fire - the check is about doc text, not every string.

## Changelog

No fragment. `changelog.d/README.md` lists "quality gate, CI, or agent tooling
changes" among the changes that get none, and nobody calling the public API can
tell the difference. This decision is recorded here rather than left implicit.

## References

- Source document: `docs/research/260815-st-0ej-bench-results-under-adr-0018.md`
- Related ADRs: `docs/adr/0018-no-process-jargon-in-code-comments.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md`
- Guard: `lib/mix/statifier/adr_guard.ex:24-30`, `:112`, `:118`, `:267`, `:298`
- Task: `lib/mix/tasks/adr.check.ex`
- Tests: `test/mix/statifier/adr_guard_test.exs:284`, `:298`, `:319`, `:406`
- Citations reworded: `lib/statifier/evaluator.ex:93`, `:115`
- Bead: `st-0ej`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [x] The paragraphs still read as prose after rewrapping, and no measured number,
      unit, or comparison was lost or altered.
- [x] `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md` and
      `bench/README.md` genuinely name the captures the reworded text points at,
      so a reader can still reach the numbers' provenance in one hop.
      *(Found a defect and fixed it: the phase-1 wording pointed at ADR-0030's
      amendment note, which cites `evaluator/functions.ex` rather than the 8.0
      capture. ADR-0030 does name that capture, but in its Context section at
      `:28`, not the amendment note, and not in its References. Reworded to cite
      `bench/README.md` alone, which names it at `:35` as the current capture.)*
- [x] Doc text only: no function body in `lib/statifier/` changed, so no Appendix D
      function's correspondence to the pseudocode is affected by this phase.

**Implementation Note**: Use `mix quality --profile loop` between edits; run full
`mix quality` as the phase gate. In interactive execution, pause here for the
human to confirm the manual items before Phase 2. In `--loop` execution the
automated list gates advancement and the manual items are surfaced at the end.

---
