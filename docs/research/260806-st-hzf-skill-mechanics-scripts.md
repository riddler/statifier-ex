---
date: 2026-08-06T17:16:38-0600
researcher: Claude
git_commit: af543224c7a803b3ac07fae3bec0a505c6387f69
branch: st-hzf-skill-mechanics-scripts
repository: statifier-ex
beads_issue: st-hzf
topic: "Extracting deterministic skill mechanics into shared scripts, and classifying every skill step as scriptable / Haiku-able / session-model"
tags: [research, skills, tooling, workflow, worktrees, beads, quality-gate]
status: complete
last_updated: 2026-08-06
last_updated_by: Claude
---

# Research: Skill mechanics extraction (st-hzf)

**Date**: 2026-08-06T17:16:38-0600
**Git Commit**: af543224c7a803b3ac07fae3bec0a505c6387f69
**Branch**: st-hzf-skill-mechanics-scripts
**Beads Issue**: st-hzf

## Research Question

Audit all 13 `SKILL.md` files under `.claude/skills/`, break each into its
constituent steps, and classify every step as (a) scriptable deterministic
mechanics, (b) needs a model but could run on Haiku, or (c) needs the session
model. Identify the mechanics that recur across skills and belong in a shared
`.claude/scripts/`, the JSON shapes those scripts should emit, the behavioral
constraints any extraction must preserve, and the risks.

## Summary

The 13 skills total 3,765 lines of prose. Decomposed, they contain roughly
**189 discrete steps**, classified as:

| Class | Count | Share |
|---|---:|---:|
| **(a) scriptable** - deterministic mechanics | 115 | ~61% |
| **(b) model needed, Haiku-sized** | 21 | ~11% |
| **(c) session model** | 53 | ~28% |

The distribution is bimodal, and the split falls almost exactly along the line
the bead already drew. The **six worktree/bead-lifecycle skills**
(`/next-issue`, `/next-issues`, `/new-worktree`, `/refresh-worktree`,
`/cleanup-worktrees`, `/create-issue`) are **~85% scriptable** - `/new-worktree`
and `/refresh-worktree` are close to 100%. The **four artifact skills**
(`/create-plan`, `/iterate-plan`, `/research-codebase`, and the judgment half of
`/implement-plan`) are the inverse: mostly session model, with a scriptable
shell around them (metadata, filenames, frontmatter, phase/checkbox parsing).
`/commit`, `/merge-request` and `/work` sit in between: heavily mechanical with
a small number of irreducible policy decisions embedded mid-flow.

There is **no `.claude/scripts/` today, and no script of any kind under
`.claude/`** - every skill directory contains exactly one `SKILL.md`. The only
non-prose file under `.claude/` is `settings.json`, which registers a single
`SessionStart` hook (`bd prime --hook-json`).

