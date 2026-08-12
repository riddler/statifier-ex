# Wurk Config Catch-Up Implementation Plan

## Overview

Catch this repo's wurk configuration up to the kit's current feature set:
re-classify the gate skips between `gate.project_level_skips` and
`gate.not_applicable_skips`, author the missing `.claude/wurk/codebase.md`
(wurk ADR-0011), and make an explicit, recorded decision for every remaining
manifest schema field the kit now offers. Beads issue: `st-rtm`

## Current State Analysis

**The gate's actual skips.** A full `mix quality` was run on this branch as
ground truth rather than inferred from `.quality.exs`. It is green, and it
skips exactly three stages:

```
○ Doctor: skipped (:doctor not installed)
○ Gettext: skipped (:gettext not installed)
○ ADR judge: skipped (disabled in .quality.exs)
```

Everything else passes (1,228 tests, 96.1% coverage). The three `.po`
summaries declared in `gate.not_applicable_skips` never appear, because the
Gettext stage skips first on `:gettext not installed`; they are the same
declaration reached by a different stage message, exactly as CLAUDE.md says.

**Classification today** (verified by loading the manifest through the kit's
own `Manifest#project_level_skip_re` / `#not_applicable_skip_re`):

| Summary | Today |
|---|---|
| `:doctor not installed` | `project_level` |
| `:gettext not installed` | `not_applicable` |
| `disabled in .quality.exs` | `project_level` |

So the half-applied piece is one pattern: `^disabled in \.quality\.exs$`.

**What is behind that pattern.** Exactly one stage, today and by
construction: `adr_judge`, the only stage carrying `enabled: false` in
`.quality.exs`. It is disabled deliberately - it shells out to the developer's
real `claude` CLI, costing money and a network round trip - and the `merge`
profile re-enables it. `.claude/wurk/mr.md` makes running it a required step
of every `/wurk:mr`, unconditionally, via `mix quality --profile merge`. So
the stage is not unrun in this project; it runs by a different route, at the
one moment its cost is worth paying.

**`gate.sabotage` is absent from the manifest.** The bead's section 3 says it
is "configured here"; it is not. `.claude/wurk.json`'s `gate` section has
`full`, `loop`, `report`, `attest`, `guard_ledger`, `build_paths`,
`also_gated_paths`, `moving_files`, and the two skip lists - and no
`sabotage`. `Manifest#sabotage?` returns `false`, `data.sabotage.enabled` is
`false` on every gate run, and `.claude/wurk/commit.md`'s Step 0 - this
project's hardest commit-time refusal condition, written against
`data.sabotage.missing` - therefore has nothing to fire on. wurk's
`docs/manifest.md` "Per-repo starting values" table records statifier-ex as
the only consumer declaring the section, which is true of the intent and
false of the file.

**No `.claude/wurk/codebase.md`.** `.claude/wurk/` holds six per-skill
extensions (`commit`, `implement`, `iterate`, `mr`, `plan`, `research`) and no
agent-family file. wurk ADR-0011 was written about this repo and this repo is
the one consumer that has not written the file.

**The ledger question, answered from the source.**
`lib/mix/statifier/gate_guard.ex:36-38` fixes the guarded surface:
`.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf`, plus
`mix.exs` matched by line content (`:43`), `test/` files gaining a `@tag
:skip` (`:52`), and `test/passing_tests.json` shrinking (`:206-236`).
`.claude/wurk.json` is on none of those lists, and no phase of this plan
touches `.quality.exs`. **No `docs/quality-gate-changes.md` entry is
mechanically required.** Whether one is wanted voluntarily is a human's call
and is recorded under Open Questions, not written by an implementing agent.

### Key Discoveries:

- Ground-truth skip set and green baseline: the `mix quality` output quoted
  above, run on this branch at plan time.
- `.quality.exs:23` (`adr_judge: [enabled: false]`) and `.quality.exs:33-35`
  (`profiles: merge: adr_judge: [enabled: true]`) are the whole reason the
  `disabled in .quality.exs` summary exists, and the whole reason it is not a
  gap.
- `.claude/wurk/mr.md` "Extra step: the ADR judge (unconditional, before step
  7's push)" - the route by which the stage does run here.
