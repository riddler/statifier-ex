# Filters W3C sub-documents out of the emitted corpus Implementation Plan

## Overview

Five W3C sub-documents (`test216sub1`, `test226sub1`, `test239sub1`,
`test242sub1`, `test276sub1`) are emitted as standalone `:scxml_w3` conformance
test modules that assert `test_scxml(xml, description, ["pass"], [])` even
though they are invoked children of another test and reach `<final id="final">`,
not `pass`. They are not conformance assertions at all: they are fixtures the
parent test's `<invoke>` loads. This plan teaches the W3C emitter to read the
upstream IRP manifest's own `<start>` / `<dep>` role declaration and skip
dependency documents, then regenerates the corpus so the five modules disappear.
Bead: st-rbp.

## Current State Analysis

**The emitter has no notion of a sub-document.**
`Cases.Emit.emit_case/6` (`tools/corpus/scxml_w3/cases.exs:115-171`) hardcodes
`test_scxml(xml, description, ["pass"], [])` at line 159 for every input, and
the driver at lines 177-203 emits one module per `.scxml` file handed to it by
`corpus:emit`'s `find` (`mise.toml`, `tasks."corpus:emit"`). Nothing in the
pipeline distinguishes a top-level test from a document another test invokes.

**The upstream manifest does distinguish them, explicitly.** The W3C IRP
`manifest.xml` marks each `<test>`'s entry point and its dependencies
separately:

```xml
<assert id="216"  specnum="6.4" specid="#invoke">
     <![CDATA[If the srcexpr attribute is present, ...]]>
<test id="216" conformance="mandatory" manual="false">
<start uri="216/test216.txml"/>
<dep uri="216/test216sub1.txml"/>
</test>
</assert>
```

Verified against a local mirror of the manifest
(`~/repos/github/ex_statechart/test/scxml_w3/cases/manifest.xml`): 202 `<start>`
elements and 9 `<dep>` elements, every one of them in the uniform shape
`<start uri="..."/>` / `<dep uri="..."/>` with no other attributes and no
nesting variation. Of the 9 deps, exactly 5 are `.txml` (the five sub-documents
above) and 4 are `.txt` (`test446.txt`, `test552.txt`, `test557.txt`,
`test558.txt`) - content files fetched by tests that read external resources.

**The fetcher takes every `.txml` uri under `<test>`, ignoring the role.**
`tools/corpus/scxml_w3/manifest.exs:23-31` maps over all children of `<test>`,
filters on `Path.extname(uri) == ".txml"`, and downloads each. That is why the
five sub-documents reach `scratch/`, get transformed by Saxon, and land in the
emitter's input list.

**Each of the five carries the parent's description, too.** The description is
read per `<assert>` (`manifest.exs:19`) and written next to every uri, so
`test216sub1_test.exs:19` asserts against the parent's `srcexpr` prose. The
defect is a role confusion, not just a wrong expected id.

**The `.txt` deps are a trap for any naive id-based filter.**
`<dep uri="446/test446.txt"/>` has basename `test446`, which is also a real
top-level test's id. A filter that collects dep basenames without checking the
extension, or without subtracting the ids that appear as a `<start>`, would
delete a legitimate conformance test. The filter must do both.

**xmerl is not reachable from `mix test`.** Verified in this worktree:
`mix run -e ':xmerl_scan.string(~c"<a/>")'` raises
`module :xmerl_scan is not available`, and `:code.lib_dir(:xmerl)` returns
`{:error, :bad_name}`. This is the pruning that `cases.exs:5-6` and
`manifest.exs` already document, and it is why the generators run under plain
`elixir` rather than `mix run`. Any manifest-parsing code that a `mix test`
unit test needs to reach therefore cannot use xmerl.

**There is an established pattern for unit-testing generator code.**
`tools/corpus/normalize.exs` is a pure module with no script body, shared by
both emitters and unit-tested by `test/corpus/normalize_test.exs:4` via
`Code.require_file/1`. `tools/corpus/scxml_w3/check_exprs.exs` does the same
with a `Mix.env() != :test` guard around its CLI body - a guard that would not
work here, since `cases.exs` runs under plain `elixir` where `Mix.env/0` has no
started Mix agent. The `normalize.exs` shape (module-only file, no top-level
body) is the one to copy.

