# Slim statifier to manifest and extensions Implementation Plan

## Overview

Delete the thirteen ported skills under `.claude/skills/`, the six ported
agent files under `.claude/agents/`, and the whole `.claude/scripts/` tree,
now that the generic `wurk:*` skills, agents, and kit scripts are installed
under `~/.claude/`. Preserve the statifier-specific judgment those files
carried by writing six `.claude/wurk/*.md` extension files, and sweep the
repo's living prose so nothing still names a deleted skill, agent, or path.

Beads issue: `st-cex`. Upstream this is wurk plan phase 2, steps 6-7 (`wu-off`),
plus the statifier half of step 10 (`wu-cgw`), which this bead pulls into the
same commit.

## Current State Analysis

### What exists today

- `.claude/skills/` - 13 skill directories, each a single `SKILL.md`
  (`commit`, `merge-request`, `create-plan`, `iterate-plan`,
  `implement-plan`, `research-codebase`, `work`, `next-issue`,
  `next-issues`, `new-worktree`, `refresh-worktree`, `cleanup-worktrees`,
  `create-issue`), ~3,765 lines total per
  `docs/skill-automation.md:45`.
- `.claude/agents/` - 6 agent files: `codebase-locator.md`,
  `codebase-analyzer.md`, `codebase-pattern-finder.md`,
  `thoughts-locator.md`, `thoughts-analyzer.md`,
  `web-search-researcher.md`.
- `.claude/scripts/` - 16 top-level Ruby scripts, `lib/` (10 files), and
  `test/` (a minitest suite plus fixtures).
- `.claude/wurk.json` - the manifest, already written and already read by the
  installed kit (`5da5e69`, `cfd3d0f`, `0440921`).
- `.claude/settings.json` - the `bd prime` SessionStart hook only.
- `.claude/wurk/` - **does not exist yet**. This plan creates it.

The installed generic equivalents already resolve: `~/.claude/skills/wurk:*`
(19 skills including `wurk:kit`) and `~/.claude/agents/wurk-*.md`. Every one
of the six target skills declares a `## Project extension` section naming the
`.claude/wurk/<name>.md` file it will read, and every one states that
extensions **add** and never override.

### The gate constraint that shapes the phasing

`.quality.exs:114-121` registers a custom stage:

```elixir
[
  key: :script_tests,
  name: "Script tests",
  command: "ruby",
  args: [".claude/scripts/test/run.rb"],
  kind: :reader,
  parse: :none
]
```

The comment above it (`.quality.exs:110-113`) states the design deliberately:

> Deliberately no `skip_exit_code`: if Ruby is missing, this stage goes red
> rather than reporting itself skipped. A skipped stage is not a passing one,
> and the whole point of registering it is that a `.claude/scripts/` change
> can no longer reach a push unmeasured.

Deleting `.claude/scripts/` therefore makes a full `mix quality` **hard red**
on that stage. Removing or retargeting the stage is `wu-s36` / upstream step
8 - a separately human-gated bead, because the edit lands in `.quality.exs`
and ADR-0011's `Gate guard` requires a `docs/quality-gate-changes.md` ledger
entry that only a human may write. This plan therefore isolates the
`.claude/scripts/` deletion into its own final phase and expects a red gate
there.

### Branch state

`origin/main` is at `5b362f8`, which is also this branch's `HEAD`. The
`5b362f8 Sweeps text node spans in the accuracy test` commit that appears
"ahead" is ahead only of the **stale local `main` ref** (`0440921`); against
the remote the branch is exactly even and carries no work of its own yet. So
there is no unrelated commit riding along in this branch, and nothing to
rebase or strip before starting. Nothing to act on.

### Key Discoveries