- ADR-0017 point 6: a manifest key that encodes a policy call must have the
  policy stated in prose it points back to; the violation is a decision
  arriving as a key with nothing prose-side stating it. `gate.project_level_skips`
  is named in that record by name. Its judge scope is `.claude/wurk` as a bare
  prefix (`lib/mix/statifier/adr_judge.ex:199`), so it covers both
  `.claude/wurk.json` and `.claude/wurk/**` - every file this plan writes is
  judged at MR time.
- CLAUDE.md's "Which skipped stages are gaps and which will never apply" is
  the prose half ADR-0017 point 6 demands for the skip lists. It must move in
  the same commit as the lists.
- wurk `docs/manifest.md:198-204`: precedence is `not_applicable_skips` first,
  and rewriting a broad `project_level_skips` pattern with a negative
  lookahead to work around a shared summary is explicitly warned against.
- wurk ADR-0011 point 1: `codebase.md` is free-form markdown, no schema, and
  should stay "around a screenful" because it is pasted into every
  codebase-agent prompt.
- wurk ADR-0010 / `docs/manifest.md:277-314`: `rebase.auto_resolve_paths`
  entries are validated disjoint from `gate.build_paths`,
  `gate.also_gated_paths`, `gate.moving_files`, `gate.guard_ledger`,
  `parallelism.repair_when`, and from `.claude/` itself - in both match
  directions.
- st-29g is the open bead that owns whether `.claude/wurk.json` belongs in
  `gate.also_gated_paths`; this plan does not pre-empt it.

## Desired End State

- `.claude/wurk.json` classifies each of the three real skip summaries
  deliberately: Doctor stays a standing project gap, Gettext and the ADR judge
  are declared permanently inapplicable to a bare gate run.
- CLAUDE.md's skip-taxonomy section states the reason for each pattern,
  including the new one, so `mix quality --profile merge`'s ADR judge finds
  the key and the prose travelling together.
- `.claude/wurk/codebase.md` exists, is about a screenful, and carries this
  repo's layout, suite split, pipeline invariants, grep vocabulary, and
  spec-port reading rules.
- `.claude/wurk.json` declares `gate.sabotage`, so `.claude/wurk/commit.md`
  Step 0 becomes enforceable rather than inert.
- Every field the bead's section 3 names has a written decision in
  `docs/workflow.md`, including the ones left at their default.
- `ruby ~/.claude/skills/wurk:kit/scripts/lib/manifest.rb check` reports
  `valid: true`, and `mix quality` is still green and unchanged from the
  baseline above.

Verification: the manifest lint, the classification probe and the sabotage
probe under each phase's Automated Verification, plus a full `mix quality`.

## What We're NOT Doing

- **Not touching `.quality.exs`.** Nothing here needs a gate-config change,
  which is also what keeps the ADR-0011 ledger out of scope. If an
  implementation finds itself editing that file, it has left the plan.
- **Not rewriting `^disabled in \.quality\.exs$` with a negative lookahead**
  to split it per stage. wurk `docs/manifest.md:198-204` names that exact
  workaround as the thing the two-list precedence rule exists to avoid.
- **Not changing `gate.also_gated_paths`**, and not adding `.claude/wurk.json`
  to it. That is st-29g's decision, still open, with three named options; a
  drive-by pick here would settle it without the analysis it asked for.
- **Not opting into `rebase.auto_resolve_paths`.** See Phase 3's decision
  table for the reasoning, recorded rather than silently skipped.
- **Not changing `lib/` or `test/`.** No phase needs them: the skip lists are
  manifest data read by kit Ruby, `codebase.md` is prompt text, and
  `gate.sabotage` is read by `gate.rb`, not by `mix quality`. The one place
  this plan comes close is `gate.sabotage` changing what `/wurk:commit`
  refuses - but that is the kit reading a manifest key, not an Elixir change.
- **No changelog fragment.** `changelog.d/README.md` excludes "quality gate,
  CI, or agent tooling changes" outright, and nothing here is observable to
  someone calling the public API.
- **Not adding an `artifacts.repository` key or a `judge` section.** Both are
  optional, both degrade correctly (the repository name derives from the git
  remote; the kit's judge is not this repo's judge - `mix adr.judge` is), and
  neither is named by the bead. Recorded here so a later reader knows they
  were looked at.

## Implementation Approach