**None of the five is in the ratchet.** `grep sub1 test/passing_tests.json`
returns nothing, so removing them shrinks nothing and needs no
`docs/quality-gate-changes.md` ledger entry under ADR-0011.

**The gate is green today.** `:scxml_w3` is excluded by default in
`test/test_helper.exs`, so the five failures do not make `mix quality` red.
The value of this change is corpus correctness and an honest emitted-case count,
not turning a red gate green.

**The committed counts are already stale.** `docs/testing.md:16-17` says 162
emitted W3C tests (159 mandatory + 3 optional); the tree holds 164 (161
mandatory + 3 optional). `tools/corpus/README.md:87-89` repeats the 162 figure.

**Regeneration is available offline in this environment.** Verified present:

- Mirror with the exact `<conformance>/<spec>/<id>.{txml,description}` layout
  plus `manifest.xml` at `~/repos/github/ex_statechart/test/scxml_w3/cases`.
- Saxon-HE jar at `~/repos/github/ex_statechart/saxon/saxon9he.jar`, which can
  be copied into `$CORPUS_SAXON_DIR` so `corpus:fetch:saxon` short-circuits on
  its own existence check.
- A JRE at `~/.local/share/mise/installs/java/temurin-21.0.11+10.0.LTS`.

`tools/corpus/scratch/` does not exist in this worktree, so the regeneration is
a cold one; the mirror turns the w3.org crawl into a copy.

## Desired End State

`test/scxml_tests/` contains 159 emitted W3C modules (156 mandatory + 3
optional) and no module whose SCXML is an invoked sub-document. `cases.exs`
skips dependency documents by reading the manifest's `<start>` / `<dep>`
declaration, reports how many it skipped, and fails loudly if the manifest is
not where it expects it. A `mix test` unit test pins the detection logic,
including the `test446.txt` collision case.

Verify by: running the W3C half of the emitter against a mirror-seeded scratch
tree and confirming the resulting `git status` is exactly five deletions under
`test/scxml_tests/` and nothing else; and by `mix test test/corpus/` passing.

### Key Discoveries:

- `tools/corpus/scxml_w3/cases.exs:159` - `["pass"]` is hardcoded for every
  emitted case.
- `tools/corpus/scxml_w3/manifest.exs:23-31` - fetches every `.txml` uri under
  `<test>` regardless of `<start>` vs `<dep>`.
- Upstream manifest declares the role directly; 202 `<start>`, 9 `<dep>`, of
  which 5 are `.txml`.
- `test446.txt` dep collides on basename with the real `test446` case - the
  filter must be extension-aware and must subtract `<start>` ids.
- xmerl is pruned from the Mix code path (verified), so the new module parses
  the manifest with a regex rather than xmerl.
- `tools/corpus/normalize.exs` + `test/corpus/normalize_test.exs:4` - the
  module-only-file plus `Code.require_file/1` pattern to copy.
- `tools/corpus/scxml_w3/cases.exs:205-214` - `System.halt(1)` on stale
  exclusions; the new filter must not feed that check.
- ADR-0004 governs `exclusions.exs` semantics ("no predicator equivalent"),
  which is why the fix does not live there.
- ADR-0006 governs the corpus-reuse and ratchet design this plan works within.

## What We're NOT Doing

- **Not hand-editing the five generated test files.** The project's
  no-hand-edited-corpus convention (`CLAUDE.md`, `docs/testing.md`) means the
  fix is in the generator. Their deletion is a consequence of a generator
  change, which is allowed; editing their bodies in place is not.
- **Not using `exclusions.exs`.** Its documented reasons are all "the predicator
  datamodel cannot run this" (`tools/corpus/scxml_w3/exclusions.exs:1-11`,
  ADR-0004), and its entries count toward the "excluded" tally the README
  reports as predicator coverage. "This file is not a standalone test" is a
  different category, and encoding it there would misreport coverage and
  require a hand-maintained list that upstream can invalidate.
- **Not using a `*subN` name heuristic.** Upstream declares the role in the
  manifest; a name pattern would be a guess that silently misfires the first
  time a legitimate case is named that way.
- **Not removing sub-documents from fetch or transform.** They stay in
  `scratch/`: a future `src`/`srcexpr` resolution feature for `<invoke>` will
  need them, `corpus:check` keeps asserting their expressions compile under
  predicator, and - decisively - a fetch-level fix would not be reliable. Fetch
  is incremental and the `CORPUS_W3_MIRROR` seed copies every `*.txml` it finds,
  so a `.txml` already in `scratch/` would survive the change. Only the emit
  stage is recomputed from nothing on every run (`corpus:emit` starts with
  `rm -rf "$CORPUS_W3_OUT"`), so only a filter there is idempotent.
