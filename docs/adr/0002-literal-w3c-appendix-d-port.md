# ADR-0002: Port the W3C SCXML algorithm literally (Appendix D)

Status: accepted (2026-08-02)

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
`enter_states`, `exit_states`, `exit_interpreter`, `is_in_final_state`. Adaptations
required by the pure-core design (ADR-0003) are documented inline where they
deviate mechanically (e.g. returning effects instead of performing I/O), never
semantically. This includes the parts v1 lacked entirely: the `running` flag,
top-level termination, `done.state.*` generation, and `<donedata>`.

## Consequences

- Conformance debugging becomes "diff the function against the pseudocode".
- One code path for internal/external/targetless transitions via the domain.
- The spec's data-structure assumptions follow (ADR-0005: full configuration).
- Code reviewers can review against a public reference document.