Three phases, one per part of the bead, each a single commit. Each phase pairs
a machine-read key with the prose that states its policy, because ADR-0017
point 6 makes that pairing a merge-time refusal condition rather than a
courtesy - a key moved in one commit and explained in the next is a violation
in the window between them, and the ADR judge reads the branch diff.

None of the three phases touches Elixir, so `gate.rb`'s carve-out will report
`applicable: false` for this branch (the st-29g observation). CLAUDE.md's
authority table covers this case explicitly: "a change touching no Elixir code
has no gate to run and may commit on review of the diff alone". Each phase
therefore carries real automated checks of its own - the manifest lint and
targeted probes against the kit's own loader - and a full `mix quality` as the
standing no-regression bar rather than as the thing that measures the change.

**Why the ADR judge sits under Manual Verification in all three phases even
though a command decides it.** `mix quality --profile merge` is command-
decidable and `.claude/wurk/mr.md` already treats a finding as a hard refuse,
so by the usual test it belongs under Automated. It is filed as Manual anyway,
deliberately: it makes real `claude` CLI calls, so putting it in the
per-phase automated gate would buy three paid model round trips per branch to
answer a question the branch only has to answer once, at MR time. The backstop
is real rather than assumed - `.claude/wurk/mr.md` runs it unconditionally
before every push, and refuses on a finding - so nothing ships unjudged. Do
not copy this categorization to a check that has no such backstop.

## Phase 1: Re-classify the gate skips

### Overview

Move `^disabled in \.quality\.exs$` from `gate.project_level_skips` to
`gate.not_applicable_skips`, and rewrite CLAUDE.md's taxonomy section to state
why - including the fact that the pattern is not stage-distinguishable, and
what that obliges a future editor to do.

**The decision, stated:** the choosing test in wurk `docs/manifest.md:176-181`
is *would this project run the stage if someone did the work?* For the ADR
judge the answer is no - not because the stage is worthless, but because the
work is already done and landed elsewhere. `.quality.exs:23` disables it on
purpose (real `claude` CLI calls, real spend), the `merge` profile re-enables
it, and `.claude/wurk/mr.md` runs `mix quality --profile merge` unconditionally
before every push. Nobody should ever "close the gap" of the bare gate not
running it; doing so would be a regression against a deliberate design. And the
reporting consequence is the one that makes the classification obviously right:
a `/wurk:mr` request body that recites "ADR judge skipped" is describing a
stage the same skill runs for real two steps later.

### Changes Required:

#### 1. The manifest

**File**: `.claude/wurk.json`
**Changes**: `gate.project_level_skips` keeps only the Doctor pattern;
`gate.not_applicable_skips` gains the `.quality.exs` pattern.

```json
"project_level_skips": [
  "^:doctor not installed$"
],
"not_applicable_skips": [
  "^:gettext not installed$",
  "^no \\.po files found$",
  "^no \\.po files outside the source locale$",
  "^disabled in \\.quality\\.exs$"
]
```

#### 2. The prose the key points back to

**File**: `CLAUDE.md`, section "Which skipped stages are gaps and which will
never apply"
**Changes**: extend the **Not applicable** bullet so Gettext is no longer "the
whole list". The added prose must carry three things, because each is load
bearing for a future reader:

- Why the ADR judge is not a gap: disabled deliberately in `.quality.exs` for
  cost, re-enabled by `--profile merge`, and run unconditionally by
  `/wurk:mr` per `.claude/wurk/mr.md`. The stage runs here; only the bare
  gate declines to run it.
- That the summary string carries no stage name, so the pattern classifies
  *every* stage disabled in `.quality.exs`, and that `adr_judge` is the only
  such stage today.
- The obligation that follows: disabling a second stage in `.quality.exs` is
  a change to what this pattern silently classifies, and must be re-argued in
  this section at that time rather than inheriting the ADR judge's answer.

The existing **Project-level gap** bullet keeps Doctor and needs no change
beyond dropping any implication that it also covers the disabled stages.

### Success Criteria:

#### Automated Verification:

- [x] `ruby ~/.claude/skills/wurk:kit/scripts/lib/manifest.rb check` reports
      `ok: true` and `valid: true`.