- **Not changing the parent tests.** `test216`, `test226`, `test239`,
  `test242`, and `test276` inline their own XML and reference their children by
  `src="file:test239sub1.scxml"` / `srcexpr`. Nothing in the emitted corpus
  resolves those URIs today (verified: `Statifier.Case.test_scxml/4` takes an
  XML string and there is no `src` resolution path), so deleting the children's
  *test modules* cannot affect them. The children's `.scxml` files remain in
  `scratch/` for when resolution does arrive.
- **Not adding `:xmerl` to `mix.exs` `extra_applications`.** Pulling an OTP app
  into the library's application list to serve a build tool inverts the
  dependency the pruning comments deliberately maintain.
- **Not writing a changelog fragment.** `changelog.d/README.md:31` excludes
  "test harness, corpus tooling, or conformance fixtures" explicitly, and no
  public API or observable library behavior changes.
- **Not touching `test/passing_tests.json` or the gate ledger.** None of the
  five is in the registry, so nothing shrinks and ADR-0011's ledger requirement
  is not triggered.
- **Not investigating the pre-existing 162-vs-164 count drift in
  `docs/testing.md`.** Phase 2 restates the counts from the actual tree after
  the change, which corrects the drift as a side effect; tracing where the two
  extra cases came from is out of scope.

## Implementation Approach

The manifest already carries the answer, so the change is to route that fact to
the emitter rather than to invent a heuristic. The routing has to survive two
constraints discovered above: the emitter runs under plain `elixir` with no Mix
and no xmerl, and the detection logic has to be reachable from `mix test` so it
can be pinned by a unit test.

Both are satisfied by putting the detection in a module-only file with no script
body and no xmerl - a regex over the manifest's uniform `<start uri="..."/>` /
`<dep uri="..."/>` elements - loaded by `Code.require_file/1` from both
`cases.exs` and a new `test/corpus/` test, exactly as `normalize.exs` is today.
The regex is a deliberate trade: a formal parser would be more robust in
general, but xmerl would cost the automated test, and the input is a single
fixed upstream file whose element shape is verified uniform across all 211
occurrences.

Phase 1 lands the module and its tests with no change to emitted output, so it
is reviewable and gate-verifiable on its own. Phase 2 wires it into the emitter
and regenerates, so the corpus diff arrives as its own reviewable commit rather
than mixed with logic.

## Phase 1: Sub-document detection module

### Overview

Add a pure, xmerl-free module that turns manifest text into the set of ids that
are dependency documents, plus its unit tests. No generator behavior changes
yet, so the emitted corpus is untouched and the gate is green on this commit
alone.

### Changes Required:

#### 1. Detection module

**File**: `tools/corpus/scxml_w3/sub_documents.exs` (new)
**Changes**: Module-only file (no top-level script body, matching
`tools/corpus/normalize.exs`) defining `Cases.SubDocuments`. A moduledoc states
why it parses with a regex rather than xmerl (xmerl is pruned from the Mix code
path, and this module has to be loadable from `mix test`).

```elixir
defmodule Cases.SubDocuments do
  @moduledoc """
  The W3C IRP manifest marks each <test>'s entry point as <start uri="..."/>
  and every document that test invokes as <dep uri="..."/>. Only <start>
  documents are conformance tests; a <dep> is a fixture some parent loads via
  <invoke src>, and emitting one as a standalone test asserts the parent's
  expected configuration against a document that never reaches it.

  Parsed with a regex rather than xmerl: Mix prunes xmerl from the code path
  (see cases.exs), so an xmerl-based module could not be reached from
  test/corpus/. Both elements occur only inside <test> and only in the uniform
  self-closing single-attribute shape, verified across the whole manifest.
  """

  @role_pattern ~r/<(start|dep)\s+uri="([^"]*)"/

  @spec ids(Path.t()) :: MapSet.t(String.t())
  def ids(manifest_path), do: manifest_path |> File.read!() |> ids_from_string()

  @spec ids_from_string(String.t()) :: MapSet.t(String.t())
  def ids_from_string(manifest) do
    roles =
      @role_pattern
      |> Regex.scan(manifest)
      |> Enum.map(fn [_full, role, uri] -> {role, uri} end)

    starts =
      for {"start", uri} <- roles, into: MapSet.new(), do: Path.basename(uri, ".txml")

    deps =
      for {"dep", uri} <- roles,
          Path.extname(uri) == ".txml",
          into: MapSet.new(),
          do: Path.basename(uri, ".txml")

    MapSet.difference(deps, starts)
  end
end
```

