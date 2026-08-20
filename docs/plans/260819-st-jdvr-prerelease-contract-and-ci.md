# Pinnable Pre-release Contract and CI Implementation Plan

## Overview

Close st-jdvr's remaining scope under the direction ADR-0061 already settled:
no pre-release is published, consumers pin `main` SHAs under a written
contract, `package/0` metadata lands without publishing, and the full local
gate starts running on the default branch so that "this SHA is green" is a
property a consumer can verify without being in the room.

Five artifacts, no `lib/` changes, no `test/` changes: the ADR itself (written
by the Direction stage, still uncommitted), a `package/0` block in `mix.exs`, a
GitHub Actions workflow, and the four documentation touches ADR-0061 names
(README consumer section, `docs/workflow.md` prose, `changelog.d/README.md`
clause, and the issue's changelog fragment).

Bead: **st-jdvr** (`area:build`). Every commit made under this plan carries
`st-jdvr` in its `Refs` trailer.

## Current State Analysis

**The direction is settled and uncommitted.** `docs/adr/0061-sha-pinning-contract-until-2-0-0.md`
is untracked and `docs/adr/README.md` carries its index row as a working-tree
modification. Both are binding input to this plan, and both must land in the
same commit: `mix adr.check`'s `adr-0058-readme-index` check is an invariant
over the working tree, so an ADR file without its table row is a red gate.

**`mix.exs` has no `package/0`.** It holds `@version "2.0.0-dev"`,
`@source_url "https://github.com/riddler/statifier-ex"`, `app: :statifier`, and
a project-level `description:`, which is where Hex reads a package description
from. Runtime dependencies are `:predicator`, `:saxy`, `:telemetry` - all Hex
packages. The one git dependency, `:credo`, is `only: [:dev, :test]`, so it is
outside the set Hex inspects when building a package tarball.

**There is no `.github/` directory.** The whole gate runs locally only. The
forge is GitHub (`.claude/wurk.json` `forge.kind`).

**The gate is one command, not four.** `.quality.exs` registers `gate_guard`
(`mix gate.check`), `regression` (`mix test.regression`), and `adr_guard`
(`mix adr.check`) as custom stages of `mix quality`. `mix gate.verify` runs
`mix quality --report -` and attests that the run was not profiled, scoped,
`--quick`-ed or `--skip`-ed. So `mix gate.verify` alone is the full gate *plus*
the ratchet, the ADR guard, the gate guard, and the attestation. Adding
separate CI steps for `mix adr.check` or `mix test.regression` would re-run
stages the same command already ran.

**The ADR judge is deliberately absent from CI.** `.quality.exs:23` disables
`adr_judge`, and its comment says in as many words that it is "local-only by
design: disabled by default, never in CI". CLAUDE.md classifies
`^disabled in \.quality\.exs$` as a not-applicable skip. CI inherits that
without doing anything.

**The corpus is committed; regenerating it is a network-and-Java job.**
`mise.toml`'s `corpus:*` tasks download the W3C IRP manifest and TXML sources
(w3.org rate-limits a few hundred sequential requests), Saxon-HE from
SourceForge, and a git clone of the SCION framework, then run a Java XSLT
transform. The *output* - `test/scion_tests/` and `test/scxml_tests/` - is
committed and is what `mix test.regression` runs. CI needs none of the fetch
pipeline and no JRE.

**`test/passing_tests.json`** lists `test/mix/**/*_test.exs`,
`test/statifier/**/*_test.exs`, plus explicit `scion_tests` and `w3c_tests`
entries; `mix test.regression` supplies the `--include scion --include
scxml_w3` tags those entries need. `test/test_helper.exs` excludes those tags
from a bare `mix test`, so a plain `mix quality` Tests stage covers the
internal suite and the `Regression ratchet` stage covers conformance. CI
mirrors that split exactly by running the same command.

**The gate guard keys `mix.exs` on line content, not on path.** This is the
one place where a factual detail differs from what ADR-0061's Consequences
section anticipated - see "Key Discoveries" below.

## Desired End State

- `docs/adr/0061-*.md` and its `docs/adr/README.md` row are committed.
- `mix.exs` has a `defp package/0` and a `package: package()` entry;
  `mix hex.build` produces a tarball locally without error, and nothing is
  published.
- `.github/workflows/ci.yml` runs `mix gate.verify` on every push to `main`,
  every pull request targeting `main`, and on `workflow_dispatch`, using the
  Erlang and Elixir versions read out of `mise.toml` at run time.
- `README.md` has an installation-and-pinning section stating ADR-0061
  decision 2's four bullets, plus a CI badge.
- `docs/workflow.md`'s "Versioning and the changelog" cites ADR-0061 and no
  longer claims there is no audience.
- `changelog.d/README.md` carries the between-pins fragment-editing clause.
- `changelog.d/st-jdvr.md` exists.
- A bare `mix quality` is green at every phase boundary, and `mix gate.check`
  reports no unjustified gate change.

Verified by: `mix gate.verify` green locally at each phase, `mix hex.build`
succeeding, and - deferred to after push - the workflow's own first green run
on GitHub.

### Key Discoveries:

- **`package/0` does not trip the gate guard, and therefore needs no ledger
  entry.** `lib/mix/statifier/gate_guard.ex:47` matches `mix.exs` changes
  against `~r/test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir|:sobelow|:doctor/`,
  with the comment at `lib/mix/statifier/gate_guard.ex:44-46` stating the
  reason: "`mix.exs` is matched by line content rather than by path ... a
  path-level guard would make every dependency change need a ledger entry."
  Every line the `package/0` block adds (`package: package()`, `defp package
  do`, `name:`, `licenses:`, `files:`, `links:`) was checked against that
  regex and none matches. ADR-0061's Consequences section says "the guard keys
  on the file"; that is the one factual slip in an otherwise binding record,
  and it does not change any decision the ADR made. See "Implementation
  Approach" for how Phase 2 handles the case where the real
  `Gate guard` stage disagrees with this analysis.
- **`mix gate.verify` is the whole CI gate** - `.quality.exs:64-129` registers
  the gate guard, the regression ratchet, and the ADR guard as custom stages,
  and `lib/mix/tasks/gate.verify.ex:56-70` shells out to `mix quality
  --report -`.
- **`mix gate.verify` captures the gate's output rather than streaming it**
  (`lib/mix/tasks/gate.verify.ex:60`, `JSON.decode(output)`), and on a red gate
  reports only the failing stage names. CI needs a failure-only second step to
  recover the human-readable detail.
- **`mix gate.check` and `mix adr.check` both need a base ref**, resolved as
  `opts[:base]`, then `origin/main`, then `main`
  (`lib/mix/statifier/gate_guard.ex:107`). When none resolves they exit 2,
  which `skip_exit_code: 2` turns into a *skip* - and `gate.verify` treats a
  custom stage's own skip as a project-level gap rather than a narrowing
  (`lib/mix/tasks/gate.verify.ex:20-26`). A CI checkout that does not
  materialize `origin/main` therefore silently loses both guards instead of
  going red. The workflow fetches `main` explicitly.
- **`test/passing_tests.json` is a guarded path**; nothing in this plan touches
  it, and no phase can move conformance results, so no `mix test.baseline`
  step is needed.
- **No phase touches `lib/` or `test/`**, so the sabotage rule
  (CLAUDE.md Conventions, `docs/testing.md`) has nothing to attach to. This is
  stated rather than omitted, per that rule's own instruction.

## What We're NOT Doing

- **Not publishing anything to Hex**, and not adding a `mix hex.publish` step,
  a release workflow, or a tag. ADR-0061 decisions 1 and 5.
- **Not writing a release recipe.** `.claude/wurk.json`'s `release` key stays
  `null` and `wurk:release` continues to refuse; that is 2.0.0-release work
  (ADR-0061 Consequences).
- **Not adding ExDoc `docs:` configuration** (`main:`, `extras:`, groups,
  hexdocs formatting). ADR-0061 decision 4 leaves this to the plan, and the
  plan declines it: nothing publishes, hexdocs is generated at publish time,
  and a docs block written a year before its first use would be configuration
  nobody has ever seen rendered. `{:ex_doc, "~> 0.34", only: :dev}` is already
  in `deps/0`, so adding the block later is a one-commit change.
- **Not regenerating the conformance corpus in CI.** The generator needs
  w3.org (rate-limited), SourceForge, a git clone, and a JRE; its output is
  committed and is what the ratchet runs. A "does the committed corpus still
  match a fresh generation" drift check is a separate, differently-shaped
  concern - a scheduled job with its own failure semantics - and is out of
  scope here.
- **Not adding a matrix of Erlang/Elixir versions.** `mise.toml` pins one
  toolchain and `mix.exs` says `elixir: "~> 1.18"`; the gate this project runs
  is one toolchain's gate, and CI's job under ADR-0061 is to certify that same
  gate on `main`, not to broaden it.
- **Not writing a `docs/quality-gate-changes.md` entry.** The guard analysis
  above says none is required. If Phase 2's `Gate guard` stage disagrees, the
  plan stops there for a human rather than an agent writing itself an approval
  (CLAUDE.md, ADR-0011).
- **Not adding new ExUnit tests.** Nothing under `lib/` changes.
- **Not chasing ADR-0061's two open questions** (Hex ownership of the
  `statifier` package; whether the satellites share a pin). Both are human or
  other-repo matters the ADR explicitly parks until a decision-5 trigger.

