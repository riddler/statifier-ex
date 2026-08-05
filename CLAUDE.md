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

## Agent authority in this repo

**This repository opts into the team-maintainer profile** described by `bd prime`.
Conservative stays the default everywhere else: a clone of a repo
that has not written an opt-in like this one gets the conservative rules, and so
does this repo for any action the table below does not name.

The grant is per action, and every action has a trigger. Authority is not
blanket - an action whose trigger has not fired is still unauthorized, and an
explicit "do not commit", "do not push", or equivalent from the current user or
orchestrator overrides every row here.

| Action | Trigger | Still unauthorized when |
|---|---|---|
| `bd` task tracking (`create`, `claim`, `update`, `note`) | any time | never - this is the default profile too |
| `mix quality` in any profile | any time | never - running the gate costs nothing but time |
| `git commit` on the issue's worktree branch | the claimed issue's work is complete **and** full `mix quality` is green; a change touching no Elixir code has no gate to run and may commit on review of the diff alone | on `main`, on a red gate, on a `--quick` or `--test-scope changed` run, or with unrelated changes in the tree |
| `git rebase` onto `origin/main` in a worktree (`/refresh-worktree`) | a branch landed on `origin/main` | a conflict appears - abort and report, do not resolve unasked |
| `git push`, `gh pr create` (`/merge-request`) | the user asks for it in their own words | inferred from "the work is done"; finishing an issue is not a request to publish it |
| `bd close <id>` | the issue's branch is merged into `origin/main`, verified against the remote | at commit time, at PR-open time, or on a local merge that has not been pushed |
| `bd dolt push` | bead state changed locally **and** the git side of the same change has already reached `origin` | as a way to publish beads for work that is not on `origin/main` yet |
| `git worktree remove`, branch delete | the branch is merged and the worktree is clean | uncommitted or unpushed work is present |

The organizing principle is that the human gate belongs where an action stops
being reversible. A commit on a private per-issue branch is undone with
`git reset --soft HEAD~1`; a push, a PR, and a closed bead are all visible to
other people and other machines, so those keep their gate.

In `/implement-plan --loop` mode, each phase's own green automated gate counts
as "the claimed issue's work is complete" for that increment's commit - the
table's existing conditions (worktree branch, green gate, no unrelated
changes) apply identically per phase; this only changes the granularity at
which completeness is judged. See
`.claude/skills/implement-plan/SKILL.md`'s `## Looped Execution Mode`.

## Non-interactive shell commands

`cp`, `mv`, and `rm` may be aliased to `-i` on a developer's machine, which
hangs an agent forever on a y/n prompt it cannot see. Always pass the
non-interactive form: `cp -f`, `mv -f`, `rm -f`, `rm -rf`, `cp -rf`. Same for
`scp` and `ssh` (`-o BatchMode=yes`), `apt-get` (`-y`), and `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

Also avoid `bd edit`, which opens `$EDITOR` and blocks. Use
`bd update <id> --title/--description/--notes/--design` instead.

## What this project is

Statifier v2: a ground-up rewrite of the SCXML statecharts engine at
`../statifier` (v1, read-only reference). The rewrite is a literal port of the
W3C SCXML Appendix D algorithm over a pure functional core. Always refer to
state machines as **state charts**.

Read before making design decisions:

- `docs/architecture.md` - layers, design principles
- `docs/datamodel.md` - predicator commitment, upstream seams
- `docs/observability.md` - debuggability seams the interpreter must keep (ADR-0012)
- `docs/testing.md` - conformance corpus, regression ratchet
- `docs/workflow.md` - model roles, beads, worktrees
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
corpus (`mise tasks` lists the stages, `tools/corpus/README.md` explains them).

Run `mix quality --profile loop` between edits; full `mix quality` must be green
before any commit. The gate formats your code for you - do not run `mix format`
as a separate step. See the ExQuality section at the end of this file for the
rules the gate expects you to follow.

## Conventions

- W3C SCXML spec: https://www.w3.org/TR/scxml/ - interpreter functions keep the
  Appendix D names in snake_case; deviations from pseudocode are semantic bugs
  unless an inline comment cites the mechanical (effects-related) reason.
- Errors are events: evaluations return `{:ok, v} | {:error, e}`; only the
  interpreter raises `error.execution`. Never rescue-to-default at a leaf.
- Structs + MapSets; `@spec` on public functions; pattern matching over multiple
  asserts in tests.
- Generated IDs are UXIDs (`sess_`, `send_`, `inv_` prefixes), created once per
  entity, immutable.
- Functions taking a state/session put it as the first argument (pipeline
  threading).
- XML in tests: triple-quoted heredocs, 4-space base indentation.
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
  see `changelog.d/README.md`. `mix.exs` stays `2.0.0-dev`; no alpha/beta/rc.

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
  `coveralls.json`, `.sobelow-conf`, a gate-relevant `mix.exs` line, adds a
  `@tag :skip`, or shrinks `test/passing_tests.json` without an entry in
  `docs/quality-gate-changes.md` naming that path. The entry is a human's call
  on the record, not one an agent writes for itself.
- **Prove the run was a full gate.** `mix gate.verify` runs the gate and exits
  non-zero if the run was profiled, scoped, `--quick`, or `--skip`-ed. Report a
  full green off its output, not off a run you remember being unscoped.
