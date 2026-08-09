# ADR-0015: Skill mechanics live in scripts, judgment lives in prose

Status: accepted (2026-08-06) - amended by ADR-0016 (2026-08-09)

**Amendment note.** [ADR-0016](0016-wurk-skills-out-of-repo-extensions-gated.md)
amends this record in two places: the location clause below (`.claude/scripts/`,
`.claude/skills/**/SKILL.md`) is superseded by wurk ADR-0002 and ADR-0004 now
that the skills and scripts live in the separate `wurk` repo, and constraint 5
("anything the scripts do must be measured by the gate") is honored by wurk's
own gate rather than by `mix quality`. The decision's principle and constraints
1-4 remain live and are still what `Mix.Statifier.AdrGuard` and
`Mix.Statifier.AdrJudge` enforce, now scoped to `.claude/wurk/`. What follows
below is the record as it stood on 2026-08-06 and is otherwise left unedited;
read it as history for the location and enforcement-site claims, and consult
ADR-0016 for how each is handled today.

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
change, or it will never fire on the branches it exists for. (As of ADR-0016:
`.claude/scripts/` and `touches_elixir.rb` both left with the kit; the carve-out
this paragraph describes is wurk's to make now, not this gate's.)

This consequence was learned the expensive way and is worth recording plainly.
st-hzf added ~8k lines of Ruby while touching no Elixir, so the carve-out fired
and a bare gate run reported green having measured nothing that changed. In the
same branch, a subagent left a Ruby test red, filed it as discovered work, and
reported its phase complete; only a hand-run caught it. Both are the same
mistake in different clothes - trusting a green signal that was never pointed at
the thing that changed.

Enforcement is layered, and deliberately not all in one place:

- Constraint 1 is mechanical, and `.claude/scripts/test/contract_test.rb` is
  its permanent, authoritative enforcement site (decided under st-biu,
  2026-08-07). The split from the ADR guard
  (`lib/mix/statifier/adr_guard.ex`) is not just the second-language cost.
  The guard is the wrong shape for this constraint: it checks only the lines
  a diff adds, honors an inline ADR-citation escape hatch, and skips when no
  base ref resolves - all correct for heuristics whose findings have
  compliant exceptions, all wrong for an absolute whole-tree ban. The test
  scans the full current content of every script on every gate run, has no
  escape hatch, and the `Script tests` stage deliberately has no skip path.
  Growing the guard a Ruby scope would re-enforce the same rule through a
  weaker mechanism, so the guard stays out of `.claude/scripts/`; a future
  constraint-1 rule is added to `contract_test.rb` only. The test also
  checks its own coverage against this ADR: every backticked operation this
  constraint names must have a matching Contract rule, so the two cannot
  drift apart silently again (they had - the write checks originally covered
  `.quality.exs` but not `.credo.exs`, `coveralls.json`, or `.sobelow-conf`).
  (As of ADR-0016: `contract_test.rb` left with the `.claude/scripts/` tree it
  guarded once the kit's mechanics moved to the `wurk` repo under st-6yb; the
  ban is enforced there now, by the ported test wurk ADR-0006 describes, and
  nothing in this repo re-enforces it - see `Mix.Statifier.AdrGuard`'s
  moduledoc for why a local substitute was deliberately not created.)
- Constraints 2, 3 and 5 are covered by the suite and by review.
- Constraint 4 is a judgment call by construction and is enforced by review.
  It is judge-shaped - deciding whether a SKILL.md rewrite quietly delegated
  a policy call is exactly what ADR-0012's propose/refute design handles -
  but the ADR judge stays scoped to `lib/statifier/` for now. Extending it
  means a second path scope (`.claude/skills/**/SKILL.md` diffs) and a
  second ADR text in its prompts, and that pays for itself only once skill
  prose churns enough for review to plausibly miss a dropped judgment step.
  When that happens, the extension goes in the judge, not in a regex: a
  script that claimed to detect swallowed judgment would itself violate this
  constraint's premise. (The extension landed: `Mix.Statifier.AdrJudge` gained
  a `.claude/skills/**/SKILL.md` scope judging this constraint - decided
  under st-laz, 2026-08-07. st-laz elected to land it early rather than wait
  for the churn trigger above to fire: the same change generalized the judge
  to a multi-ADR registry, which made a second scope nearly free, and a
  scope that exists before the churn arrives is one review does not have to
  remember to add under pressure. The trigger stands as written for any
  future constraint; it was not met here, it was overtaken.)

Costs accepted: the scripts are a second language in the repo (Ruby 2.6,
stdlib only, no gems - the only Ruby guaranteed present), a second test harness,
and a maintenance surface that drifts if the tools underneath it change - the
tmux idle classifier in particular is tested against captured ANSI fixtures that
a Claude Code CLI upgrade can invalidate. The audit's classification is a dated
snapshot in `docs/research/`; `docs/skill-automation.md` recorded which steps
could be delegated to a cheaper model and why. (As of ADR-0016: the scripts and
their maintenance surface moved to the `wurk` repo with everything else this
paragraph describes, and `docs/skill-automation.md` no longer carries that
classification - see ADR-0016 and `docs/workflow.md`'s Model roles section for
where model routing is decided today.)
