# ADR-0013: Archive the v1 statifier repo in place

Status: accepted (2026-08-06)

## Context

`riddler/statifier` is the pre-rewrite v1 implementation: 13 stars, dormant
since 2026-02-28, and the source of the Hex package `statifier` (latest 1.9.0,
owned by johnnyt). Its README, CI badges, GitHub Pages docs
(`riddler.github.io/statifier`), and the Hex package's GitHub link all embed
that repo name. This rewrite is version 2.0.0-dev of the same package: the OTP
app is already `:statifier` and the intent is to publish 2.0.0 to the same Hex
name from `riddler/statifier-ex`.

Three fates were considered: leave it alone (the naming story stays ambiguous
and the repo looks live when it is not), rename it to `statifier-legacy`
(GitHub redirects repo links, but Pages URLs do not redirect, the Hex 1.x
metadata would point at a name that no longer exists, and later creating a new
`riddler/statifier` would silently hijack the redirect), or archive it in
place. ADR-0007 assumed statifier-ex might eventually replace the old repo via
force-push or recreation; that path shares the rename option's problems.

## Decision

Archive `riddler/statifier` in place and keep its name forever as the v1
tombstone. This repo stays `riddler/statifier-ex` permanently; it takes over
the `statifier` identity on Hex, not on GitHub. The package name is the
identity that matters for an Elixir library, and the same owner holds it, so
no name needs freeing.

Sequencing:

1. Now, by a human on GitHub (agents do not mutate public repos):
   - Push a final commit to `riddler/statifier` adding a README banner:
     development has moved to <https://github.com/riddler/statifier-ex>,
     which will publish `statifier` 2.0; 1.9.x remains usable as-is.
   - Update the repo description to say it is the archived v1, then run
     `gh repo archive riddler/statifier --yes`.
2. At the 2.0 release, from this repo: add `package()` to `mix.exs`
   publishing as `statifier` with links to `riddler/statifier-ex`, and
   `mix hex.publish`. That flips the Hex page's GitHub link to the new home.
3. Never: rename `riddler/statifier`, and never create a new repo at that
   name. If a critical 1.x fix is ever needed, unarchive, fix, re-archive.

## Consequences

- The naming story is unambiguous: one archived v1 repo, one live rewrite
  repo, one Hex package that spans both.
- The 13 stars, inbound links, Pages docs, and Hex 1.x metadata all keep
  working; nothing redirects, so nothing can be hijacked.
- ADR-0007's expectation that this repo might replace `riddler/statifier`
  by force-push or recreation is retired; beads' rename-resilience is now
  just insurance.
- Open question: whether the v1 Pages site should eventually point readers
  at the 2.0 hexdocs, or simply remain frozen. Archived repos keep serving
  Pages, so nothing forces a choice before the 2.0 release.
