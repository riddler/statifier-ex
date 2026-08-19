# ADR Number Collision Guard Implementation Plan

## Overview

Implement ADR-0056 (`docs/adr/0056-adr-number-collisions-fail-the-gate-tree-locally.md`,
accepted 2026-08-19, uncommitted on this branch): make a concurrent ADR number
collision a named `mix quality` failure instead of a human catch at rebase
time. The mechanism is a **tree-local numbering invariant** enforced inside the
existing `ADR guard` stage, plus a secondary base-ref early-warning half, plus
a narrowed no-base-ref skip so the tree-local half can never report itself
skipped while a collision sits in the tree.

Bead: **st-9vco** (`area:gate-tooling`), the prevention half of the pair split
from st-8d5e (the stale-citation cleanup half).

This plan implements an accepted record. It does not re-open ADR-0056's
alternatives (a plan-time number reservation, or a cheap renumber-and-repoint
script), both of which decision 7 weighed and declined; it does not add a new
gate stage, a fetch, or a new skip line, all of which decision 3 forbids.

## Current State Analysis

**The seam exists and is close to the right shape.**
`lib/mix/statifier/adr_guard.ex` already splits into a git-and-filesystem
`collect/1` (`:181-199`) and a pure `analyze/1` (`:155-164`), with
`opts[:runner]` and `opts[:reader]` seams (`:182-183`) that let every test
drive it without a fixture repository. `Mix.Tasks.Adr.Check.execute/2`
(`lib/mix/tasks/adr.check.ex:72-81`) is a three-way dispatch on `collect/1`'s
return, and the stage is registered in `.quality.exs:92-99` as `ADR guard`,
`kind: :reader`, `skip_exit_code: 2`, absent from the loop profile.

**Every existing check is a pattern over added diff lines.** `analyze/1`
composes five list comprehensions over `parse_diff/1`'s output
(`adr_guard.ex:520-544`). The new checks are different in kind: they are
questions about the working tree's *filenames and README*, not about diff
lines. They therefore need new data on `source`, not new patterns.

**`source` is already extensible.** The `@type source` (`:62-65`) is
`%{:diff => String.t(), optional(:files) => %{String.t() => String.t()}}` -
the `:files` key was added for the ADR-0018 heredoc check and is optional, so
`analyze/1` tolerates a hand-built `%{diff: ...}`. All 663 lines of
`test/mix/statifier/adr_guard_test.exs` build sources that way. A third
optional key follows that precedent exactly and keeps those tests untouched.