The `.txml` extension filter and the `<start>` subtraction are both required:
`<dep uri="446/test446.txt"/>` would otherwise remove the real `test446` case.

#### 2. Unit tests

**File**: `test/corpus/sub_documents_test.exs` (new)
**Changes**: `Code.require_file/1` the module the way
`test/corpus/normalize_test.exs:4` does, with the generator-tooling sabotage
exemption line. Cases to pin, each from an inline manifest heredoc:

- a `<start>` + `<dep uri="...txml">` pair yields exactly the dep id
- a `.txt` dep is not returned (`test446.txt`)
- an id that appears as both a `<dep>` and a `<start>` is not returned (the
  `test446` collision, asserted directly rather than only via the extension
  filter)
- a manifest with no `<dep>` yields an empty set
- a heredoc reproducing the five real manifest entries verbatim (`<start
  uri="216/test216.txml"/>` / `<dep uri="216/test216sub1.txml"/>` and the same
  for 226, 239, 242, 276) yields exactly those five ids. Still an inline
  heredoc - this plan adds no committed manifest fixture file

```elixir
# sabotage: n/a - generator tooling (tools/corpus/), not lib/ behavior
```

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` while iterating (never the phase bar).
- [x] Full `mix quality` passes with no scoping, no `--quick`, no `--skip`.
- [x] `mix gate.verify` confirms the run was a full gate.
- [x] `mix test test/corpus/sub_documents_test.exs` passes and the new file is
      picked up by the default `mix test` run (it is not tagged `:scion` or
      `:scxml_w3`).
- [x] `git status --porcelain test/scxml_tests` is empty - this phase changes no
      emitted output.
- [x] `mix test.regression` passes (registry untouched, asserted rather than
      assumed).

#### Manual Verification:

- [ ] Spot-check two manifest entries against
      `~/repos/github/ex_statechart/test/scxml_w3/cases/manifest.xml` (or
      `https://www.w3.org/Voice/2013/scxml-irp/manifest.xml`) and confirm
      `<dep>` is upstream's own declaration of an invoked sub-document, not an
      inference this plan is making.
- [ ] No regressions in related features: `tools/corpus/normalize.exs` and
      `check_exprs.exs` are untouched, and `mise run corpus:check` is unaffected.

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are deferred to the end.

---

## Phase 2: Emitter filter and corpus regeneration

### Overview

Wire the detection into `cases.exs`, regenerate the W3C corpus, and update the
counts the docs report. This is the phase whose diff removes the five test
modules.

### Changes Required:

#### 1. Emitter

**File**: `tools/corpus/scxml_w3/cases.exs`
**Changes**: require the new module alongside `normalize.exs` (line 29), resolve
the manifest from `in_root`, fail loudly if it is missing, skip inputs whose
name is a sub-document, and report the tally. The sub-document check goes
*after* the `exclusions` check so an exclusions entry naming a sub-document
would still register as matched and not trip the stale check at lines 205-214.

```elixir
Code.require_file(Path.join([__DIR__, "sub_documents.exs"]))

# ... after `[out_root, in_root | inputs] = System.argv()`

manifest_path = Path.join(in_root, "manifest.xml")

if !File.exists?(manifest_path) do
  IO.puts(:stderr, "missing #{manifest_path}; run `mise run corpus:fetch:w3` first")
  System.halt(1)
end

sub_documents = Cases.SubDocuments.ids(manifest_path)
```

The reduce accumulator gains a `sub_document` counter, and the branch becomes:

```elixir
cond do
  Map.has_key?(exclusions, name) -> ...
  MapSet.member?(sub_documents, name) -> # counted, not emitted
  true -> Cases.Emit.emit_case(...)
end
```

The summary line at line 216 gains the count, e.g.
`emitted 159 W3C case(s), excluded 13, skipped 5 sub-document(s)`.

Also extend the header comment block at `cases.exs:13-23`, which currently says
"Two filters apply before a case is emitted", to describe three.