## Implementation Approach

Four phases, ordered so each one is independently committable with a green
bare `mix quality`, and so the riskiest unknown is isolated:

1. **ADR-0061 lands first** because everything after it cites it, and because
   an ADR file and its index row must travel together for the ADR guard.
2. **`package/0` is its own phase** because it is the only change that could
   possibly trip the `Gate guard`. Isolating it means that if the analysis
   above is wrong, exactly one small commit is blocked on a human while phases
   3 and 4 proceed unaffected.
3. **CI is its own phase** because it is the one artifact this repository
   cannot verify locally at all.
4. **Documentation last**, because the README badge points at a workflow file
   that must already exist, and because the prose describes a contract whose
   mechanical half (CI, `package/0`) is by then in the tree.

**Ordering, stated precisely.** Phase 1 precedes all of them. Phase 4 depends
on **both** Phase 2 and Phase 3, and the dependency is real rather than
stylistic in each case: the README badge names a workflow file Phase 3 creates,
and the `docs/workflow.md` paragraph asserts that "`package/0` metadata is in
`mix.exs` already", which is a false statement about the tree until Phase 2
lands. Nothing in Phase 4's automated criteria would catch that lie, so it is
an ordering constraint, not a preference. Phases 2 and 3 are genuinely
independent of each other and may be done in either order or in parallel
worktrees.

