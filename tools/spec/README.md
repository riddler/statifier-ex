# Spec tooling

A local cache of the W3C SCXML REC's Appendix D pseudocode, for verifying a
ported interpreter function against the algorithm it is a port of (ADR-0002)
without re-fetching and re-stripping ~300KB of HTML every time.

## Fetching

```bash
mise run spec:fetch
```

Downloads `https://www.w3.org/TR/scxml/` and extracts the "Algorithm for
SCXML Interpretation" appendix into `tools/spec/scratch/appendix-d.txt`: one
block per datatype, global variable, predicate, procedure, and function, in
document order, with its explanatory prose and its pseudocode preserved
verbatim (the pseudocode's indentation carries its block structure, so it is
not reflowed).

The task is resumable and idempotent, matching `corpus:fetch:saxon` and
`corpus:fetch:scion`: it checks for the finished `appendix-d.txt` before
doing any network work and exits immediately if it is already there, so a
repeat run costs nothing and never triggers w3.org's rate limiter.
`mise run spec:clean` discards the cache; the next `spec:fetch` refetches.

## Not vendored

Nothing under `tools/spec/scratch/` is committed. The W3C Document License
permits redistributing the REC verbatim with its notices, but an extracted
subset is a derivative work the license does not cover, so the cache stays
local and gitignored, the same reasoning `tools/corpus/scratch/` already
follows for the conformance corpus's upstream sources.

## Layout

```
tools/spec/
  extract_appendix_d.exs   REC HTML -> Appendix D plain text
  scratch/                 gitignored
    scxml-rec.html          the fetched REC
    appendix-d.txt          the extracted Appendix D pseudocode
```

`extract_appendix_d.exs` runs under plain `elixir`, not `mix run`, for the
same reason as the corpus generator scripts under `tools/corpus/`: it needs
xmerl, which Mix prunes from the code path.

If the REC's markup changes shape, the extractor raises rather than writing
a truncated file - it checks for a plausible number of procedure/function
blocks and for a few pseudocode blocks known to exist (`enterStates`,
`exitStates`, `selectTransitions`, `getChildStates`, `isDescendant`).