**The no-base-ref path is currently all-or-nothing.** `collect/1` returns the
bare atom `:no_base_ref` (`:187`), `execute/2` turns it into `{:skip, ...}`
(`:78`), and `run/1` exits 2, which `skip_exit_code: 2` turns into a reasoned
skip. There is no way today to run part of the guard. Two existing tests pin
that behavior: `adr_check_test.exs:95` ("no base ref is a skip that writes its
own reason") and `:165` ("a skip states its reason as prose"), both asserting
the exact string `"no base ref: neither origin/main nor main resolves"`.

**The README is prose today and the bijection happens to hold.** Verified
against the working tree: `docs/adr/` holds 56 files matching
`[0-9][0-9][0-9][0-9]-*.md`, `docs/adr/README.md`'s table holds 56 rows, there
are no duplicate number prefixes, no duplicate rows, no missing rows, and no
dangling links. The only non-row content is the footer prose after the table
("New ADRs: next number, same three-section format ..."). The table is the
file's only link-bearing structure, so a link-target-scoped parser sees exactly
the record rows.

**The branch's own tree is already the first test case.** This branch adds
`docs/adr/0056-...md` (untracked) and its README row (modified). Both were
placed correctly, so the invariant this plan adds must pass against the very
branch that adds it - which is the self-referential hazard Phase 1's success
criteria verify explicitly rather than discovering at commit time.

**The ledger is not mechanically required here.** `mix gate.check` guards only
the paths in `.claude/wurk.json`'s `gate.moving_files`: `.quality.exs`,
`.credo.exs`, `coveralls.json`, `.sobelow-conf`, `.doctor.exs` (plus
gate-relevant `mix.exs` lines, `@tag :skip` additions, and a shrinking
`test/passing_tests.json`). Neither `lib/mix/statifier/adr_guard.ex` nor
`lib/mix/tasks/adr.check.ex` is guarded, and this plan touches no guarded path.
**`mix gate.check` will therefore be green with or without a
`docs/quality-gate-changes.md` entry** - exactly the situation st-wjg's entry
(`docs/quality-gate-changes.md:280-310`) describes and calls "voluntary".

### Key Discoveries:

- `Mix.Statifier.AdrGuard.collect/1` - `lib/mix/statifier/adr_guard.ex:181-199`;
  base-ref resolution order `opts[:base]` / `origin/main` / `main` at `:184-189`.
- `analyze/1`'s composition point - `lib/mix/statifier/adr_guard.ex:155-164`.
- The finding shape - `lib/mix/statifier/adr_guard.ex:511-513`:
  `%{file:, line:, severity:, check:, message:}`. `line` is typed
  `pos_integer() | nil` (`:56`), and the task's `human/1`
  (`lib/mix/tasks/adr.check.ex:115-117`) unconditionally prints
  `"#{file}:#{line}"` with a comment claiming there is always a line number.
  A file-level finding with `line: nil` prints `"docs/adr/README.md:"` - a
  cosmetic defect Phase 1 must fix in `human/1`, not by inventing a line.
- `execute/2`'s three-way dispatch - `lib/mix/tasks/adr.check.ex:76-81`.
- The stage registration - `.quality.exs:92-99`, `skip_exit_code: 2`.
- The two skip-pinning tests - `test/mix/tasks/adr_check_test.exs:95-100` and
  `:164-169`.
- The `runner/1` stub shape - `test/mix/statifier/adr_guard_test.exs:477-483`
  and `test/mix/tasks/adr_check_test.exs:10-24`; `rev-parse` is keyed by the
  ref it is asked to resolve.
- ADR-0056 decisions 1-7 and its two Open Questions
  (`docs/adr/0056-...md:199-218`), both resolved below.
- ADR-0011 and st-wjg's precedent - `docs/quality-gate-changes.md:280-310`.
- Sabotage note format - `docs/testing.md:146-176`:
  `# sabotage: <what was broken> -> red`, above the `test` line.
- `changelog.d/README.md:29-33` puts "quality gate, CI, or agent tooling
  changes" on the no-fragment list. **No changelog fragment is owed.**

## Desired End State

After this plan, `mix quality` fails, naming both files, whenever:

1. two files in `docs/adr/` share a four-digit number prefix;
2. `docs/adr/README.md`'s table and `docs/adr/` are not in bijection - a record
   with no row, a number with two rows, or a row whose link target does not
   exist;
3. (early warning only) the branch adds `docs/adr/NNNN-*.md` whose number
   already exists on the resolved base ref under a different filename.

Checks 1 and 2 run even when no base ref resolves, so the stage cannot report
itself skipped while a visible collision sits in the tree. Check 3 is honest
about its own asymmetry: a finding is always real, a pass promises nothing when
`origin/main` is stale.

Replayed against st-hbdr: after `wurk:mr` step 3's `git fetch origin` and
rebase, main's `0052-chart-identity-and-position-serialization.md` and the
branch's `0052-...-test-helpers...md` both sit in `docs/adr/`; check 1 fires
naming both paths and check 2 fires on the missing/duplicate row. Step 4's
full gate is red before the push.

**How to verify the end state**: with the branch's own tree, a bare
`mix quality` is green (the tree is consistent). Hand-copying any existing ADR
to a colliding filename makes the ADR guard stage red with both paths named;
deleting a README row makes it red on the bijection; both revert to green.

## What We're NOT Doing

- **No `.git/FETCH_HEAD`-mtime freshness advisory.** ADR-0056's Open Question 1
  raises it and declines it by default: an mtime heuristic mislabels a fresh
  clone and adds a claim the check cannot fully stand behind. This plan takes
  the record's default and does not implement it. The `.claude/wurk/mr.md`
  fetch-then-gate sequence is the freshness guarantee; a per-run advisory would
  restate it less reliably.
- **No new `.quality.exs` stage, no `enabled: false` entry, no fetch inside the
  gate.** ADR-0056 decision 3. A second stage matching
  `^disabled in \.quality\.exs$` would silently widen CLAUDE.md's
  not-applicable classification, and a fetch-dependent stage that skips when
  offline is the self-skipping shape the bead's acceptance criterion forbids.
- **No renumber-and-repoint script.** ADR-0056 decision 7 declines it as the
  primary mechanism; it remains available to st-8d5e or a successor.
- **No citation checking outside `docs/adr/`.** Stale citations in `lib/`
  moduledocs, plans, or the gate ledger are st-8d5e's scope (ADR-0056
  Consequences). The bijection covers `docs/adr/` and its README only. This is
  also what keeps the check clear of ADR-0056's own warning that a mechanical
  link check over ADR citations must distinguish pointer sites from
  historical-statement sites.
- **No parsing of the README's Decision or Status prose columns.** ADR-0056
  decision 5 scopes the machine-read half to the number, the link target, and
  row uniqueness. "superseded by 0017", "amends 0015 in part" and similar stay
  human-owned.
- **No agent-authored `docs/quality-gate-changes.md` entry.** CLAUDE.md: the
  entry "is a human's call on the record, not one an agent writes for itself."
  It is listed under Deferred Manual Verification as a human task, with the
  finding that `mix gate.check` does not block the branch without it.
- **No changelog fragment.** `changelog.d/README.md:33` excludes gate tooling.
- **Not correcting the "untracked" description of `0056` in Current State
  Analysis.** The plan critic read the working tree as clean and flagged the
  wording as stale. It is not: `git status --short` at planning time reports
  `?? docs/adr/0056-adr-number-collisions-fail-the-gate-tree-locally.md` and
  ` M docs/adr/README.md`. Recorded here so the discrepancy is not
  re-investigated. The framing is load-bearing either way, since the tree-local
  check reads the filesystem and does not care about git status - which is
  precisely why an uncommitted record is already in scope.