If Phase 4 must run before Phase 2 for some reason, the `docs/workflow.md`
sentence has to be reworded to the future tense in the same edit - do not leave
it asserting a `package/0` block that is not there.

### Recorded choices

These were decided during planning rather than escalated, and are recorded
here so the reasoning survives to whoever implements and reviews.

- **The `mix.exs` guard question** is decided by reading the guard's source
  rather than by assuming ADR-0061's prose. The decision is to proceed with no
  ledger entry, and to let the real stage adjudicate in Phase 2's
  `mix gate.check` step. Blocking a human pre-emptively on a guard that the
  code says will not fire would be an unnecessary stop; writing the entry
  pre-emptively would be an agent granting itself an approval. Running the
  check is the third option and the correct one.
- **Toolchain versions are read from `mise.toml` at run time**, not duplicated
  into the workflow. A duplicated pin drifts silently the first time
  `mise.toml` moves; a six-line `sed` step cannot. `mise` itself is not used to
  provision CI because it would build Erlang from source and install the
  temurin JRE that only the corpus generator needs.
- **CI runs `mix gate.verify` as the single gate step**, with a
  `if: failure()` step running `mix quality` for readable triage output. The
  happy path pays for one gate run; only red runs pay for two.
- **A changelog fragment is written**, even though `changelog.d/README.md`
  says CI and documentation changes get none. What this issue delivers to a
  user is the dependency contract itself - how to depend on this library and
  what a pin does and does not promise - which is squarely "someone who only
  ever calls the public API could tell the difference". The bead's acceptance
  criteria require one independently.

---

## Phase 1: Land ADR-0061 and its index row

### Overview

Commit the Direction stage's record so the rest of the plan cites an in-tree
document, and so the ADR guard's README-bijection invariant is satisfied by a
single commit rather than by a working tree.

### Changes Required:

#### 1. The ADR and its index

**File**: `docs/adr/0061-sha-pinning-contract-until-2-0-0.md` (untracked, already written)
**Changes**: `git add` it unchanged. It is the Direction stage's output and is
binding input to this plan; do not edit its decisions.

**File**: `docs/adr/README.md` (already modified in the working tree)
**Changes**: The 0061 row is already present. Commit it in the same commit as
the ADR file - `mix adr.check`'s `adr-0058-readme-index` check is an invariant
over the working tree's `docs/adr/` listing versus the README table, and it
clears on no escape hatch.

