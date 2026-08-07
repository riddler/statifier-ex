# Candidate tables carry a description summary Implementation Plan

## Overview

`/next-issue` and `/next-issues` present a candidate table that says what each
bead *constrains* (id, priority, type, areas, verdict) but not what it is
*about*. This plan adds a deterministic per-candidate `summary` to
`select_batch.rb`'s envelope, records the decision to compute it in the script
rather than route it to a Haiku subagent, and makes title + summary mandatory
columns in both skills' presentation prose (including the AskUserQuestion
option text). Beads issue: st-sdv.

## Current State Analysis

- `select_batch.rb`'s `annotate/2`
  (`.claude/scripts/select_batch.rb:220-252`) builds a candidate hash from the
  `bd` issue and `public_candidate/1` (`:254-264`) projects the seven fields
  that reach the envelope: `id`, `title`, `priority`, `issue_type`, `areas`,
  `verdict`, `reason`. `description` is dropped on the floor.
- The description is already in hand at that point, in both input modes:
  - default mode goes through `bead_ready/2` (`:180-193`) -> `bead.rb ready`
    -> `bd ready --json`, whose issue objects carry `description` (verified by
    running `bd ready --json` in this worktree);
  - explicit-selection mode goes through `explicit_candidates/2` (`:162-178`)
    -> `bead.rb show` -> `bd show <id> --json`, which also carries
    `description` (verified via `ruby .claude/scripts/bead.rb show st-sdv`).
  No new shell call is needed - this is a projection change, not a data
  acquisition change.
- `.claude/skills/next-issues/SKILL.md:138-139` lists the candidate row's
  fields and says "show it in full"; step 2 (`:186-190`) names only
  "id, title, priority, verdict" and leaves the rest to the model. The
  AskUserQuestion options at `:192-199` are described purely in terms of ids,
  areas and collisions ("take st-qww.7 despite area:skills collision with
  worktree st-abc-slug") - nothing names the subject matter.
- `.claude/skills/next-issue/SKILL.md:78-92` has the same shape: "present the
  top few rows of `data.candidates` (id, title, type, priority, verdict)".
- The reported symptom (2026-08-07, two consecutive `/next-issues` runs) is
  the predictable result: the table renders as a constraint summary and is
  useless as a menu. Two ready beads, `st-trm` and `st-tgv`, currently share
  an identical title, so title alone cannot even distinguish rows from one
  another.
- ADR-0015 fixes where each half of this belongs: the truncation is
  deterministic mechanics (script), the presentation requirement is prose
  (SKILL.md). Constraint 2 - one definition site for shared mechanics - means
  the truncation lives in `.claude/scripts/lib/`, not inline in
  `select_batch.rb`, because two skills consume it.
- `docs/skill-automation.md`'s "Model routing" section is the precedent for
  recording a Haiku routing decision: the "What is explicitly not routed to
  Haiku, and why" list is exactly the register this bead's second acceptance
  criterion asks for, and it cites ADR-0015 rather than re-arguing it.
- The Ruby suite is `.claude/scripts/test/run.rb`, registered as the
  `Script tests` stage in `.quality.exs`, and `.claude/scripts/` is inside
  `TouchesElixir.gate_applicable?` - so a bare `mix quality` does measure this
  branch.

## Desired End State

`ruby .claude/scripts/select_batch.rb --n 3` emits, for every row in
`data.candidates`, a `summary` string (or `null` when the bead has no
description) alongside the existing `title`. Both SKILL.md files require
title and summary as columns of the presented table in mandatory language, and
require each AskUserQuestion option's text to name what its beads are about.
`docs/skill-automation.md` records, with reasoning, that this truncation is
script-side and not a Haiku delegation point. A live run of `/next-issues`
in this repo produces a table from which a reader who has never seen these
beads can tell what each one is.

Verified by: the Ruby suite (`ruby .claude/scripts/test/run.rb`), a full
`mix quality`, and the Phase 4 live run whose output is pasted into the bead
as a note.

### Key Discoveries:

- `select_batch.rb:254-264` (`public_candidate/1`) is the single choke point
  for the envelope's candidate shape - one method to change.
- `select_batch.rb:220-252` (`annotate/2`) is where the raw `bd` issue is
  still available; the summary must be computed there, because
  `public_candidate/1` only sees the annotated hash.
- `.claude/scripts/lib/areas.rb` is the model for a small, pure, well-commented
  helper module with a single named caller - the same shape the new
  `lib/summary.rb` should take.
- `gate.rb`'s sabotage scan is Elixir-only (`TEST_LINE_RE = /\btest\s+"/`,
  `gate.rb:78-79`), so Ruby tests are not mechanically checked for notes.
  `test/gate_test.rb` nevertheless carries them (e.g. `gate_test.rb:113`,
  `:150`, `:184`) while `test/select_batch_test.rb` carries none. Follow the
  `gate_test.rb` precedent: new tests in this branch get sabotage notes.
