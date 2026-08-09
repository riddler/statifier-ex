# Statifier-ex extension: /wurk:iterate

Deliberately thin. `/wurk:iterate` already reads `.claude/wurk/plan.md`, so
this file does not duplicate the criteria or sections stated there - see that
file for the always-required success criteria, the optional sections, and the
domain patterns a re-cut phase must still follow.

## Preserve the corpus/ratchet criteria when re-cutting phases

If a plan being iterated on carries `## Corpus/Ratchet Notes` or ratchet
criteria (`mix test.regression`, `mix test.baseline add`) in a phase being
split or reworked, carry those criteria into the resulting phase(s) rather
than dropping them. A re-cut phase that silently loses its ratchet step is a
regression in the plan, not a simplification of it.

## ADR contradiction

`~/.claude/skills/wurk:iterate/SKILL.md` already states the generic rule -
flag, never silently edit, a change that would contradict an accepted ADR -
so it is not restated here.
