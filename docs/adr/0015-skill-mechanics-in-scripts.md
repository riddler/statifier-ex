# ADR-0015: Skill mechanics live in scripts, judgment lives in prose

Status: accepted (2026-08-06)

## Context

The thirteen skills under `.claude/skills/` were, until st-hzf, ~3800 lines of
prose that a model read and then executed step by step. An audit of all of them
(`docs/research/260806-st-hzf-skill-mechanics-scripts.md`) decomposed that prose
into ~189 steps and classified each one. About 61% were deterministic mechanics:
shelling out to `bd` and parsing its output, computing disjoint area-label sets,
creating a worktree and branch, warming `deps`/`_build`/the dialyzer PLT, opening
a tmux window, detecting whether the checkout is a worktree or `main`, reading
GitHub PR state. Roughly 28% needed real judgment, and the remainder sat in
between.

Having a model drive the mechanical 61% is worse than having a script do it in
three distinct ways, and only the first is about cost:

1. It is slow and token-hungry, and it re-derives the same result every session.
2. It is **non-deterministic where determinism is the whole point.** Two skills
   that must agree - `/merge-request` and `/cleanup-worktrees` both extract bead
   ids from `^Refs:` trailers, and a PR that closes the wrong set of beads is a
   silent data error - agreed only because two prose passages described the same
   regex. Prose cross-references do not fail a test when they drift.
3. It hides which steps are load-bearing. When everything is prose, the sentence
   that encodes a real policy gate reads exactly like the sentence that says to
   run `git fetch`.

ADR-0010 (worktree-per-issue) and ADR-0011 (gate config is not agent-editable)
both put a human gate at a specific point in these workflows. Those gates live in
the *seam between* steps, which means any automation that spans a seam can
quietly relocate a decision that was deliberately placed.

## Decision

**Deterministic skill mechanics belong in scripts under `.claude/scripts/`;
judgment stays in the SKILL.md prose.** A SKILL.md says when to invoke, which
script to run, and how to read its output - and, where a step is a policy call,
it states the policy and does not delegate it.

Five constraints make that split safe rather than merely tidy:

**1. Scripts are step-scoped, and the banned-operation list is absolute.**
No script anywhere under `.claude/scripts/` may contain a code path that runs
`git push`, runs `gh pr create`, runs `bd close`, runs `bd edit`, writes
`docs/quality-gate-changes.md`, or writes `.quality.exs`, `.credo.exs`,
`coveralls.json`, or `.sobelow-conf`. CLAUDE.md's authority table draws a line
between what an agent may do alone and what needs a human ask; a script that
spanned that line would move the gate without anyone deciding to. This is why
there is no `ship.rb` and never will be: a helper that commits *and* pushes is
exactly the shape that erases the asymmetry the table exists to create.

**2. Shared mechanics have exactly one definition site.** Where two skills must
agree, they agree by calling the same code, not by describing the same behavior
twice. `lib/refs.rb` is the single definition of the `^Refs:` extraction;
`rebase_onto.rb` is the single definition of the capture-then-abort rebase.

**3. One structured envelope.** Every script emits a JSON envelope with `ok`,
`data`, `warnings`, `blocked`, and `commands`, and uses the documented exit
codes. The `commands` field keeps a run auditable without the caller having to
read raw command spew - which matters because CLAUDE.md forbids truncating gate
output, and the way to obey that without drowning is to emit less, not to filter
more.

**4. Judgment is not scriptable, and pretending otherwise is the failure mode
to avoid.** Two examples fix the boundary. The sabotage protocol
(`docs/testing.md`) requires actually breaking the code a test covers and
watching it go red; a script can check that a `# sabotage:` note *exists*, which
would convert a verification discipline into a comment-formatting rule. `gate.rb`
therefore reports missing notes as warnings that never gate. Likewise `/commit`'s
refusal on "changes unrelated to the claimed issue" has no mechanical test and
stays a prose instruction. When a step needs judgment, the script reports the
inputs and the model decides.

**5. Anything the scripts do must be measured by the gate.** A script that
drives commit and worktree mechanics is not incidental tooling; a bug in it is a
bug in the project's ability to ship correctly. `.claude/scripts/` carries a
stdlib minitest suite, and `.quality.exs` registers it as the `Script tests`
stage, with the ADR-0011 ledger entry that registering a stage requires.

## Consequences

The gate's carve-out predicate is now about **what the gate measures**, not about
what the Elixir compiler builds. `lib/touches_elixir.rb` keeps `any?` (does this
touch the Elixir build?) and adds `gate_applicable?` (does the gate have anything
to measure?), which includes `.claude/scripts/`. A future stage measuring
something else outside `lib/` must be added to `gate_applicable?` in the same
change, or it will never fire on the branches it exists for.

This consequence was learned the expensive way and is worth recording plainly.
st-hzf added ~8k lines of Ruby while touching no Elixir, so the carve-out fired
and a bare gate run reported green having measured nothing that changed. In the
same branch, a subagent left a Ruby test red, filed it as discovered work, and
reported its phase complete; only a hand-run caught it. Both are the same
mistake in different clothes - trusting a green signal that was never pointed at
the thing that changed.

Enforcement is layered, and deliberately not all in one place:

- Constraint 1 is mechanical today: `.claude/scripts/test/contract_test.rb`
  greps every script for the banned operations and fails the `Script tests`
  stage. It is a test rather than an `adr.check` rule because the existing ADR
  guard (`lib/mix/statifier/adr_guard.ex`) scans Elixir under `lib/statifier/`
  and would have to grow a second language to cover Ruby.
- Constraints 2, 3 and 5 are covered by the suite and by review.
- Constraint 4 is a judgment call by construction and is enforced by review.
  It is the natural candidate for the ADR judge (ADR-0012's mechanism), which
  is scoped to `lib/statifier/` today.

Costs accepted: the scripts are a second language in the repo (Ruby 2.6,
stdlib only, no gems - the only Ruby guaranteed present), a second test harness,
and a maintenance surface that drifts if the tools underneath it change - the
tmux idle classifier in particular is tested against captured ANSI fixtures that
a Claude Code CLI upgrade can invalidate. The audit's classification is a dated
snapshot in `docs/research/`; the living version is `docs/skill-automation.md`,
which also records which steps could be delegated to a cheaper model and why.