- `bd` descriptions in this repo are prose whose first sentence is written as
  a topic sentence (`st-bl0`, `st-trm`, `st-sdv` itself all read correctly
  when cut at the first sentence) - which is what makes the deterministic
  option viable rather than merely cheap.
- No changelog fragment: `changelog.d/README.md` explicitly excludes "quality
  gate, CI, or agent tooling changes".

## What We're NOT Doing

- **Not adding a Haiku summarization path**, and not adding a
  `.claude/agents/` definition for one. See the decision in Phase 1.
- **Not touching the greedy walk, the verdict table, or `data.recommended`.**
  Selection semantics are unchanged; this is a presentation payload.
- **Not renaming the duplicate-titled beads** (`st-trm`, `st-tgv`). The fix for
  "two rows look identical" is the summary column, not editing bead titles;
  if a reader still cannot separate them after Phase 4, that is a bead-content
  problem to file separately.
- **Not adding `summary` to other scripts' envelopes** (`work_state.rb`,
  `bead.rb show`). `bead.rb show` already returns the full description; only
  the candidate *table* has the space problem.
- **Not rewriting either SKILL.md beyond the presentation steps.** Steps 0-1
  and 3-7 stay as they are.
- **Not a new ADR.** ADR-0015 already decides the script-vs-prose split; this
  is an application of it, recorded where its living register lives
  (`docs/skill-automation.md`), exactly as the st-hzf precedent does.

## Implementation Approach

Four phases, decision first: record *where* the truncation happens before
writing the code that implements it, so the code cites a decision that already
exists rather than the decision being reverse-engineered from the diff.

1. Record the routing decision in `docs/skill-automation.md`.
2. Implement `lib/summary.rb` + wire it into `select_batch.rb`, with tests.
3. Make title + summary mandatory columns in both SKILL.md files, including
   AskUserQuestion option text.
4. Verify against a live run and record the evidence on the bead.

Phases 1 and 3 touch documentation and skill prose only (no gate to run
beyond a formatting sanity check); Phase 2 is the only one with automated
verification of substance. They are kept separate because each is
independently reviewable and independently committable, and because a reviewer
reading the commit for Phase 2 should be able to follow its `# see
docs/skill-automation.md` comment to a decision that landed first.

### The decision: deterministic truncation in the script

**Decision: the summary is computed deterministically in
`.claude/scripts/lib/summary.rb`. It is not routed to a Haiku subagent, and
"summarize a bead description for the candidate table" is recorded in
`docs/skill-automation.md`'s "What is explicitly not routed to Haiku, and why"
list.**

Reasoning, in the shape ADR-0015 and the st-hzf routing record already use:

- **Determinism is the point of the artifact.** The candidate table is a
  decision input presented before anything is claimed. A model-written summary
  makes the same bead read differently on two runs an hour apart, which is
  precisely the failure mode ADR-0015's second reason for extraction names
  ("non-deterministic where determinism is the whole point"). A user comparing
  today's table to yesterday's should be comparing beads, not prose.
- **The cost scales with the candidate list, not the batch.** Every
  `/next-issue` and `/next-issues` invocation summarizes *every* ready
  candidate, not just the recommended ones - a dozen-plus model calls per
  pickup, on a step that runs several times a day, to compress text a human
  already wrote.
- **It is on the interactive path.** The picker blocks on this table. N
  sequential (or fanned-out) model calls before anything appears on screen
  makes the fast, cheap step in the workflow the slow one.
- **The input is already a summary.** `bd` descriptions here open with a topic
  sentence; the deterministic first-sentence cut reproduces what a summarizer
  would mostly have written. Where a description opens badly, the fix belongs
  in the bead - a model paraphrase would launder a badly written description
  into a plausible-looking row and hide that.
- **The escape hatch stays open and costs nothing.** The envelope field is a
  string either way. If Phase 4's live run shows the deterministic cut is
  genuinely unreadable for a class of beads, layering a Haiku pass over the
  same field later is an additive change requiring no envelope or skill
  change - which is the reason to start with the cheap option rather than an
  argument against ever revisiting it.

