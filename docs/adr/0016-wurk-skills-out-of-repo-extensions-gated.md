# ADR-0016: The wurk skills live in their own repo; this repo gates its extensions

Status: accepted (2026-08-09) - amends ADR-0015 in part

## Context

ADR-0015 settled the split that made this project's agent workflow reviewable:
deterministic mechanics belong in scripts, judgment stays in prose. It also
recorded where both halves lived - scripts under `.claude/scripts/`, judgment in
the `.claude/skills/**/SKILL.md` files - and made the fifth of its constraints
out of that location: anything the scripts do must be measured by *this* gate,
which is why `.quality.exs` carried a `Script tests` stage and why
`gate_applicable?` had to learn a path outside `lib/`.

That layout assumed the skills were this project's. They were not, quite. The
same set had already been hand-copied to predicator-ex and had drifted, which is
the failure ADR-0015's constraint 2 rules out *within* a repo and had no answer
for *across* repos. Wurk (`~/repos/github/wurk`) is the answer, and its own ADRs
settle the shape rather than this one restating it:

- wurk ADR-0002, *Standalone repo, installed into ~/.claude by symlink* - one
  source of truth, `install.rb` symlinks each skill and agent into `~/.claude`,
  updating is `git pull`, and the kit's minitest suite is that repo's gate.
- wurk ADR-0003, *The wurk: namespace via colon-named skill directories, not a
  plugin* - why the installed names are `wurk:commit`, `wurk:mr`, and so on, and
  why plugin packaging is deferred rather than rejected.
- wurk ADR-0004, *Project specifics enter through a JSON manifest and markdown
  extensions* - the two seams that stay in a consumer repo: `.claude/wurk.json`
  for machine-consumed constants, `.claude/wurk/<skill>.md` for domain prose a
  generic skill reads and honors. Extensions add; they never override.
- wurk ADR-0006, *Kit scripts stay Ruby-stdlib with the statifier envelope
  contract* - the scripts, the envelope, and the absolute banned-operation list
  moved wholesale, and the contract test that re-reads the ADR prose on every run
  moved with them.

Phase 2 of that migration landed here in two beads, deliberately split so the
diffs stayed readable: st-cex reduced `.claude/` to the manifest and the six
extension files, and st-6yb deleted `.claude/scripts/` and rewired the gate off
it. What neither of those commits carried, and what the wurk ADRs correctly
decline to decide for a consumer, is the question ADR-0015 owned: what this
repo's gate still measures.

## Decision

**The skills and the kit are not in this repository, and what remains judged
here is the extension surface, `.claude/wurk/**`.**

Concretely:

1. `~/.claude/skills/wurk:*` are symlinks into `~/repos/github/wurk` (wurk
   ADR-0002). Nothing under `.claude/` in this repo is a skill. The two files
   that stay are the manifest `.claude/wurk.json` and the extensions
   `.claude/wurk/*.md` (wurk ADR-0004), and both are consumed by generic skills
   this repo does not own.

2. **ADR-0015's split stands as a principle and is amended in two places.** The
   principle - mechanics in scripts, judgment in prose, and a script that spans
   a policy seam is the failure mode - is unchanged and is now enforced for
   every consumer instead of one. What changes is location and measurement.
   ADR-0015's location clause (`.claude/scripts/`, `.claude/skills/**/SKILL.md`)
   is superseded by wurk ADR-0002 and ADR-0004; its constraint 5 ("anything the
   scripts do must be measured by the gate") is honored by wurk's gate rather
   than by `mix quality`.

3. The gate changes st-6yb made are the mechanical form of point 2, and this is
   their rationale. `.quality.exs` drops the `Script tests` stage, because the
   suite it ran now lives in another repo with its own gate and retargeting was
   not available; the ADR-0011 ledger entry for that removal is dated 2026-08-09
   under st-6yb. `gate.also_gated_paths` in `.claude/wurk.json` is emptied,
   because neither path it named still exists. `Mix.Statifier.AdrJudge`'s
   ADR-0015 constraint-4 scope moves from `.claude/skills/**/SKILL.md` to
   `.claude/wurk/`, which is where judgment-bearing prose this repo owns lives
   now. Read that commit and this ADR together; they were split for diff
   legibility, not because they are separate decisions.

4. **Constraint 1's enforcement site is not re-created here.** ADR-0015 argued
   that re-enforcing the absolute banned-operation ban through a second, weaker
   mechanism weakens it, and named `.claude/scripts/test/contract_test.rb` as the
   permanent site. That test left with the tree it guarded. The right response
   is not a local substitute - the ADR guard is still the wrong shape for a
   whole-tree ban, and a grep would be worse - but the ported test in wurk (wurk
   ADR-0006), which scans the scripts this repo actually calls. Nothing in this
   repo enforces the ban, and nothing in this repo should try to.

5. **This amends ADR-0015; it does not supersede it.** ADR-0015 stays `accepted`
   and stays the record of why the split exists, why judgment is not scriptable,
   and what constraint 4 means - all of which the ADR judge still cites over
   `.claude/wurk/`. Only its location clause and its constraint 5 are overtaken.
   An ADR whose central decision survives intact is amended, not replaced, and
   calling this a supersession would invite a future reader to stop reading a
   document three of whose five constraints are still live policy.

## Consequences

- The reading order for "why does the gate no longer run the Ruby suite" is:
  this ADR, then st-6yb's commit, then the 2026-08-09 ledger entry. None of the
  three restates the wurk ADRs; they cite them.
- Agent behavior in this repo can change without a commit in this repo. A `git
  pull` in `~/repos/github/wurk` updates every installed skill. Wurk ADR-0002
  accepts that and names the trigger to revisit (consumers needing to pin
  divergent versions); this repo inherits both the convenience and the exposure.
- The manifest becomes a load-bearing interface. A generic skill that needs a
  value this repo has not declared fails at the seam rather than guessing, and
  wurk ADR-0004's add-not-override rule means pressure to change generic
  behavior surfaces as schema work upstream, not as a local fork.
- `.claude/wurk/*.md` is now the only agent prose this repo's gate judges. A
  policy call that migrates upward into a generic skill leaves this gate's reach
  entirely - which is correct (it is no longer this project's call to make) but
  is worth naming, because "the judge is green" now means less than it did on
  2026-08-06.

Two open questions are recorded here rather than guessed at, both for a
maintainer:

- **Should `.claude/wurk/` be listed in `gate.also_gated_paths`?** It is not
  today, so a branch that edits only extension prose reports "no gate
  applicable" and carves out - while `AdrJudge` holds a scope over exactly those
  paths. The mismatch is currently harmless: the judge runs only under
  `--profile merge` and skips cleanly, so nothing is silently unmeasured on a
  path anyone runs. But it is the same conflation ADR-0015's Consequences
  describe learning the expensive way under st-hzf, and it will stop being
  harmless the moment an extension-only branch is expected to be judged before
  merge. Left unchanged here because listing the path is a gate-config change
  and ADR-0011 makes that a human's call.
- **Does the ADR-0015 constraint-4 judge still have material to read?** Its
  scope was thirteen SKILL.md files; it is now six extension files that are
  mostly additive domain prose. If the judge's findings go to zero because the
  judgment-bearing prose moved upstream, the honest response is to retire the
  scope or move the check to wurk, not to leave a scope that cannot fire.