The recurring mechanics cluster into eight families, described in
[Shared script families](#shared-script-families). Two of them are duplicated
regexes or command sequences that *must* agree across skills and currently agree
only by prose cross-reference - the `^Refs:` bead-id extraction
(`/merge-request` step 2 vs `/cleanup-worktrees` step 4.5) and the
capture-then-abort rebase-conflict ordering (`/merge-request` step 3c vs
`/refresh-worktree` step 3d). Those are the clearest correctness arguments for
extraction, independent of speed or token cost.

## Detailed Findings

### Inventory

| Skill | Lines | frontmatter `model:` | (a) | (b) | (c) |
|---|---:|---|---:|---:|---:|
| `create-issue` | 87 | *(none)* | 4 | 2 | 1 |
| `next-issue` | 155 | sonnet | 8 | 3 | 2 |
| `next-issues` | 338 | sonnet | 13 | 2 | 3 |
| `new-worktree` | 262 | sonnet | 8 | 1 | 1 |
| `refresh-worktree` | 159 | sonnet | 10 | 0 | 1 |
| `cleanup-worktrees` | 364 | sonnet | 12 | 0 | 2 |
| `merge-request` | 268 | sonnet | 11 | 2 | 3 |
| `commit` | 460 | sonnet | 13 | 3 | 5 |
| `work` | 282 | opus | 6 | 2 | 4 |
| `research-codebase` | 299 | *(none)* | 8 | 2 | 6 |
| `create-plan` | 552 | opus | 5 | 1 | 12 |
| `iterate-plan` | 271 | opus | 3 | 1 | 6 |
| `implement-plan` | 268 | sonnet | 14 | 2 | 7 |
| **Total** | **3,765** | | **115** | **21** | **53** |

Counts are per decomposed step, not per numbered heading; a numbered step that
mixes a shell call with a judgment call is counted once in each class.

### The lifecycle skills (highest extraction value)

#### `/new-worktree` (`.claude/skills/new-worktree/SKILL.md`)

Every numbered step is mechanical. Step 1 guards (`git branch --list <name>`,
`ls ../statifier-ex-worktrees/<name>`, `git fetch origin` with an offline
fallback to local `main`); step 2 creates
(`git worktree add ... -b <name> --no-track origin/main`, then
`mise trust <path>`); step 3 warms
(`cp -Rc deps _build <path>/ || cp -R ...`, plus PLT-presence detection);
step 4 verifies (`mix deps.get`, `mix quality --profile loop`); step 5 opens the
tmux window; step 6 reports.

The only non-scriptable input is "if given only a bead id, ask for the slug"
(L28-29). Everything else - including the `$win`-non-empty check, the
`'=statifier-ex'` quoting rule, the `-P -F '#{window_id}'` capture, the
`--model opus` constant and the appended `$FINISH` clause - is a fixed script
with no decisions in it. **This is the single best extraction target in the
repo: ~262 lines of prose that a script reduces to one invocation and one JSON
result.**

#### `/refresh-worktree` (`.claude/skills/refresh-worktree/SKILL.md`)

Also effectively 100% mechanical: enumerate (`git worktree list --porcelain`),
fetch once, then per worktree `merge-base --is-ancestor` /
`status --porcelain` / record `before` / `rebase origin/main` /
capture-then-abort on conflict / `mix.lock`-moved build repair /
`mix quality --profile loop`. The one session-level item is the *interpretation*
of a conflict as feedback on `area:` labels (L89-92, and `docs/workflow.md`
L139-142) rather than a chore.

#### `/cleanup-worktrees` (`.claude/skills/cleanup-worktrees/SKILL.md`)

The longest lifecycle skill (364 lines) and almost entirely a specification of
deterministic checks, several written as literal regexes and awk programs:

- merge detection via `gh pr list --state merged --head <branch> --json
  number,mergedAt,headRefOid --jq '.[0]'`, never git ancestry (L16-38)
- `headRefOid` vs local `git rev-parse HEAD` (L81-101), with two documented
  wrong alternatives (`@{upstream}`, `origin/main..HEAD`)
- window matching on **name and path together** via
  `tmux list-panes -a -F '#{window_id} #{window_name} #{pane_current_path}'`
  piped to awk (L117-124)
- the idle classifier (L150-202): spinner match on `\([0-9]+s · ` or
  `esc to interrupt`, never the randomized verb; last `❯` line captured with
  `-e` so the dim `\e[2m ... \e[0m` suggested-prompt placeholder can be told
  apart from real typed text; sample twice ~3s apart
- quiesce via `send-keys C-u` then `'/exit' Enter`, poll ≤15s, never a signal
- removal order (`worktree remove`, `prune`, `branch -D`), `kill-window` only
  when every pane is a bare shell
- bead closing from `^Refs:`-anchored trailers in
  `gh pr view <number> --json commits --jq '.commits[].messageBody'` (L258-289)

The idle classifier reads like judgment but is not - the skill already specifies
it as a byte-level decision procedure, complete with captured fixtures. It is
prose *because there was nowhere else to put it*, and it is the passage most
likely to be executed inconsistently by a model reading 364 lines.

#### `/next-issues` (`.claude/skills/next-issues/SKILL.md`)

Selection is set arithmetic, and the skill says so: "two beads are batchable iff
their `area:` label sets are disjoint... a batch is a set intersection rather
than an opinion" (L15-18). The whole of step 3's verdict table (epic /
unlabeled / `area:build` / collides-with-live-worktree / free) plus the greedy
priority-ordered walk is a pure function of `bd ready --json`, `bd show --json`
labels, `git worktree list --porcelain`, and `gh pr list --state merged`.