- [x] The classification probe reports the intended taxonomy for all three
      real summaries:

      ```bash
      ruby -e '
      $LOAD_PATH.unshift File.expand_path("~/.claude/skills/wurk:kit/scripts/lib")
      require "manifest"
      m = Manifest.load(start: Dir.pwd)
      pl, na = m.project_level_skip_re, m.not_applicable_skip_re
      [":doctor not installed", ":gettext not installed",
       "disabled in .quality.exs"].each do |s|
        c = (na && s =~ na) ? "not_applicable" :
            ((pl && s =~ pl) ? "project_level" : "run_level")
        puts "#{s} -> #{c}"
      end' 2>/dev/null
      ```

      Expected: `:doctor not installed -> project_level`,
      `:gettext not installed -> not_applicable`,
      `disabled in .quality.exs -> not_applicable`.
- [x] `git diff` for the phase shows `CLAUDE.md` changed. A manifest-only diff
      is the ADR-0017 point 6 failure by construction and fails this phase.
- [x] Full `mix quality` green, with the same three skipped stages and no new
      findings (use `mix quality --profile loop` while iterating; it is never
      the phase gate).

#### Manual Verification:

- [x] `mix quality --profile merge` produces no ADR judge finding against the
      `.claude/wurk` scope for this diff - the key and its prose moved
      together, and the prose states the policy rather than pointing at the
      key.
- [x] Read the new CLAUDE.md paragraph cold: does it tell someone who has
      never seen `.quality.exs` why the ADR judge skip is not a gap, and what
      they owe the section if they disable a second stage?
- [x] The stated reporting outcome holds: a `/wurk:mr` request body on a green
      branch would name Doctor and nothing else.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: Author `.claude/wurk/codebase.md`

### Overview

Write the host-project orientation file wurk ADR-0011 defines, addressed to
the `wurk-codebase-locator`, `-analyzer`, and `-pattern-finder` agents. Free-
form markdown, no schema, kept to roughly a screenful because every
codebase-agent spawn pastes it verbatim (ADR-0011 point 1 and its fourth
consequence).

### Changes Required:

#### 1. The orientation file

**File**: `.claude/wurk/codebase.md` (new)
**Changes**: model the shape on `/Users/johnnyt/repos/github/wurk/.claude/wurk/codebase.md`
- a title, then Layout / Suites / Module families / Terms of art / Reading
rules. Content, all verified against the tree at plan time:

- **Layout.** `lib/statifier/` in pipeline order - `parser/` (Saxy SAX to a
  generic DOM with `Parser.Location` on every node), `lowering/` (DOM to typed
  `Document` structs), `validator/` with one check per file under
  `validator/checks/`, `compiler/` (Document to interned `Machine`),
  `interpreter/` (`selection`, `name_match`, `exit_entry`, `content`),
  `evaluator/`, `effect/` including `effect/trace/`. `lib/mix/tasks/` and
  `lib/mix/statifier/` hold the repo's own gate machinery (`gate.check`,
  `gate.verify`, `adr.check`, `adr.judge`, `test.regression`,
  `test.baseline`). `tools/corpus/` holds the corpus pipeline (`mise run
  corpus`; `tools/corpus/README.md` explains the stages). `docs/adr/` holds
  the settled decisions.
- **Suites.** `test/statifier/` mirrors `lib/statifier/` one-to-one and runs
  by default. `test/scion_tests/` (`:scion`) and `test/scxml_tests/`
  (`:scxml_w3`, split `mandatory/` and `optional/`) are generated conformance
  corpora, excluded by default. `test/passing_tests.json` is the regression
  ratchet. `test/support/` is harness (`Statifier.Case.test_scxml/4` is the
  single coupling surface every suite goes through; `Statifier.TmpDir` backs
  `@tag :isolated_tmp_dir`). A fourth suite, `:adr_judge_corpus`, makes real
  `claude` CLI calls and is excluded from every ordinary run.
- **Module families worth mining.** `Document.*` (uncompiled) versus
  `Machine.*` (interned, valid by construction) are parallel families and the
  best pattern source for a new SCXML element; `validator/checks/*.ex` is one
  file per check and the template for a new one; `effect/*.ex` and
  `effect/trace/*.ex` are one struct per effect.