#### 2. Regenerated corpus

**Files**: deletion of
`test/scxml_tests/mandatory/invoke/test216sub1_test.exs`,
`test226sub1_test.exs`, `test239sub1_test.exs`, `test242sub1_test.exs`, and
`test/scxml_tests/mandatory/data/test276sub1_test.exs`.
**Changes**: produced by running the generator, not by hand. Offline procedure,
using the resources verified present in Current State Analysis:

```bash
export CORPUS_W3_MIRROR=~/repos/github/ex_statechart/test/scxml_w3/cases
mkdir -p tools/corpus/scratch/saxon
cp -f ~/repos/github/ex_statechart/saxon/saxon9he.jar tools/corpus/scratch/saxon/
mise run corpus:transform          # depends only on fetch:w3 + fetch:saxon
rm -rf test/scxml_tests
find tools/corpus/scratch/scxml_w3/cases -type f -iname '*.scxml' -print0 \
  | sort -z \
  | xargs -0 elixir tools/corpus/scxml_w3/cases.exs \
      test/scxml_tests tools/corpus/scratch/scxml_w3/cases
git status --porcelain test/scxml_tests
```

The W3C half is run directly rather than through `mise run corpus:emit`, because
that task also depends on `corpus:fetch:scion` (a GitHub clone) and `rm -rf`s
`test/scion_tests/`, neither of which this change needs. `test/scion_tests/`
must be left untouched.

**The diff is the verification.** `git status --porcelain test/scxml_tests` must
show exactly five ` D` lines and nothing else. Any additional add, delete, or
modify means the mirror has drifted from current upstream, and the regeneration
must be redone with a networked `mise run corpus:fetch:w3` (no
`CORPUS_W3_MIRROR`) before the phase can land.

If neither the mirror nor network is available, this phase cannot be completed
in that environment - do not hand-delete the five files to simulate it. Report
the blocker instead.

#### 3. Docs

**File**: `docs/testing.md`
**Changes**: line 16-17, restate the W3C suite counts from the post-change tree
(`find test/scxml_tests -name '*_test.exs' | wc -l`), expected 159 (156
mandatory + 3 optional), and note that dependency documents are not emitted.

