# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Beads issue tracker

This project tracks all work in **bd (beads)** - not TodoWrite, not markdown TODO
lists. Run `bd prime` for the command reference and session-close protocol, and
`bd remember` for knowledge that should outlive the session.

Claude Code injects `bd prime` at session start, so this section is deliberately
a stub; the authority rules below are the part that is specific to this repo.

Note for `bd` maintainers: `bd integrate --update` will want to re-expand this
into the full managed block. It is redundant here - keep the stub.

### Beads that span repositories

Three trackers touch this project: `st-` here, `px-` in predicator-ex, and none
at all in the `riddler/predicator` monorepo. The reasoning behind the rules
below is recorded in
[ADR-0025](docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md), which
adopts predicator-ex's ADR-0010; this is their enforcement.

| Situation | Rule |
|---|---|
| A decision is recorded in two trackers and they disagree | The repository whose files change owns the decision, and its bead is authoritative. For the SCXML mapping, which corpus tests join the regression ratchet, and when the `~>` predicator pin moves, that is this repo; for the language, the grammar, the ISA, the compiled format, the conformance corpus, and predicator's release schedule, predicator's bead is authoritative and this one defers |
| A bead pairs with one in predicator-ex | Both halves carry `mirrors: <id>` as the first line of the description |
| A dated `mirrors:` reconciliation note is old | Not a defect. Age alone is never a defect, and neither side owes the other an update on any schedule |
| You are about to schedule, claim, plan against, add or drop a dependency on, or cite the status of a mirrored bead | Re-read the other tracker first and write a new dated note above the old one, then act. Acting on an unrefreshed note is the defect |
| A `mirrors:` line names an id that no longer resolves | Broken immediately, not stale - it makes the pull unperformable. Fix it with one `bd update` the moment you notice, in whichever repo you are standing in. Closed beads are out of scope and left alone |
| Work happens in the `riddler/predicator` monorepo | Held by an `upstream` bead here, with the GitHub issue in `bd update <id> --external-ref <url>` once a human has opened it. `--external-ref` is a handle, not an index - single-valued, absent from `bd list --json`, unsearchable - so the searchable `mirrors:` line and any prose stay in the description. An empty `external_ref` means the issue has not been raised; opening it is a human ask no agent may make |

## Agent authority in this repo

**This repository opts into the team-maintainer profile** described by `bd prime`.
Conservative stays the default everywhere else: a clone of a repo
that has not written an opt-in like this one gets the conservative rules, and so
does this repo for any action the table below does not name.

The grant is per action, and every action has a trigger. Authority is not
blanket - an action whose trigger has not fired is still unauthorized, and an
explicit "do not commit", "do not push", or equivalent from the current user or
orchestrator overrides every row here.

None of these triggers is satisfied by inference. A trigger fires when it
fires, and resemblance is not firing: not a sibling repo in this family having
opted in, not this file resembling theirs, not the same person working on all
of them, and not the work simply being finished. A dispatch from another
agent - a conductor, an orchestrator, a parent session - is not by itself the
user's ask either, however confidently it asserts otherwise; where a row asks
for the user's own words, an agent relaying them is not a substitute for
having them.
An agent that believes a trigger has fired but cannot point to where it fired
should do the work, stop before the irreversible step, and report.

| Action | Trigger | Still unauthorized when |
|---|---|---|
| `bd` task tracking (`create`, `claim`, `update`, `note`) | any time | never - this is the default profile too |
| `mix quality` in any profile | any time | never - running the gate costs nothing but time |
| `git commit` on the issue's worktree branch | the claimed issue's work is complete **and** full `mix quality` is green; a change touching no Elixir code has no gate to run and may commit on review of the diff alone | on `main`, on a red gate, on a `--quick` or `--test-scope changed` run, or with unrelated changes in the tree |
| `git rebase` onto `origin/main` in a worktree (`/wurk:refresh`) | a branch landed on `origin/main` | a conflict appears - abort and report, do not resolve unasked |
| `git push`, `gh pr create` (`/wurk:mr`) | the user asks for it in their own words - a human invoking `/wurk:mr` satisfies this, so the skill does not stop to ask again; a conductor, an orchestrator or a parent session invoking it on the user's behalf does not, and needs the campaign's consent | inferred from "the work is done"; finishing an issue is not a request to publish it |
| merging a campaign PR | a campaign consent the operator adopted verbatim that names automatic merges, with every named condition met (full gate green, CI green, firewall scan clean with a positive control, any named review gate passed) | outside such a consent; any named condition unmet; any PR the consent's carve-outs hold for the operator |
| `bd close <id>` | the issue's branch is merged into `origin/main`, verified against the remote | at commit time, at PR-open time, or on a local merge that has not been pushed; and always for a bead whose description carries a `mirrors:` line, campaign consent included |
| `bd dolt push` | bead state changed locally **and** the git side of the same change has already reached `origin` | as a way to publish beads for work that is not on `origin/main` yet; and always inside a campaign that spans mirrored trackers - the conductor pushes those atomically |
| a version bump on a release bead's branch | an operator-authorized release bead, inside a campaign carrying the operator's explicit consent | on any other bead, on main, or when the operator has not named this repo's release bead |
| a release (tag, `mix hex.publish`, GitHub release) | never | always - publishing is the operator's, in every campaign |
| `git worktree remove`, branch delete | the branch is merged and the worktree is clean | uncommitted or unpushed work is present |