Note for the implementer: ADR-0061's Consequences section contains one factual
slip (it says the gate guard "keys on the file" for `mix.exs`; the guard keys
on line content - `lib/mix/statifier/gate_guard.ex:44-47`). **Do not fix it in
this phase.** An accepted ADR's text is amended by a new record or an explicit
amendment note, not by a quiet edit inside an unrelated implementation commit,
and nothing in this plan depends on the sentence being right. This plan's
"Key Discoveries" is where the correction lives.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` while iterating (never as the phase gate).
- [x] Full `mix quality` is green; specifically the `ADR guard` stage reports
      no `adr-0058-readme-index` or `adr-0058-duplicate-number` finding.
- [x] `git status --short` shows no remaining untracked file under `docs/adr/`.

#### Manual Verification:
- [ ] The committed ADR is byte-identical to what the Direction stage wrote -
      no decisions were reworded on the way in.
- [ ] The README table row's link resolves to the file's real name.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual items before moving on. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement
automatically via `/wurk:commit --auto`, and Manual Verification is deferred
and surfaced once at the end.

---

## Phase 2: `package/0` metadata in `mix.exs`

### Overview

Add the Hex package block so that publishing 2.0.0 later is a decision rather
than a project (ADR-0061 decision 4). Nothing is published, and no version
changes.

### Changes Required:

#### 1. The project list

**File**: `mix.exs`
**Changes**: Add one entry to `project/0`, immediately after `source_url:` -
that is, at the end of the `description:` / `source_url:` run, so the
packaging keys sit together. Keyword order in `project/0` has no effect on
Mix; the point is only that a reader finds the packaging keys in one place. Do
not touch any line matching the guard
pattern (`test_coverage`, `dialyzer:`, `warnings_as_errors`, `aliases`, or any
of the dev-dep atoms) - reformatting one of those lines is what would demand a
ledger entry, not `package/0` itself.

```elixir
      source_url: @source_url,
      package: package(),
      test_coverage: [tool: ExCoveralls],