**File**: `tools/corpus/README.md`
**Changes**: update the emitted count at lines 87-89, and extend the "Two
filters apply before a W3C case is emitted" list at lines 118-127 with the
sub-document filter and the reason it is not an `exclusions.exs` entry. Add
`scxml_w3/sub_documents.exs` to the layout block at lines 49-61.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` while iterating (never the phase bar).
- [x] Full `mix quality` passes with no scoping, no `--quick`, no `--skip`.
- [x] `mix gate.verify` confirms the run was a full gate.
- [x] `git status --porcelain test/scxml_tests` after regeneration shows exactly
      the five expected deletions and nothing else.
- [x] `git status --porcelain test/scion_tests` is empty.
- [x] `find test/scxml_tests -name '*_test.exs' | wc -l` returns 159, matching
      the number `docs/testing.md` now states.
- [x] `find test/scxml_tests -iname '*sub1_test.exs'` returns nothing. (Do not
      use `grep -rl sub1 test/scxml_tests` as the check: it legitimately still
      matches six files afterwards - the five parents that name a child inside
      their inlined XML, `test216`, `test226`, `test239`, `test242`, `test276`,
      plus `test422`, whose unrelated SCXML happens to declare
      `<state id="sub1">`.)
- [x] `mix test --include scxml_w3` no longer reports the
      `Expected active states ["pass"], but got ["final"]` failures for
      `test216sub1`, `test239sub1`, `test242sub1`.
- [x] `mix test.regression` passes - no registry entry pointed at a deleted
      file.
- [x] `mix test test/corpus/` passes, including `emitted_paths_test.exs`.
- [x] Re-running the emit command a second time produces no further diff
      (idempotent regeneration).
- [x] `mix gate.check` passes with no `docs/quality-gate-changes.md` entry,
      confirming this branch touches no guarded path.

#### Manual Verification:

- [ ] A full networked `mise run corpus` on a machine with network access
      reproduces the same `test/scxml_tests/` tree, confirming the mirror-seeded
      run was faithful and that `corpus:emit`'s SCION half still works. This is
      the item the offline procedure above substitutes for locally and cannot
      itself prove.
- [ ] Judgment call: read the five deleted modules' SCXML in the git diff and
      confirm each is an invoked fixture rather than a conformance assertion
      that merely happens to end in a state named `final`.
- [ ] Confirm the emitted count stated in `docs/testing.md` and
      `tools/corpus/README.md` reads correctly to someone who did not write this
      change, given the pre-existing 162-vs-164 drift being corrected in the
      same commit.
- [ ] No regressions in related features: `mise run corpus:check` still passes
      over the transformed mandatory tree, including the sub-documents that
      remain in `scratch/`.

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are deferred to the end.

---

## Corpus/Ratchet Notes

- **Ratchet**: unaffected. None of the five ids appears in
  `test/passing_tests.json` (verified by grep), so the registry neither shrinks
  nor grows and ADR-0011's `docs/quality-gate-changes.md` ledger requirement
  does not fire. `mix test.regression` is still run in both phases to assert
  that rather than assume it.
- **No `mix test.baseline add` in this plan.** Deleting test modules cannot make
  anything newly pass. If the parent invoke tests (`test216`, `test226`,
  `test239`, `test242`, `test276`) later start passing, that is `<invoke>`
  implementation work and belongs to its own bead.
- **Regeneration cost**: a cold `mise run corpus` fetches ~200 `.txml` from
  w3.org at 500ms pacing plus a Saxon download and a SCION clone. This plan's
  Phase 2 avoids all three locally by seeding from
  `~/repos/github/ex_statechart/test/scxml_w3/cases`, copying the Saxon jar from
  `~/repos/github/ex_statechart/saxon/`, and running the W3C emitter directly
  instead of via `corpus:emit`.
- **Scratch is disposable but not free**: `tools/corpus/scratch/` is gitignored
  and does not exist in this worktree. Leave it populated after Phase 2; a
  later re-verification is then instant.

## Open Questions

Recorded rather than left open - every one was decided during planning, with the
reasoning kept here for the reviewer.

1. **Does this cover three sub-documents or five?** Five. The bead names only
   `test216sub1`, `test239sub1`, and `test242sub1` because only those three
   currently clear their `required_features` gate and fail. `test226sub1` and
   `test276sub1` are identical in kind - invoked fixtures ending in
   `<final id="final">` while asserting `["pass"]` - and are merely gated out
   today. Fixing three and leaving two latent would mean a second bead the first
   time the feature gate widens.
2. **`exclusions.exs`, a new reason atom, or a pipeline-stage filter?** A
   pipeline-stage filter at emit. Decided against `exclusions.exs` on semantics
   (ADR-0004: "no predicator equivalent") and on reporting (its entries count as
   predicator-coverage exclusions). Decided against a new reason atom in the
   same file for the same reason - the file's meaning, not its shape, is what
   makes it the wrong home.
3. **Filter at fetch, at transform, or at emit?** At emit. Fetch is incremental
   and the `CORPUS_W3_MIRROR` seed copies every `*.txml` it finds, so a
   fetch-level filter would leave already-downloaded sub-documents in place and
   silently do nothing on a warm tree. Emit is the only stage that starts from
   `rm -rf` on every run, which makes it the only idempotent place for the
   filter.
4. **Regex or xmerl for the manifest?** Regex. xmerl is pruned from the Mix code
   path (verified in this worktree), so an xmerl-based module could not be
   loaded by a `mix test` unit test, and the alternative - adding `:xmerl` to
   `mix.exs` `extra_applications` - would put an OTP app in the library's
   application list to serve a build tool. The manifest's 211 `<start>`/`<dep>`
   elements are uniform self-closing single-attribute tags, so the parse is
   safe; the trade is recorded in the module's moduledoc so a future reader does
   not "fix" it back to xmerl.
5. **Do the sub-documents keep being fetched and transformed?** Yes. They are
   needed by any future `src`/`srcexpr` resolution for `<invoke>`, they remain
   covered by `corpus:check`, and removing them from fetch would not have been
   reliable anyway (see 3).
6. **Does removing them affect the parent tests?** No. The parents inline their
   own XML and reference children by `src="file:...scxml"`; nothing in the
   emitted corpus resolves those URIs, and the children's `.scxml` files remain
   in `scratch/` regardless.
7. **Changelog fragment?** None. `changelog.d/README.md` excludes corpus tooling
   and conformance fixtures explicitly, and no public API or observable library
   behavior changes.
8. **What about the stale 162-vs-164 count in `docs/testing.md`?** Restated from
   the actual tree in Phase 2, which corrects it incidentally. Tracing the
   origin of the two-case drift is deliberately out of scope; if the reviewer
   wants it traced, it is a separate bead.
9. **Is the local mirror current with upstream?** Unverifiable offline. The plan
   does not assume it: Phase 2's automated criterion requires the regeneration
   diff to be exactly five deletions, so a drifted mirror fails the phase rather
   than landing a silently different corpus, and the fallback (networked
   `corpus:fetch:w3`) is named.

## Testing Strategy

### Unit Tests:

- `test/corpus/sub_documents_test.exs` (new, Phase 1) - the detection logic
  against inline manifest heredocs: a `.txml` dep is detected, a `.txt` dep is
  not, an id that is both a dep and a start is not returned, an empty manifest
  yields an empty set. The `test446` collision is the key edge case; without it
  a plausible implementation deletes a real conformance test.
- `test/corpus/emitted_paths_test.exs` (existing) - continues to assert the
  path-shape and module-uniqueness invariants over whatever the emitter
  produces; it is count-independent, so it needs no change.
- No `lib/` behavior changes, so no new sabotage notes beyond the
  generator-tooling exemption line the new test file carries
  (`# sabotage: n/a - generator tooling (tools/corpus/), not lib/ behavior`),
  matching `test/corpus/normalize_test.exs`.