- Six generic skills read an extension file, and each names what it expects:
  `wurk:commit` ("test-verification discipline and whether an unverified test
  blocks a commit, changelog detail beyond the mode, ledger citations,
  version-bump rules"), `wurk:mr` ("an extra merge-time judgment stage"),
  `wurk:plan` ("the success criteria it always wants, the optional sections
  its plans carry, the domain patterns"), `wurk:iterate` (reads both
  `iterate.md` and `plan.md`), `wurk:implement` ("test-verification
  discipline, domain rules, the debugging move" - and it must be **passed by
  path** into `--loop` phase subagents, which have no memory of the session),
  `wurk:research` ("the project's own vocabulary for its pipeline or layers,
  reference checkouts").
- The sabotage protocol exists in full at
  `.claude/skills/implement-plan/SKILL.md:214-238`, and its commit-side
  refusal at `.claude/skills/commit/SKILL.md:36-37,136-157`.
- The ADR judge step exists exactly once, at
  `.claude/skills/merge-request/SKILL.md:137-147`.
- Corpus/ratchet criteria and the `## Corpus/Ratchet Notes` optional section
  are at `.claude/skills/create-plan/SKILL.md:321-352,420-448` and
  `iterate-plan/SKILL.md:231-245`.
- The pipeline-layer vocabulary's fullest statement is not in a skill at all -
  it is in `.claude/agents/codebase-analyzer.md:42-57`, which is also being
  deleted. It must be extracted before Phase 3.
- The generic `wurk:work` already carries the Direction stage prompt
  (`~/.claude/skills/wurk:work/SKILL.md:213-231`), but genericized: it says
  "the same shape and status convention every other record in that project
  carries" and so drops statifier's "there is no `proposed` state here"
  rationale (`.claude/skills/work/SKILL.md:216-224`). That single rule needs
  a home in `docs/`, since this bead creates no `work.md` extension.
- The area-label vocabulary from `.claude/skills/create-issue/SKILL.md:64`
  is not lost: it already lives in `.claude/wurk.json`
  (`beads.areas.labels`) and in `docs/workflow.md:152-161`.
- Only four lines outside the deleted trees name any of the six agents, all
  in dated `docs/plans/` and `docs/research/` documents
  (`260803-st2-gm6:41`, `260805-st2-ott:84`, `260805-st2-2yx:158-159`).
  Those are historical record and stay.
- `docs/skill-automation.md` is the hard case: it self-describes as "the
  living, repo-side record" but its entire substance is line counts and
  `Reason:` line-number citations into `.claude/skills/*/SKILL.md`. It cannot
  be mechanically renamed - every pointer dies with the tree.
- ADR-0011 (`docs/quality-gate-changes.md` ledger) and ADR-0015 (skill
  mechanics in scripts) both bound this work. ADR-0015's constraints are the
  ones the deletion invalidates; recording that is `wu-1oo`'s ADR, not this
  bead's.

## Desired End State

`.claude/` contains exactly four things: `wurk.json`, `settings.json`,
`wurk/` (six `.md` files), and nothing else. Every statifier-specific rule
those 3,765 lines carried is either in an extension file, already in the
manifest, or already in `CLAUDE.md`/`docs/`. No living prose in the repo
names a deleted skill, agent, or path; dated plans, research documents, ADRs,
and the gate ledger keep their historical text untouched.

Verification:

```bash
ls -A .claude                      # wurk.json settings.json wurk
ls .claude/wurk                    # commit.md implement.md iterate.md mr.md plan.md research.md
test ! -d .claude/skills && test ! -d .claude/scripts && test ! -d .claude/agents
```

and a `git grep` for the old slash-command and agent names returning hits
only in `docs/plans/`, `docs/research/`, `docs/adr/`,
`docs/quality-gate-changes.md`, `.quality.exs`, and
`lib/mix/statifier/adr_*.ex` + their tests and fixtures - all of which this
plan deliberately leaves alone.

The full `mix quality` gate is green through Phase 3 and red on exactly one
stage after Phase 4, by design.

## What We're NOT Doing

- **No `.quality.exs` edits.** The `Script tests` stage stays registered and
  therefore red after Phase 4. Removing or retargeting it is `wu-s36`
  (upstream step 8) and needs a human-written ADR-0011 ledger entry in
  `docs/quality-gate-changes.md`. Not touching `.credo.exs`,
  `coveralls.json`, or `.sobelow-conf` either.
- **No `gate.*` edits in `.claude/wurk.json`.** `gate.also_gated_paths`
  currently lists `.claude/scripts/` and `.claude/skills/`, both of which
  this plan deletes. Shrinking that array is gate-config work and belongs to
  `wu-s36` with the `.quality.exs` change and the same ledger entry. A stale
  entry is harmless in the meantime: the carve-out simply never matches it.
  `beads.areas.labels` keeps `area:skills` unchanged for the same reason -
  the manifest is not being edited in this bead at all.
- **No ADR-0015 surface changes.** `lib/mix/statifier/adr_judge.ex:187-199`
  scopes the `adr-0015-swallowed-judgment` registry entry to
  `.claude/skills/**/SKILL.md`; `adr_guard.ex:14-16` describes
  `.claude/scripts/` in its moduledoc; `test/mix/statifier/adr_judge_test.exs`,
  `test/mix/tasks/adr_judge_test.exs`, and the two
  `test/fixtures/adr_judge/0015_*.diff` fixtures pin that scope. All of it
  stays. The registry scope is explicitly `wu-s36`'s ("narrow the ADR judge
  scope to `.claude/wurk/**`") and ADR-0015's own supersession is `wu-1oo`'s
  ADR. Splitting that surface half here and half there would leave a repo
  where ADR-0015's code and its prose disagree, which is worse than leaving
  both stale together for one bead. None of it fails the gate meanwhile: the
  ADR judge is `enabled: false` outside `--profile merge`, and the tests
  assert against synthetic diff strings, never the filesystem.
- **No seventh or eighth extension file.** The bead names six. `work.md` and
  `issue.md` are not written: the area vocabulary is already in the manifest
  and `docs/workflow.md`, and the one genuinely orphaned rule (statifier ADRs
  have no `proposed` state) is relocated into `docs/workflow.md` in Phase 2
  instead.
- **No rewriting of dated documents.** Everything under `docs/plans/`,
  `docs/research/`, and `docs/adr/` records what existed when it was written.
  `docs/quality-gate-changes.md` is an append-only ledger and gets no new
  entry here, because this bead makes no guarded change.
- **No `bd close`, no push, no PR.** Out of the plan's remit entirely; see
  `CLAUDE.md`'s authority table.

## Implementation Approach

The order is dictated by one thing: **extract before deleting, and delete the
gate's own subject last.**

Phases 1-3 are all gate-safe. Phase 1 writes files into a path the gate does
not measure. Phase 2 edits `CLAUDE.md` and `docs/`, likewise unmeasured
(`gate.build_paths` is `lib/ test/ config/ mix.exs mix.lock`). Phase 3
deletes `.claude/skills/` and `.claude/agents/`; `.claude/skills/` **is** in
`gate.also_gated_paths`, so a full gate does run, and it runs green - the
`Script tests` stage's harness is still present, the `Gate guard` sees no
guarded path in the diff, and the Elixir suite never reads those files.

Phase 4 alone deletes `.claude/scripts/` and alone turns the gate red. It is
last, it is on its own, and its success criterion is a *shape* of failure
rather than a green run.

Phases 1 and 2 are kept separate rather than merged: Phase 2's rewrites cite
the extension files Phase 1 creates, and two docs-only commits read far
better in `git log` than one commit that both invents a surface and rewires
prose to it.

Two rules bind every extension file written in Phase 1:

1. **Add, never restate.** If the generic `wurk:*` skill already says it, the
   extension file does not repeat it. The extension exists for what only
   statifier knows.
2. **Never contradict.** Extensions cannot override the generic skill; a
   place where statifier genuinely needs different behavior is a finding to
   report upstream, not something to write into an extension file.

---

## Phase 1: Write the six extension files

### Overview

Create `.claude/wurk/` and populate it with `commit.md`, `mr.md`, `plan.md`,
`iterate.md`, `implement.md`, and `research.md`, extracting from the skills
and agents that Phase 3 will delete. Nothing is deleted in this phase, so
every source is still readable while it runs.

### Changes Required:

#### 1. `.claude/wurk/commit.md`

**File**: `.claude/wurk/commit.md` (new)
**Source**: `.claude/skills/commit/SKILL.md`
**Changes**: additional required steps for `/wurk:commit`, in the order the
generic skill's own steps run.

- **Sabotage check and its refusal condition** - from
  `commit/SKILL.md:136-157` and the auto-mode refusal row at `:36-37`. Keep
  intact: the kit's scan is a report and never gates; a present note proves a
  comment shape exists, not that a mutation was run; a missing note means
  **stop and sabotage now**, not fix a formatting nit; auto mode may sabotage
  the test itself and continue but may not commit an unverified test; and
  generated corpus files (`test/scion_tests/`, `test/scxml_tests/`) are
  exempt. Point at `docs/testing.md` for the rationale and at
  `.claude/wurk/implement.md` for the protocol itself, so the mutation kinds
  have exactly one definition site in this repo.
- **Changelog detail beyond `mode: fragments`** - from `:245-279`. The
  v2-differs-from-v1 narrowing ("re-implementing something v1 already did is
  invisible to a user; most Phase 0 work needs no fragment at all - that is
  the expected outcome, not a step you skipped"), the needs/does-not-need
  lists, standard headings only, the fragment is staged with its change, and
  `CHANGELOG.md` is never edited outside a release.
- **The `2.0.0-dev` no-bump rule** - from `:55-59`. No version-bump ritual;
  no alpha/beta/rc.
- **ADR-0011 ledger citations** - from `:32-34` and `:479-484`. A red `Gate
  guard` is not a failure to fix; writing the `docs/quality-gate-changes.md`
  entry yourself is granting yourself the permission the check exists to
  withhold.
- **Ratchet note** - from `:527`: ratchet additions
  (`test/passing_tests.json`, `mix test.baseline add`) ride in the same
  commit as the feature that unlocked them, and `mix test.regression` is the
  named gate stage that proves it.
- **Diff-classification vocabulary** - from `:171-178`: parser elements,
  interpreter functions, effects, ratchet movement - so a commit body says
  something a reader of this codebase can use.
- **Do NOT carry over** the "first commit is `.gitignore` only" convention
  (`:63-68`): upstream deliberately dropped it (wurk plan, step-2 notes,
  item 18) and this repo is long past its first commit.

#### 2. `.claude/wurk/mr.md`

**File**: `.claude/wurk/mr.md` (new)
**Source**: `.claude/skills/merge-request/SKILL.md`
**Changes**: one extra step plus two project facts.

- **The ADR judge step**, verbatim in substance from `:137-147`: run
  `mix quality --profile merge` after the full gate and before pushing; it is
  a separate profile because it makes real `claude` CLI calls that cost money
  and a network round trip, which is why it is disabled in every other run;
  it **skips cleanly** (no `claude` CLI on `PATH`, no `lib/statifier/`
  changes, no base ref) and a skip is fine to push through; **a finding is a
  hard refuse** - treat it exactly as a red gate, report it, stop. Say where
  in the generic skill's sequence it lands.
- **Rebase-merge-only**, from `:251-258`. `docs/workflow.md:193-215` already
  states the policy at length, so state the consequence for this skill and
  link there: do not offer or perform a squash merge, do not restructure the
  branch's commits on the assumption they will be squashed, and several
  commits from `/wurk:commit --auto` need no cleanup pass.
- **The changelog question at request time**, from `:149-164`: the v2/v1
  narrowing again in one line, and the rule that if a fragment is needed and
  absent you **ask the user** rather than inventing one - a changelog entry
  is a promise to users about observable behavior.

#### 3. `.claude/wurk/plan.md`

**File**: `.claude/wurk/plan.md` (new)
**Source**: `.claude/skills/create-plan/SKILL.md`
**Changes**: the success criteria this project always wants, its optional
sections, and its domain patterns.

- **Always-required automated criteria** - from `:420-448`: full `mix
  quality` as the per-phase gate; `mix quality --profile loop` while
  iterating; `mix quality --format json --report -` when an agent routes on
  results; and, whenever a phase can move conformance results,
  `mix test.regression` plus `mix test.baseline add` for the ratchet.
- **Always-required manual criteria**: spec-conformance judgment - the
  touched functions match the W3C Appendix D pseudocode line for line.
- **The Appendix D rule** - from `:117-118`: for interpreter work, deviations
  from the Appendix D pseudocode are semantic bugs unless mechanically
  required (ADR-0002), and the plan must say which deviation and why.
- **Optional sections this project's plans carry**: `## Corpus/Ratchet Notes`
  (corpus regeneration or `test/passing_tests.json` changes) and
  `## Performance Considerations`, both from `:321-352` - included only when
  they apply.
- **Phase-splitting along the pipeline's module boundaries** - from
  `:218-220`: parser vs interpreter vs corpus tooling, so phases parallelize
  across worktrees per `docs/workflow.md`.
- **Common patterns**, from `:450-478`, all three verbatim in substance:
  *New SCXML element* (lowering builder under `lib/statifier/lowering/`,
  Document structs and validator checks, compiler/Machine if runtime
  structure changes, interpreter behavior keeping Appendix D structure,
  internal tests plus ratchet); *Interpreter feature* (start from the
  pseudocode, port literally, note mechanical deviations inline, effects out
  never side effects in (ADR-0003), verify against SCION/W3C before
  ratcheting); *Refactoring* (document current behavior, incremental changes,
  conformance suites green throughout, ratchet/regression strategy).
- **Reference checkout**: say explicitly when a research sub-agent should
  look at `../statifier` (v1, read-only) rather than this repo (`:491-493`).

#### 4. `.claude/wurk/iterate.md`

**File**: `.claude/wurk/iterate.md` (new)
**Source**: `.claude/skills/iterate-plan/SKILL.md`
**Changes**: deliberately thin. `wurk:iterate` already reads
`.claude/wurk/plan.md`, so this file must **not** duplicate the criteria or
sections stated there - it points at them and adds only what is specific to
editing an existing plan:

- **ADR contradiction is escalated, never quietly edited** - from
  `:147-153,199-200`: a plan edit that would contradict an accepted ADR needs
  a direction-level decision per `docs/workflow.md`; no script has ADR
  awareness and none will.
- **Preserve, do not silently drop, the corpus/ratchet criteria and the
  `## Corpus/Ratchet Notes` section** when re-cutting phases.
- **Reference checkout** pointer, same one line as `plan.md` (`:99-102`).

#### 5. `.claude/wurk/implement.md`

**File**: `.claude/wurk/implement.md` (new)
**Source**: `.claude/skills/implement-plan/SKILL.md`
**Changes**: this is the largest and most load-bearing extension file,
because `wurk:implement` passes its **path** to `--loop` phase subagents that
have no other context. It must therefore be self-contained.

- **The sabotage protocol in full**, from `:214-238`. Every part: a test that
  passed on its first run has not been verified, only observed; the mutation
  kinds (invert a condition, drop a clause, skip a recursive call, return the
  input unchanged); confirm it fails *for the right reason*; revert; confirm
  green; the note grammar
  (`# sabotage: enter_states/2 skips the initial child -> red`) directly
  above the test; a test that stays green under sabotage is broken - fix the
  test, never weaken the mutation; deleting a body or raising is not a
  mutation because everything fails and nothing is learned; the corpus
  exemption (`test/scion_tests/`, `test/scxml_tests/`) and the harness
  exemption with its stated grammar (`# sabotage: n/a - <why>`), never
  omitted silently; and that this is slow on purpose and budgeted for in the
  phase rather than deferred, because `/wurk:commit` will refuse without it.
  Cite `docs/testing.md`.
- **Interpreter domain rules**, from `:185-195`: keep the Appendix D function
  names and pseudocode structure (ADR-0002), a deviation needs an inline
  comment citing the mechanical reason; return effects, never perform side
  effects in the core (ADR-0003); evaluations return
  `{:ok, v} | {:error, e}` and only the interpreter maps errors to
  `error.execution` - never rescue-to-default at a leaf; ratchet newly
  passing conformance tests in the same change.
- **The debugging move**, from `:275-279`: for interpreter behavior, diff the
  function against the Appendix D pseudocode before anything else. That is
  *the* debugging move in this project.
- **Loop-hygiene note**, from `:179-181`: the gate's Format stage formats for
  you, so never run `mix format` as a separate step.
- **Test conventions** worth stating because a fresh phase subagent will not
  have read `CLAUDE.md`: structs and MapSets, `@spec` on public functions,
  pattern matching over multiple asserts, XML in tests as triple-quoted
  heredocs at 4-space base indentation, and scratch dirs via
  `@tag :isolated_tmp_dir` (`Statifier.TmpDir`) - **never** ExUnit's
  `@tag :tmp_dir`.

#### 6. `.claude/wurk/research.md`

**File**: `.claude/wurk/research.md` (new)
**Source**: `.claude/skills/research-codebase/SKILL.md` **and**
`.claude/agents/codebase-analyzer.md`, `codebase-locator.md`,
`codebase-pattern-finder.md`, `thoughts-locator.md` - the agent files carry
the fullest statements and are deleted in Phase 3.

- **The pipeline vocabulary**, from `codebase-analyzer.md:42-57`: XML string
  -> Parser (Saxy SAX -> generic DOM) -> Lowering (typed builders) ->
  Document -> Validator + Compiler -> Machine (interned, valid by
  construction) -> Interpreter (pure Appendix D core) -> `{state, [effect]}`.
  Plus: interpreter functions keep the Appendix D names in snake_case
  (`select_transitions`, `compute_exit_set`, `compute_entry_set`,
  `microstep`, `enter_states`, `exit_states`); errors are events; the
  datamodel is predicator, compiling to
  `{:static, term} | {:compiled, instructions, source}` at Machine-build
  time.
- **The tree map**, from `codebase-locator.md:43-56,73-81`: `lib/statifier/`,
  `test/statifier/`, `test/scion_tests/` (tag `:scion`, excluded by default),
  `test/scxml_tests/` (tag `:scxml_w3`, excluded by default), `test/support/`
  (`Statifier.Case`, `test_scxml/4`), `tools/corpus/`,
  `lib/statifier/lowering/*.ex`, `test/passing_tests.json`.
- **The `../statifier` v1 reference checkout**, from
  `research-codebase/SKILL.md:130-132`: read-only, and a sub-agent must be
  pointed at it **explicitly** and only when the question involves v1
  behavior.
- **Good search keys** in this codebase, from
  `codebase-pattern-finder.md:59-62` and `thoughts-locator.md:52-60`: SCXML
  element names (`history`, `parallel`, `invoke`, `send`), Appendix D
  function names, "datamodel", "predicator", "corpus", "ratchet".
- **Areas that reliably want their own sub-agent**: the interpreter core, the
  lowering builders, the conformance corpus and ratchet, and the v1
  comparison.
- **External authority**: the W3C SCXML spec at
  https://www.w3.org/TR/scxml/ - `site:w3.org/TR/scxml` is the right web
  search shape.
- **Accepted ADRs are settled**: cite the number, do not re-argue
  (`research-codebase/SKILL.md:127`).

### Success Criteria:

#### Automated Verification:
- [x] All six files exist: `ls .claude/wurk` lists exactly `commit.md`,
      `implement.md`, `iterate.md`, `mr.md`, `plan.md`, `research.md`
- [x] No extension file names a script path that no longer resolves:
      `git grep -n '\.claude/scripts' -- .claude/wurk` returns nothing
- [x] No extension file names an old slash-command or agent:
      `git grep -nE '/(commit|create-plan|iterate-plan|implement-plan|research-codebase|merge-request|work|next-issues?|new-worktree|refresh-worktree|cleanup-worktrees|create-issue)\b|thoughts-(locator|analyzer)' -- .claude/wurk`
      returns nothing
- [x] Full `mix quality` is green (the diff touches no gated path, so the
      kit reports the carve-out; say "docs only, no quality gate applicable"
      rather than implying a green run that never happened - and run the full
      gate anyway to confirm the tree was already green)

#### Manual Verification:
- [ ] Each file reads as an **addition** to its generic skill: nothing in it
      restates or contradicts `~/.claude/skills/wurk:<name>/SKILL.md`
- [ ] `implement.md` is self-contained enough to be handed by path to a
      subagent with no other context - the sabotage protocol in particular
      needs no external read to follow
- [ ] `iterate.md` does not duplicate `plan.md`; it points at it
- [ ] Nothing from the extraction table is missing: sabotage protocol, ADR
      judge, corpus/ratchet criteria, Appendix D rule, pipeline vocabulary

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Sweep the living prose

### Overview

Update every document that describes how this repo works **today** so it
names the `wurk:*` skills, points at surfaces that will still exist, and
carries the two rules that lose their home when the local skills go. Dated
documents are left untouched.

### Changes Required:

#### 1. `CLAUDE.md`

**File**: `CLAUDE.md` (`AGENTS.md` is a symlink to it, so it follows)
**Changes**: rename in the authority table and the loop paragraph, and add a
pointer to the new extension surface.

- `:34` `/refresh-worktree` -> `/wurk:refresh`
- `:35` `/merge-request` -> `/wurk:mr` (both occurrences)
- `:45` `/implement-plan --loop` -> `/wurk:implement --loop`
- `:50` `.claude/skills/implement-plan/SKILL.md`'s
  `## Looped Execution Mode` -> `~/.claude/skills/wurk:implement/SKILL.md`'s
  `## Looped execution mode`. This is a path outside the repo now; word it as
  "the installed `wurk:implement` skill's `## Looped execution mode`" so it
  does not read as a repo file.
- `:57` `/commit --auto` -> `/wurk:commit --auto`
- Add a short paragraph in the "What this project is" area naming
  `.claude/wurk.json` as the project manifest and `.claude/wurk/*.md` as the
  extension files the `wurk:*` skills read, so a session knows where the
  project-specific half lives.

#### 2. `docs/workflow.md`

**File**: `docs/workflow.md`
**Changes**: the densest rewrite - 38 old-name mentions, all present tense.

- Model roles (`:14-16`): `/create-plan` and `/iterate-plan` -> `/wurk:plan`
  and `/wurk:iterate`; `/implement-plan` -> `/wurk:implement`.
- `:24-28`: `/work` -> `/wurk:work`, `/research-codebase` ->
  `/wurk:research`, `/create-plan` -> `/wurk:plan`,
  `/implement-plan --loop` -> `/wurk:implement --loop`.
- `:39-41`: `/new-worktree` -> `/wurk:branch`. Note the generic skill reads
  `parallelism.model` from the manifest (`worktree-per-issue` here), so the
  sentence should say the model is a manifest setting rather than a skill
  behavior.
- `:43-48`: the Direction bucket. Repoint `.claude/skills/work/SKILL.md`'s
  Step 3 to the installed `wurk:work` skill's step 3, **and** carry over the
  one rule the generic prompt genericized away
  (`.claude/skills/work/SKILL.md:216-224`): statifier ADRs are written
  directly as `Status: accepted (<date>)`; there is no `proposed` state,
  because a second status would need something to sweep for drafts that were
  never promoted, and the human gate is the review of the branch the ADR
  lands on.
- `:74-97`: `/next-issue` and `/next-issues` both collapse to `/wurk:next`
  (`n` defaults to 1; the batch form is `n > 1`). `/new-worktree` ->
  `/wurk:branch`. `/commit --auto` -> `/wurk:commit --auto`.
- `:108,144`: `/cleanup-worktrees` -> `/wurk:cleanup`.
- `:133,140,173`: `/refresh-worktree` -> `/wurk:refresh`.
- `:159`: the `area:skills` row. Its `Covers` column names two directories
  that will not exist. Repoint to `.claude/wurk.json`, `.claude/wurk/**`,
  `.claude/settings.json`. The label itself stays in the manifest; only this
  table's description changes.
- `:211,251,254`: `/cleanup-worktrees` -> `/wurk:cleanup`,
  `/refresh-worktree` -> `/wurk:refresh`.
- `:225-230`: `/work` -> `/wurk:work`, `/create-plan` -> `/wurk:plan`,
  `/implement-plan --loop` -> `/wurk:implement --loop`,
  `/research-codebase` -> `/wurk:research`.
- `:241-245`: `/commit` -> `/wurk:commit`; the
  `.claude/skills/implement-plan/SKILL.md` pointer gets the same treatment as
  `CLAUDE.md:50`.
- `:246`: `/merge-request` -> `/wurk:mr`.

#### 3. `docs/skill-automation.md`

**File**: `docs/skill-automation.md`
**Changes**: retire it as a dated record rather than renaming it. Its
substance is line counts and `Reason:` citations into files that will not
exist; a rename produces a document of dead pointers that still claims to be
living.

Replace the opening paragraph (`:1-21`) with a short dated header stating
that this was `st-hzf`'s audit of the thirteen skills that lived under
`.claude/skills/` until `st-cex`, that those skills and the
`.claude/scripts/` tree they were extracted into now live in the `wurk` repo
and are installed as `wurk:*`, that the classification below is the record of
that audit and its line references are to the tree as it stood then, and that
ADR-0015 (which it implements) is the decision to consult, pending its own
supersession record. Leave every table and every `Reason:` line below
untouched - rewriting a record defeats its purpose.

#### 4. Left alone, deliberately

`docs/adr/0010-*.md` and `docs/adr/0015-*.md` (ADR prose records decisions as
made; a rename there is a superseding ADR, which is `wu-1oo`),
`docs/quality-gate-changes.md` (append-only ledger; no guarded change here to
record), all 13 `docs/plans/` and 3 `docs/research/` documents (dated),
`.quality.exs` and `lib/mix/statifier/adr_*.ex` and their tests and fixtures
(see "What We're NOT Doing").

### Success Criteria:

#### Automated Verification:
- [x] No old slash-command name survives in living prose:
      `git grep -nE '/(commit|create-plan|iterate-plan|implement-plan|research-codebase|merge-request|work|next-issues?|new-worktree|refresh-worktree|cleanup-worktrees|create-issue)\b' -- CLAUDE.md docs/workflow.md`
      returns nothing
- [x] No pointer into a deleted tree survives in living prose:
      `git grep -nE '\.claude/(skills|scripts|agents)' -- CLAUDE.md docs/workflow.md`
      returns nothing
- [x] `docs/skill-automation.md` still contains its classification tables
      (`git grep -c 'implement-plan' docs/skill-automation.md` is unchanged
      from before the edit) and its new header names `st-cex` and ADR-0015
- [x] Full `mix quality` is green (docs-only diff; the kit reports the
      carve-out - report it as such, not as a green run)

#### Manual Verification:
- [ ] `CLAUDE.md`'s authority table still reads correctly with the new names:
      each trigger and each "still unauthorized when" clause still describes
      the skill it now points at
- [ ] `docs/workflow.md`'s `/wurk:next` paragraphs read as one skill with an
      `n`, not as two skills awkwardly merged
- [ ] The `area:skills` row's new `Covers` value matches what an `area:skills`
      bead would now actually touch
- [ ] `docs/skill-automation.md` reads unambiguously as a dated record; no
      reader would take its line numbers as current

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Delete the ported skills and agents

### Overview

Remove `.claude/skills/` (13 directories) and `.claude/agents/` (6 files).
This is the last phase whose gate is expected green, and it is a real gate
run rather than a carve-out: `.claude/skills/` is listed in the manifest's
`gate.also_gated_paths`, so a full `mix quality` is applicable and must pass.

### Changes Required:

#### 1. Delete the skill tree

**File**: `.claude/skills/` (entire directory)
**Changes**:

```bash
git rm -r -f .claude/skills
```

Thirteen directories: `cleanup-worktrees`, `commit`, `create-issue`,
`create-plan`, `implement-plan`, `iterate-plan`, `merge-request`,
`new-worktree`, `next-issue`, `next-issues`, `refresh-worktree`,
`research-codebase`, `work`.

#### 2. Delete the agent files

**File**: `.claude/agents/` (entire directory)
**Changes**:

```bash
git rm -r -f .claude/agents
```

Six files: `codebase-analyzer.md`, `codebase-locator.md`,
`codebase-pattern-finder.md`, `thoughts-analyzer.md`, `thoughts-locator.md`,
`web-search-researcher.md`. The installed `wurk-*` agents under
`~/.claude/agents/` replace them; the `thoughts-*` pair is renamed
`wurk-docs-*` there.

### Success Criteria:

#### Automated Verification:
- [ ] `test ! -d .claude/skills && test ! -d .claude/agents` succeeds
- [ ] `.claude/scripts/` is untouched: `git diff --name-only` for this phase
      shows no path under `.claude/scripts/`
- [ ] **Full `mix quality` is green**, all stages, including `Script tests`
      (its harness is still present) and `Gate guard` (no guarded path is in
      the diff, so no ledger entry is needed or permitted)
- [ ] `mix gate.verify` attests the run was full, not profiled or scoped
- [ ] Elixir tests still pass, specifically
      `test/mix/statifier/adr_judge_test.exs` and
      `test/mix/tasks/adr_judge_test.exs` - they assert against synthetic
      diff strings and never read the filesystem, so the deletion must not
      move them

#### Manual Verification:
- [ ] A fresh Claude session in this checkout still resolves `/wurk:commit`,
      `/wurk:plan`, and the rest from `~/.claude/skills/`
- [ ] The `wurk-codebase-locator` and `wurk-docs-locator` agents are
      spawnable and the removed local agent names no longer appear in the
      agent list
- [ ] Nothing in `.claude/wurk/*.md` written in Phase 1 turns out to have
      depended on a file just deleted

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: Delete the scripts tree (gate goes red by design)

### Overview

Remove `.claude/scripts/`. This phase is isolated and last because it is the
one change in this plan that **cannot** produce a green gate: `.quality.exs`
registers a `Script tests` stage that shells into
`.claude/scripts/test/run.rb`, deliberately without a `skip_exit_code`, so a
missing harness reddens rather than skips. Fixing that is `wu-s36`.

**Read this before running the gate**: the failure is anticipated. Do not
treat it as a defect to chase, and above all do not go green by weakening the
check - not by adding `skip_exit_code`, not by `--skip`, not by
`enabled: false`, not by narrowing the profile. `CLAUDE.md`'s ExQuality
section forbids all of it, and ADR-0011 makes `.quality.exs` a human's file
regardless.

### Changes Required:

#### 1. Delete the scripts tree

**File**: `.claude/scripts/` (entire directory)
**Changes**:

```bash
git rm -r -f .claude/scripts
```

16 top-level scripts, `lib/` (11 files), `test/` (the minitest suite,
`run.rb`, `support/`, and `fixtures/`), and `README.md`. Every one of them is
replaced by `~/.claude/skills/wurk:kit/scripts/`, which the installed skills
already call.

#### 2. Nothing else

No `.quality.exs` edit. No `.claude/wurk.json` edit. No
`docs/quality-gate-changes.md` entry. All three belong to `wu-s36`.

### Success Criteria:

#### Automated Verification:
- [ ] `test ! -d .claude/scripts` succeeds, and `ls -A .claude` lists exactly
      `settings.json`, `wurk`, `wurk.json`
- [ ] The diff for this phase touches **only** paths under
      `.claude/scripts/`: `git diff --name-only` shows nothing else
- [ ] The set of failing stages is **exactly** `["Script tests"]`. Decide it
      mechanically off the JSON report rather than by reading prose - capture
      it once and filter:

      ```bash
      mix quality --format json --report gate.json
      jq -r '[.stages[] | select(.status == "failed") | .name]' gate.json
      ```

      must print exactly `["Script tests"]`. (`deps/ex_quality/usage-rules.md`
      is the authority on the report's key names; adjust the filter to match
      it, do not adjust the assertion.) **This exact shape is the pass
      condition for this phase** - a green run is not expected, and any
      *second* failing stage is a real defect that must be fixed here
- [ ] That stage failed for the missing harness, not for a test result:
      `grep -c 'No such file or directory' <the Script tests stage output>`
      is non-zero and no minitest failure summary appears in it
- [ ] `mix quality --profile loop` is green: the loop profile's `stages:`
      allow-list excludes `Script tests`, so the inner loop is unaffected and
      that is the check that proves nothing else broke

#### Manual Verification:
- [ ] Read the full gate output end to end - do not truncate it, per
      `CLAUDE.md`'s ExQuality rules - and confirm the `○` skipped lines too:
      a stage that quietly went from running to skipped is a regression the
      failing-stage filter above will not catch
- [ ] Confirm no attempt was made to silence the stage: `git diff` for this
      phase shows no `.quality.exs`, `.credo.exs`, `coveralls.json`,
      `.sobelow-conf`, or `.claude/wurk.json` change, and no `@tag :skip` was
      added anywhere
- [ ] The human decides whether this phase is committed at all - see
      **Open question for the human** below. Do not resolve it by editing
      gate config

**Implementation Note**: The full gate is expected red here for exactly one
stage and exactly one reason, so this phase's Automated Verification is a
failure *shape*, not a green run. That makes it the one phase in this plan
that `/wurk:commit --auto` cannot advance past on its own: auto mode refuses
on a red gate, correctly, and this is the refusal working as designed rather
than a defect. Run this phase interactively, or expect a `--loop` run to stop
here and report. Manual Verification is not deferred for this phase; the
human is needed at its end regardless.

---

## Open question for the human

**Should Phase 4 be committed on this branch, or left uncommitted for the
human to sequence against `wu-s36`?**

The plan deliberately does not answer this, and no agent should answer it by
editing gate config.

The tension: `CLAUDE.md`'s authority table permits an agent to commit on the
issue's worktree branch only when "full `mix quality` is green", and Phase 4
cannot be green until `wu-s36` removes the `Script tests` stage. So Phase 4's
commit falls outside the standing grant either way. The two options:

1. **Commit it here anyway, with the human explicitly authorizing the red
   gate.** The branch is then complete and self-describing, and `wu-s36`
   lands the `.quality.exs` change plus its ledger entry on top - possibly on
   this same branch, which would make the pair green together before any PR
   is opened. Cost: an intermediate commit on the branch has a red gate,
   which is a state the repo's discipline otherwise never produces.
2. **Stop after Phase 3 and hand Phase 4 to `wu-s36`.** `st-cex` then lands
   green and complete-as-far-as-it-goes, and the scripts deletion moves into
   the human-gated bead that already has to touch `.quality.exs` - which is
   where the ledger entry lives anyway, so the two halves of one gate change
   travel together. Cost: `.claude/scripts/` survives one bead longer than
   the bead description says it should, and `st-cex` does not fully satisfy
   its own acceptance criteria.

Option 2 is the smaller deviation from the repo's own rules and keeps every
commit's gate honest; option 1 finishes the bead as written. This is a
sequencing call about the human's own gate, so it is recorded here rather
than decided.

Whichever is chosen, the prohibition is the same: **do not make the gate
green by weakening it.**

## Testing Strategy

### Unit Tests:

No new Elixir tests. This plan adds and deletes Markdown and Ruby files and
edits documentation; it changes no `lib/` behavior, so there is nothing to
sabotage and nothing to ratchet. The relevant existing tests are
`test/mix/statifier/adr_judge_test.exs` and `test/mix/tasks/adr_judge_test.exs`,
which pin ADR-0015's `.claude/skills/**/SKILL.md` scope. They must keep
passing unchanged through every phase; if either goes red, the deletion
reached further than intended and the fix is to narrow the deletion, not the
test.

### Manual Testing Steps:

1. After Phase 1, open each `.claude/wurk/*.md` beside its generic
   `~/.claude/skills/wurk:<name>/SKILL.md` and confirm the extension only
   adds.
2. After Phase 2, read `CLAUDE.md` and `docs/workflow.md` end to end as a new
   contributor would: every skill named must be one that resolves today.
3. After Phase 3, start a fresh Claude session in this checkout and invoke
   `/wurk:commit` and `/wurk:plan` far enough to confirm each reads its
   extension file, then abandon the run.
4. After Phase 3, drive one small real change through
   `/wurk:branch` -> `/wurk:work` -> `/wurk:commit` to confirm the extension
   files fire in a live loop. (This overlaps `wu-902`'s definition of done
   and can be left to it.)
5. After Phase 4, run the full gate once, read all of it, and record the
   exact failing-stage output in the bead note so `wu-s36` inherits the
   evidence.

## References

- Bead: `st-cex`
- Upstream plan: `~/repos/github/wurk/docs/plan.md` - phase 2 steps 6-7
  (`wu-off`), step 8 (`wu-s36`), step 9 (`wu-1oo`), step 10 (`wu-cgw`),
  definition of done (`wu-902`); the extraction table is in the "Step 2
  outcome notes (second half)" section
- Manifest: `.claude/wurk.json`
- Gate config: `.quality.exs:114-121` (the `Script tests` stage) and
  `:110-113` (why it has no `skip_exit_code`)
- Related ADRs: `docs/adr/0002-*` (Appendix D naming),
  `docs/adr/0003-pure-core-with-effects.md`,
  `docs/adr/0010-worktree-parallel-development.md`,
  `docs/adr/0011-*` (gate-change ledger),
  `docs/adr/0015-skill-mechanics-in-scripts.md`
- Repo docs: `CLAUDE.md`, `docs/workflow.md`, `docs/skill-automation.md`,
  `docs/testing.md`, `docs/quality-gate-changes.md`
- Extraction sources (all deleted by Phase 3, so read them during Phases 1-2):
  `.claude/skills/commit/SKILL.md`, `merge-request/SKILL.md`,
  `create-plan/SKILL.md`, `iterate-plan/SKILL.md`,
  `implement-plan/SKILL.md`, `research-codebase/SKILL.md`,
  `work/SKILL.md`, and `.claude/agents/codebase-analyzer.md`,
  `codebase-locator.md`, `codebase-pattern-finder.md`,
  `thoughts-locator.md`
- Installed generic skills: `~/.claude/skills/wurk:commit/SKILL.md`,
  `wurk:mr`, `wurk:plan`, `wurk:iterate`, `wurk:implement`, `wurk:research`,
  `wurk:work`, and `~/.claude/skills/wurk:kit/REFERENCE.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Each file reads as an **addition** to its generic skill: nothing in it
      restates or contradicts `~/.claude/skills/wurk:<name>/SKILL.md`
- [ ] `implement.md` is self-contained enough to be handed by path to a
      subagent with no other context - the sabotage protocol in particular
      needs no external read to follow
- [ ] `iterate.md` does not duplicate `plan.md`; it points at it
- [ ] Nothing from the extraction table is missing: sabotage protocol, ADR
      judge, corpus/ratchet criteria, Appendix D rule, pipeline vocabulary

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] `CLAUDE.md`'s authority table still reads correctly with the new names:
      each trigger and each "still unauthorized when" clause still describes
      the skill it now points at
- [ ] `docs/workflow.md`'s `/wurk:next` paragraphs read as one skill with an
      `n`, not as two skills awkwardly merged
- [ ] The `area:skills` row's new `Covers` value matches what an `area:skills`
      bead would now actually touch
- [ ] `docs/skill-automation.md` reads unambiguously as a dated record; no
      reader would take its line numbers as current

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---