Also mechanical: the `n > 4` refusal, the refusal to mix bead ids with filters,
the `--label-any` upstream workaround (per-label `bd ready --json` then union by
id, because beads#5358 makes the flag silently return the unfiltered set), and
the filter-sanity check that compares filtered vs unfiltered counts.

What is *not* mechanical is step 4's picker: presenting the candidate table,
offering legal alternatives, and framing the override option text so it names
the specific risk being accepted. That needs the AskUserQuestion tool and a
human; in `--auto` mode the override option does not exist and the step becomes
scriptable again.

Step 2's hardening ("this survey must not simply trust that step 0.5 ran and
succeeded", L143-165) exists because of a live failure on 2026-08-05 where a
merged-but-not-removed worktree for `st-o9a` made `st-d9g` report a phantom
collision. That is exactly the class of bug a shared survey script removes -
one implementation, one staleness rule.

#### `/next-issue` and `/create-issue`

`/next-issue` is the degenerate `n=1` case of `/next-issues` plus a claim and a
hand-off. `bd dolt pull`/`push` best-effort wrappers, `bd ready --claim --json`
(the atomic path), `bd update <id> --claim`, `bd show <id>`, and the
`/new-worktree <id>-<slug> -- /work <id> --auto` invocation are all scriptable;
the slug and the one-line "why now" are Haiku-sized; the pick itself is the
user's in manual mode.

`/create-issue` is the shortest skill (87 lines) and the only one with no
`model:` frontmatter. `bd create` / `bd q` / `bd link` / `bd update --add-label`
are scriptable; inferring type and priority from a description, and choosing
`area:` labels from the paths named in acceptance criteria, are bounded
judgment.

### `/commit`, `/merge-request`, `/work`

These are mechanically dense but carry the repo's authority boundaries inline,
which is what makes them the delicate ones.

`/commit` (460 lines) mechanizes: mode parse; the eight auto-refusal conditions;
`mix gate.verify` and its attestation; the non-Elixir carve-out
(explicitly "not a judgment call", L101); the sabotage-note scan; the five-strategy
bead-detection ladder; the three hard message limits (subject <50, body ≤72,
total ≤40 lines - pure validation that should never occupy a model); staging,
the heredoc commit, the attribution verification regex, and the
`git reset --soft HEAD~1` recovery.

Two of its steps resist extraction absolutely. **Strategy 2 of bead detection**
(L148-157) reads the bead out of the session's own seeded prompt - no script can
see that, so it must be passed in as an argument. And **"the working tree
carries changes unrelated to the claimed issue"** (L37) is the one auto-refusal
condition with no mechanical test at all.

`/merge-request` (268 lines) is the same shape: locate, resolve beads from
`^Refs:` trailers, fetch, no-op detect (`git rev-list --count HEAD..origin/main`),
rebase with capture-then-abort, `mix.lock` build repair, `mix gate.verify`,
`mix quality --profile merge` (the ADR judge), changelog check, **the one
unskippable human confirmation**, `git push -u` or `--force-with-lease`,
`gh pr create`, `bd dolt push` + `bd note <id> "PR: <url>"`. It explicitly tells
the model not to reimplement `/refresh-worktree`'s step 3d/3e (L86-87, L95-100) -
a cross-reference that is already asking for a shared script.

`/work` (282 lines) runs almost no git plumbing by design (L265-269: "the only
things this session does itself are `bd` calls, the just-do-it `/commit --auto`
gate, and its own report"). Its two scriptable jewels are **step 0's
locate-self** -

```bash
[ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]
```

- the most reusable primitive in the whole set, and **step 2's skip-satisfied
scan** (a `docs/research/` doc naming the bead, a `docs/plans/` plan naming it,
and `bd show` notes matching `loop: Phase N complete, commit <sha>` /
`loop stopped at Phase N: <reason>`). That scan is the resumability seam that
makes `/work <id>` re-invocable, and it is pure state detection.

Sizing (step 2's four buckets) is the skill's reason for existing and is
irreducibly session-model: "sizing happens here, with the codebase in reach"
(L120-123).

### The artifact skills

`/research-codebase`, `/create-plan`, `/iterate-plan` and `/implement-plan`
invert the ratio, but they still contain a well-defined mechanical shell:

- **The metadata triple** - `date +%Y-%m-%dT%H:%M:%S%z`, `git rev-parse HEAD`,
  `git branch --show-current` - exists only to fill frontmatter fields.
- **Artifact filename computation**: `YYMMDD-[issue-id-]kebab-description.md`,
  the identical rule in `docs/plans/` and `docs/research/`. The `st2-` → `st-`
  rename (commit `36c4b9d`) rippled through every one of these filenames, which
  is itself an argument for one name builder.
- **Frontmatter emission and the follow-up mutation** (bump `last_updated`,
  add `last_updated_note`, append a timestamped `## Follow-up Research` heading).
- **GitHub permalink rewriting** (`gh repo view --json owner,name`, then
  `file:line` → `https://github.com/{owner}/{repo}/blob/{commit}/{file}#L{line}`)
  - a pure text transform over an already-written document.
- **The plan file as a state machine.** `## Phase N:` sectioning,
  `#### Automated Verification:` vs `#### Manual Verification:`, `- [ ]` vs
  `- [x]`, and the `## Deferred Manual Verification` append-at-bottom. Three
  skills read and write this grammar (`/create-plan` produces it,
  `/implement-plan` drives on it, `/iterate-plan` must not break it) and there
  is no shared parser.
- **`/create-plan` states its 9-section template three times** (as a list, as a
  fenced example, and as a Pre-Write Checklist), and the ex_quality command menu
  appears verbatim in three skills.

`/implement-plan`'s loop is the most mechanical of the four: precondition checks
(`git status --porcelain` empty, bead claimed), phase-text extraction, resume
scan for the first unchecked Automated box, prompt assembly, checkbox toggling,
verbatim Manual-item deferral, the refusal path (stop, **uncheck** this phase's
Automated boxes, touch nothing else, `bd note`), and the success path
(`bd note <id> "loop: Phase N complete, commit <sha>"`). All of that is a
deterministic state machine wrapped around one session-model subagent per phase.

## Shared script families

Eight families, ordered by how many skills they serve. Suggested home:
`.claude/scripts/` for the shared ones, with skill-specific drivers alongside.

**1. `bd` wrapper (`bead.rb`)** - serves 9 skills.
`bd show`, `bd ready`, `bd update --claim`, `bd note`, `bd close`, `bd link`,
`bd q`, `bd dolt pull/push`. `bd ready` already speaks `--json`; **`bd show` is
parsed as prose in at least four skills and is the single biggest parsing win.**
Verified this session: `bd show <id> --json` returns a one-element array whose
object carries `id, title, description, acceptance_criteria, notes, status,
priority, issue_type, assignee, labels, dependent_count, dependency_count`.
Note `notes` is one string blob, not a list - a wrapper should split it.

**2. Repo/worktree state (`repo_state.rb`, `worktree_survey.rb`)** - serves 8.
Locate-self (`--git-dir` vs `--git-common-dir`), `git worktree list --porcelain`
parsing, `<id>-<slug>` branch decomposition, dirty check, ahead/behind,
`origin/main` ancestry, and the per-worktree PR-state join. `/next-issues` step
2, `/refresh-worktree` step 1 and `/cleanup-worktrees` step 1 are three
variations on one survey.

**3. PR state (`pr_state.rb`)** - serves 4.
One place that knows merge detection is `gh`-based and ancestry is *wrong* under
rebase-merge-only. Also the home for the `^Refs:` extraction so
`/merge-request`'s `Closes` lines and `/cleanup-worktrees`'s closes cannot drift.

**4. Worktree lifecycle (`worktree_create.rb`, `worktree_refresh.rb`,
`worktree_cleanup.rb`)** - serves 5.
Guard/create/`mise trust`/warm/verify; rebase sweep with capture-then-abort and
`mix.lock`-conditional PLT repair; merged-detection/removal/branch delete. The
rebase+repair block is shared verbatim between `/refresh-worktree` and
`/merge-request` today.

**5. tmux (`tmux_window.rb`)** - serves 2, but carries the most fragile logic.
Session guard with the quoted `'=statifier-ex'` target, window-name guard,
`-d -P -F '#{window_id}'` creation, the empty-`$win` trap, the name+path window
match, the idle classifier, `/exit` quiesce with a 15s poll, and the
all-panes-are-shells precondition on `kill-window`.

**6. Selection (`select_batch.rb`)** - serves 2.
The verdict table and greedy disjoint-area walk, plus the `--label-any`
workaround and the filtered-vs-unfiltered sanity check. `/next-issue` is this
with `n=1`.

**7. Quality gate (`gate.rb`)** - serves 4.
Wraps `mix gate.verify` and `mix quality --format json --report -`, and folds in
the non-Elixir carve-out predicate (stated identically in `/commit` and
`/merge-request`) and the sabotage-note scan.

**8. Documents (`doc_meta.rb`, `plan_state.rb`, `permalinks.rb`)** - serves 4.
Metadata triple, filename builder, frontmatter emit/update, plan phase and
checkbox parsing plus its mutations, permalink rewriting.

## Output shapes

The organizing recommendation is **one envelope for every script**, so the model
learns one shape rather than eight:

```json
{
  "ok": true,
  "script": "worktree_create",
  "data": { },
  "warnings": [{"code": "plt_missing", "message": "..."}],
  "blocked": [{"code": "branch_exists", "message": "...", "needs": "human"}],
  "commands": ["git worktree add ...", "..."]
}
```

`commands` matters: CLAUDE.md forbids truncating gate output, and a script that
hides what it ran trades one opacity for another. Echoing the command list keeps
the run auditable while the model reads `data`.

Representative payloads:

**`repo_state.rb`** (replaces `/work` step 0, `/merge-request` step 1, half of
`/commit` step 1):

```json
{"checkout":"worktree","root":"/abs/path","branch":"st-abc-exit-sets",
 "branch_bead":"st-abc","is_main":false,"dirty":false,"dirty_files":[],
 "upstream":"origin/st-abc-exit-sets","commits_ahead":3,"commits_behind":0,
 "unpushed":[{"sha":"abc1234","subject":"Adds ...","refs":["st-abc"]}],
 "refs_beads":["st-abc"],"touches_elixir":true,
 "changed_files":["lib/..."],"plan_docs":["docs/plans/260806-st-abc-x.md"],
 "changelog_fragments":["changelog.d/st-abc.md"]}
```

**`worktree_survey.rb`** (replaces `/next-issues` step 2, `/refresh-worktree`
step 1, `/cleanup-worktrees` step 1):

```json
{"main_checkout":"/Users/johnnyt/repos/github/statifier-ex",
 "worktrees":[
   {"path":"...","branch":"st-abc-exit-sets","bead":"st-abc",
    "areas":["area:interpreter"],"dirty":false,
    "ancestor_of_origin_main":false,
    "pr":{"number":41,"state":"MERGED","head_oid":"...","merged_at":"..."},
    "stale":true,"holds_areas":[],
    "tmux":{"window_id":"@42","name":"st-abc-exit-sets","idle":true}}],
 "gh_available":true,
 "degraded":[]}
```

`holds_areas` distinct from `areas` is the fix for the 2026-08-05 phantom
collision: a stale worktree has areas but holds none. `gh_available` +
`degraded` carry the "say so once, not once per worktree" rule.

**`select_batch.rb`**:

```json
{"n":3,"mode":"auto","candidates":[
   {"id":"st-abc","title":"...","priority":1,"areas":["area:parser"],
    "verdict":"free"},
   {"id":"st-qww.7","title":"...","priority":1,"areas":["area:skills"],
    "verdict":"collides_live","collides_with":{"area":"area:skills",
      "worktree":"st-hzf-skill-mechanics-scripts"},"overridable":true}],
 "recommended":["st-abc","st-d9g"],
 "alternatives":[{"label":"...","beads":["st-abc"],"why":"..."}],
 "skipped":[{"id":"st-mp4","reason":"unlabeled - blast radius undecided"}],
 "ceiling_hit":true}
```

**`gate.rb`**:

```json
{"applicable":true,"carve_out_reason":null,"ran":"full","attested":true,
 "exit_code":0,
 "stages":[{"name":"Gate guard","status":"pass","findings":[]}],
 "skipped_stages":[{"name":"Dialyzer","reason":"..."}],
 "gate_guard":{"status":"pass","guarded_paths":[],"ledger_entry":null},
 "sabotage":{"missing":[{"file":"...","line":31,"test":"..."}],"ok_count":4}}
```

`skipped_stages` must stay in the shape: CLAUDE.md's "read the `○` lines" rule
says a skipped stage is not a passing one, and a summary that drops them
launders exactly the information the rule protects.

**`plan_state.rb <path>`**:

```json
{"path":"docs/plans/260806-st-abc-x.md","bead_id":"st-abc",
 "sections_missing":[],
 "phases":[{"n":1,"name":"Lowering builder","line_start":85,"line_end":140,
            "automated":{"total":2,"checked":2},
            "manual":{"total":3,"checked":0,"items":["..."]},
            "complete":true}],
 "next_phase":2,
 "deferred_manual_section":{"present":true,"line":410}}
```

with mutating subcommands `check` / `uncheck` / `defer` / `validate`.

**`bead.rb resolve`** encodes `/commit`'s five-strategy ladder as data:

```json
{"resolved":{"id":"st-abc","strategy":"plan_doc","confidence":"strong"},
 "candidates":[
   {"id":"st-xyz","strategy":"branch_prefix","status":"closed",
    "warning":"stale branch name (ADR-0010)"}]}
```

The `strategy`/`confidence`/`warning` fields are not decoration: without them a
`branch_bead` field reads as authoritative, and the closed-bead case
(`/commit` L174-179) stops surfacing.

## Behavioral constraints any extraction must preserve

From `CLAUDE.md`:

- **The agent-authority table is per action, with a trigger each.** A commit on
  a per-issue worktree branch is reversible and may be automated; push, PR,
  `bd close`, and `bd dolt push` are visible to other people and machines and
  keep a human gate. **The practical consequence for this work: every script
  must be step-scoped.** A `push.rb` that refuses unless the session passes a
  flag it only sets after a human asked is fine; a `ship.rb` that chains
  commit → push → PR is not, because it collapses the asymmetry the table
  exists to encode.
- **Authority belongs to the session that owns the work, not to a subagent it
  delegates to.** A subagent that believes it satisfied a trigger reports that;
  it does not act on it. Any script that commits must therefore never be
  reachable from a phase subagent.
- **Non-interactive shell flags** are mandatory: `cp -f`, `mv -f`, `rm -f`,
  `rm -rf`, `cp -rf`, `ssh -o BatchMode=yes`, `apt-get -y`,
  `HOMEBREW_NO_AUTO_UPDATE=1`, and never `bd edit`. A Ruby script shelling out
  inherits this rule; `/new-worktree`'s `mise trust` step exists for the same
  class of hang.
- **ExQuality rules**: never truncate gate output, read the `○` skipped lines,
  a scoped or `--quick` green is not a full green, and **never go green by
  weakening the check**. `mix gate.verify` mechanizes the third; the fourth is
  still prose. A gate wrapper that grows a convenience `--skip` passthrough
  quietly defeats it.
- **ADR-0011**: `.quality.exs`, `.credo.exs`, `coveralls.json`,
  `.sobelow-conf`, gate-relevant `mix.exs` lines, added `@tag :skip`, and a
  shrunk `test/passing_tests.json` all require an entry in
  `docs/quality-gate-changes.md` naming the path, and **that entry is a human's
  call**. No script may have a code path that writes it.

From `docs/workflow.md`:

- **The `area:` vocabulary is closed**: `area:interpreter`, `area:parser`,
  `area:datamodel`, `area:corpus`, `area:test-harness`, `area:skills`,
  `area:docs`, `area:build`. Two beads are batchable iff their area sets are
  disjoint; `area:build` is exclusive and lands alone; `upstream` beads carry no
  area and collide with nothing.
- **Areas are about file collision, not subject matter**, and the label is a
  *prediction* written before the work exists - deliberately not derived from a
  diff. A script that "improves" labels by inferring them from changed files
  inverts the design.
- **Model roles**: Fable for direction, Opus for planning, Sonnet for
  implementation. **A skill's `model:` frontmatter beats an Agent-call
  override** for the turn the skill is active; an orchestrator's per-stage model
  must mirror the frontmatter rather than contradict it. A CLI session is the
  exception, which is why `/new-worktree` passes `--model opus` explicitly.

Language: **Ruby with the stdlib**, per the user's global preferences and the
bead. See [Open questions](#open-questions) on the Ruby version.

## Haiku delegation candidates

21 steps are model-needed but bounded. They cluster into five kinds:

1. **Branch slug generation** - "2-4 distinctive kebab-case words from the
   title, not a full transcription". Appears in `/next-issue` step 2,
   `/next-issues` step 5, `/work` step 0, and `/new-worktree`'s input handling.
   Input is one title string; output is one slug. The cheapest and most
   frequently executed judgment in the set.
2. **Commit message drafting** - `/commit` step 2's body, and `/merge-request`
   step 7b's PR body. The *validation* (subject <50, body ≤72, ≤40 lines,
   `Refs:` present, no attribution) is scriptable and must stay scriptable; only
   the prose is a model's job.
3. **Diff and change summarization** - `/commit` step 1's classification of what
   was added/fixed/refactored; the "one-line why-now" per candidate in
   `/next-issue` step 1.
4. **Bounded classification** - `/create-issue`'s type and priority inference;
   `/iterate-plan`'s "does this change require codebase research" binary;
   `/implement-plan`'s refusal-reason classification; `/create-plan`'s
   "any unresolved open questions left in the plan" scan.
5. **Kebab description for artifact filenames** - the `description` slug in
   `docs/research/YYMMDD-<id>-<description>.md`.

**Mechanism note.** All six agent definitions under `.claude/agents/` are
`model: sonnet`; there is no Haiku agent today. Routing to Haiku means either
adding a `.claude/agents/` definition (e.g. a `scribe` agent for slug/message
drafting) or passing `model: "haiku"` on the Agent call. The frontmatter-beats-
override rule in `docs/workflow.md` means a Haiku subagent that invokes a stage
skill would run that skill on the skill's own model - so Haiku delegation only
works for prompts composed directly in the Agent call, never for a step routed
through the Skill tool.

## Risks

**Prose that carries judgment a script would silently drop.** Ranked:

1. **The sabotage protocol** (`/implement-plan` L180-203, enforced by `/commit`
   step 0). A script can assert that a `# sabotage:` line exists; it cannot
   assert the mutation was plausible, that the test failed *for the right
   reason*, or that a function body was not simply deleted. `/commit` L122-124
   names this as the one failure mode the check cannot detect afterwards, and
   forbids inventing a note. **Automating the note's presence without keeping
   the paragraph in front of the model converts a verification discipline into a
   comment-formatting rule.** Highest risk in the set.
2. **"Changes unrelated to the claimed issue"** (`/commit` L37) - the one
   auto-refusal with no mechanical test. Extraction must leave it as an explicit
   session-model gate, not quietly drop it because the other seven conditions
   automated cleanly.
3. **Gate guard is deliberately un-fixable by the agent** (ADR-0011). The script
   family must be able to *report* a guard failure and must contain no path that
   writes the ledger entry.
4. **`bd close` fires on merge and nowhere else.** `/commit`, `/merge-request`
   and `/work` each say so independently, and `/cleanup-worktrees` is the only
   closer. A generic "finish the bead" helper is the most tempting and most
   wrong extraction available.
5. **Phase sizing** (`/create-plan` L232-239): a phase is "the smallest unit
   that is independently gate-verifiable and independently committable", and
   phases that would leave an intermediate gate red must be combined. A
   phase-splitting script produces syntactically valid phases that break
   `--loop`.
6. **Changelog fragments are a promise to users** (`/merge-request` L157-160:
   do not invent one; `/commit` L203-206: most work needs none, and that is the
   expected outcome, not a skipped step). A script that templates a fragment
   whenever `lib/` changed inverts both rules.
7. **The branch name is a creation-time label, not an authority** (ADR-0010).
   Any JSON field named `branch_bead` reads as authoritative unless it ships
   with `strategy` / `confidence` / `warning`.
8. **The rebase-before-gate ordering** (`/merge-request` step 3 before step 4):
   the gate must attest to the tree that will merge. An optimizer that reorders
   or skips the gate on the no-op fast path silently invalidates the
   attestation.
9. **`--auto` "does not lower a bar, it removes a prompt"** and "a refusal is a
   report, not a fallback to interactive" (`/commit` L20, L44-45).
10. **`/research-codebase`'s documentarian-not-critic stance.** A scaffolding
    script that emits section headings invites filling them; nothing in a
    skeleton stops the model writing recommendations.
11. **`/next-issues`'s "manual mode presents, it does not impose"** (L309-312).
    The picker is the point of the skill. A script that returns a
    `recommended` array must not let the calling model treat it as the outcome.
12. **`/iterate-plan` L174-176**: flag changes that contradict an accepted ADR
    rather than silently editing the plan. An Edit-applying script has no ADR
    awareness.

**Load-bearing composition.** Skills call other skills, so a behavior change in
one propagates:

```
/next-issue ─┐
/next-issues ┼─> /new-worktree <name> -- /work <id> --auto
/work (main) ┘        └─ tmux window, seeded session (--model opus)

/work (worktree)
  ├─ intake ──> /create-issue
  ├─ Research  ──> Agent(general-purpose, opus)  -> /research-codebase <id>
  ├─ Plan      ──> Agent(general-purpose, opus)  -> /create-plan <id>
  ├─ Direction ──> Agent(general-purpose, fable) -> inline prompt, no stage skill
  └─ Implement ──> Agent(general-purpose, sonnet)-> /implement-plan <path> --loop
                        ├─ per-phase Agent (layer 2)
                        └─ /commit --auto  (the advancement gate, per phase)

human asks ──> /merge-request  -> push + gh pr create + bd note
merge lands ──> /cleanup-worktrees (the only bd closer)
             └> /refresh-worktree (survivors rebase onto the new origin/main)
```

Specific fragilities:

- **`/new-worktree` step 5 is the convergence point** for every caller. The
  appended `$FINISH` clause is edited there precisely so it reaches every seeded
  session without touching the calling skills. A script must keep that single
  point of edit.
- **`/implement-plan --loop` runs `/commit --auto` itself**, deliberately
  independent of the phase subagent's self-report. `/work` must not re-run it.
  Extraction must not make the gate reachable from the subagent.
- **`/merge-request` and `/cleanup-worktrees` must agree on the `^Refs:`
  contract**, or the PR body's `Closes` lines and the actual closes diverge.
- **`/merge-request` explicitly defers to `/refresh-worktree`'s rebase and
  build-repair logic**; today that agreement is a prose cross-reference.
- **A seeded session cannot spawn a nested `claude` CLI**
  (`--permission-mode auto`'s classifier blocks `tmux send-keys ... 'claude'`,
  observed 2026-08-03 in the st-5bk worktree). In-process Agent subagents are
  unaffected. This constrains any script that would want to launch a session.
- **Spawn depth** `/work` -> implement subagent -> per-phase subagent is already
  at Claude Code's default three layers; nothing extracted may add a layer.

**Sequencing risk for the implementation.** `.claude/skills/**` is
`area:skills`, and `st-hzf` already holds it. Rewriting 13 SKILL.md files in one
branch conflicts with any other `area:skills` bead, and there is currently a
live worktree (`st-95c-old-repo-fate`) plus `st-mp4-cond-source-positions`.
Adding a Ruby toolchain line to `mise.toml` would be `area:build`, which
batches with nothing.

## Code References

- `.claude/skills/new-worktree/SKILL.md:49-231` - guard, create, warm, verify,
  tmux; the most fully scriptable skill
- `.claude/skills/cleanup-worktrees/SKILL.md:150-202` - the idle classifier,
  specified to the byte with captured ANSI fixtures
- `.claude/skills/cleanup-worktrees/SKILL.md:258-289` - `^Refs:`-anchored bead
  extraction and the `146c69f` fixture for why the anchor is required
- `.claude/skills/next-issues/SKILL.md:167-198` - the verdict table and greedy
  disjoint-area walk
- `.claude/skills/next-issues/SKILL.md:143-165` - the survey hardening added
  after the 2026-08-05 phantom-collision failure
- `.claude/skills/next-issues/SKILL.md:60-71` - the `--label-any` upstream
  workaround (beads#5358)
- `.claude/skills/refresh-worktree/SKILL.md:75-121` - capture-then-abort and
  `mix.lock`-conditional PLT repair
- `.claude/skills/commit/SKILL.md:27-45` - the eight auto-refusal conditions
- `.claude/skills/commit/SKILL.md:95-126` - the non-Elixir carve-out and the
  sabotage scan
- `.claude/skills/commit/SKILL.md:139-189` - the five-strategy bead ladder
- `.claude/skills/work/SKILL.md:37-62` - locate-self and the depth-one recursion
- `.claude/skills/work/SKILL.md:129-141` - the skip-satisfied resumability scan
- `.claude/skills/work/SKILL.md:146-183` - the stage contract and its invariants
- `.claude/skills/implement-plan/SKILL.md:42-122` - the loop state machine
- `.claude/skills/research-codebase/SKILL.md:64-72,164-174,251-257` - the
  metadata triple, filename rule, and permalink rewrite
- `docs/workflow.md:147-191` - the `area:` vocabulary and the disjointness rule
- `docs/workflow.md:6-48` - model roles and the frontmatter-beats-override rule
- `CLAUDE.md` - the agent authority table, non-interactive shell flags, the
  ExQuality rules and ADR-0011's mechanical half

## Architecture Documentation

- **ADR-0007** - beads is the only tracker; issue state syncs through
  `refs/dolt/data`, and `.beads/issues.jsonl` is a passive export.
- **ADR-0009** - ex_quality is the gate; full `mix quality` before any commit.
- **ADR-0010** - one issue, one branch, one worktree; the claim is the lock; the
  worktree name is fixed at creation and never renamed; `Refs:` trailers are
  what close beads, so a stale-looking name is the expected outcome.
- **ADR-0011** - the gate's own config is not agent-editable;
  `docs/quality-gate-changes.md` is where a human's call is recorded, not where
  an agent grants itself one.
- **Rebase-merge-only** (`docs/workflow.md:193`) - the reason merge detection
  must ask GitHub rather than git ancestry, and the reason
  `git branch -D` (not `-d`) is needed at cleanup.

## Historical Context (from docs/)

- `docs/plans/260805-st2-ott-work-orchestrator.md` - the plan that produced
  `/work` as the single entry point and moved sizing out of `/next-issue`.
- `docs/plans/260805-st2-7jr-selection-choices.md` - the plan that made
  `/next-issues` present choices rather than decide.
- `docs/plans/260803-st2-gm6-looped-plan-execution.md` - the plan that added
  `--loop` to `/implement-plan` and made `/commit --auto` the advancement gate.
- `docs/plans/260805-st2-qww.7-branch-naming-decision.md` - the decision that
  branch names are creation-time labels.
- `docs/plans/260804-st2-h6p-gate-weakening-check.md` - the plan behind
  `mix gate.check` / `mix gate.verify`.

## Related Research

- `docs/research/260803-st2-2yx-phase-agent-type.md` - agent-type selection for
  phase subagents.
- `docs/research/260803-st2-qjs-predicator-path-assign.md` - unrelated subject,
  useful as the frontmatter/format precedent for this document.

## Open Questions

These are recorded here because no human was available during this research
stage; each needs a decision before or during implementation.

1. **Ruby version.** The only Ruby on this machine is `/usr/bin/ruby`
   **2.6.10** (macOS system Ruby); `mise.toml` provisions Erlang, Elixir and
   Java but no Ruby. Either the scripts target 2.6 syntax (no endless methods,
   no `Data`, no hash-value shorthand, no `Struct` keyword_init defaults) or a
   `ruby` line is added to `mise.toml` - which is an `area:build` change that
   batches with nothing and touches a file the gate guard watches. **Recommend
   targeting 2.6 stdlib** unless the user wants the toolchain line.
2. **Script location.** The bead names both `.claude/skills/<name>/` and a
   shared `.claude/scripts/`. Recommendation is `.claude/scripts/` for all eight
   families with thin per-skill entry points, since six of the eight are shared
   by three or more skills - but the split is the user's call.
3. **How scripts are tested.** The bead's acceptance criteria say "runnable,
   tested scripts". There is no Ruby test harness in this repo and `mix quality`
   has no stage that would run one. Options: minitest under
   `.claude/scripts/test/` run manually, a `mise` task, or a new quality stage
   (which would touch `.quality.exs` and need a ledger entry per ADR-0011).
4. **Haiku routing mechanism.** No Haiku agent exists under `.claude/agents/`.
   Add one (e.g. a `scribe` agent for slugs and message drafts) or pass
   `model: "haiku"` per Agent call? The frontmatter-beats-override rule means
   Haiku only applies to prompts composed directly in the Agent call.
5. **Scope of this bead.** Rewriting all 13 SKILL.md files plus building eight
   script families is large for one branch, and `area:skills` batches with
   nothing else that touches `.claude/skills/**`. Should this be split into
   child beads (e.g. lifecycle scripts first, artifact/doc scripts second,
   Haiku routing third)?
6. **Does `bd show --json` cover every field the skills parse?** `notes` comes
   back as a single string blob rather than a list, so the
   `loop: Phase N complete, commit <sha>` scan that `/work` depends on needs the
   wrapper to split and parse it. Worth confirming against the installed `bd`
   version before committing to a shape.
7. **How much prose stays.** The bead says SKILL.md shrinks to "when to invoke,
   which script to run, how to interpret its output". Several of the risks above
   argue that specific paragraphs (the sabotage protocol, phase sizing, the
   authority asymmetry, "manual mode presents, it does not impose") must survive
   verbatim even when the mechanics around them are extracted. Where that prose
   lives once the steps are gone - inline, or a `REFERENCE.md` beside the
   SKILL.md - is undecided.
