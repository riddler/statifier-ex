# Statifier-ex extension: /wurk:plan

Success criteria this project always wants, its optional sections, and its
domain patterns. Adds only - see `~/.claude/skills/wurk:plan/SKILL.md` for
everything this does not repeat.

## Always-required automated criteria

Every phase's Automated Verification list includes, as applicable:

- Full `mix quality` as the per-phase gate.
- `mix quality --profile loop` named as the command to use while iterating
  (not as a phase gate - `mix quality --profile loop` alone never satisfies a
  phase).
- `mix quality --format json --report -` when a later agent needs to route on
  the results programmatically.
- Whenever a phase can move conformance results: `mix test.regression` and
  `mix test.baseline add` for the ratchet.

## Always-required manual criteria

Every phase touching `lib/statifier/` includes a manual criterion for
spec-conformance judgment: the touched functions match the W3C Appendix D
pseudocode line for line.

## The Appendix D rule

For interpreter work, deviations from the Appendix D pseudocode are semantic
bugs unless mechanically required (ADR-0002). A plan touching the interpreter
must say which deviation, if any, and why it is mechanically necessary rather
than leaving it for the implementer to discover.

## Optional sections this project's plans carry

Include only when they apply:

- `## Corpus/Ratchet Notes` - corpus regeneration or `test/passing_tests.json`
  changes.
- `## Performance Considerations` - performance implications or optimizations.

## Phase-splitting along the pipeline's module boundaries

Beyond the generic module-boundary guidance, this project's boundaries are:
parser vs interpreter vs corpus tooling. Splitting along these lets phases
parallelize across worktrees per `docs/workflow.md`.

## Reference checkout

Say explicitly, in a phase or in a research sub-agent's prompt, when it should
look at `../statifier` (v1, read-only reference) rather than this repo. Only
point an agent there when the question involves v1 behavior specifically.

## Common patterns

**New SCXML element**: add the lowering builder under
`lib/statifier/lowering/`; extend the Document structs and validator checks;
extend the compiler/Machine if the element affects runtime structure; wire
interpreter behavior while keeping the Appendix D structure; add internal
tests plus ratchet any newly passing conformance tests.

**Interpreter feature**: start from the Appendix D pseudocode for the affected
functions; port literally, noting any mechanical deviation with an inline
comment; effects out, never side effects in the core (ADR-0003); verify
against SCION/W3C tests before ratcheting.

**Refactoring**: document current behavior; plan incremental changes; keep the
conformance suites green throughout; include a ratchet/regression strategy.
