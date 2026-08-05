---
date: 2026-08-05T10:05:21-0600
researcher: Claude
git_commit: c83c06a61dbd73e7d500c347be122f1c552483f7
branch: st2-2yx-narrower-phase-agent-type
repository: statifier_2
beads_issue: st2-2yx
topic: "Should implement-plan's per-phase subagent get a narrower agent type instead of a prompt-level constraint?"
tags: [research, skills, agents, implement-plan, work, subagents]
status: complete
last_updated: 2026-08-05
last_updated_by: Claude
---

# Decision: keep `general-purpose` for implement-plan's per-phase subagent

**Date**: 2026-08-05T10:05:21-0600
**Git Commit**: c83c06a61dbd73e7d500c347be122f1c552483f7
**Branch**: st2-2yx-narrower-phase-agent-type
**Beads Issue**: st2-2yx

Placement note: this is a decision about the agent harness in `.claude/`, not
about the engine or the development process architecture that `docs/adr/`
governs (quality gates, worktrees, issue tracking are all repo-wide process;
this is one dispatch parameter inside one skill) - so it lands here as a
research/decision document naming the bead, per the Direction stage's rule.

## Question

`.claude/skills/implement-plan/SKILL.md`'s Looped Execution Mode spawns its
per-phase subagent as `general-purpose` (tools: `*`) and relies on a prompt
instruction (landed by st2-4k4) to forbid that subagent from delegating the
phase or re-invoking `/implement-plan` or `/work`. Should that prompt-level
constraint become a tool-level one - a narrower agent type in
`.claude/agents/` with Edit/Write/Bash/Read but no Agent/Skill, or an Agent
tool trimmed so it cannot invoke Skill?

## Decision

**Keep `general-purpose`. The prompt-level constraint stands; do not build a
narrower agent type now.** This confirms the provisional call recorded in
st2-4k4's notes and inline in `implement-plan/SKILL.md` next to the
Agent-dispatch line, now on the strength of an actual harness evaluation
rather than a scope deferral. The follow-on edit this implies: none.

Three findings drive it, in order of weight:

1. **The tool-level restriction is not the guarantee it appears to be.** The
   harness does support the mechanism - but only one level deep, and it does
   not cover the hazard's other pathway at all (details below). The prompt
   instruction stays load-bearing either way, so the narrower type adds a
   second enforcement layer, not a replacement.
2. **Both sides of the trade are theoretical, and the status quo wins a
   theoretical trade.** st2-4k4 did not reproduce the nested-delegation
   failure (0 Agent/Skill tool_use across all three st2-00p.9 phase
   subagents), and the same evidence shows the "use sub-tasks sparingly"
   allowance also went unused. No observed hazard, no observed cost - and the
   harness's own depth cap plus `/commit --auto`'s independent checks already
   bound the worst case.
3. **A whitelist type has real carrying costs** - tool enumeration risk,
   model-tier duplication, roster spillover, and one more file for
   `work/SKILL.md`'s stage-contract table warning to apply to.

## Harness facts (verified via the claude-code-guide agent, 2026-08-05)

Checked against https://code.claude.com/docs/en/sub-agents.md rather than
guessed:

- **`tools:` in `.claude/agents/*.md` frontmatter is a hard whitelist.** When
  present, the subagent gets only the listed tools; omitted, it inherits
  every tool available to subagents, which includes both `Agent` and `Skill`.
- **`Agent` and `Skill` are independently excludable.** A type with
  `tools: Agent, Read, Edit, Write, Bash, Grep, Glob` is expressible: it can
  spawn sub-tasks but cannot invoke slash commands. So the "keep Agent, drop
  Skill" middle option is real, not wishful.
- **But the exclusion holds for the agent itself, not its subtree.** Each
  spawned subagent resolves its tools from its own definition; a phase agent
  without `Skill` that spawns a `general-purpose` debugging sub-task hands
  that sub-task the full toolset, `Skill` included.
- **There is no `Skill(...)` matcher.** The `Skill` tool is all-or-nothing;
  "may invoke skills except /implement-plan and /work" is not expressible.
- **`Agent(agent_type)` trimming exists** (restricting which subagent types
  may be spawned), but the docs scope it to an agent running as the main
  thread; whether it binds a subagent's own `Agent` tool is not documented.
  Treated as unverified for this use, and recorded as the open question below.
- **The default spawn-depth cap is 3 layers**, and at the limit the `Agent`
  tool is withheld. The per-phase subagent already sits at layer 2
  (`/work` main -> implement subagent -> per-phase subagent, per
  `work/SKILL.md` Step 4), so anything it spawns is the last layer that can
  exist. A runaway re-dispatch cannot recurse past one extra level.

## Why the hard guarantee is thinner than the bead's framing

The hazard st2-4k4 hypothesized has two pathways:

- **Skill re-entry**: the phase agent invokes `/implement-plan` (or `/work`)
  itself. Dropping `Skill` closes this one at tool level, genuinely.
