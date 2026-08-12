---
date: 2026-08-12
issue: st-1xz
title: Closes the doctor gate gap
status: draft
---

# Doctor Documentation-Coverage Gate Implementation Plan

## Overview

Turn the standing `○ Doctor: skipped (:doctor not installed)` line in every
`mix quality` run into a real, passing gate stage. Beads issue: `st-1xz`.

This plan takes the bead's **outcome 1**: add `:doctor` as a dev-only
dependency, configure thresholds in `.doctor.exs` that are *stricter* than
doctor's own defaults on every axis, backfill the fifteen missing `@doc`
strings the tool finds, and retire the skip pattern from
`.claude/wurk.json`. Outcome 2 (record a deliberate decision not to check doc
coverage) is not taken: the research below ran doctor for real against this
codebase and found no reason to decline.

The plan additionally closes a hole it discovered while checking the ADR-0011
interaction: neither `.doctor.exs` nor a `:doctor` line in `mix.exs` is
currently a guarded path, so today this whole change could land with no
ledger entry at all. That is not the behavior ADR-0011 describes for a file
that configures a gate threshold, so the plan makes doctor's config surface
guarded *before* it introduces that config surface, and accepts the human
handoff that follows.

## Current State Analysis

### The skip today

`mix quality` reports `○ Doctor: skipped (:doctor not installed)`.
`.claude/wurk.json:42-44` matches it under `gate.project_level_skips`, so the
wurk kit classifies it as a real gap in what the project checks - reported on
every run, not blocking. `CLAUDE.md` ("Which skipped stages are gaps and which
will never apply", the "Project-level gap" bullet) names Doctor as the sole
member and says the decision is owned by st-1xz.

### What the Doctor stage actually does

`deps/ex_quality/lib/ex_quality/stages/doctor.ex` shells out to
`mix doctor --raise` with `MIX_ENV=dev` and parses a coverage percentage out
of the text. The only key it reads from `.quality.exs` is
`doctor: [summary_only: bool]`; every real threshold lives in a `.doctor.exs`
file the doctor package itself loads (`deps/doctor/lib/config.ex:37-52`). The
stage auto-enables purely on `:doctor` being present in `deps/0` - no
`.quality.exs` change is needed to make it run.

### Measured ground truth (doctor 0.23.0, run against this branch)

The dependency was added temporarily, `mix doctor` was run, and the tree was
reverted. Results, with doctor's **defaults**:

```
Passed Modules: 76      Failed Modules: 13
Total Doc Coverage:        92.6%
Total Moduledoc Coverage: 100.0%
Total Spec Coverage:      100.0%
```

With a strict `.doctor.exs` (100% on every axis) the failures rise to fifteen
modules. Every one of the fifteen is the *same* defect: exactly one public
function with no `@doc`. Nothing else is short:

- Moduledoc coverage is already 100% (86 modules, 87 `@moduledoc """`, two
  `@moduledoc false`, which doctor counts as documented).
- Spec coverage is already 100% (282 `@spec`).
- `struct_type_spec_required` is already satisfied - every `defstruct` module
  reports `Struct Spec: Yes`.
- The two `defimpl` modules under `lib/statifier/machine/content/` report
  `N/A` across the board and are not counted.

So the honest threshold is 100%, and the gap to it is fifteen `@doc` strings.
There is no version of this where a threshold has to be bent to fit the
codebase - which is precisely the acceptance criterion the bead states.

### The exact fifteen sites

| File | Function |
|---|---|
| `lib/mix/statifier/adr_judge.ex:437` | `scoped_chunks/2` |
| `lib/statifier/compiler.ex:105` | `compile/1` |
| `lib/statifier/lowering.ex:70` | `lower/1` |
| `lib/statifier/validator.ex:62` | `validate/2` |
| `lib/statifier/validator/checks/boilerplate.ex:31` | `check/2` |
| `lib/statifier/validator/checks/content.ex:36` | `check/2` |
| `lib/statifier/validator/checks/default_entry.ex:33` | `check/2` |
| `lib/statifier/validator/checks/donedata.ex:16` | `check/2` |
| `lib/statifier/validator/checks/enums.ex:44` | `check/2` |
| `lib/statifier/validator/checks/final.ex:27` | `check/2` |
| `lib/statifier/validator/checks/history.ex:40` | `check/2` |
| `lib/statifier/validator/checks/ids.ex:26` | `check/2` |
| `lib/statifier/validator/checks/initial_element.ex:25` | `check/2` |
| `lib/statifier/validator/checks/initial_targets.ex:39` | `check/2` |
| `lib/statifier/validator/checks/targets.ex:24` | `check/2` |

`lib/statifier/validator/checks/default_transition.ex:38` already carries a
`@doc` and is the model the other eleven follow.

### The ADR-0011 surface, as it actually stands

`lib/mix/statifier/gate_guard.ex:36` guards four paths by name
(`.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf`) and
`gate_guard.ex:43` guards `mix.exs` by line content:

```elixir
@mix_exs_pattern ~r/test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir|:sobelow/
```

`:doctor` is **not** in that alternation, and `.doctor.exs` is **not** in
`@guarded_paths`. This was verified rather than assumed: with the experiment's
`mix.exs` edit and a new `.doctor.exs` both in the tree, `mix gate.check`
printed `No unjustified gate changes`. `.claude/wurk.json`'s
`gate.moving_files` mirrors the same four-path list and likewise omits it.

That is a genuine hole. Every other gate dependency is named in the pattern,
and `.sobelow-conf` - a threshold file introduced by the same shape of change
(st-21b, `docs/quality-gate-changes.md:193-208`) - is guarded. A doc-coverage
threshold file that no check watches would be lowerable without a ledger
entry, which is exactly what ADR-0011 exists to prevent.

### Key Discoveries:

- `deps/ex_quality/lib/ex_quality/stages/doctor.ex:9` - the stage enables on
  the dep alone; `.quality.exs` need not change.
- `deps/doctor/lib/config.ex:37-52` - defaults are
  `min_module_doc_coverage: 40`, `min_overall_doc_coverage: 50`,
  `min_overall_spec_coverage: 0`. The plan's config raises all of these.
- `lib/mix/statifier/gate_guard.ex:43` - `:doctor` absent from the mix.exs
  pattern; `gate_guard.ex:36` - `.doctor.exs` absent from `@guarded_paths`.
- `test/mix/statifier/gate_guard_test.exs:37-42` - the guarded-path list is
  deliberately spelled out in the test rather than read from
  `guarded_paths/0`, with a sabotage note. Extending the list means editing
  that assertion.
- `docs/adr/0011-quality-gate-config-not-agent-editable.md` - the policy; the
  ledger entry is a human's call. `.claude/wurk/commit.md:46-52` restates it:
  "writing that entry yourself is granting yourself the permission the check
  exists to withhold."
- `docs/adr/0017-judgment-not-scriptable-in-wurk-extensions.md` point 6 scopes
  `.claude/wurk.json` - a change to the skip lists needs its prose reason in
  `CLAUDE.md` on the same branch. `CLAUDE.md` says so explicitly and says
  `mix quality --profile merge` refuses the branch otherwise.
- `changelog.d/README.md:36` - "quality gate, CI, or agent tooling changes"
  are on the do-not-write-a-fragment list.
- A full `mix quality` with the dep installed was run during research: every
  stage stayed green except Doctor, and the `○ Doctor` line was gone. Doctor
  costs about 1.7s and briefly contends for the build lock with the other
  parallel analysis stages; that is cosmetic log noise, not a failure.

## Desired End State

A bare `mix quality` prints `✓ Doctor: 100.0% documented` (or the equivalent
passing summary) instead of `○ Doctor: skipped (:doctor not installed)`, with
every threshold in `.doctor.exs` at 100% and no module ignored.
`gate.project_level_skips` in `.claude/wurk.json` is an empty list, and
`CLAUDE.md`'s gate section says why it is empty rather than still naming
Doctor as an undecided gap. `mix gate.check` treats `.doctor.exs` and a
`:doctor` line in `mix.exs` as guarded, and `docs/quality-gate-changes.md`
carries a human-approved entry naming both.

Verified by: `mix quality` green end to end with a `✓ Doctor` line, and
`mix gate.verify` confirming the run was a full unscoped gate.

## What We're NOT Doing

- **Not touching `.quality.exs`.** The stage auto-enables on the dep, and
  `summary_only` would only hide the report that makes a failure readable.
  Leaving it alone also keeps one guarded file out of the diff.
- **Not lowering any threshold, ever, to fit the codebase.** If a branch that
  lands before this one adds an undocumented public function, the answer is to
  document it in Phase 3, not to relax `.doctor.exs`. No `ignore_modules` or
  `ignore_paths` entries are configured; the codebase meets 100% without them.
- **Not excluding `lib/mix/` from doctor.** Doctor already reports every Mix
  support module at 100%/100% except one function, so a path exclusion would
  buy nothing and would carve a hole in a check for no reason. This is a
  deliberate departure from the "consider ignore_paths for lib/mix" framing:
  the measurement says the exclusion is unnecessary.
- **Not writing the `docs/quality-gate-changes.md` entry.** ADR-0011 and
  `.claude/wurk/commit.md` both put that with a human. Phase 4 stops there.
- **Not planning any workaround for the resulting red gate** - no `--skip`, no
  disabling the Gate guard stage, no `enabled: false`, no narrowing of the
  guard's own pattern to dodge itself.
- **No changelog fragment.** `changelog.d/README.md` excludes quality-gate and
  agent-tooling changes, and nobody calling the public API can tell the
  difference.
- **No ADR.** ADR-0009 already settled ex_quality as the gate and ADR-0011
  already settled how its config changes; adding a stage that those two
  records already anticipate is a ledger entry, not a new decision. Every
  prior stage addition (adr_guard, regression, adr_judge, sobelow) landed the
  same way.

## Implementation Approach

The ordering is driven by one fact: the Gate guard reads the **whole branch
diff against `origin/main`**, not a single commit. So the moment any commit on
this branch introduces a guarded change, every later `mix quality` on the
branch is red until the ledger entry exists. Everything that can land cleanly
must therefore land first.

**The execution order is Phase 1, Phase 2, Phase 4, Phase 3.** The phases are
numbered by topic, and the order they run in is deliberately not the order
they are numbered in. This paragraph is the authoritative statement of the
order; the reasoning for Phase 3 moving to the end is in Phase 3's own
"Sequencing correction" note - in short, removing the skip pattern while the
stage still skips reclassifies `○ Doctor` as run-level, which is a hard red.

1. **Phase 1** extends the Gate guard to cover doctor's config surface. It
   edits `lib/` and `test/` and `.claude/wurk.json` - none of them guarded,
   and the branch contains no `.doctor.exs` or `:doctor` mix.exs line yet, so
   the guard stays green and the phase commits cleanly.
2. **Phase 2** backfills the fifteen `@doc` strings. `lib/` only. Green,
   commits cleanly.
3. **Phase 4** adds the dep and `.doctor.exs`. This is the only phase that
   touches a guarded path, and by Phase 1's own doing it is now correctly
   caught. Its gate is red on the Gate guard stage - and *only* that stage -
   until a human writes the ledger entry. The phase ends in a handoff.
4. **Phase 3** retires the skip classification in `.claude/wurk.json` and
   rewrites the `CLAUDE.md` prose. Neither is guarded, and by this point
   Doctor genuinely runs, so removing its pattern describes reality rather
   than anticipating it. This is the final commit on the branch.

Phases 1 and 2 are each independently committable and independently
gate-verifiable, and so is Phase 3 in its executed position. Phase 4 is
verifiable in every stage but one, and the remaining stage is a human gate by
design rather than a defect in the phasing.

---

## Phase 1: Guard doctor's config surface

### Overview

Make `mix gate.check` treat `.doctor.exs` and a `:doctor` dependency line in
`mix.exs` as gate config, so that Phase 4's change is caught by the project's
own mechanism rather than slipping past it. Nothing in this phase installs
doctor; it only teaches the guard what to watch for.

### Changes Required:

#### 1. The guard's path list and mix.exs pattern

**File**: `lib/mix/statifier/gate_guard.ex`
**Changes**: add `.doctor.exs` to `@guarded_paths` (line 36) and `:doctor` to
`@mix_exs_pattern` (line 43).

```elixir
@guarded_paths [".quality.exs", ".credo.exs", "coveralls.json", ".sobelow-conf", ".doctor.exs"]

@mix_exs_pattern ~r/test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir|:sobelow|:doctor/
```

Note that `@guarded_paths` also feeds `interesting?/1` (`gate_guard.ex:141`),
which is what makes a brand-new untracked `.doctor.exs` visible to the diff at
all. Without this edit the file is invisible until it is committed.

#### 2. Tests

**File**: `test/mix/statifier/gate_guard_test.exs`
**Changes**: extend the spelled-out list at line 41 and add two cases - a diff
adding `.doctor.exs` produces a `gate-config` finding, and a `mix.exs` diff
adding a `{:doctor, ...}` line produces one. Follow the existing table-driven
style in that file.

Each new test gets a sabotage line per `docs/testing.md`, for example:

```elixir
# sabotage: drop ".doctor.exs" from @guarded_paths -> red
# sabotage: drop `:doctor` from @mix_exs_pattern -> red
```

Break the code, confirm red, revert, keep the note.

#### 3. Manifest mirror

**File**: `.claude/wurk.json`
**Changes**: add `".doctor.exs"` to `gate.moving_files` (line 36), so the wurk
kit's view of gate-moving files matches `guarded_paths/0`.

**File**: `CLAUDE.md`
**Changes**: one sentence in the ExQuality section noting that `.doctor.exs`
joined the guarded set and why (it holds doc-coverage thresholds, the same
shape as `.sobelow-conf`). ADR-0017 point 6 wants the reason for a
`.claude/wurk.json` gate key change recorded in prose on the same branch, and
this keeps the manifest edit from arriving bare.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green, including the Gate guard stage - this phase
      introduces no guarded change of its own, so the guard must stay green.
- [x] `mix gate.verify` confirms the run was a full, unscoped, unskipped gate.
- [x] `mix quality --profile loop` used between edits (not as the phase gate).
- [x] `mix test test/mix/statifier/gate_guard_test.exs` passes, and the two new
      cases exist.

#### Manual Verification:
- [ ] Each new test was actually sabotaged - the covered code was broken, the
      test went red, and the change was reverted - and the sabotage note names
      the real mutation.
- [ ] The `CLAUDE.md` sentence reads as policy, not as a changelog line.
- [ ] No regressions in the other gate stages' behavior.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving on. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement
automatically, and Manual Verification items are deferred and surfaced once at
the end.

---

## Phase 2: Backfill the fifteen missing `@doc` strings

### Overview

Bring every public function in `lib/` up to a `@doc`, so that a 100%
doc-coverage threshold is met without any threshold being bent. This is the
only phase that touches the library proper, and it touches nothing but
documentation attributes.

### Changes Required:

#### 1. The eleven validator checks

**File**: `lib/statifier/validator/checks/{boilerplate,content,default_entry,donedata,enums,final,history,ids,initial_element,initial_targets,targets}.ex`
**Changes**: add a `@doc` immediately above each module's existing
`@spec check(...)`. Model it on
`lib/statifier/validator/checks/default_transition.ex:38`, which already has
one. Each module's `@moduledoc` already explains the rule being checked, so
the `@doc` should say what `check/2` returns for this specific check rather
than restating the moduledoc:

```elixir
@doc """
Returns an error for every `<state>` whose `initial` attribute names a state
that is not one of its own children.
"""
@spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
```

#### 2. The four remaining entry points

**File**: `lib/statifier/compiler.ex` (`compile/1`, line 105),
`lib/statifier/lowering.ex` (`lower/1`, line 70),
`lib/statifier/validator.ex` (`validate/2`, line 62),
`lib/mix/statifier/adr_judge.ex` (`scoped_chunks/2`, line 437)
**Changes**: add a `@doc` above each existing `@spec`, describing the return
contract. These four are the public seams of their modules, so their docs
matter more than the eleven above; write real prose, not a restatement of the
spec.

#### 3. Constraint: prose only, no `iex>` examples

**Changes**: none of the fifteen `@doc` strings may contain an `iex>` prompt.
An `iex>` block becomes a doctest, which needs a `doctest` call wired into the
matching test module to run - and an unwired one is documentation that is
never verified, exactly the shape this project's sabotage rule exists to
prevent. If a worked example genuinely helps, it belongs in the module's
`@moduledoc` alongside existing examples, or in a real test.

House style note: these modules use `-` and ordinary punctuation, not em
dashes. Match the file you are editing.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green - notably Credo strict, `warnings_as_errors`
      compile, and Dialyzer, which is what proves an added attribute did not
      change how a function is compiled.
- [x] `mix gate.verify` confirms the run was a full, unscoped gate.
- [x] `mix quality --profile loop` used between edits.
- [x] This command exits 0 and prints nothing (it is the stand-in for doctor,
      which is not installed until Phase 4):

```bash
ruby -e '
sites = {
  "lib/mix/statifier/adr_judge.ex" => "scoped_chunks",
  "lib/statifier/compiler.ex" => "compile",
  "lib/statifier/lowering.ex" => "lower",
  "lib/statifier/validator.ex" => "validate"
}
%w[boilerplate content default_entry donedata enums final history ids
   initial_element initial_targets targets].each do |c|
  sites["lib/statifier/validator/checks/#{c}.ex"] = "check"
end
missing = sites.reject do |path, fun|
  lines = File.readlines(path)
  i = lines.index { |l| l =~ /^\s*def #{fun}\(/ }
  next false unless i
  # Scan back over the attribute block (@spec, @impl, comments) until either an
  # @doc or the previous definition boundary is reached. A fixed-size window
  # would miss an @doc pushed out of range by a multi-line @spec.
  j = i - 1
  j -= 1 while j >= 0 && lines[j] !~ /^\s*(def|defp|@moduledoc|@typedoc)\b/ &&
                         lines[j] !~ /^\s*@doc\b/
  j >= 0 && lines[j] =~ /^\s*@doc\b/
end
missing.each { |path, fun| puts "MISSING @doc: #{path} #{fun}" }
exit(missing.empty? ? 0 : 1)'
```

This script was run against the current tree during planning: it reports
exactly the fifteen sites in the table above, and reports nothing for
`default_transition.ex`'s already-documented `check/2` (the positive control).

- [x] `grep -rn "iex>" lib/statifier/validator/checks/ lib/statifier/compiler.ex lib/statifier/lowering.ex lib/statifier/validator.ex` returns no *new* matches relative to `origin/main`.

#### Manual Verification:
- [ ] Each `@doc` says something the `@spec` does not - a return contract, an
      ordering guarantee, an error case - rather than paraphrasing the types.
- [ ] The four entry-point docs (`compile/1`, `lower/1`, `validate/2`,
      `scoped_chunks/2`) would help a reader who has not read the module body.
- [ ] No `@doc` contradicts the module's `@moduledoc` or an ADR it cites.
- [ ] `lib/statifier/` was touched, so per this project's plan extension: the
      touched functions are unchanged in behavior, so the W3C Appendix D
      correspondence is trivially preserved - confirm by eye that the diff
      contains no executable line, only attributes.

**Implementation Note**: Same as Phase 1. No test file changes are expected in
this phase, so the sabotage rule has nothing to bite on; if a test does get
added, it needs its sabotage note.

---

## Phase 3: Retire the project-level skip classification

### Overview

Remove `^:doctor not installed$` from `gate.project_level_skips` and rewrite
the `CLAUDE.md` prose that currently names Doctor as an undecided gap owned by
st-1xz. **This phase executes last**, after Phase 4 - see the sequencing note
immediately below, which the Implementation Approach section also states.

### Sequencing correction

The obvious ordering - retire the classification before installing the dep, so
the manifest never lags reality - does not work. Removing the pattern while
the stage still skips leaves `○ Doctor: skipped (:doctor not installed)`
matching neither manifest list, which the wurk kit classifies as run-level:
a hard red. So Phase 3 and Phase 4 cannot both be green in that order. Two
options were considered and one is chosen:

- Merge Phase 3 into Phase 4 as one commit. Keeps every phase green, but puts
  a `.claude/wurk.json` edit and a `CLAUDE.md` edit into the commit that is
  already blocked on a human ledger entry.
- **Chosen**: run Phase 3 *after* Phase 4's config change is in the tree.

So the executed order is Phase 1, Phase 2, Phase 4, Phase 3. The phases are
numbered by topic and the plan states the order explicitly rather than
renumbering, because Phase 4 is the phase with the human handoff and readers
look for it last. An implementer following `--loop` should treat this section
as authoritative over the numbering: **Phase 3 is the final commit.**

### Changes Required:

#### 1. Manifest

**File**: `.claude/wurk.json`
**Changes**: `gate.project_level_skips` becomes `[]`.

```json
"project_level_skips": [],
```

#### 2. The prose that owns the classification

**File**: `CLAUDE.md`, the "Which skipped stages are gaps and which will never
apply" section, "Project-level gap" bullet
**Changes**: the bullet currently reads that Doctor is the member and "whether
to adopt it is an open decision owned by st-1xz". Replace the membership
sentence with a statement that the list is now empty, that Doctor was its only
member and st-1xz adopted it rather than declaring it inapplicable, and that
the category and its manifest key stay because the next stage this project
declines to run belongs here rather than in the not-applicable list. Keep the
existing closing rule ("Do not move a pattern here into the not-applicable
list to quiet a report") - it is what the category is for.

Do **not** move the pattern to `gate.not_applicable_skips`. Doctor now runs;
there is nothing to classify.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` is green, and its output contains no `○` line for
      Doctor at all - the stage reports `✓`.
- [ ] `mix gate.verify` confirms a full, unscoped gate.
- [ ] `ruby ~/.claude/skills/wurk:kit/scripts/gate.rb` (via the manifest lint
      in `/wurk:kit`) accepts the manifest with an empty
      `project_level_skips` list.
- [ ] `mix quality --profile merge` is green, including the ADR judge, which
      is what checks the ADR-0017 point 6 obligation that a `.claude/wurk.json`
      gate-key change arrive with its prose.

#### Manual Verification:
- [ ] The rewritten `CLAUDE.md` bullet still explains what the *category* is
      for, not only that it is currently empty - a reader arriving at the next
      skipped stage must be able to classify it from this text.
- [ ] Nothing in `CLAUDE.md` still says the doctor decision is open or owned
      by st-1xz.
- [ ] The not-applicable bullet is unchanged.

**Implementation Note**: Same as Phase 1. This is the last commit on the
branch.

---

## Phase 4: Install doctor and configure the thresholds

### Overview

Add the dependency and the threshold file. This is the guarded change, and the
one that ends in a human handoff.

### Changes Required:

#### 1. Dependency

**File**: `mix.exs`
**Changes**: add to `deps/0`, alongside the other dev-only tooling.

```elixir
{:doctor, "~> 0.23", only: :dev, runtime: false}
```

`~> 0.23` rather than `~> 0.22`: 0.22 resolves to 0.23.0 today anyway, and
pinning the minor the config struct was read from keeps `.doctor.exs`'s keys
and the package in step. `mix deps.get` also pulls `:decimal` transitively;
`mix.lock` changes accordingly. `only: :dev` matches the stage, which sets
`MIX_ENV=dev` when it shells out.

#### 2. Threshold configuration

**File**: `.doctor.exs` (new)
**Changes**: create with 100% on every axis. Every value here is at or above
doctor's own default (`deps/doctor/lib/config.ex:39-52`), and three of them
are far above it: module doc 40 -> 100, overall doc 50 -> 100, overall spec
0 -> 100. Nothing is weakened.

```elixir
%Doctor.Config{
  ignore_modules: [],
  ignore_paths: [],
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 100,
  min_overall_doc_coverage: 100,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 100,
  exception_moduledoc_required: true,
  raise: false,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false,
  failed: false
}
```

`raise: false` in the file is correct: the ExQuality stage passes `--raise` on
the command line itself (`deps/ex_quality/.../doctor.ex:56`), and it is the
stage's exit code that decides the gate. `ignore_modules` and `ignore_paths`
stay empty - the measured codebase needs neither.

Add a short header comment stating what the file is and that ADR-0011 covers
it, in the style of `.sobelow-conf`.

#### 3. Expected gate result

After Phases 1, 2 and this one, `mix quality` should print `✓ Doctor` and
`✗ Gate guard`. Every other stage stays green. This is measured, not
predicted: the research run had exactly this shape with the docs still
missing (Doctor red, everything else green), and Phase 2 removes the Doctor
failure.

### The human handoff

The Gate guard failure is **expected and correct**. Phase 1 deliberately made
`.doctor.exs` and the `:doctor` mix.exs line guarded, so `mix gate.check` now
reports two `gate-config` findings with no clearing entry.

Closing it requires an entry in `docs/quality-gate-changes.md` with a
`## <date> - st-1xz` heading, an `Approved-by:` line naming the human, and one
bullet per guarded path:

- `mix.exs`: adds `:doctor` as a dev-only dep, so the Doctor stage runs
  instead of reporting itself skipped
- `.doctor.exs`: adds the file, setting every coverage threshold to 100%

**An agent must not write this entry.** ADR-0011 and
`.claude/wurk/commit.md:46-52` put it with a human: writing it is granting
oneself the permission the check exists to withhold. The correct agent
behavior at this point is to report the two findings, state that the ledger
entry is outstanding, and stop. There is no workaround to attempt - not
`--skip`, not `enabled: false`, not narrowing the guard's pattern back, not
deleting `.doctor.exs` in favor of inline `.quality.exs` config that would
merely relocate the same guarded edit.

The `Approved-by:` line and the guarded path must appear in the **same diff**
as the change (`gate_guard.ex:261-265`), so the ledger entry rides in this
phase's commit once the human has written it - not a follow-up commit.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` shows `✓ Doctor` with a 100% summary, and the
      `○ Doctor: skipped (:doctor not installed)` line is gone.
- [ ] `mix doctor` alone exits 0.
- [ ] Every stage other than Gate guard is green.
- [ ] `mix gate.check` reports exactly two findings, on `mix.exs` and
      `.doctor.exs`, and no others - proving Phase 1's guard extension fires
      on precisely the intended surface.
- [ ] After the human writes the ledger entry: full `mix quality` green, and
      `mix gate.verify` confirms a full unscoped run.

#### Manual Verification:
- [ ] **A human writes the `docs/quality-gate-changes.md` entry.** This is a
      blocking handoff, not an agent step. Until it exists the phase cannot
      commit, and that refusal is the design working.
- [ ] The human confirms the thresholds are the right bar for this project -
      that 100% doc coverage is discipline the project intends to keep, not a
      number chosen because it happened to be reachable.
- [ ] Doctor's build-lock contention with the parallel analysis stages is
      cosmetic in practice (a few `Waiting for lock on the build directory`
      lines), not a slowdown worth configuring around.

**If Phase 1 was declined**: the guard-related criteria above simply do not
apply. `mix gate.check` reports nothing, there is no ledger entry to wait on,
and this becomes an ordinary green phase that commits without a handoff. The
cost is that `.doctor.exs` is then a threshold file no check watches, which
is the trade named in "Decisions taken without a human present", item 2.

**Implementation Note**: Same loop/full-gate rule as the other phases. Under
`--loop`, this phase will not advance: `/wurk:commit --auto` sees a red gate
and stops. That is the intended behavior. The loop should surface the
outstanding ledger entry and halt rather than retry.

---

## Testing Strategy

### Unit Tests:

- `test/mix/statifier/gate_guard_test.exs` - two new cases (Phase 1): a diff
  adding `.doctor.exs` yields a `gate-config` finding; a `mix.exs` diff adding
  a `{:doctor, ...}` line yields one. The existing spelled-out
  `guarded_paths/0` assertion at line 41 gains `.doctor.exs`. Both new cases
  carry sabotage notes naming a real mutation of `@guarded_paths` /
  `@mix_exs_pattern`.
- No new tests for Phase 2. Doc attributes are not behavior, and the
  verification that matters is doctor itself, which arrives in Phase 4. The
  interim ruby check in Phase 2 is a gate criterion, not a committed test - do
  not add it to `test/`, where it would duplicate what doctor checks better.
- No new tests for Phases 3 and 4. The classification logic lives in the
  out-of-repo wurk kit and has its own suite there
  (`~/.claude/skills/wurk:kit/scripts/test/gate_test.rb`); this repo's change
  is manifest data.

### Manual Testing Steps:

1. On a clean tree after Phase 4, run `mix quality` with no flags and read the
   whole output. Confirm the `○` lines are now only Gettext and ADR judge -
   the two not-applicable ones - and that Doctor shows `✓`.
2. Temporarily delete a `@doc` from one of the fifteen backfilled functions
   and re-run `mix quality`. Confirm Doctor goes red and names that module.
   Restore it. This is the end-to-end proof the stage is load-bearing.
3. Run `mix gate.check` before the ledger entry is written and confirm it names
   both `mix.exs` and `.doctor.exs`.
4. Run `mix quality --profile merge` on the finished branch and confirm the ADR
   judge is green on the `.claude/wurk.json` and `CLAUDE.md` edits.

## Decisions taken without a human present

This plan was produced unattended. Nothing below is left open - each was
decided, with the reasoning recorded so a human can overturn it cheaply.

1. **100% on every axis, rather than a number with headroom.** Decided:
   100%. The measurement shows the codebase reaches it with fifteen `@doc`
   strings, and any lower number would be a threshold chosen to fit the
   codebase, which the bead's acceptance criteria forbid. A human who wants
   headroom for future contributors should say so at the Phase 4 review; the
   plan does not build it in, because headroom in a threshold is
   indistinguishable from a weakened threshold once nobody remembers why it is
   there.
2. **Extending the Gate guard is in scope.** Decided: yes, and first. The bead
   does not ask for it, and strictly speaking this change could land today
   with no ledger entry at all. But shipping a threshold file that ADR-0011
   plainly intends to cover, while leaving it unguarded, would be closing one
   gap by opening a quieter one. A human who disagrees can drop Phase 1, at
   which point Phase 4 needs no ledger entry and the branch has no human
   handoff - and `.doctor.exs` becomes lowerable by any future agent without
   anyone being asked.
3. **`~> 0.23`, not `~> 0.22`.** Decided on the version whose config struct the
   `.doctor.exs` keys were read from.
4. **No `ignore_paths` for `lib/mix/`.** Decided against, on measurement: those
   modules already pass at 100%, so an exclusion would protect nothing and
   would remove ten modules from the check.
5. **No changelog fragment, no ADR.** Decided per `changelog.d/README.md:36`
   and the precedent of every prior stage addition.
6. **Phase 3 executes last, not third.** Decided in the Phase 3 sequencing
   note, because removing the skip pattern while the stage still skips makes
   the skip run-level and the gate red.

## References

- Bead: `st-1xz`
- Related ADRs: `docs/adr/0009-ex-quality-as-quality-gate.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0017-judgment-not-scriptable-in-wurk-extensions.md`
- Ledger: `docs/quality-gate-changes.md` (the `st-21b` entry at line 193 is the
  closest precedent - a dev-only gate dep plus a new threshold file)
- Stage source: `deps/ex_quality/lib/ex_quality/stages/doctor.ex:18`
- Doctor config defaults: `deps/doctor/lib/config.ex:37-52`
- Guard source: `lib/mix/statifier/gate_guard.ex:36`, `:43`, `:141`, `:261`
- Guard tests: `test/mix/statifier/gate_guard_test.exs:37`
- Prior plan that classified this skip: `docs/plans/260812-st-rtm-wurk-config-catchup.md`
- Commit extension: `.claude/wurk/commit.md:46`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Each new test was actually sabotaged - the covered code was broken, the
      test went red, and the change was reverted - and the sabotage note names
      the real mutation.
- [ ] The `CLAUDE.md` sentence reads as policy, not as a changelog line.
- [ ] No regressions in the other gate stages' behavior.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full gate as the phase gate. In interactive execution, pause here for the
human to confirm the manual testing before moving on. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement
automatically, and Manual Verification items are deferred and surfaced once at
the end.

---

### Phase 2

- [ ] Each `@doc` says something the `@spec` does not - a return contract, an
      ordering guarantee, an error case - rather than paraphrasing the types.
- [ ] The four entry-point docs (`compile/1`, `lower/1`, `validate/2`,
      `scoped_chunks/2`) would help a reader who has not read the module body.
- [ ] No `@doc` contradicts the module's `@moduledoc` or an ADR it cites.
- [ ] `lib/statifier/` was touched, so per this project's plan extension: the
      touched functions are unchanged in behavior, so the W3C Appendix D
      correspondence is trivially preserved - confirm by eye that the diff
      contains no executable line, only attributes.

**Implementation Note**: Same as Phase 1. No test file changes are expected in
this phase, so the sabotage rule has nothing to bite on; if a test does get
added, it needs its sabotage note.

---