### Manual Testing Steps:

1. Seed scratch and regenerate the W3C half offline using the commands in Phase
   2, then read `git status --porcelain test/scxml_tests` and confirm it is
   exactly five deletions.
2. Read the diff of the five deleted files and confirm each is an invoked
   fixture, not a standalone assertion.
3. Run `mix test --include scxml_w3` and confirm the three previously failing
   `sub1` cases are absent from the run rather than passing under a changed
   expectation.
4. On a networked machine, run a full `mise run corpus` from an empty
   `scratch/` and confirm a zero-diff match against the committed tree, the same
   reproducibility check `tools/corpus/README.md:104-112` records for 2026-08-05.

## References

- Bead: `st-rbp`
- Emitter: `tools/corpus/scxml_w3/cases.exs`
- Fetcher: `tools/corpus/scxml_w3/manifest.exs`
- Exclusions (deliberately not used): `tools/corpus/scxml_w3/exclusions.exs`
- Shared-module pattern to copy: `tools/corpus/normalize.exs`,
  `test/corpus/normalize_test.exs`
- Pipeline tasks and `CORPUS_*` paths: `mise.toml`
- Corpus tooling overview: `tools/corpus/README.md`
- Suites and conventions: `docs/testing.md`
- Related ADRs: `docs/adr/0004-predicator-as-the-datamodel.md`,
  `docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`
- Prior plan that surfaced the defect:
  `docs/plans/260811-st-k8d-configuration-out-of-termination.md`
- Local mirror used for offline regeneration:
  `~/repos/github/ex_statechart/test/scxml_w3/cases`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spot-check two manifest entries against
      `~/repos/github/ex_statechart/test/scxml_w3/cases/manifest.xml` (or
      `https://www.w3.org/Voice/2013/scxml-irp/manifest.xml`) and confirm
      `<dep>` is upstream's own declaration of an invoked sub-document, not an
      inference this plan is making.
- [ ] No regressions in related features: `tools/corpus/normalize.exs` and
      `check_exprs.exs` are untouched, and `mise run corpus:check` is unaffected.

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are deferred to the end.

---

### Phase 2

- [ ] A full networked `mise run corpus` on a machine with network access
      reproduces the same `test/scxml_tests/` tree, confirming the mirror-seeded
      run was faithful and that `corpus:emit`'s SCION half still works. This is
      the item the offline procedure above substitutes for locally and cannot
      itself prove.
- [ ] Judgment call: read the five deleted modules' SCXML in the git diff and
      confirm each is an invoked fixture rather than a conformance assertion
      that merely happens to end in a state named `final`.
- [ ] Confirm the emitted count stated in `docs/testing.md` and
      `tools/corpus/README.md` reads correctly to someone who did not write this
      change, given the pre-existing 162-vs-164 drift being corrected in the
      same commit.
- [ ] No regressions in related features: `mise run corpus:check` still passes
      over the transformed mandatory tree, including the sub-documents that
      remain in `scratch/`.

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are deferred to the end.

---