- **Plain delegation**: the phase agent spawns a `general-purpose` subagent
  with a prompt like "implement phases 2-5 of this plan". No `Skill` use
  involved - only the `Agent` tool, which the middle option deliberately
  keeps for the debugging allowance. Only the prompt instruction covers this
  pathway, and it also covers the sub-task loophole above (the phase prompt's
  rule travels with the phase agent's judgment about what it asks sub-tasks
  to do).

So the honest accounting is: the narrower type converts one of two pathways
from prompt-level to tool-level, for the agent itself only, while the prompt
instruction remains necessary for everything else. That is a real but small
hardening - to be weighed against costs, not taken as "the guarantee".

## Severity if the prompt instruction ever fails

Bounded on two independent axes:

- **Depth**: a nested `/implement-plan --loop` at layer 2 dispatches its
  phases at layer 3, where the harness withholds `Agent` - the recursion
  terminates by construction.
- **The gate**: `/commit`'s own checks (full `mix quality`, sabotage notes,
  branch/issue checks, ADR-0011's gate guard) run for real wherever they are
  invoked from. A nested loop committing "outside the orchestrator" still
  cannot commit red, unsabotaged, or gate-weakened work. The damage is
  duplicated work, confusing bead notes, and wasted tokens - waste, not
  corruption.

This matches where CLAUDE.md's authority table already draws the line: the
repo's enforcement pattern is independent verification at the irreversible
action (the orchestrator runs `/commit --auto` regardless of the subagent's
self-report), not capability removal from the subagent. A tool-level
restriction would be a new enforcement style for this repo, adopted against a
hazard that has not been observed.

## Costs of the narrower type (why it loses the close call)

- **Enumeration risk.** `general-purpose` is `*`; a whitelist must name every
  tool a phase might legitimately need (TodoWrite, WebFetch for spec URLs,
  ToolSearch, NotebookEdit, ...). Under-enumeration fails mid-phase in a
  future run, in exactly the unattended mode where nobody is watching - a
  more likely failure than the one the restriction prevents.
- **Sync surface.** The type's `model: sonnet` frontmatter duplicates the
  tier scheme a second place; `work/SKILL.md` Step 3 already warns what
  happens when a table and the frontmatter that actually runs diverge. One
  more file to keep honest.
- **Roster spillover.** Project agent types are visible to every session and
  their `description` drives automatic delegation; a `phase-implementer` type
  invites dispatch from contexts outside the loop it was designed for.

## What would change this call

Revisit (reopen against this document) if any of these happens:

1. **An observed incident**: transcript evidence of a phase subagent actually
   invoking `Agent` or `Skill` to delegate its phase, despite the prompt
   instruction. One real occurrence outweighs this document's
   theoretical-vs-theoretical reasoning.
2. **The harness closes the subtree loophole**: a `Skill(...)` matcher, or
   confirmation that `Agent(agent_type)` trimming binds subagents' own
   `Agent` tools. Then a `phase-implementer` type with `Skill` dropped and
   `Agent` trimmed to the read-only research types (`codebase-analyzer`,
   `codebase-locator`, `codebase-pattern-finder` - none of which hold `Agent`
   or `Skill` themselves) would be a genuine subtree guarantee that still
   preserves the debugging allowance, and the trade flips.
3. **The debugging allowance proves dead in practice** across several more
   looped runs (it is at 0 uses in 3 phases so far - too small a sample to
   delete it on). If it stays unused, the simpler narrowing is dropping
   `Agent` and `Skill` both, which sidesteps the subtree loophole entirely at
   the price of the allowance.

## References

- `.claude/skills/implement-plan/SKILL.md` - Looped Execution Mode step 2:
  the per-phase prompt contract, the do-not-delegate bullet (st2-4k4), and
  the inline agent-type-vs-prompt note this document confirms.
- `.claude/skills/work/SKILL.md` - Step 3 stage-contract table and its
  divergence warning; Step 4 layer accounting (main -> implement -> phase).
- `.claude/agents/*.md` - the six existing project types, all read-only
  research agents; frontmatter shape is `name`/`description`/`tools`/`model`.
- `CLAUDE.md`, "Agent authority in this repo" - subagents report satisfied
  triggers, they do not act on them; the orchestrator's `/commit --auto` is
  the independent gate.
- Bead st2-4k4 notes - the transcript evidence (5 sub-transcripts, spawn
  depths, 0 Agent/Skill tool_use in phase subagents) and the provisional
  call this evaluation confirms.
- https://code.claude.com/docs/en/sub-agents.md - `tools:` whitelist
  semantics, per-subagent tool resolution, `Agent(agent_type)` syntax,
  spawn-depth cap.

## Open Questions

- Whether `Agent(agent_type)` trimming in a `.claude/agents/*.md` `tools:`
  list restricts which types a *subagent* may spawn, or only applies to an
  agent running as the main thread. The docs describe the main-thread case;
  the subagent case is undocumented. If it does bind subagents, option 2
  under "What would change this call" becomes buildable today.