## Implementation Approach

Three phases, each independently committable and independently green under a
full `mix quality`, ordered so that no phase leaves a half-wired structure
behind:

- **Phase 1** adds the tree-local invariant end to end - data on `source`,
  checks in `analyze/1`, reporting through `mix adr.check` - plus ADR-0056
  decision 6's README footer sentence. It is complete and useful on its own,
  and its gate run is the self-referential proof that this branch's own tree
  satisfies the invariant it introduces.
- **Phase 2** narrows the no-base-ref path so the Phase 1 checks run without a
  base ref. It is a behavior change to two pinned tests and is kept separate so
  the skip-semantics change is reviewable on its own diff.
- **Phase 3** adds the base-ref early-warning half and writes its asymmetry
  into the moduledoc and the task doc.

Phase ordering is a hard dependency chain: Phase 2 has nothing to run without
Phase 1's checks, and Phase 3's `{:no_base_ref, source}` handling is Phase 2's
shape. They are not parallelizable across worktrees.

**The `source` extension is the one design decision worth stating up front.**
`analyze/1` must stay pure and must keep tolerating the hand-built
`%{diff: ...}` sources that every existing test uses. So the numbering data
arrives as a third *optional* key, `:adr`, and each new check returns `[]` when
it is absent. This is the same move `:files` made for ADR-0018 and it means
Phase 1 changes no existing test.

**Directory listing is a filesystem read, not a git read.** "Tree-local" means
the working tree, so an untracked `docs/adr/0057-*.md` is in scope - which is
what makes the check fire on a record before it is ever committed. That means
`collect/1` needs a directory-lister seam alongside `opts[:reader]`.

## Phase 1: The tree-local numbering invariant

### Overview

`collect/1` gathers the `docs/adr/` listing and the README text; `analyze/1`
gains `adr-0056-duplicate-number` and `adr-0056-readme-index` checks; the task
prints file-level findings correctly; the README footer gains the
fetch-before-picking sentence.

### Changes Required:

#### 1. `source` gains an optional `:adr` key

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: extend `@type source` and add a `@type adr_index`.

```elixir
@type adr_index :: %{
        :files => [String.t()],
        :readme => String.t() | nil,
        optional(:base_files) => [String.t()]
      }

@type source :: %{
        :diff => String.t(),
        optional(:files) => %{String.t() => String.t()},
        optional(:adr) => adr_index()
      }
```

`:files` here is the list of basenames under `docs/adr/` matching
`[0-9][0-9][0-9][0-9]-*.md`; `:readme` is `docs/adr/README.md`'s full text, or
`nil` when it cannot be read (which is itself a finding). `:base_files` is
Phase 3's; declare it now so the type does not churn twice.

#### 2. `collect/1` gathers the index

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: add an `opts[:lister]` seam, compute the index once at the top of
`collect/1`, and thread it into `collect_from/4`.

**`collect_from/3` becomes `collect_from/4`** in this phase, not in Phase 2.
The index is a filesystem read that does not depend on the base ref, so it is
computed before the ref is resolved and passed down - which is also what lets
Phase 2 hand the same index to the no-base-ref branch without moving any code:

```elixir
def collect(opts) do
  runner = Keyword.get(opts, :runner, &git/1)
  reader = Keyword.get(opts, :reader, &File.read/1)
  lister = Keyword.get(opts, :lister, &File.ls/1)
  index = adr_index(lister, reader)
  candidates = Enum.reject([opts[:base], "origin/main", "main"], &is_nil/1)

  case Enum.find(candidates, &resolves?(&1, runner)) do
    nil -> :no_base_ref
    ref -> collect_from(ref, runner, reader, index)
  end
end

defp collect_from(ref, runner, reader, index) do
  with {:ok, base} <- run(runner, ["merge-base", ref, "HEAD"]),
       base = String.trim(base),
       {:ok, diff} <- run(runner, ["diff", base | @diff_flags]) do
    full_diff = diff <> untracked_diff(runner)
    {:ok, %{diff: full_diff, files: file_texts(full_diff, reader), adr: index}}
  end
end
```

Phase 1 leaves the `nil ->` branch returning the bare `:no_base_ref` atom
exactly as it does today; narrowing that branch is the whole of Phase 2.

```elixir
@adr_dir "docs/adr"
@adr_readme "docs/adr/README.md"
@adr_filename_pattern ~r/^(\d{4})-.+\.md$/

# Deliberately a filesystem listing rather than a git one: the invariant is
# about the working tree, so an untracked record that has not been committed
# yet is still in scope.
defp adr_index(lister, reader) do
  files =
    case lister.(@adr_dir) do
      {:ok, entries} -> entries |> Enum.filter(&Regex.match?(@adr_filename_pattern, &1)) |> Enum.sort()
      {:error, _reason} -> []
    end

  readme =
    case reader.(@adr_readme) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end

  %{files: files, readme: readme}
end
```