The counter-argument, recorded rather than dismissed: a first-sentence cut can
be an unhelpfully generic opener ("This is a follow-up to st-abc.") where a
model would have read further. That is real, and it is why the summary is
positioned as an *aid alongside* the title rather than a replacement for
`bd show`, and why Phase 4's acceptance is judged against a real table rather
than against unit tests alone.

### Open questions, and the default chosen for each

No human was available while this plan was written, so each of these is
recorded with a default that makes the plan executable. Any of them can be
revised during implementation without restructuring the plan.

1. **What character cap?** Default: **140 characters**, cutting at a word
   boundary and appending `...`. Rationale: wide enough for a real sentence,
   narrow enough that a four-column markdown table still wraps sanely in a
   terminal, and the same order of magnitude as the AskUserQuestion option
   text budget. `MAX_CHARS` is a named constant so revising it is a one-line
   change.
2. **What should a bead with no description render as?** Default: the envelope
   carries `"summary": null` (the key is always present, so the column is
   never missing), and the skills render `-`. A bead with no description is
   itself information the picker should see.
3. **Should the summary be the first sentence or the whole first paragraph
   truncated?** Default: **first sentence, then truncate to the cap.** The
   bead names both as acceptable; the first sentence degrades more gracefully
   because paragraph-truncation usually cuts mid-clause.
4. **Should `st-trm`/`st-tgv`'s identical titles be fixed too?** Default: no -
   out of scope (see "What We're NOT Doing"). They serve instead as the
   natural test case for Phase 4.

## Phase 1: Record the routing decision

### Overview

Write the deterministic-vs-Haiku decision into the living routing record
before the code that implements it exists.

### Changes Required:

#### 1. The Haiku routing register

**File**: `docs/skill-automation.md`
**Changes**: Add an entry to the "What is explicitly not routed to Haiku, and
why" bullet list (currently `:228-249`), matching the existing entries' form -
one bold name, one sentence of reasoning, no re-argument of ADR-0015. Keep
the list's closing paragraph ("Each of these needs either the codebase in
reach or an authority a subagent does not hold") true by either extending it
to name the third disqualifying property this entry introduces (determinism on
an interactive path) or by placing the new bullet with a short note that it is
excluded for a different reason than the others. The entry names st-sdv as
the bead that decided it and states the escape hatch (a Haiku pass can be
layered over the same envelope field later without an envelope or skill
change).

Also check the "Skill-to-script map" row for `next-issue` / `next-issues`
(`:70-71`) - it stays accurate, since no new script is added, only a new
`lib/` module composed into `select_batch.rb`. If the map's "composed
internally" convention (`:61-66`) warrants naming `lib/summary.rb`, follow the
convention already stated there rather than inventing a new one.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` is green (this phase touches no Elixir and no script; the
      gate has nothing new to measure, which is itself the expected result)

#### Manual Verification:
- [ ] The new entry reads in the same register as the five beside it: what is
      not routed, and why, in one sentence each - no ADR-0015 re-argument
- [ ] The section's closing paragraph is still true of every bullet under it
- [ ] House style of the file is matched (this file uses plain hyphens; do not
      introduce em dashes)

**Implementation Note**: In interactive execution, pause here for manual
confirmation from the human that the manual verification was successful before
proceeding to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via `/commit --auto`);
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: `lib/summary.rb` and the envelope field

### Overview

Compute a deterministic one-line summary from a bead description and put it in
`data.candidates[].summary`.

### Changes Required:

#### 1. The summarizer

**File**: `.claude/scripts/lib/summary.rb` (new)
**Changes**: A pure, stdlib-only, Ruby 2.6-compatible module in the shape of
`lib/areas.rb`: a module doc comment stating what it is for, that it is
deterministic by decision (cite `docs/skill-automation.md` and ADR-0015), and
who calls it.

```ruby
# frozen_string_literal: true