```

#### 2. The package function

**File**: `mix.exs`
**Changes**: Add a private `package/0` between `elixirc_paths/1` and `deps/0`.
The description stays at project level, where it already is - Hex reads
`project[:description]`, so repeating it here would be a second copy to drift.

```elixir
  # Hex package metadata. Nothing is published before 2.0.0 (ADR-0061); this
  # exists so that publishing is a decision rather than a project.
  defp package do
    [
      name: "statifier",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end
```

`name: "statifier"` continues the v1 package (ADR-0061 decision 4). `files`
deliberately excludes `test/`, `tools/`, `docs/`, `bench/`, and `changelog.d/`:
a package tarball carries the library and the documents a consumer reads from
Hex, not the generated conformance corpus - which is several thousand files -
nor the corpus generator.

#### 3. Prove the metadata is complete without publishing

Run `mix hex.build` and delete the tarball it writes (`statifier-*.tar` is
already gitignored). This is the only mechanical check that the metadata is
publishable: it validates the required fields and - relevantly here - refuses
git dependencies in a published package. `:credo` is the tree's one git
dependency and is `only: [:dev, :test]`, so it should be out of scope for the
build; if `mix hex.build` disagrees, that is a real finding to report, not
something to work around by loosening the dependency.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` while iterating.
- [x] Full `mix quality` is green.
- [x] **`mix gate.check` reports "No unjustified gate changes".** This is the
      adjudication of the ledger question; see the blocking note below.
- [x] `mix hex.build` exits 0; the resulting `statifier-*.tar` is removed
      afterwards and `git status --short` is clean apart from `mix.exs`.
- [x] `mix format --check-formatted` passes (covered by the gate's Format
      stage).

#### Manual Verification:
- [ ] A human reads the `files` list and agrees it is what a consumer should
      receive - in particular that omitting `changelog.d/` is right, given
      that ADR-0061's upgrade briefing is a `git diff` against the repository
      rather than a file read out of a tarball.
- [ ] The `links` URLs resolve.

**BLOCKING NOTE - the ledger question.** CLAUDE.md and ADR-0011 say a
gate-relevant `mix.exs` edit needs an entry in `docs/quality-gate-changes.md`,
and that **the entry is a human's call on the record, not one an agent writes
for itself**. Reading `lib/mix/statifier/gate_guard.ex:44-47` says this
particular edit is not gate-relevant, because the guard matches `mix.exs` by
line content and none of the added lines match its pattern. If `mix gate.check`
nevertheless reports a finding on `mix.exs`, **stop this phase and report it**:
do not write a ledger entry, do not reshape the code to dodge the pattern, and
do not proceed to commit. Phases 3 and 4 are independent of this phase and may
continue regardless.

**Implementation Note**: Same as Phase 1.

---

## Phase 3: CI on the default branch

### Overview

Run the identical local gate on GitHub for every commit that reaches `main`
and every pull request that proposes to, so that "pin only commits reachable
from `main`" (ADR-0061 decision 2) is a checkable claim rather than a
convention.

### Changes Required:

#### 1. The workflow

**File**: `.github/workflows/ci.yml` (new; `.github/` does not exist yet)
**Changes**: One job, one gate command.

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  gate:
    name: Full quality gate
    runs-on: ubuntu-latest
    timeout-minutes: 45

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # mix gate.check and mix adr.check resolve a base ref as origin/main,
      # then main. Without one they exit 2, which skip_exit_code: 2 turns into
      # a skipped stage that gate.verify accepts - the guards would go quiet
      # instead of red. Materialize the ref explicitly.
      - name: Materialize origin/main for the gate and ADR guards
        run: git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main

      # Single source of truth for the toolchain: a version duplicated into
      # this file drifts the first time mise.toml moves. mise itself is not
      # used to provision CI - it would build Erlang from source and install
      # the temurin JRE that only the corpus generator needs.
      - name: Read the toolchain out of mise.toml
        id: toolchain
        run: |
          set -euo pipefail
          erlang="$(sed -n 's/^erlang *= *"\(.*\)".*$/\1/p' mise.toml | head -1)"
          elixir="$(sed -n 's/^elixir *= *"\(.*\)".*$/\1/p' mise.toml | head -1)"
          test -n "$erlang" || { echo "no erlang version in mise.toml" >&2; exit 1; }
          test -n "$elixir" || { echo "no elixir version in mise.toml" >&2; exit 1; }
          echo "erlang=$erlang" >> "$GITHUB_OUTPUT"
          echo "elixir=$elixir" >> "$GITHUB_OUTPUT"

      - uses: erlef/setup-beam@v1
        with:
          otp-version: ${{ steps.toolchain.outputs.erlang }}
          elixir-version: ${{ steps.toolchain.outputs.elixir }}

      # _build carries the Dialyzer PLT
      # (_build/dev/dialyxir_erlang-*_elixir-*_deps-dev.plt), so this cache is
      # the PLT cache too. The restore-keys fallback means a lockfile bump
      # rebuilds the PLT incrementally from the previous one rather than from
      # scratch.
      - name: Cache deps and build
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: mix-${{ runner.os }}-otp${{ steps.toolchain.outputs.erlang }}-ex${{ steps.toolchain.outputs.elixir }}-${{ hashFiles('mix.lock') }}
          restore-keys: |
            mix-${{ runner.os }}-otp${{ steps.toolchain.outputs.erlang }}-ex${{ steps.toolchain.outputs.elixir }}-

      - name: Fetch dependencies
        run: mix deps.get

      # The full gate, attested. .quality.exs registers the gate guard, the
      # regression ratchet, and the ADR guard as custom stages of mix quality,
      # and gate.verify runs mix quality and fails if the run was profiled,
      # scoped, --quick-ed or --skip-ed. So this one command is the same gate
      # a developer must have green before committing. The ADR judge stays
      # disabled here, exactly as .quality.exs:23 intends.
      - name: Full quality gate
        run: mix gate.verify

      # gate.verify captures the gate's output to parse its JSON report, so a
      # red run reports failing stage names without the detail underneath.
      # Only a failed run pays for the second pass.
      - name: Gate detail on failure
        if: failure()
        run: mix quality
```

#### 2. Why this does not look like v1's CI

The v1 reference checkout (`~/repos/github/statifier/.github/workflows/ci.yml`,
read-only) fans the gate out into six jobs - format, a five-way Elixir/OTP test
matrix, credo, dialyzer, regression, examples - each re-installing and
re-compiling. A reviewer who knows that file will ask why v2's is one job.
Three reasons, all specific to this repo:

- **v1 had no single gate command; v2 does.** `mix quality` did not exist
  there, so the checks had to be enumerated. Here, enumerating them would
  create a second definition of "the gate" that drifts from `.quality.exs` -
  the exact drift `mix gate.verify` exists to make impossible.
- **`env: MIX_ENV: test` (v1, line 23) would break v2's gate.** `:ex_quality`
  is `only: :dev`, so `mix quality` would not exist in a `test` environment.
- **No `paths-ignore` for `docs/**` and `*.md`.** v1 skips CI for
  documentation changes. v2 must not: the ADR guard's README-bijection check
  and the gate guard's ledger check are checks *over documentation*, and
  ADR-0061 decision 2 promises that every commit reachable from `main` passed
  the full gate - a promise a docs-only commit that skipped CI would quietly
  falsify.

The five-way version matrix is dropped for the reason given in "What We're NOT
Doing": `mise.toml` pins one toolchain, and CI's job here is to certify that
toolchain's gate on `main`.

One incidental gain worth expecting rather than being surprised by: the runner
is Linux and therefore case-sensitive, while local development is macOS with
`core.ignorecase=true`. `tools/corpus/README.md` describes a class of
case-only path drift that is invisible to `git status` on a case-insensitive
filesystem, guarded today by `test/corpus/emitted_paths_test.exs`. If that
guard ever has a hole, CI is where it shows up first - as a real red, not a
flake.

Deliberately absent, and why: no `MIX_ENV` is exported (an explicit `MIX_ENV`
would follow the nested `mix test` the Tests and ratchet stages spawn and run
the suite in the wrong environment); no corpus regeneration and no JRE (see
"What We're NOT Doing"); no separate `mix adr.check` or `mix test.regression`
step (both are already stages of the command above); no coverage upload (the
coverage threshold is enforced in-process by `coveralls.json`, so there is
nothing external to report to).

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` while iterating; full `mix quality` green as
      the phase gate. The workflow file is not Elixir, so the gate proves only
      that the tree is still clean - which is the honest bar for this phase.
- [x] The file parses as YAML:
      `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")'`.
- [x] The version-extraction step reproduces `mise.toml`'s values when run by
      hand in the repo root: it prints `27.3` and `1.18.3-otp-27` given the
      current `mise.toml`.
- [x] `mix gate.check` reports no unjustified gate change (adding a workflow
      file is not a guarded path, and this confirms it).

#### Manual Verification:
- [ ] **Deferred until after push** - see "Deferred Manual Verification". A
      workflow that has never run is unverified by definition, and no local
      command can change that.

**Implementation Note**: Same as Phase 1, with the standing caveat that this
phase's automated criteria prove the file is well-formed and the tree is
green, not that the workflow works. Do not report this phase as verified on a
green local gate alone.

---

## Phase 4: The consumer contract in prose

### Overview

Write ADR-0061 decisions 2, 3, and 6 into the four places a reader looks:
`README.md` for consumers, `docs/workflow.md` for maintainers,
`changelog.d/README.md` for the fragment rule, and the issue's own fragment.

### Changes Required:

#### 1. Consumer-facing installation and pinning

**File**: `README.md`
**Changes**: Add a CI badge under the title, and an `## Installation` section
between "Why a rewrite" and "Development". House style here is plain ASCII
punctuation; match it.

```markdown
[![CI](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml)
```

Then an `## Installation` section whose body is, verbatim (the fenced snippet
inside it is an `elixir` block holding the dependency line):

> Statifier v2 is not on Hex yet, and will not be before 2.0.0 - no alpha,
> beta, or release-candidate versions along the way. Until then, depend on a
> commit reachable from `main`:
>
>     {:statifier, github: "riddler/statifier-ex", ref: "<sha>"}
>
> What a pin gives you (the full contract is
> [ADR-0061](docs/adr/0061-sha-pinning-contract-until-2-0-0.md)):
>
> - **Pin only commits reachable from `main`.** Every one of them has passed
>   the full quality gate - the same gate CI runs on the default branch. A
>   branch tip is covered by nothing.
> - **Between two pins, any public API and any observable behavior may
>   change** without deprecation, notice period, or compatibility shim.
>   `2.0.0-dev` is one moving version. There are no tags before 2.0.0; the pin
>   is the SHA.
> - **What will never break silently:** persisted position and recording blobs
>   refuse with a typed error on a format-version or chart-identity mismatch
>   rather than misreading; API shape changes fail your compile.
> - **How to see what changed:**
>   `git diff <old-sha>..<new-sha> -- changelog.d/ CHANGELOG.md` lists every
>   user-visible difference between two pins.

#### 2. The maintainer-facing half

**File**: `docs/workflow.md`, "Versioning and the changelog" (line 298)
**Changes**: Replace the justification in the first paragraph (lines 300-304).
The old reason - "there is no audience for a pre-release of an engine that
cannot yet run a statechart" - is now false and must not survive. Match the
file's existing prose style.

The replacement keeps the rule and re-grounds it: `mix.exs` holds `2.0.0-dev`
for the whole rewrite and nothing is published until 2.0.0 is complete, not
for want of an audience but because every consumer that exists today is
git-capable, because a Hex pre-release is a permanent artifact plus a recurring
publish ceremony this project does not want yet, and because pre-release
sections would fracture the single 2.0.0 migration document the `changelog.d/`
design exists to produce (ADR-0061 decision 1). Add that consumers pin `main`
SHAs under the contract in ADR-0061, that the rule defers to a named trigger
(a satellite needing to publish to Hex, or an embedder policy forbidding git
dependencies) rather than standing forever (decision 5), and that `package/0`
metadata is in `mix.exs` already so that publishing is a decision rather than a
project (decision 4).

#### 3. The between-pins fragment clause

**File**: `changelog.d/README.md`, inside "### While v2 is unreleased"
**Changes**: Append a paragraph after the existing narrower rule, stating
ADR-0061 decision 3: a change that breaks code or persisted data written
against an earlier `main` SHA gets a fragment touch, **by editing the issue's
existing fragment in place** so that it describes the current v2-vs-v1
difference. Say why editing in place rather than appending: the `git diff`
between two pins carries the between-pins signal, while the fragment's final
text stays a clean v1-to-v2 migration statement for release assembly rather
than a transcript of intermediate churn. Note that consumers rely on this
diff being complete (ADR-0061 decision 2), so the absence of a fragment touch
on a change that reshapes v2-only public surface is a review finding.

#### 4. The fragment

**File**: `changelog.d/st-jdvr.md` (new)
**Changes**:

```markdown
### Added

- Documents how to depend on v2 before its release: pin a commit reachable
  from `main` as a git dependency, and read
  `git diff <old>..<new> -- changelog.d/ CHANGELOG.md` as the upgrade
  briefing. Any public API or behavior may change between two pins
  (see ADR-0061).
```

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` while iterating; full `mix quality` green as
      the phase gate.
- [x] `changelog.d/st-jdvr.md` exists and uses only a standard Keep a Changelog
      heading.
- [x] `! grep -q "no audience" docs/workflow.md` - the retired justification is
      gone.
- [x] All three documents cite the record. Note that
      `grep -q PATTERN f1 f2 f3` exits 0 on the *first* file that matches, so
      it does not decide this; use a per-file loop whose output must be empty:
      `for f in README.md docs/workflow.md changelog.d/README.md; do grep -q 0061 "$f" || echo "missing: $f"; done`
- [x] `mix gate.check` reports no unjustified gate change.

#### Manual Verification:
- [ ] A reader who has never seen this repository can, from `README.md` alone,
      add the dependency and state what a pin does and does not promise.
- [ ] The four README bullets say the same thing as ADR-0061 decision 2 - no
      promise is widened or narrowed in the retelling.
- [ ] `docs/workflow.md`'s new justification is the ADR's, not a paraphrase
      that reintroduces "no audience" by another name.
- [ ] The badge renders green on GitHub and links to the right workflow
      (deferred until Phase 3's workflow has run - see below).

**Implementation Note**: Same as Phase 1.

---

## Testing Strategy

### Unit Tests:

No new ExUnit tests. No phase touches `lib/` or `test/`; the changes are one
ADR, Mix project metadata, a CI workflow, and prose. The sabotage rule
(CLAUDE.md Conventions, `docs/testing.md`) attaches to tests asserting `lib/`
behavior and there are none here - stated rather than silently omitted, as
that rule requires.

The existing suite is the regression protection that matters: `mix quality`
must stay green through all four phases, and `mix.exs` is compiled by every
stage of it, so a malformed `package/0` fails the gate immediately.

### Manual Testing Steps:

1. After Phase 2, run `mix hex.build`, then `tar tf statifier-2.0.0-dev.tar`
   and inspect `contents.tar.gz`'s file list; confirm it contains `lib/`,
   `mix.exs`, `README.md`, `LICENSE`, `CHANGELOG.md` and nothing from `test/`,
   `tools/`, or `docs/`. Delete the tarball.
2. After Phase 3 is pushed, open the workflow run on GitHub and read the
   `Full quality gate` step's log end to end - never truncated. Confirm the
   `Gate guard`, `Regression ratchet`, and `ADR guard` stages each report a
   real result rather than a skip, and that `ADR judge` is the only stage
   skipped for `disabled in .quality.exs`.
3. After Phase 4, follow the README's own installation snippet in a scratch
   Mix project against a real `main` SHA and confirm `mix deps.get` and
   `mix compile` succeed.

## Deferred Manual Verification

Everything here is unverifiable in this worktree and must be walked after the
branch is pushed - `/wurk:verify` is the mechanism.

- [x] **The workflow runs at all.** Its first pull-request run completes rather
      than failing on syntax, a missing action version, or a permissions error.
- [x] **The gate is green in CI, not merely locally.** `mix gate.verify` exits
      0 on the runner. A first red run that is red for an environment reason
      (a `Statifier.TmpDir` path, a timezone, a locale) is a finding about the
      suite, not a reason to narrow the CI command.
- [x] **The base-ref fetch works.** The `Gate guard` and `ADR guard` stages
      report real results in the CI log rather than skipping with "no base
      ref". A skip here is silent by design and will not turn CI red on its
      own, which is exactly why a human has to look once.
- [x] **The version-extraction step reads `mise.toml` correctly on the
      runner**, and `setup-beam` accepts both strings verbatim
      (`27.3`, `1.18.3-otp-27`).
- [x] **Wall-clock and caching.** The run finishes inside
      `timeout-minutes: 45`, and a second run on an unchanged `mix.lock`
      restores `deps`/`_build` and does not rebuild the Dialyzer PLT from
      scratch. Raise the timeout or split the PLT into its own cache if not.
- [ ] **The README badge** renders, is green, and links to this workflow.
- [x] **`mix hex.build` tarball contents** reviewed by a human (manual testing
      step 1 above), since nothing automated judges whether the `files` list is
      the right list.
- [x] **ADR-0061's own open question**: that the maintainer holds Hex ownership
      and credentials for the existing `statifier` package. Nothing in this
      plan depends on it; it becomes load-bearing the day a decision-5 trigger
      fires.

**Walked 2026-08-20 (`/wurk:verify`).** Settled against PR #205's runs. The
first run was red for an environment reason, which this section's second item
anticipated: `adr_judge_test.exs` pinned a skip reason that only holds where
the `claude` CLI is on PATH, latent on `main` and green everywhere it had run
until a runner ran it. Fixed as a suite finding, not by narrowing the CI
command. The base-ref fetch works - `Gate guard` and `ADR guard` report real
results (7.3s, 6.8s) rather than the silent skip. Wall-clock: 3m44s cold
against a 45-minute timeout, and a re-run restored the cache on the exact key
with no PLT rebuild - Dialyzer 27.3s against 140.9s, whole run 1m4s. No
timeout raise and no separate PLT cache needed. The badge items stay open: the
workflow is not on `main` yet, so nothing renders until this merges.


### Phase 1

- [x] The committed ADR is byte-identical to what the Direction stage wrote -
      no decisions were reworded on the way in.
- [x] The README table row's link resolves to the file's real name.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual items before moving on. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement
automatically via `/wurk:commit --auto`, and Manual Verification is deferred
and surfaced once at the end.

---

### Phase 2

- [x] A human reads the `files` list and agrees it is what a consumer should
      receive - in particular that omitting `changelog.d/` is right, given
      that ADR-0061's upgrade briefing is a `git diff` against the repository
      rather than a file read out of a tarball.
- [x] The `links` URLs resolve.

**Walked 2026-08-19 (`/wurk:verify`).** The `files` review was not a
rubber stamp: bare `lib` shipped `lib/mix/` - this project's own gate
tooling (`gate.check`, `gate.verify`, `adr.check`, `adr.judge`,
`test.baseline`, `test.regression`) and its four support modules - into
the consumer's `mix help`, where those tasks would read this repo's
`.quality.exs` and `docs/adr/` against the consumer's tree. The list now
names `lib/statifier lib/statifier.ex`, dropping ten files while keeping
`Statifier.Testing` (ADR-0053). Re-verified with `mix hex.build`: 143
files, no `lib/mix/`. Omitting `changelog.d/` was confirmed correct as
written.

**BLOCKING NOTE - the ledger question.** CLAUDE.md and ADR-0011 say a
gate-relevant `mix.exs` edit needs an entry in `docs/quality-gate-changes.md`,
and that **the entry is a human's call on the record, not one an agent writes
for itself**. Reading `lib/mix/statifier/gate_guard.ex:44-47` says this
particular edit is not gate-relevant, because the guard matches `mix.exs` by
line content and none of the added lines match its pattern. If `mix gate.check`
nevertheless reports a finding on `mix.exs`, **stop this phase and report it**:
do not write a ledger entry, do not reshape the code to dodge the pattern, and
do not proceed to commit. Phases 3 and 4 are independent of this phase and may
continue regardless.

**Implementation Note**: Same as Phase 1.

---

### Phase 3

- [x] **Deferred until after push** - see "Deferred Manual Verification". A
      workflow that has never run is unverified by definition, and no local
      command can change that.

**Implementation Note**: Same as Phase 1, with the standing caveat that this
phase's automated criteria prove the file is well-formed and the tree is
green, not that the workflow works. Do not report this phase as verified on a
green local gate alone.

---

### Phase 4

- [x] A reader who has never seen this repository can, from `README.md` alone,
      add the dependency and state what a pin does and does not promise.
- [x] The four README bullets say the same thing as ADR-0061 decision 2 - no
      promise is widened or narrowed in the retelling.
- [x] `docs/workflow.md`'s new justification is the ADR's, not a paraphrase
      that reintroduces "no audience" by another name.
- [ ] The badge renders green on GitHub and links to the right workflow
      (deferred until Phase 3's workflow has run - see below).

**Implementation Note**: Same as Phase 1.

---
## References

- Bead: `st-jdvr`
- Direction record: `docs/adr/0061-sha-pinning-contract-until-2-0-0.md`
  (uncommitted at the time of writing; Phase 1 lands it)
- Gate policy: `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `CLAUDE.md` "ExQuality" section,
  `docs/quality-gate-changes.md`
- Gate guard implementation: `lib/mix/statifier/gate_guard.ex:44-47`
  (the `mix.exs` line-content pattern), `lib/mix/statifier/gate_guard.ex:107`
  (base-ref resolution)
- Gate attestation: `lib/mix/tasks/gate.verify.ex:20-26`, `:56-70`
- Gate stage registration: `.quality.exs:64-129`
- Ratchet: `lib/mix/tasks/test.regression.ex`, `test/passing_tests.json`
- ADR guard's README-bijection check: `lib/mix/tasks/adr.check.ex` moduledoc
- Toolchain and corpus pipeline: `mise.toml`, `tools/corpus/README.md`
- Changelog rules: `changelog.d/README.md`, `docs/workflow.md:298-315`