`opts[:lister]` defaults to `&File.ls/1` and mirrors the existing
`opts[:reader]` / `opts[:runner]` convention (documented at `:174-178`). A
missing `docs/adr/` directory yields `files: []`, which makes both checks
vacuous rather than raising - this task must run in a checkout that has no
`docs/adr/` without exploding.

#### 3. The duplicate-number check

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: new private `duplicate_number_findings/1`, added to `analyze/1`'s
composition.

Group the listed filenames by their four-digit prefix; any group with more than
one member is one finding **per file in the group**, each naming the other
paths in its message so the gate output identifies both sides of the collision
regardless of which finding the reader looks at first. `line: nil`, severity
`"error"`, check `"adr-0056-duplicate-number"`.

Message shape:

```
ADR number 0052 is used by two records; ADR-0056 requires one file per number
(also: docs/adr/0052-chart-identity-and-position-serialization.md)
```

#### 4. The README bijection check

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: new private `readme_index_findings/1`, added to `analyze/1`.

Parse rows with a link-target-scoped pattern - this resolves ADR-0056's Open
Question 2 by implementing the scoping from the start, as the record's own
guidance instructs:

```elixir
# Scoped by link target, per ADR-0056 open question 2: only rows whose link
# resolves to a record file in this directory are index rows. A future row
# linking a predicator-ex ADR, a wurk ADR, or an http(s) URL is not this
# check's business, and neither is the footer prose below the table.
@readme_row_pattern ~r/^\|\s*\[(\d{4})\]\((\d{4}-[^)\/]+\.md)\)/m
```

Four findings, all `line: nil`, check `"adr-0056-readme-index"`:

- **missing row**: a listed record file has no row whose link target equals its
  basename. `file:` is the record path.
- **dangling row**: a row's link target is absent from the directory listing.
  `file:` is `docs/adr/README.md`.
- **duplicate row**: two rows share a number, or two rows share a link target.
  `file:` is `docs/adr/README.md`.
- **unreadable README**: `readme` is `nil` while `files` is non-empty. `file:`
  is `docs/adr/README.md`. (Without this, deleting the README would make the
  bijection vacuously true - the silent-pass shape ADR-0056 exists to avoid.)

A row whose displayed number disagrees with its link target's prefix
(`| [0052](0053-...md) |`) is a duplicate-or-missing pairing under the rules
above and needs no fifth finding kind; the check keys on the **link target**,
because that is the half that has to resolve.

#### 5. `analyze/1` composition

**File**: `lib/mix/statifier/adr_guard.ex`

```elixir
def analyze(source) do
  files = parse_diff(source.diff)
  texts = Map.get(source, :files, %{})
  index = Map.get(source, :adr)

  naming_findings(files) ++
    effects_findings(files) ++
    eval_findings(files) ++
    uxid_findings(files) ++
    bead_id_findings(files, texts) ++
    duplicate_number_findings(index) ++
    readme_index_findings(index)
end
```

Both new functions have a `defp _(nil), do: []` head, so every existing
hand-built `%{diff: ...}` source keeps its current behavior.

#### 6. File-level findings print correctly

**File**: `lib/mix/tasks/adr.check.ex`
**Changes**: `human/1` (`:113-117`) currently assumes a line number and its
comment says so. Add a `line: nil` clause printing just the path, and correct
the comment: the diff-line checks always have a line, the numbering checks
never do.

#### 7. Moduledoc and task doc

**Files**: `lib/mix/statifier/adr_guard.ex` (moduledoc, `:2-52`),
`lib/mix/tasks/adr.check.ex` (moduledoc, `:4-35`, and `@advice`, `:45-53`)

State that two checks are not diff-line patterns but invariants over the
working tree, that they carry no line number, and that **they do not clear on
the `ADR-0\d{3}|deviation` escape hatch** - there is no such thing as a
justified duplicate ADR number, and an ADR citation is not a filename. Add one
sentence to `@advice` telling the reader the fix is a renumber plus a README
row move, not a suppression comment.

#### 8. ADR-0056 decision 6: the README footer sentence

**File**: `docs/adr/README.md`
**Changes**: extend the existing footer paragraph.

```markdown
New ADRs: next number, same three-section format (Context, Decision, Consequences),
drafted or reviewed at the direction level per `docs/workflow.md`. Pick the number
against a freshly fetched remote - `git fetch origin && git ls-tree origin/main
--name-only docs/adr/` - so a branch does not start behind a record that has
already landed; `mix quality`'s ADR guard catches a collision that materializes
later, but only once the colliding file is in your tree.
```

This is prose guidance per ADR-0017, not a mechanism, and it doubles as a live
test of the row parser's scoping: the footer is not a table row and must not be
read as one.

#### 9. Tests

**File**: `test/mix/statifier/adr_guard_test.exs`

A new `describe "ADR-0056 - numbering invariant"` block, driving `analyze/1`
with hand-built `%{diff: "", adr: %{files: [...], readme: "..."}}` maps - no
fixture repository, matching the file's existing convention. Cases:

- a consistent directory and table produce no findings;
- two files sharing `0052` produce two findings, each naming the other path;
- a record with no row produces a missing-row finding naming the record;
- a row whose link target does not exist produces a dangling-row finding;
- two rows for the same number produce a duplicate-row finding;
- a `nil` readme with a non-empty listing produces the unreadable finding;
- a listing with no matching files and a `nil` readme produces nothing
  (the empty-checkout case);
- a README whose table is followed by footer prose containing a parenthesized
  `.md` reference produces no dangling finding (scoping);
- a row linking outside `docs/adr/` (`../../other/docs/adr/0001-x.md`, or an
  `https://` target) is ignored by both halves (ADR-0056 open question 2);
- `analyze/1` on a source with no `:adr` key returns only the diff-line
  findings.

Plus, in the `describe "collect/1"` block: `collect/1` populates `:adr` from
the injected `lister` and `reader`, filtering non-record filenames
(`README.md`, `.DS_Store`, `draft.md`) out of `files`.

**File**: `test/mix/tasks/adr_check_test.exs`

- a numbering finding is reported as `{:error, _}` with the finding contract
  and an empty/absent line;
- prose output for a `line: nil` finding prints the path without a trailing
  colon.

Every test above carries a `# sabotage: <mutation> -> red` note per
`docs/testing.md:146-176`, verified by actually breaking the named code path
and confirming red. Examples: `# sabotage: group duplicate prefixes but return
[] for groups of size > 1 -> red`; `# sabotage: drop the link-target arm of
@readme_row_pattern so any [NNNN](...) row counts -> red`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix quality --profile loop` between edits;
      a loop or scoped run never satisfies this bar).
- [x] `mix gate.verify` exits zero, proving the run was a full, unprofiled,
      unscoped, un-`--skip`-ed gate.
- [x] `mix adr.check` alone exits 0 against this branch's tree.
- [x] **The self-referential check**: with `docs/adr/0056-...md` and its README
      row present in the tree, the new checks find nothing. This is the phase's
      whole point and is verified by the gate run itself, not by inspection.
- [x] The finding contract for a numbering finding carries `line: nil` in both
      prose and JSON - decided by the new tests in
      `test/mix/tasks/adr_check_test.exs`, which the full gate runs. (Not a CLI
      criterion: producing one requires hand-creating a colliding file, which
      is the Manual Verification item below.)
- [x] `mix quality --format json --report -` shows the `ADR guard` stage as
      passed, not skipped.
- [x] Doctor stays at its 100% thresholds - every new public function keeps a
      `@doc`/`@spec`; the new functions are private, so this is a no-change
      assertion to confirm rather than work to do.

#### Manual Verification:
- [ ] Sabotage each new test for real: `cp -f` an existing ADR to a colliding
      number, confirm `mix adr.check` names both paths and exits 1, `rm -f` it,
      confirm green. Then delete a README row, confirm the missing-row finding,
      restore it.
- [ ] The README footer sentence reads as guidance an author will follow, and
      its parenthesized `git` command does not confuse the row parser (covered
      by a test, but read the rendered table once).
- [ ] The moduledoc's claim that the numbering checks do not clear on the
      escape hatch matches the code.
- [ ] No regressions in the five existing checks - the diff touches none of
      their code paths.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full gate is the phase gate. In interactive execution, pause here for the
manual confirmation. Under `--loop`, the Automated Verification list gates
advancement and the manual items defer to the end.

---

## Phase 2: The no-base-ref path narrows to the diff-based halves

### Overview

ADR-0056 decision 4: the tree-local invariant needs no base ref, so it runs
regardless. The stage reserves its skip for the diff-based checks only, and can
no longer report itself skipped while a collision sits in the tree.

### Changes Required:

#### 1. `collect/1` returns a source alongside the no-base-ref signal

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: the bare `:no_base_ref` atom becomes `{:no_base_ref, source}`.
Phase 1 already computes `index` at the top of `collect/1` and threads it into
`collect_from/4`, so this phase changes exactly two lines - the `@spec` and the
`nil ->` branch:

```elixir
@spec collect(opts :: keyword()) ::
        {:ok, source()} | {:no_base_ref, source()} | {:error, String.t()}

# ... unchanged body ...
  case Enum.find(candidates, &resolves?(&1, runner)) do
    nil -> {:no_base_ref, %{diff: "", adr: index}}
    ref -> collect_from(ref, runner, reader, index)
  end
```

The tuple form is chosen over folding into `{:ok, _}` deliberately: the task
still has to distinguish "the diff-based checks ran and found nothing" from
"the diff-based checks did not run", and only the first is a pass.

#### 2. `execute/2` runs the tree-local half unconditionally

**File**: `lib/mix/tasks/adr.check.ex`

```elixir
case AdrGuard.collect(collect_opts(parsed, opts)) do
  {:ok, source} -> source |> AdrGuard.analyze() |> respond(json?)
  {:no_base_ref, source} -> source |> AdrGuard.analyze() |> respond_partial(json?)
  {:error, reason} -> {:error, failed(reason, json?)}
