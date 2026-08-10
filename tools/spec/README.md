# Spec tooling

A local cache of the W3C SCXML REC's Appendix D pseudocode, for verifying a
ported interpreter function against the algorithm it is a port of (ADR-0002)
without re-fetching and re-stripping ~300KB of HTML every time.

## Fetching

```bash
mise run spec:fetch
```

Downloads `https://www.w3.org/TR/scxml/` and extracts the "Algorithm for
SCXML Interpretation" appendix into `appendix-d.txt` in the shared cache
directory described below: one block per datatype, global variable,
predicate, procedure, and function, in document order, with its explanatory
prose and its pseudocode preserved verbatim (the pseudocode's indentation
carries its block structure, so it is not reflowed).

The task is resumable and idempotent, matching `corpus:fetch:saxon` and
`corpus:fetch:scion`: it checks for the finished `appendix-d.txt` before
doing any network work and exits immediately if it is already there, so a
repeat run costs nothing and never triggers w3.org's rate limiter. It prints
the path either way. `mise run spec:clean` discards the cache; the next
`spec:fetch` refetches.

## Where the cache lives

**One cache, shared by every worktree, inside the common git directory.**
Both tasks resolve it as:

```
$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/
```

which is the same directory from every worktree and from the main checkout,
so the REC is fetched once per clone rather than once per branch in flight.
A per-worktree copy under `{{config_root}}` would have meant re-fetching the
same never-varying document for every branch, which is the cost this task
exists to remove.

Inside `.git` rather than beside it because **no checkout tracks anything
under `.git`, on any branch.** A `.gitignore` rule only protects the
worktrees whose checked-out `.gitignore` already carries it - a sibling
worktree on an older branch would show the extracted text as untracked and
committable. Given that the extracted subset is not redistributable (see
below), "cannot be committed by construction" is worth more than "is ignored
if you are on the right branch."

The consequence worth knowing: **nothing appears under `tools/spec/scratch/`
in your worktree, ever.** Run `mise run spec:fetch` and read the path it
prints - it prints one whether it fetched or found the cache already there.

Export `SPEC_SCRATCH` to relocate the cache; a value in the environment wins
over the derived default. Point it somewhere git does not track.

## Not vendored

Neither the fetched REC nor the extracted text is committed. The W3C
Document License permits redistributing the REC verbatim with its notices,
but an extracted subset is a derivative work the license does not cover, so
the cache stays local - the same reasoning `tools/corpus/scratch/` already
follows for the conformance corpus's upstream sources, enforced here by
location rather than by a gitignore rule.

## Layout

Committed, in every worktree:

```
tools/spec/
  extract_appendix_d.exs   REC HTML -> Appendix D plain text
  README.md                this file
```

Not committed, one copy per clone:

```
<common .git dir>/spec-cache/
  scxml-rec.html           the fetched REC
  appendix-d.txt           the extracted Appendix D pseudocode
```

`extract_appendix_d.exs` runs under plain `elixir`, not `mix run`, for the
same reason as the corpus generator scripts under `tools/corpus/`: it needs
xmerl, which Mix prunes from the code path.

If the REC's markup changes shape, the extractor raises rather than writing
a truncated file - it checks for a plausible number of procedure/function
blocks and for a few pseudocode blocks known to exist (`enterStates`,
`exitStates`, `selectTransitions`, `getChildStates`, `isDescendant`).