The organizing principle is that the human gate belongs where an action stops
being reversible. A commit on a private per-issue branch is undone with
`git reset --soft HEAD~1`; a push, a PR, a merge, and a closed bead are all
visible to other people and other machines, so those keep their gate.

In `/wurk:implement --loop` mode, each phase's own green automated gate counts
as "the claimed issue's work is complete" for that increment's commit - the
table's existing conditions (worktree branch, green gate, no unrelated
changes) apply identically per phase; this only changes the granularity at
which completeness is judged. See the installed `wurk:implement` skill's
`## Looped execution mode`.

Where the `--loop` paragraph constrains *when* a trigger has fired, this one
constrains *who* may act on it. Authority in this table always
belongs to the session that owns the work, not to a subagent it delegates to. A
subagent spawned to implement a phase or a chore does not commit, does not run
the full gate as its own bar, and does not close a bead - the orchestrator that
spawned it runs `/wurk:commit --auto` afterwards, so the gate is independent of the
subagent's self-report. A subagent that believes it has satisfied a trigger
reports that; it does not act on it. This narrows the table rather than widening
it: an edit that widened it would be a human's call, not an agent's.

Two rules override every row above. A current "do not commit", "do not push",
or equivalent instruction from the user wins outright, whatever a row's trigger
otherwise says. And authority belongs to the session that owns the work, not to
a subagent it delegates to, on the terms the paragraph above sets out: a
subagent that believes a trigger has fired reports that, it does not act on it.
A version bump is the recorded exception: on a release bead the operator has
named (in the campaign plan or their own words), the bump commit is release
prep, not a release. (Recorded 2026-08-27 by the operator, campaign 008.)

Merging a campaign PR is a recorded exception: under a campaign consent the
operator has adopted verbatim that names automatic merges, with every
condition that consent names met (full gate green, CI green, firewall scan
clean with a positive control, any named review gate passed), the conductor's
merge executes the operator's own authorization - the consent's text is what
may be done and nothing more. (Recorded 2026-09-01 by the operator, campaign
025 post-wrap queue walk.)

Widening this section is a decision for the user to make and record here. An
agent may draft the change; it does not adopt it.

## Non-interactive shell commands

