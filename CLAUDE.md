# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## What this project is

Statifier v2: a ground-up rewrite of the SCXML statecharts engine at
`../statifier` (v1, read-only reference). The rewrite is a literal port of the
W3C SCXML Appendix D algorithm over a pure functional core. Always refer to
state machines as **state charts**.

Read before making design decisions:

- `docs/architecture.md` - layers, design principles
- `docs/datamodel.md` - predicator commitment, upstream seams
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

Run `mix quality --profile loop` between edits; full `mix quality` must be green
before any commit. Run `mix format` after writing any Elixir file.

## Model roles

- **Fable**: direction - architecture, ADRs, spec interpretation, phase review.
- **Opus**: planning - `/create-plan`, `/iterate-plan`.
- **Sonnet**: implementation - `/implement-plan`, mechanical ports, corpus work.

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
- Commit messages: title < 50 chars, simple present tense ("Adds ...", "Fixes ..."),
  body wrapped at ~72 chars, functional changes highlighted. No AI attribution
  trailers.

## Parallel work

One beads issue = one branch = one worktree under `../statecharts_2-worktrees/`
named `<beads-id>-<slug>`. Claim the issue before creating the worktree; split
work along module boundaries; every worktree runs the same quality gate. See
`docs/workflow.md` and ADR-0010.
