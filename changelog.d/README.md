# Changelog fragments

Changelog entries for unreleased work live here as one file per issue, not as
edits to `CHANGELOG.md`. At release the fragments are assembled into a single
version section and deleted.

## Why fragments

Parallel work happens in one worktree per issue (ADR-0010), so several branches
are usually open at once. If each branch appended to the `## [Unreleased]` block
at the top of `CHANGELOG.md`, every branch would touch the same few lines of the
same file and nearly every pull request would conflict with every other one.

A fragment is named after its issue, so no two branches ever write the same file
and the conflict cannot happen.

## When a change needs a fragment

The changelog serves **people who use the library**. Repo history is git's job,
and work tracking is beads' job. Neither belongs here.

Write a fragment for:

- a public API addition, change, or removal
- a change in observable behavior
- an SCXML feature becoming supported
- a bug fix a user could have noticed
- anything breaking

Do **not** write a fragment for:

- test harness, corpus tooling, or conformance fixtures
- documentation, ADRs, or plans
- internal refactors with no visible effect
- quality gate, CI, or agent tooling changes

If you are unsure, ask whether someone who only ever calls the public API could
tell the difference. If not, skip it.

### While v2 is unreleased

Version 2.0.0 replaces the entire engine, so its changelog entry is a **migration
document** for 1.x users, not a transcript of the rewrite. Someone upgrading does
not benefit from a line per interpreter function that landed - to them the whole
engine is new.

So during the rewrite the rule is narrower: **write a fragment when v2 differs
from v1.** A removed feature, a changed public API, different behavior for the
same input, or a capability v1 never had. Re-implementing something v1 already
did is invisible to a user and gets no fragment.

Rewrite progress is tracked by beads phases and by the regression ratchet
(`test/passing_tests.json`), which are better signals than a changelog anyway.

The rule widens by one clause under the SHA-pinning contract (ADR-0061
decision 3): a change that breaks code or persisted data written against an
earlier `main` SHA gets a fragment touch too, even when it re-touches a
v2-only feature that already has one. Make that touch by editing the issue's
existing fragment in place, not by appending a new one - the `git diff`
between two pins already carries the between-pins signal, so the fragment
itself can stay a clean v1-to-v2 migration statement for release assembly
rather than a transcript of intermediate churn. Consumers rely on the diff
between pins being complete (decision 2), so a change that reshapes v2-only
public surface with no fragment touch to show for it is a review finding.

## Format

One file per issue, named for the beads issue ID:

    changelog.d/st-abc.md

Contents are the Keep a Changelog section heading followed by the entry:

```markdown
### Changed

- `Statifier.interpret/2` returns `{:ok, session}` instead of a bare session.
```

Rules:

- Use only the standard headings: `Added`, `Changed`, `Deprecated`, `Removed`,
  `Fixed`, `Security`.
- One line per change, present tense, describing the effect on the user.
- No nested bullets. Detail belongs in the pull request and the commit body; a
  changelog line that needs sub-points is really several changes or one that is
  over-explained.
- One file may carry more than one heading if an issue genuinely spans them.
- For a breaking change, say what to do about it, not just what broke.

Good:

```markdown
### Removed

- Drops `Statifier.Validator.validate/1`. Parse errors now arrive as
  `{:error, reason}` from `Statifier.parse/1`.
```

Too much:

```markdown
### Removed

- **Validator removal**: The validator module has been removed
  - **Rationale**: Validation is now part of parsing
  - **Impact**: Callers must handle `{:error, reason}`
  - **Migration**: Replace calls to ...
```

## At release

Assemble the fragments into a new version section in `CHANGELOG.md`, grouped by
heading and ordered `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
`Security`. Delete the fragments in the same commit that cuts the release, and
tag it.