- **Terms of art (the best search keys).** Appendix D function names -
  `select_transitions`, `select_eventless_transitions`,
  `remove_conflicting_transitions`, `get_transition_domain`,
  `compute_exit_set`, `compute_entry_set`, `add_descendant_states_to_enter`,
  `microstep`, `macrostep`, `enter_states`, `exit_states`, `main_event_loop`,
  `exit_interpreter`. SCXML element names as they appear in tests and
  lowering builders. Project coinages: `t_index` / `c_index`, LCCA, full
  configuration versus leaf-state view, `done.state.<id>`, `error.execution`,
  UXID prefixes `sess_` / `send_` / `inv_`.
- **Reading rules** (the part no CLAUDE.md read reproduces):
  - Appendix D function names are the highest-yield grep keys; reach for them
    before English descriptions of behavior.
  - Describe a ported interpreter function **against the spec pseudocode**,
    not by inferring intent from the Elixir. A deviation is a finding worth
    reporting, and an inline comment citing a mechanical reason is what makes
    one legitimate (ADR-0002).
  - The core is pure: `(machine_state, event) -> {machine_state, [effect]}`.
    Anything that looks like a side effect in `lib/statifier/` is either an
    `Effect` struct being returned or a bug (ADR-0003).
  - Evaluations return `{:ok, v} | {:error, e}`; only the interpreter raises
    `error.execution`, and only in `Interpreter.Content`. A rescue-to-default
    at a leaf is a finding.
  - State ids are strings only at the `Statifier` boundary; below it
    everything is an interned integer index (ADR-0005).
  - Expressions are predicator, never ECMAScript or `eval`; `<invoke>` is the
    escape hatch (ADR-0004).
  - Accepted ADRs under `docs/adr/` are settled - cite the number rather than
    re-arguing.

The file states facts and search strategy only. Per ADR-0011 point 5 it adds
and never overrides, and per ADR-0017 point 1 it must not become the place a
policy call is restated or, worse, moved to - the sabotage discipline,
commit-time refusals and gate policy stay in their own files and are not
summarized here.

### Success Criteria:

#### Automated Verification:

- [x] `.claude/wurk/codebase.md` exists and is non-empty.
- [x] `wc -l .claude/wurk/codebase.md` is under 70 lines - ADR-0011's
      "around a screenful", made checkable, pinned near wurk's own 55-line
      file rather than at a round number, with the margin covering the two
      headings this repo's deeper pipeline needs that wurk's does not.
- [x] Every path the file names resolves: each `lib/`, `test/`, `tools/`, or
      `docs/` path mentioned exists on disk.
- [x] Full `mix quality` green (unchanged; the file is prompt text and no
      stage reads it).

#### Manual Verification:

- [x] `mix quality --profile merge` produces no ADR judge finding: the file
      carries orientation, not a policy call lifted out of `commit.md`,
      `implement.md`, or CLAUDE.md.
- [x] Spawn a `wurk-codebase-analyzer` with the file pasted under "Project
      orientation, from .claude/wurk/codebase.md" and a question about an
      interpreter function; confirm it reaches for Appendix D names and
      describes the function against the pseudocode.
- [x] Every claim in the file is true today - especially the suite split and
      the module families, which are the parts that rot first.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: Declare `gate.sabotage` and record the schema decisions

### Overview

The review pass. One field turns out to be a real hole rather than a
confirmation - `gate.sabotage` is absent, which makes `.claude/wurk/commit.md`
Step 0 unenforceable - so this phase adds it. The other five are confirmed and
recorded, including the two that stay at their default, because "we looked and
chose the default" and "nobody looked" are indistinguishable from the file
alone.

### Changes Required:

#### 1. The sabotage scan

**File**: `.claude/wurk.json`, `gate` section
**Changes**: add the section, with the values this project's own prose already
states.

```json
"sabotage": {
  "test_roots": ["test/"],
  "test_pattern": "\\btest\\s+\"",
  "exempt_prefixes": ["test/scion_tests/", "test/scxml_tests/"]
}
```

`test_roots` and `test_pattern` must be given together or not at all; the
section is present-or-absent, never partly on. `exempt_prefixes` matches
`.claude/wurk/commit.md`'s "Generated corpus files (`test/scion_tests/`,
`test/scxml_tests/`) are exempt" and `docs/testing.md`'s exemption rule -
the prose ADR-0017 point 6 requires this key to point back to already exists,
which is why this key needs no new prose beyond the decision record below.

Note the consequence, and do not soften it: with the section declared,
`data.sabotage.missing` starts reporting on every commit, and
`.claude/wurk/commit.md` Step 0 turns that report into a refusal. That is the
intended state - the policy has been written down and unenforceable since the
manifest was authored - but the first commits after this land may stop on
tests that were never noted.

