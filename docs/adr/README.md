# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | accepted |
| [0002](0002-literal-w3c-appendix-d-port.md) | Port the W3C SCXML algorithm literally (Appendix D) | accepted (amended 2026-08-09: predicate naming) |
| [0003](0003-pure-core-with-effects.md) | Pure functional core returning effects | accepted |
| [0004](0004-predicator-as-the-datamodel.md) | Predicator is the datamodel; no ECMAScript, no Elixir eval | accepted |
| [0005](0005-full-configuration-and-interned-state-indexes.md) | Full configuration; interned state indexes | accepted |
| [0006](0006-reuse-conformance-corpus-and-regression-ratchet.md) | Reuse conformance corpus and ratchet; commit a generator | accepted |
| [0007](0007-beads-for-issue-tracking.md) | Beads for issue tracking | accepted |
| [0008](0008-uxid-for-identifiers.md) | UXID for generated identifiers | accepted |
| [0009](0009-ex-quality-as-quality-gate.md) | ex_quality is the quality gate | accepted |
| [0010](0010-worktree-parallel-development.md) | Worktree parallel development via beads | accepted |
| [0011](0011-quality-gate-config-not-agent-editable.md) | Quality gate config is not agent-editable | accepted |
| [0012](0012-debuggability-designed-into-the-core.md) | Debuggability is designed into the core | accepted |
| [0013](0013-archive-v1-statifier-repo-in-place.md) | Archive the v1 statifier repo in place | accepted |
| [0014](0014-expression-spans-in-cond-diagnostics.md) | Expression-level spans are part of the retained-location constraint | accepted |
| [0015](0015-skill-mechanics-in-scripts.md) | Skill mechanics live in scripts, judgment lives in prose | superseded by 0017 (amended in part by 0016) |
| [0016](0016-wurk-skills-out-of-repo-extensions-gated.md) | The wurk skills live in their own repo; this repo gates its extensions | accepted (amends 0015 in part; amended by 0017) |
| [0017](0017-judgment-not-scriptable-in-wurk-extensions.md) | Judgment is not scriptable, scoped to the wurk extension surface | accepted (supersedes 0015; amends 0016 in part) |
| [0018](0018-no-process-jargon-in-code-comments.md) | Process artifacts are not code comments | accepted |
| [0019](0019-macrostep-round-budget.md) | A round budget bounds the macrostep fold | accepted (amended in part by 0020: round ordinal) |
| [0020](0020-round-ordinal-joins-the-step-counters.md) | A round ordinal joins the step counters | accepted (amends 0019 in part) |
| [0021](0021-donedata-content-expr-failure-yields-no-data.md) | A failed donedata content expr yields no data | accepted |
| [0022](0022-parallel-is-never-the-lcca.md) | A parallel is never the LCCA; SCION's contrary tests leave the corpus | accepted |
| [0023](0023-numeric-type-fixes-upstream-not-boundary-coercion.md) | Numeric-type gaps are fixed in predicator, never coerced at the boundary | accepted |
| [0024](0024-data-src-is-never-fetched.md) | `<data src>` is never fetched | accepted |
| [0025](0025-cross-repo-tracker-authority-and-mirrors.md) | Tracker authority follows the artifact; mirrors pull (adopts predicator ADR-0010) | accepted |

New ADRs: next number, same three-section format (Context, Decision, Consequences),
drafted or reviewed at the direction level per `docs/workflow.md`.
