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

### Historical note: the v2 rewrite rules

While 2.0.0 was unreleased, two narrower rules applied: a fragment was
warranted only where v2 **differed** from v1 (the fragments assembled into
the `[2.0.0]` migration document, not a transcript of the rewrite), and
under the SHA-pinning contract a change that broke code or persisted data
written against an earlier `main` SHA edited its issue's fragment in place
(ADR-0061 decision 3). Both retired with the 2.0.0 release (ADR-0066); the
general rule above is the whole rule again.

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