#### 2. The decision record

**File**: `docs/workflow.md`, new section after "Worktrees and parallel
agents"
**Changes**: a short section, "Wurk manifest decisions", carrying one row per
reviewed field. It is the prose home for the review, and the place a future
reader finds out that a default was chosen rather than inherited.

| Field | Decision | Reason |
|---|---|---|
| `rebase.auto_resolve_paths` | Leave absent (feature off) | wurk ADR-0010 biases hard toward stopping, and the validator rejects any entry that is or is under `.claude/`, or that collides with `gate.build_paths`, `also_gated_paths`, `moving_files`, `guard_ledger`, or `parallelism.repair_when`. What is left is `docs/`, and this repo's conflict-prone docs are already per-issue-named - `docs/plans/<date>-<id>-*.md`, `changelog.d/<id>.md`, `docs/research/*` - so two branches do not write the same file (`changelog.d/README.md` states that as the reason fragments exist). wurk allows exactly `docs/plan.md`, a single shared file this repo has no equivalent of. There is no incident to point at here and no file the allowlist would help; opting in would buy model spend and a new failure surface for nothing. |
| `repo.default_branch` | Leave absent | The loader default is `main` and this repo's default branch is `main`. Setting it explicitly changes no behavior at any of the six sites `docs/manifest.md:141-151` lists. |
| `models.direction` | Keep `fable` | Landed by st-4i0, settled against the wu-ubm research; wurk `docs/manifest.md:383-390` records the resolution as yes. Unchanged. |
| `gate.sabotage` | **Add** | Was absent, contrary to wurk's per-repo table. Its absence made `.claude/wurk/commit.md` Step 0 inert. Values above. |
| `gate.attest` | Keep `["mix", "gate.verify"]` | Matches the table; `mix gate.verify` is the tier-2 proof that a run was a full gate rather than a profiled or scoped one (ADR-0011). Unchanged. |
| `gate.guard_ledger` | Keep `docs/quality-gate-changes.md` | Matches the table and matches `Mix.Statifier.GateGuard`'s own `@ledger_path` (`lib/mix/statifier/gate_guard.ex:37`), which is the definition site the kit field has to agree with. Unchanged. |

The section should also name what was deliberately not decided here:
`gate.also_gated_paths` and whether `.claude/wurk.json` belongs in it is
st-29g's, still open.

### Success Criteria:

#### Automated Verification:

- [x] `ruby ~/.claude/skills/wurk:kit/scripts/lib/manifest.rb check` reports
      `ok: true` and `valid: true`.
- [x] The sabotage probe confirms the section is live and reads back the
      intended values:

      ```bash
      ruby -e '
      $LOAD_PATH.unshift File.expand_path("~/.claude/skills/wurk:kit/scripts/lib")
      require "manifest"
      m = Manifest.load(start: Dir.pwd)
      puts m.sabotage?
      p m.sabotage_test_roots, m.sabotage_test_pattern, m.sabotage_exempt_prefixes
      ' 2>/dev/null
      ```

      Expected: `true`, `["test/"]`, `"\\btest\\s+\""`,
      `["test/scion_tests/", "test/scxml_tests/"]`.
- [x] `rebase` is still absent from the manifest and `models.direction` still
      reads `fable`.
- [x] `git diff` for the phase shows `docs/workflow.md` changed alongside
      `.claude/wurk.json` - the same key-and-prose pairing Phase 1 requires.
- [x] Full `mix quality` green.

#### Manual Verification:

- [x] `mix quality --profile merge` produces no ADR judge finding: the new
      `gate.sabotage` key points back at `docs/testing.md` and
      `.claude/wurk/commit.md`, which state the discipline, and the new
      `docs/workflow.md` section records the decision rather than replacing
      the discipline with a check on its own artifact.
- [x] Run `/wurk:commit` (or `gate.rb` directly) on a branch with a new test
      and confirm `data.sabotage.enabled` is now `true` and `missing` reports
      what it should - the scan being on is the whole point of the change.
- [x] Read the `rebase.auto_resolve_paths` row cold: is "off" still the right
      answer for this repo, or does a real conflict since plan time argue
      otherwise?

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