end
```

`respond_partial/2` returns `{:error, document(...)}` when the tree-local
checks found anything - a real collision is a failure whether or not a base ref
resolved - and `{:skip, skipped(json?)}` only when they found nothing.

#### 3. The skip reason states what did run

**File**: `lib/mix/tasks/adr.check.ex`
**Changes**: `@skip_reason` (`:43`) becomes:

```elixir
@skip_reason "no base ref: neither origin/main nor main resolves; " <>
               "the docs/adr/ numbering invariant ran and is clean"
```

A skip that does not say what still ran is exactly the silent skip the bead's
acceptance criterion forbids. The string is asserted verbatim in two existing
tests, both of which this phase updates.

#### 4. Exit-status documentation

**File**: `lib/mix/tasks/adr.check.ex` (moduledoc `:30-34`)
**Changes**: rewrite the exit-status paragraph - 2 now means "no base ref, so
the diff-based checks had nothing to diff against; the numbering invariant ran
and was clean", and 1 is possible with no base ref at all when a collision is
in the tree.

#### 5. Tests

**File**: `test/mix/statifier/adr_guard_test.exs`
- `:487`'s `collect/1` no-base-ref assertion updates to the tuple form and
  asserts the returned source carries `:adr` and an empty `:diff`.

**File**: `test/mix/tasks/adr_check_test.exs`
- `:95` and `:165` update to the new reason string.
- **New**: with no base ref and a colliding `:adr` index injected through
  `lister`/`reader`, `execute/2` returns `{:error, _}`, not `{:skip, _}`. This
  is the phase's reason for existing and is the direct mechanical statement of
  the bead's acceptance criterion.
- **New**: with no base ref and a clean index, `execute/2` returns
  `{:skip, _}` whose reason names the invariant as having run.

Each new or changed test carries its sabotage note; the changed ones get a note
that still names a mutation in the code path they now cover (e.g.
`# sabotage: have respond_partial/2 skip regardless of findings -> red`).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green; `mix gate.verify` exits zero.
- [x] The no-base-ref path is decided by the test suite, not by a CLI
      invocation: the two new `adr_check_test.exs` tests (colliding index with
      no base ref is `{:error, _}`; clean index with no base ref is
      `{:skip, _}` whose reason names the invariant) pass under the full gate.
      **There is no CLI form of this criterion in an ordinary worktree** -
      `--base` falls through to `origin/main`/`main` when it does not resolve,
      so `mix adr.check --base does-not-exist-anywhere` exercises the ordinary
      diff path, not this one. Checking it off from a CLI run would be checking
      off the wrong thing. The scratch-clone walkthrough is under Manual
      Verification.
- [x] `mix quality --format json --report -` still shows `ADR guard` as passed
      in a normal worktree (where `origin/main` resolves), i.e. this phase does
      not turn ordinary runs into skips.
- [x] No new pattern in `.claude/wurk.json`'s `gate.project_level_skips` or
      `gate.not_applicable_skips`, and no edit to `.quality.exs` - ADR-0056
      decision 4 turns on this being true, and ADR-0017 point 6's re-argument
      obligation is not triggered.

#### Manual Verification:
- [ ] In a scratch clone with no `origin` and no `main` (`git init` plus one
      commit), `mix adr.check` skips cleanly on a consistent `docs/adr/`, and
      fails naming both files once a colliding record is copied in.
- [ ] The new skip reason reads honestly: someone seeing it in a gate report
      can tell what was and was not checked.
- [ ] The `{:no_base_ref, source}` shape change is confined to this guard - no
      other caller of `AdrGuard.collect/1` exists (grep confirms `adr.check` is
      the only one).

**Implementation Note**: as Phase 1.

---

## Phase 3: The base-ref early-warning half

### Overview

ADR-0056 decision 2: a branch-added `docs/adr/NNNN-*.md` whose number exists on
the base ref under a different filename is a finding. This half moves detection
earlier on runs that happen to have fresh refs; it guarantees nothing, and the
code says so.

### Changes Required:

#### 1. `collect_from/4` carries the base listing

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: one more `git` call, keeping `analyze/1` pure.

```elixir
# Filenames only - the check compares numbers, and asking for anything more
# would make the guard's data depend on blob contents it never reads.
defp base_adr_files(runner, base) do
  case run(runner, ["ls-tree", "--name-only", base, "docs/adr/"]) do
    {:ok, output} ->
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&Path.basename/1)
      |> Enum.filter(&Regex.match?(@adr_filename_pattern, &1))

    {:error, _reason} ->
      []
  end
end
```

Stored on `source.adr[:base_files]` (the key declared in Phase 1). Resolved
against the same merge-base `collect_from/3` already computes at `:193`, not
against the ref tip: the question is "what number existed at the point this
branch diverged", and a merge-base listing is what makes a number *added by
this branch* distinguishable.

#### 2. The cross-ref check

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: `base_number_findings/1`, added to `analyze/1`.

For each number present in `files` but under a filename absent from
`base_files`, where the same number *is* present in `base_files` under a
different filename: one finding on the branch's file path, check
`"adr-0056-base-number"`, `line: nil`, message naming the base ref's filename
for that number and directing the author to renumber.

