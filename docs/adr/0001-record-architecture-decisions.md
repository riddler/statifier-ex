# ADR-0001: Record architecture decisions

Status: accepted (2026-08-02)

## Context

Statifier v2 is a ground-up rewrite whose direction is shaped up front (see
`docs/architecture.md`) and refined continuously during implementation, by several
people and several AI models. Decisions made in conversation evaporate; decisions
made in code are invisible until someone trips over them.

## Decision

We record architecturally significant decisions as numbered ADRs in `docs/adr/`,
one file per decision, in this format: Context, Decision, Consequences. An ADR is
amended by a new ADR that supersedes it, not by rewriting history. New ADRs are
drafted or reviewed at the direction level (Fable) per `docs/workflow.md`.

## Consequences

- The "why" survives model context windows, worktree boundaries, and time.
- Plans and PRs can cite ADR numbers instead of re-arguing settled questions.
- Superseded decisions remain visible as the path taken.