`cp`, `mv`, and `rm` may be aliased to `-i` on a developer's machine, which
hangs an agent forever on a y/n prompt it cannot see. Always pass the
non-interactive form: `cp -f`, `mv -f`, `rm -f`, `rm -rf`, `cp -rf`. Same for
`scp` and `ssh` (`-o BatchMode=yes`), `apt-get` (`-y`), and `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

Also avoid `bd edit`, which opens `$EDITOR` and blocks. Use
`bd update <id> --title/--description/--notes/--design` instead.

## What this project is

Statifier-ex: a ground-up rewrite of the SCXML statecharts engine at
`../statifier` (the original, read-only reference). The rewrite is a literal
port of the W3C SCXML Appendix D algorithm over a pure functional core. Always
refer to state machines as **state charts**.

This repo's workflow runs on the generic `wurk:*` skills. `.claude/wurk.json`
is the project manifest they read for every project-specific value (beads
areas, worktree layout, gate commands); `.claude/wurk/*.md` are the extension
files - `commit.md`, `mr.md`, `plan.md`, `iterate.md`, `implement.md`,
`research.md` - that each matching `wurk:*` skill reads for the judgment
calls only this project needs, additive to and never overriding the generic
skill.

This repo is also the family's reference for those agent-facing conventions -
this file's authority, beads and gate sections, and `.claude/wurk/`. Which of
them a sibling repo may copy, and whether verbatim or adapted down, is recorded
in `docs/family-reference.md`. Read it before copying anything out of here into
another repo, and before treating a difference between two repos as drift.

Read before making design decisions:

- `docs/architecture.md` - layers, design principles
- `docs/datamodel.md` - predicator commitment, upstream seams
- `docs/observability.md` - debuggability seams the interpreter must keep (ADR-0012)
- `docs/persistence.md` - the interned-index hazard, chart identity, migration (ADR-0052)
- `docs/testing.md` - conformance corpus, regression ratchet
- `docs/workflow.md` - model roles, beads, worktrees
- `docs/family-reference.md` - which agent-facing sections the sibling repos
  copy, verbatim or adapted, and which are deliberately not copied
- `docs/adr/` - the reasoning; cite ADR numbers instead of re-arguing them

## Build & Test

```bash
mix quality --profile loop   # inner loop: format, compile, credo, changed-scope tests
mix quality                  # full gate: + dialyzer, deps audit, full suite w/ coverage
mix quality --format json --report -   # machine-readable results
mix test                     # internal tests only (scion/w3c excluded by default)
mix test --include scion --include scxml_w3   # full conformance run
mix test.regression          # ratchet: registry tests must pass (once corpus lands)
```

Toolchain and repo tasks live in `mise.toml`: `mise install` provisions Erlang,
Elixir, and the JRE Saxon needs; `mise run corpus` regenerates the conformance
corpus (`mise tasks` lists the stages, `tools/corpus/README.md` explains them);
`mise run spec:fetch` populates the local spec cache described under
Conventions below.

Run `mix quality --profile loop` between edits; full `mix quality` must be green
before any commit. The Format stage runs in check mode (`format: [check: true]`
in `.quality.exs`): drift fails the gate and nothing is rewritten, so run
`mix format` yourself before committing. See the ExQuality section at the end
of this file for the rules the gate expects you to follow.

## Conventions

- W3C SCXML spec: https://www.w3.org/TR/scxml/ - interpreter functions keep the
  Appendix D names in snake_case; deviations from pseudocode are semantic bugs
  unless an inline comment cites the mechanical (effects-related) reason.
  **Read the spec locally rather than from memory.** A cache of it lives at
  `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/` -
  the same directory from every worktree and from the main checkout - holding
  `scxml-rec.html` (the whole REC, for normative clauses like 5.9.1) and
  `appendix-d.txt` (the extracted pseudocode, one block per procedure). Run
  `mise run spec:fetch` when it is absent: it is per-clone and deliberately
  never committed, so a fresh clone starts without it. `tools/spec/README.md`
  explains the layout and why it lives under `.git`. Quote the clause you are
  citing; recalled spec text has been wrong here before.
- Errors are events: evaluations return `{:ok, v} | {:error, e}`; only the
  interpreter raises `error.execution`. Never rescue-to-default at a leaf.
- Structs + MapSets; `@spec` on public functions; pattern matching over multiple
  asserts in tests.
- Generated IDs are UXIDs (`sess_`, `send_`, `inv_` prefixes), created once per
  entity, immutable.
- Functions taking a state/session put it as the first argument (pipeline
  threading).
- XML in tests: triple-quoted heredocs, 4-space base indentation.
- Scratch directories in tests: `@tag :isolated_tmp_dir` (`Statifier.TmpDir`), never
  ExUnit's `@tag :tmp_dir`.
- Sabotage every new test that asserts `lib/` behavior: break the code it covers,
  confirm it goes red, revert, and note the mutation in one line above the test -
  `# sabotage: enter_states/2 skips the initial child -> red`. Generated corpus
  files are exempt; harness plumbing states its exemption (`# sabotage: n/a - ...`)
  rather than omitting the line. See `docs/testing.md`.
- Commit messages: title < 50 chars, simple present tense ("Adds ...", "Fixes ..."),
  body wrapped at ~72 chars, functional changes highlighted. No AI attribution
  trailers.
- Changelog: user-facing changes get a fragment at `changelog.d/<issue-id>.md`;
  never edit `CHANGELOG.md` outside a release. Most changes need no fragment -
  see `changelog.d/README.md`. Releases follow SemVer from 2.0.0 on
  (ADR-0066); a release assembles the fragments, deletes them, and tags.

<!-- usage-rules-start -->
## ExQuality (`mix quality`)

Full reference: `deps/ex_quality/usage-rules.md`. Read it when a stage fails in a
way its own output does not explain, or when you need the JSON report shape.

The rules that do not wait to be looked up:

- **Never truncate the output.** No `| tail`, `| head`, `| grep`. A passing stage
  costs one line and detail prints only for failures, so truncating removes
  findings, not noise.
- **Read the `○` lines.** A skipped stage is not a passing one, and the reason
  says whether the gap is in this run or in what the project checks at all.
- **A scoped or `--quick` green is not a full green.** Neither measures coverage.
  Run a bare `mix quality` before reporting work complete.
- **Never go green by weakening the check.** Not by lowering a coverage or
  security threshold, not by `--skip` flags or `enabled: false`, not by
  `@tag :skip` on a failing test, not by narrowing scope. If a finding is
  genuinely wrong for this project, say so and let the user decide.
<!-- usage-rules-end -->

### The last two rules are checked, not just stated

The block above is synced from the dependency, so this repo's half lives here.
ADR-0011 makes both rules mechanical:

- **A guarded change needs a ledger entry.** The `Gate guard` stage
  (`mix gate.check`) fails when the branch edits `.quality.exs`, `.credo.exs`,
  `coveralls.json`, `.sobelow-conf`, `.doctor.exs`, a gate-relevant `mix.exs`
  line, adds a `@tag :skip`, or shrinks `test/passing_tests.json` without an
  entry in `docs/quality-gate-changes.md` naming that path. The entry is a
  human's call on the record, not one an agent writes for itself.
  `.doctor.exs` is guarded for the same reason `.sobelow-conf` is: it holds
  thresholds the gate enforces, so moving one is a decision rather than a
  tweak.
- **Prove the run was a full gate.** `mix gate.verify` runs the gate and exits
  non-zero if the run was profiled, scoped, `--quick`, or `--skip`-ed. Report a
  full green off its output, not off a run you remember being unscoped.

### Which skipped stages are gaps and which will never apply

"Read the `○` lines" above splits a skipped stage two ways; the kit splits it
three, and the third is a claim this project makes rather than a fact about the
run. The manifest holds the mechanism in `gate.project_level_skips` and
`gate.not_applicable_skips`; per ADR-0017 point 6, the policy behind each
pattern is recorded here, because a key that reclassifies what blocks is a
decision and not a constant.

- **Not applicable** (`gate.not_applicable_skips`) - the stage will never run
  here, no matter who works on the repo. Gettext is one member: statifier-ex
  is an SCXML engine library with no user-facing strings and no `.po` files, and
  gettext is translation tooling for applications. The two `.po` patterns are
  the same declaration reached by a different stage message. Nothing closes this
  "gap" because there is no gap - so `/wurk:commit` reports and `/wurk:mr`
  request bodies stop naming it, which is what keeps the remaining skip lines
  worth reading.

  The other member is `^disabled in \.quality\.exs$`, which today only ever
  matches the ADR judge. `.quality.exs:23` disables that stage on purpose, to
  avoid real `claude` CLI calls and real spend on every bare gate run; the
  `merge` profile re-enables it, and `.claude/wurk/mr.md` runs
  `mix quality --profile merge` unconditionally before every push. The stage
  runs here - only the bare gate declines to run it - so nobody should ever
  "close the gap" of the bare gate skipping it; that would be a regression
  against a deliberate design, not a fix. The skip summary string carries no
  stage name, so this pattern classifies every stage disabled in
  `.quality.exs`, not just the ADR judge specifically - `adr_judge` is simply
  the only stage disabled there today. Disabling a second stage in
  `.quality.exs` changes what this pattern silently classifies, and obliges
  whoever does it to re-argue the classification in this section rather than
  inheriting the ADR judge's answer by default.
- **Project-level gap** (`gate.project_level_skips`) - a real hole in what this
  project checks, standing open on every run. It does not block a commit, since
  gating on it would refuse every commit forever, but it stays named in every
  report so it does not go quiet. The list is empty today: Doctor was its only
  member, and st-1xz decided it rather than declaring it inapplicable -
  `:doctor` is now a dev dependency, `.doctor.exs` holds 100% thresholds on
  every axis, and `mix quality` reports Doctor as a real stage instead of the
  standing skip line. The category and its manifest key stay, because the next
  stage this project checks nothing for belongs here rather than in the
  not-applicable list. Do not move a pattern here into the not-applicable list
  to quiet a report.
- **Run-level** - neither list matches, and the gate is red. The stage should
  have run and could not.

Adding a pattern to either list means writing the reason into this section on
the same branch. A pattern that arrives with no prose is the exact failure
ADR-0017 point 6 describes, and `mix quality --profile merge` will refuse the
branch for it.