# Summary turns a bead description into the one-line blurb the candidate
# table shows next to the title (st-sdv). Deterministic by decision, not by
# accident: see docs/skill-automation.md's "What is explicitly not routed to
# Haiku, and why" and ADR-0015. select_batch.rb is the only caller.
module Summary
  MAX_CHARS = 140

  # Sentence boundary: a terminator followed by whitespace and something
  # that can start a sentence. The uppercase-ish lookahead is what keeps
  # "bd 1.1.2" and ".beads/hooks/" from splitting.
  SENTENCE_END = /(?<=[.!?])\s+(?=[A-Z"'(\[])/.freeze

  # Boundaries that look like sentence ends but are not.
  ABBREVIATION = /\b(?:e\.g|i\.e|etc|vs|cf|approx|fig|no)\.\z/i.freeze

  class << self
    # nil for a blank/missing description - the key is always present in the
    # envelope so the table's column is never missing, and "this bead has no
    # description" is information the picker should see.
    def of(description, max: MAX_CHARS)
      # first paragraph -> collapse whitespace -> first sentence -> truncate
    end
  end
end
```

Behavior to implement, in order: take the text before the first blank line;
collapse all whitespace runs to single spaces and strip; take the first
sentence per `SENTENCE_END`, rejecting a boundary whose preceding text matches
`ABBREVIATION`; if the result exceeds `max`, cut at the last space at or
before `max - 3` and append `...` (plain ASCII); return `nil` for empty input.

#### 2. Wiring into the candidate row

**File**: `.claude/scripts/select_batch.rb`
**Changes**:
- `require_relative "lib/summary"` alongside the existing `lib/` requires
  (`:6-9`).
- In `annotate/2` (`:220-252`), add `summary: Summary.of(issue["description"])`
  to the returned hash.
- In `public_candidate/1` (`:254-264`), add `"summary" => c[:summary]` directly
  after `"title"`, so the envelope's field order matches the column order the
  skills are about to mandate.

#### 3. Tests

**File**: `.claude/scripts/test/summary_test.rb` (new)
**Changes**: Unit tests for `Summary.of`, each with a sabotage note per the
`gate_test.rb` precedent (`gate_test.rb:113` and friends) - the gate's own
scan is Elixir-only, so these notes are a discipline this branch keeps rather
than one the gate enforces:
- a multi-sentence description returns only the first sentence
- a description whose first sentence exceeds the cap is truncated at a word
  boundary and ends in `...`
- an embedded `e.g.` / `i.e.` does not end the summary early
- a version number or dotted path (`bd 1.1.2`, `.beads/hooks/`) does not split
- a multi-paragraph description never reaches into the second paragraph
- embedded newlines and runs of whitespace collapse to single spaces
- `nil` and `""` both return `nil`

**File**: `.claude/scripts/test/select_batch_test.rb`
**Changes**: The `issue/4` helper (`:63-65`) currently emits no `description`;
give it a `description:` keyword with a default so existing tests are
unaffected. Add tests asserting:
- every row of `data.candidates` carries a `summary` key derived from the
  description, in default (`bd ready`) mode
- the same holds in explicit-selection mode, where the description comes from
  `bd show` rather than `bd ready` (this is the path most likely to regress -
  it is a different code path in `candidates_for/2`)
- a candidate whose description is empty carries `"summary" => nil` rather
  than omitting the key
- two candidates with identical titles and different descriptions produce
  different summaries (the st-trm/st-tgv case that motivated the bead)

### Success Criteria:

#### Automated Verification:
- [ ] Ruby suite green: `ruby .claude/scripts/test/run.rb`
- [ ] Syntax check passes on 2.6:
      `find .claude/scripts -name '*.rb' -exec /usr/bin/ruby -c {} +`
- [ ] Full quality gate passes, including the `Script tests` stage:
      `mix quality`
- [ ] A real run emits the field:
      `ruby .claude/scripts/select_batch.rb --n 3` and every entry in
      `data.candidates` has both `title` and `summary`

#### Manual Verification:
- [ ] Each new test was actually sabotaged: the named mutation was applied,
      the test went red for the right reason, and the mutation was reverted
      (docs/testing.md) - the note is the record of that, not a substitute
- [ ] The summaries in the real run read as sentences, not as mid-clause cuts
- [ ] No 2.7+ syntax slipped in (`.claude/scripts/README.md`'s banned list)

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 3: Make title + summary mandatory columns

### Overview

Both skills must state the table's columns as a requirement, not leave them to
the model's discretion - and the AskUserQuestion options must name what the
beads are about.

### Changes Required:

#### 1. `/next-issues`

**File**: `.claude/skills/next-issues/SKILL.md`
**Changes**:
- Step 1's `data.candidates` bullet (`:138-139`): add `summary` to the listed
  fields and say in one clause what it is (the bead's first sentence,
  truncated - deterministic, from `lib/summary.rb`), with a pointer to
  `docs/skill-automation.md` for why it is not model-written.
- Step 2 (`:186-190`): replace "Show the full candidate table first - id,
  title, priority, verdict" with an explicit mandatory column list rendered as
  a table spec, in the imperative the rest of this file uses for policy:

  | Column | Source | Required |
  |---|---|---|
  | Bead | `id` | always |
  | Title | `title` | always |
  | What it is | `summary` (`-` when null) | always |
  | Pri / Type | `priority`, `issue_type` | always |
  | Areas | `areas` | always |
  | Verdict | `verdict` + `reason` | always |

  State plainly that **title and summary are not optional columns and are not
  dropped for width** - the constraint columns are what a reader can
  reconstruct from `bd ready`; the subject matter is what they cannot. If the
  table is too wide, wrap the summary, do not drop it.
- Step 2's AskUserQuestion bullets (`:192-199`): require each option's text to
  name what its beads are about, not just their ids and areas. Give the
  concrete form - one clause per bead, `<id>: <short summary>`, trimmed to fit
  the option's text budget - and update the existing override example so it
  carries both the risk it accepts *and* the subject
  ("take st-qww.7 (branch-naming decision) despite area:skills collision with
  worktree st-abc-slug").
- The Guidelines section (`:289-321`): add a one-line bullet stating that the
  candidate table is a menu of work, not a constraint report, so a run that
  presents constraints without subjects has failed the same way a run that
  claims before presenting has.

#### 2. `/next-issue`

**File**: `.claude/skills/next-issue/SKILL.md`
**Changes**: Step 1 (`:78-92`) currently says "Read `data.candidates` for the
full ranked list (id, title, priority, issue_type, verdict, reason)" and
"present the top few rows ... (id, title, type, priority, verdict)". Add
`summary` to both, and state the same mandatory-column rule in the same
words - this skill and `/next-issues` must not drift on what a candidate table
is. Where `/next-issues` carries the full column table, this file may point at
it rather than duplicating it, but the "title and summary are mandatory"
sentence itself is stated here too, since this is the skill a reader lands in
for the single-bead case.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` is green (no Elixir and no script change in this phase)
- [ ] Both files' frontmatter is intact and the skills still load:
      `ruby -e 'ARGV.each { |f| abort f unless File.read(f).start_with?("---\n") }' .claude/skills/next-issue/SKILL.md .claude/skills/next-issues/SKILL.md`

#### Manual Verification:
- [ ] The column requirement is stated as a requirement in both files - a
      model reading either one cannot conclude the summary column is optional
- [ ] The two files agree; neither has invented a different column set
- [ ] The AskUserQuestion guidance produces option text a reader can act on
      without expanding anything
- [ ] House style matched: both SKILL.md files use plain hyphens today

**Implementation Note**: In interactive execution, pause here for manual
confirmation from the human that the manual verification was successful before
proceeding to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via `/commit --auto`);
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 4: Live-run verification

### Overview

The acceptance criterion is about a reader, not about a test. Run the real
thing and judge the real table.

### Changes Required:

#### 1. The run

**File**: none (verification phase)
**Changes**: From this worktree, run the selection mechanics exactly as the
skill does - it claims nothing and creates nothing, so this is safe to run
repeatedly:

```bash
ruby .claude/scripts/select_batch.rb --n 3
ruby .claude/scripts/select_batch.rb st-trm st-tgv   # the identical-title pair
```

Render the candidate table from the output using the Phase 3 column spec,
exactly as `/next-issues` step 2 would, and judge it against the bead's
criterion: **can a reader who has never seen these beads tell what each one
is, from the table alone?** Specifically check the two rows that share a
title.

If a row fails that test, classify the failure before fixing anything:
- the *description* opens badly -> the bead needs a better first sentence;
  file it, do not paper over it in the summarizer;
- the *cut* is wrong (mid-clause, split on an abbreviation, swallowed a whole
  paragraph) -> a `lib/summary.rb` bug; fix and re-run Phase 2's tests with a
  regression case added;
- the *cap* is too tight -> revise `MAX_CHARS` (open question 1's default was
  chosen without a live sample).

#### 2. The record

**File**: none (bead note)
**Changes**: Record the rendered table on the bead so the verification is
evidence rather than a claim:

```bash
ruby .claude/scripts/bead.rb note st-sdv "$(date +%F): live /next-issues table verified - <n> candidates, all rows carry title+summary; st-trm/st-tgv distinguishable"
```

### Success Criteria:

#### Automated Verification:
- [ ] `ruby .claude/scripts/select_batch.rb --n 3` exits 0 and every candidate
      row has a `summary` key
- [ ] Ruby suite still green after any Phase 4 fixes:
      `ruby .claude/scripts/test/run.rb`
- [ ] Full gate green before the final commit: `mix quality`

#### Manual Verification:
- [ ] The rendered table answers "what is this bead about?" for every row
      without running `bd show`
- [ ] `st-trm` and `st-tgv` are distinguishable from each other in the table
- [ ] An AskUserQuestion-shaped option string built from the recommended batch
      names the subjects and fits the option text budget
- [ ] The verification note is on the bead

**Implementation Note**: In interactive execution, pause here for manual
confirmation from the human that the manual testing was successful. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end - and for this phase in particular, the manual
items *are* the acceptance criterion, so they must be surfaced explicitly and
not merely listed.

---

## Testing Strategy

### Unit Tests:

- `.claude/scripts/test/summary_test.rb` - the truncation rules in isolation:
  first-sentence extraction, abbreviation guards, dotted-number and dotted-path
  non-splits, paragraph boundary, whitespace collapse, cap and word-boundary
  cut, nil/empty input. Pure function, no `FakeSh` needed.
- `.claude/scripts/test/select_batch_test.rb` - the envelope contract: the
  `summary` key is present on every candidate in both input modes, is `nil`
  (not absent) for a description-less bead, and distinguishes two candidates
  that share a title.
- Both use stdlib minitest under `test/run.rb`; every new test carries a
  `# sabotage: ... -> red` note per `docs/testing.md`, verified by actually
  applying the mutation.

### Conformance Tests:

None. This branch touches no interpreter, parser, or datamodel code, so no
SCION/W3C test changes state and `test/passing_tests.json` does not move. A
shrinking ratchet on this branch would be a bug, not a result.

### Manual Testing Steps:

1. `ruby .claude/scripts/select_batch.rb --n 3` - read the raw envelope and
   confirm `title` and `summary` sit adjacent in every candidate.
2. Render the table per the Phase 3 column spec and read it as a picker would.
3. `ruby .claude/scripts/select_batch.rb st-trm st-tgv` - confirm the
   explicit-selection path carries summaries too (different code path) and
   that the identical-title pair is now separable.
4. Compose the AskUserQuestion option text for the recommended batch by hand
   and confirm it names the subjects within its length budget.
5. Confirm nothing was claimed: `ruby .claude/scripts/bead.rb show st-trm`
   still shows its prior status.

## Corpus/Ratchet Notes

None. No corpus regeneration, and `test/passing_tests.json` is untouched -
which also means the `Gate guard` stage has nothing to flag on this branch and
no `docs/quality-gate-changes.md` entry is needed (ADR-0011). No changelog
fragment either: `changelog.d/README.md` excludes agent tooling changes.

## References

- Beads issue: `st-sdv`
- Related ADRs: `docs/adr/0015-skill-mechanics-in-scripts.md` (script vs
  prose split, the five constraints), `docs/adr/0010-worktree-parallel-development.md`
  (why the picker's authority is where it is), `docs/adr/0011-quality-gate-config-not-agent-editable.md`
- Routing record (the precedent this plan's decision follows):
  `docs/skill-automation.md` - "Model routing", especially "What is explicitly
  not routed to Haiku, and why"
- Script contract: `.claude/scripts/README.md`
- Prior plan that built these scripts:
  `docs/plans/260806-st-hzf-skill-mechanics-scripts.md` (Phase 6 is
  `select_batch.rb`)
- Code: `.claude/scripts/select_batch.rb:220-264`,
  `.claude/scripts/lib/areas.rb`, `.claude/scripts/test/select_batch_test.rb:59-65`
- Skills: `.claude/skills/next-issues/SKILL.md:134-199`,
  `.claude/skills/next-issue/SKILL.md:70-102`
- Sabotage protocol: `docs/testing.md` (Sabotage testing);
  `.claude/scripts/test/gate_test.rb:113` for the Ruby-side precedent

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The new entry reads in the same register as the five beside it: what is
      not routed, and why, in one sentence each - no ADR-0015 re-argument
- [ ] The section's closing paragraph is still true of every bullet under it
- [ ] House style of the file is matched (this file uses plain hyphens; do not
      introduce em dashes)

**Implementation Note**: In interactive execution, pause here for manual
confirmation from the human that the manual verification was successful before
proceeding to the next phase. In looped (`--loop`) execution, this phase's
Automated Verification gates advancement automatically (via `/commit --auto`);
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---
