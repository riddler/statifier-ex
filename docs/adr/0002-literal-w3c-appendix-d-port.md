# ADR-0002: Port the W3C SCXML algorithm literally (Appendix D)

Status: accepted (2026-08-02) - amended 2026-08-09 (predicate naming)

## Context

v1's interpreter was an independent re-derivation of SCXML semantics, not a port of
the spec's Appendix D pseudocode. None of the spec's function names existed. Exit
sets were computed by four heuristic predicates instead of the spec's single
"descendants of the transition domain" rule; internal, external, and targetless
transitions had three separate code paths; conflict resolution discarded
non-conflicting transitions from parallel regions ("for simplicity" comments in
code). The conformance long tail (37 failing SCION tests, 32 failing W3C tests)
traced almost entirely to these divergences, and debugging meant reverse-engineering
heuristics rather than reading the spec.

## Decision

The v2 interpreter is a function-for-function port of Appendix D, keeping the
spec's names in snake_case: `main_event_loop`, `select_transitions`,
`select_eventless_transitions`, `remove_conflicting_transitions`,
`get_transition_domain`, `compute_exit_set`, `compute_entry_set`,
`add_descendant_states_to_enter`, `add_ancestor_states_to_enter`, `microstep`,
`enter_states`, `exit_states`, `exit_interpreter`, `in_final_state?`. Adaptations
required by the pure-core design (ADR-0003) are documented inline where they
deviate mechanically (e.g. returning effects instead of performing I/O), never
semantically. This includes the parts v1 lacked entirely: the `running` flag,
top-level termination, `done.state.*` generation, and `<donedata>`.

**Boolean predicates take Elixir's `?` form.** *(Amended 2026-08-09.)* The
snake_case rule above transliterates every name except the spec's `isFoo`
predicates, where a literal transliteration collides with the language. Elixir
reserves the `is_` prefix for guard-safe macros, and
`Credo.Check.Readability.PredicateFunctionNames` - enabled `strict: true` under
ADR-0009, and not agent-editable under ADR-0011 - rejects both `is_in_final_state`
and `is_in_final_state?` on an ordinary `def`. So an `isFoo` predicate drops the
prefix and gains a trailing `?`: `is_in_final_state` as originally written above
is `in_final_state?`, and likewise `isAtomicState` is `atomic?`, `isCompoundState`
`compound?`, `isDescendant` `descendant?`, `isHistoryState` `history?`,
`isParallelState` `parallel?`, `isFinalState` `final?`. This is orthographic, not
semantic: the function still ports its pseudocode counterpart argument for
argument and result for result, so "diff the function against the pseudocode"
survives intact. Each such function names its Appendix D counterpart in its
`@doc` so the diff stays mechanical for a reader working from the spec. Nothing
here licenses a *semantic* deviation in a predicate - `descendant?` is
`isDescendant`'s proper-descendant test, not a self-inclusive one.

## Consequences

- Conformance debugging becomes "diff the function against the pseudocode".
- One code path for internal/external/targetless transitions via the domain.
- The spec's data-structure assumptions follow (ADR-0005: full configuration).
- Code reviewers can review against a public reference document.
- Predicate ports read as ordinary Elixir and pass the gate unmodified, at the
  cost of one lookup (the `@doc`) between an `isFoo` in the pseudocode and a
  `foo?` in the tree.