Absent `:base_files` (Phase 2's no-base-ref source, or a hand-built source)
returns `[]`.

Note the overlap with Phase 1's duplicate check is deliberate and harmless:
after a rebase both files are in the tree and both checks fire. Before a
rebase, only this one can. Neither subsumes the other.

#### 3. The asymmetry, written down

**Files**: `lib/mix/statifier/adr_guard.ex` (moduledoc),
`lib/mix/tasks/adr.check.ex` (moduledoc)

A short paragraph, quoting ADR-0056 decision 2's own framing: a finding from
this half is always real, a pass promises nothing when `origin/main` is stale,
and **no document, skill, or report may cite a bare-gate ADR guard pass as
evidence that no collision exists on the remote.** The guarantee lives in the
tree-local half at the post-fetch, post-rebase gate run.

#### 4. Tests

**File**: `test/mix/statifier/adr_guard_test.exs`
- a branch file whose number exists on the base under a different filename is a
  finding naming both;
- the same number under the *same* filename (an edit to an existing record) is
  not a finding;
- a number absent from the base is not a finding;
- an absent `:base_files` key produces no findings;
- `collect/1` populates `:base_files` from an injected `runner`'s `ls-tree`
  response, filtering `README.md` and any nested path out.

Each with its sabotage note.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` is green; `mix gate.verify` exits zero.
- [ ] `git fetch origin && mix adr.check` exits 0 on this branch. **The fetch
      is part of the criterion, not a preamble to it.** ADR-0056 decision 2
      says a pass from this half "promises nothing when `origin/main` is
      stale", and that "no document, skill, or report may cite a bare-gate ADR
      guard pass as evidence that no collision exists on the remote" - a plan
      checkbox is such a report. Run without an immediately preceding fetch,
      this box is not checkable; with one, it mechanically confirms ADR-0056's
      Consequences claim that 0055 was the highest number on the remote and
      0056 is free on both sides.
- [ ] With a scratch branch that copies an existing on-main record to a new
      filename under the same number, `mix adr.check` exits 1 with an
      `adr-0056-base-number` finding.
- [ ] `mix quality --format json --report -` still shows `ADR guard` passed.

#### Manual Verification:
- [ ] Replay st-hbdr's shape by hand: create a branch, add
      `docs/adr/0052-something-else.md` plus its README row, and confirm the
      guard names main's `0052-chart-identity-and-position-serialization.md`.
- [ ] The moduledoc's asymmetry paragraph is strong enough that a future reader
      does not cite a bare-gate pass as remote evidence.
- [ ] Confirm no `git fetch` was added anywhere in the guard or the task
      (ADR-0056 decision 3): `grep -rn "fetch" lib/mix/` returns nothing new.

**Implementation Note**: as Phase 1.

---

## Testing Strategy

### Unit Tests:

- `test/mix/statifier/adr_guard_test.exs` - the pure checks, driven with
  hand-built `%{diff: "", adr: %{...}}` sources, following the file's existing
  no-fixture-repository convention (`:5-26`). Edge cases: empty directory,
  unreadable README, footer prose that looks like a row, rows linking outside
  `docs/adr/`, a number appearing three times, a row whose displayed number and
  link target disagree.
- `collect/1` tests through `opts[:runner]` / `opts[:reader]` / the new
  `opts[:lister]`, extending the existing `describe "collect/1"` block
  (`:484-604`) and its `runner/1` stub shape (`:477-483`).
- `test/mix/tasks/adr_check_test.exs` - exit-status routing: a numbering
  finding is exit 1 in both prose and JSON; no base ref with a clean tree is
  exit 2 with the amended reason; no base ref with a collision is exit 1.
- Every test asserting `lib/` behavior carries `# sabotage: <mutation> -> red`
  per `docs/testing.md:167`, with the mutation actually run and confirmed red.
  The truthy-sentinel trap (`docs/testing.md:178-188`) is a live risk here:
  mutations must not be of the form `files || []`, since the guard's fallbacks
  are already empty lists and such a mutation would never fire.

### Manual Testing Steps:

1. On this branch, run `mix quality`. It must be green - the branch's own
   `0056` record and README row satisfy the invariant the branch introduces.
2. `cp -f docs/adr/0051-invoke-handlers-are-registered-per-session.md
   docs/adr/0052-duplicate-for-testing.md`; run `mix adr.check`. Expect exit 1
   naming both `0052-*` paths and a missing-row finding for the copy.
   `rm -f docs/adr/0052-duplicate-for-testing.md`; confirm green.
3. Delete the `0055` row from `docs/adr/README.md`; run `mix adr.check`. Expect
   a missing-row finding naming the record. Restore it.
4. Point a README row at a nonexistent file; expect a dangling-row finding.
   Restore.
5. In a throwaway `git init` clone with no remotes, confirm the skip path from
   Phase 2 behaves as documented in both the clean and colliding cases.
6. Replay the st-hbdr collision shape for Phase 3, as described in that phase's
   manual criteria.

## Resolved Questions

ADR-0056 records two open questions (`docs/adr/0056-...md:199-218`). Both are
resolved here, at implementation time, without reopening the decision - which
is what the record itself says is allowed. Neither remains open in this plan.

1. **Should the base-ref half warn about ref age?** *No.* The record declines
   it by default and permits it only if the implementer finds it "cheap and
   honest". A `.git/FETCH_HEAD` mtime is neither in a worktree-heavy workflow:
   `FETCH_HEAD` is per-clone, worktrees share it, and a fresh clone has an
   mtime that means "cloned", not "fetched" - so the advisory would be wrong in
   exactly the case (a fresh CI checkout) where it would be read most. Recorded
   in "What We're NOT Doing".
2. **Does the bijection tolerate the README's non-record rows?** *Scoped by
   link target from the start*, as the record instructs. Phase 1's
   `@readme_row_pattern` requires the link target to be a bare
   `NNNN-*.md` with no `/`, so a cross-repo path, an `https://` link, or a
   future superseded-records section linking elsewhere is invisible to both
   halves. Covered by two named tests in Phase 1.

## Open Questions for the human

**None block implementation.** These are the calls this planning session made
without a human present, recorded so they can be overridden cheaply:

1. **The skip reason string is being changed** (Phase 2), and two existing
   tests assert it verbatim. The wording chosen - "no base ref: neither
   origin/main nor main resolves; the docs/adr/ numbering invariant ran and is
   clean" - is a judgment about what a gate report should say. Any wording that
   names what still ran satisfies ADR-0056 decision 4.
2. **`{:no_base_ref, source}` versus folding into `{:ok, source}`.** The tuple
   keeps the pass/skip distinction honest at the task boundary. The alternative
   - always `{:ok, source}` plus a `base_ref: nil` field - is defensible and
   would leave `collect/1`'s spec simpler. Chosen the tuple because the
   sibling `Mix.Statifier.GateGuard` uses the same three-way return shape and
   the symmetry is worth keeping.
3. **Duplicate-number findings are emitted per file, not per number.** Two
   files sharing `0052` produce two findings. This doubles the finding count
   for one problem, which inflates the stage's `finding_count`, but it means
   whichever finding a reader looks at first names a real path they can act on.
4. **The gate-ledger entry is a human's call** and is deliberately absent from
   every phase - see Deferred Manual Verification.

## References

- Direction record: `docs/adr/0056-adr-number-collisions-fail-the-gate-tree-locally.md`
  (accepted 2026-08-19, uncommitted on this branch)
- Related ADRs: `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0017-*.md` (point 6, skip reclassification),
  `docs/adr/0018-*.md` (the precedent for adding a check to this guard)
- Implementation site: `lib/mix/statifier/adr_guard.ex`,
  `lib/mix/tasks/adr.check.ex`
- Stage registration: `.quality.exs:92-99`
- Existing tests: `test/mix/statifier/adr_guard_test.exs`,
  `test/mix/tasks/adr_check_test.exs`
- Ledger precedent: `docs/quality-gate-changes.md:280-310` (st-wjg)
- Sabotage convention: `docs/testing.md:146-212`
- Changelog policy: `changelog.d/README.md:29-33`
- Bead: `st-9vco` (prevention half; `st-8d5e` is the cleanup half)

## Deferred Manual Verification

### Human tasks - not for an agent

- [ ] **The `docs/quality-gate-changes.md` entry.** ADR-0056 decision 3 and its
      Consequences call for a **voluntary** entry with a human `Approved-by:`
      line, per st-wjg's precedent. CLAUDE.md states plainly that this entry
      "is a human's call on the record, not one an agent writes for itself", so
      no phase of this plan writes it and no agent should.

      **Verified, not assumed**: `mix gate.check` will *not* fail this branch
      without it. `.claude/wurk.json`'s `gate.moving_files` lists exactly
      `.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf`,
      `.doctor.exs`; `lib/mix/statifier/adr_guard.ex` and
      `lib/mix/tasks/adr.check.ex` are not guarded paths, this plan adds no
      `@tag :skip` and does not shrink `test/passing_tests.json`, and it edits
      no gate-relevant `mix.exs` line. The Gate guard stage is green either
      way. The entry is owed to the record, not to the gate.

      Content it should cover, if the human writes one: the two new checks and
      what each catches; that the README table is now machine-read (an author
      adding a record without its row now gets a named gate failure); the
      narrowed skip; and that nothing is loosened - no threshold moves, no
      check is skipped, no `.quality.exs` change.

### Phase 1
- [ ] Sabotage-by-hand of the colliding-file and missing-row cases (step 2 and
      3 of Manual Testing Steps).
- [ ] The README footer sentence reads as usable authoring guidance.

### Phase 2
- [ ] The scratch-clone no-base-ref walkthrough, clean and colliding.
- [ ] The amended skip reason is honest about what ran.

### Phase 3
- [ ] The st-hbdr replay against a real `origin/main`.
- [ ] Confirm no fetch was introduced anywhere under `lib/mix/`.