None. No phase changes `lib/` or `test/`, so there is nothing in the Elixir
suite to cover: the skip lists and `gate.sabotage` are manifest data read by
the kit's Ruby (whose tests live in the `wurk` repo, not here), and
`codebase.md` is prompt text with no consumer inside `mix quality`. Adding an
Elixir test that asserts the content of `.claude/wurk.json` would be a second,
drifting statement of what `lib/manifest.rb` already validates. The probes in
each phase's Automated Verification run the real loader against the real file
and are the honest check.

The one place this plan does move test-suite behavior is Phase 3's
`gate.sabotage`, and it moves it in the kit, not the suite: `mix test` runs
identically before and after; what changes is what `/wurk:commit` refuses.

### Manual Testing Steps:

1. Run `mix quality` and confirm the three skipped stages are unchanged from
   the baseline in Current State Analysis - the plan reclassifies skips, it
   must not make a stage start or stop skipping.
2. Run the classification probe from Phase 1 and read the three lines against
   the taxonomy in CLAUDE.md; they must agree word for word with the section.
3. Run `mix quality --profile merge` once on the finished branch, before the
   push. Every file this plan writes is inside the ADR judge's `.claude/wurk`
   scope, so this is the check that the key-and-prose pairing actually held.
   `.claude/wurk/mr.md` makes a finding a hard refuse.
4. Spawn one `wurk-codebase-*` agent with `codebase.md` forwarded and judge
   whether the orientation changed its output.
5. On the next branch that adds a test, confirm the sabotage scan reports.

## Open Questions

Recorded rather than guessed at; no human was available when this plan was
written. Each names the choice made and the reasoning, so a maintainer can
overturn one without re-deriving it.

1. **Is `disabled in .quality.exs` really "not applicable", or a gap?**
   Neither list's stated definition fits perfectly. `docs/manifest.md`'s
   not-applicable wording is "the stage will never run here", and the ADR
   judge does run here - under `--profile merge`, on every `/wurk:mr`. The
   *choosing test* the same document states, though - would the project run it
   if someone did the work? - answers no cleanly: the work is done and the
   stage is deliberately off in the bare gate for cost reasons.
   **Assumption: not-applicable**, chosen because the reporting consequence
   settles it - naming a stage as a standing gap in a request body produced by
   the same skill that runs the stage for real is noise, which is exactly what
   `not_applicable_skips` exists to remove. A maintainer who wants MR bodies to
   keep saying "the bare gate did not run the ADR judge" should move the
   pattern back and say so in CLAUDE.md.

2. **The pattern is not stage-distinguishable, and cannot be made so here.**
   ex_quality's summary string is `disabled in .quality.exs` with no stage
   name, and this repo does not author it. Today `adr_judge` is the only stage
   with `enabled: false`, so the pattern classifies exactly one stage.
   **Assumption: accept the broad pattern**, and carry the obligation in
   CLAUDE.md prose instead - disabling a second stage means re-arguing the
   classification. The alternatives were both rejected: a negative-lookahead
   rewrite is warned against by name in `docs/manifest.md:198-204`, and getting
   the stage name into the summary is an upstream ex_quality change, out of
   scope for this bead and worth its own if the situation recurs.

3. **`gate.sabotage` is absent, not "configured here" as the bead assumes.**
   **Assumption: the bead and wurk's per-repo table are right about intent and
   the manifest is wrong**, so Phase 3 adds it. Note the behavioral edge: this
   turns on a report that `.claude/wurk/commit.md` Step 0 converts into a
   commit-time refusal, so the first commits afterward may stop on tests
   written before the scan existed. A maintainer who wants that transition
   sequenced separately should split Phase 3 into its own bead; the plan
   bundles it because a written-down policy nothing can enforce is the worse
   state to leave standing.

4. **No `docs/quality-gate-changes.md` entry is required, and none is
   written.** `Mix.Statifier.GateGuard`'s guarded surface
   (`lib/mix/statifier/gate_guard.ex:36-52, 206-236`) does not include
   `.claude/wurk.json`, and no phase touches `.quality.exs`, so the Gate guard
   stage stays green. The question a human owns: whether the skip
   re-classification deserves a *voluntary* entry in the spirit of the st-6f7
   precedent, which recorded a narrowing the mechanical check could not see.
   **Assumption: no entry.** An agent writing one would be granting itself the
   permission the check exists to withhold, which `.claude/wurk/commit.md`
   forbids in as many words. The ADR-0017 judge covers this surface instead,
   and CLAUDE.md carries the prose.

5. **Is `docs/workflow.md` the right home for the schema decision record?**
   It is the file CLAUDE.md points at for "model roles, beads, worktrees", it
   already discusses `.claude/wurk.json` (`parallelism.model` at line 43, the
   area-label table at line 167), and the alternatives are worse: CLAUDE.md is
   instructions rather than a decision log, and an ADR is too heavy for
   "confirmed at the default". **Assumption: `docs/workflow.md`.** If a
   maintainer would rather these live on the bead, the section moves and the
   plan loses nothing.

6. **`gate.also_gated_paths` and `.claude/wurk.json`.** Every phase of this
   plan lands a change to what the workflow does, on a branch where `gate.rb`
   will report `applicable: false`. That is the exact observation st-29g was
   filed on. **Assumption: leave it alone** - st-29g names three options,
   including raising it upstream in wurk as a carve-out-model gap, and picking
   one in passing here would settle a bead by accident.

## References

- Bead: `st-rtm`
- Related beads: `st-29g` (is `wurk.json` a gated path), `st-8nj` (judge scope
  over the manifest, resolved into ADR-0017 point 6), `st-4i0`
  (`models.direction`), `st-5y5` (added `gate.project_level_skips`)
- Manifest schema: `/Users/johnnyt/repos/github/wurk/docs/manifest.md` -
  especially lines 171-211 (the two skip lists), 213-245 (`gate.sabotage`),
  277-314 (`rebase.auto_resolve_paths`), 356-401 (per-repo starting values)
- wurk ADRs: `/Users/johnnyt/repos/github/wurk/docs/adr/0011-codebase-orientation-extension-file.md`,
  `/Users/johnnyt/repos/github/wurk/docs/adr/0010-bounded-rebase-conflict-auto-resolution.md`
- Shape to model `codebase.md` on:
  `/Users/johnnyt/repos/github/wurk/.claude/wurk/codebase.md`
- This repo: `CLAUDE.md` ("Which skipped stages are gaps and which will never
  apply"), `.quality.exs:23,33-35`, `.claude/wurk/commit.md`,
  `.claude/wurk/mr.md`, `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0017-judgment-not-scriptable-in-wurk-extensions.md`,
  `docs/testing.md`, `changelog.d/README.md`
- Enforcement sites: `lib/mix/statifier/gate_guard.ex:36-52`,
  `lib/mix/statifier/adr_judge.ex:196-201`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [x] `mix quality --profile merge` produces no ADR judge finding against the
      `.claude/wurk` scope for this diff - the key and its prose moved
      together, and the prose states the policy rather than pointing at the
      key.
- [x] Read the new CLAUDE.md paragraph cold: does it tell someone who has
      never seen `.quality.exs` why the ADR judge skip is not a gap, and what
      they owe the section if they disable a second stage?
- [x] The stated reporting outcome holds: a `/wurk:mr` request body on a green
      branch would name Doctor and nothing else.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [x] `mix quality --profile merge` produces no ADR judge finding: the file
      carries orientation, not a policy call lifted out of `commit.md`,
      `implement.md`, or CLAUDE.md.
- [x] Spawn a `wurk-codebase-analyzer` with the file pasted under "Project
      orientation, from .claude/wurk/codebase.md" and a question about an
      interpreter function; confirm it reaches for Appendix D names and
      describes the function against the pseudocode.
- [x] Every claim in the file is true today - especially the suite split and
      the module families, which are the parts that rot first.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 3

- [x] `mix quality --profile merge` produces no ADR judge finding: the new
      `gate.sabotage` key points back at `docs/testing.md` and
      `.claude/wurk/commit.md`, which state the discipline, and the new
      `docs/workflow.md` section records the decision rather than replacing
      the discipline with a check on its own artifact.
- [x] Run `/wurk:commit` (or `gate.rb` directly) on a branch with a new test
      and confirm `data.sabotage.enabled` is now `true` and `missing` reports
      what it should - the scan being on is the whole point of the change.
- [x] Read the `rebase.auto_resolve_paths` row cold: is "off" still the right
      answer for this repo, or does a real conflict since plan time argue
      otherwise?

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---
