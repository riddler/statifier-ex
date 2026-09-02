# Statifier-ex extension: /wurk:release

Additional required steps for `/wurk:release` in this repo. The skill reads
this file before step 1 of its `kind: "hex"` recipe and treats what is here as
required steps placed where this file says. Extensions add; they never
override, and nothing below rewrites a step the skill already performs.

Read this together with `.claude/wurk.json`'s `release` block. Between them
they name every file a release commit here touches, and no others.

The reference for the shape is `e739263`, the 2.4.0 prep - the most recent
release prep in this repo, and the commit every step below is modeled on.

## Why the recipe names no changelog

`kind: "hex"`'s changelog step renames a `## [Unreleased]` heading in one file
to `## [X.Y.Z] - YYYY-MM-DD`. This repo has no such heading and never will:
`changelog.mode` is `fragments`, and `CHANGELOG.md` says so in its own header -
"Entries for unreleased work are not written here directly. Each issue drops a
fragment in `changelog.d/`; the fragments are assembled into the section below
at release." `CLAUDE.md` states the same rule from the authoring side: "user-
facing changes get a fragment at `changelog.d/<issue-id>.md`; never edit
`CHANGELOG.md` outside a release."

Pointing `release.changelog` at `CHANGELOG.md` would make the skill's
precondition read for an unreleased section that is not there, and its edit
rename a heading that does not exist.

So `release.changelog` is deliberately absent, and a recipe that does not name
a changelog names no changelog edit. The promotion this repo actually performs
is step B below - a required step, not an optional one. A release commit
without it is not a release commit.

The unreleased-work check the skill makes before anything else reads
`changelog.d/` here: if the directory holds no fragment other than its own
`README.md`, there is nothing to release, and the run stops exactly as it
would on an empty unreleased section. That is the directory's resting state
between releases, so a run that stops there has found the expected condition,
not a broken repo.

## Step A: the version carrier

**None.** `mix.exs`'s `@version` is the only place this package's version
string lives; `lib/` and `docs/` carry no second copy, and `mix.exs` derives
both `version:` and `source_ref: "v#{@version}"` from that one attribute
rather than repeating the literal. So the skill's own `version_file` edit is
the whole of the bump.

Stated explicitly so that a future release does not go looking for a carrier
that was never there. If one is ever added - a module attribute stamped into
compiled output, a version literal in a guide - it belongs in this section and
in the table below, in the same change that adds it.

## Step B: promote the changelog fragments

Placed where the skill's changelog step would have been, and modeled on the
2.4.0 prep commit `e739263`, which is the reference for the shape.

1. Read every `changelog.d/*.md` fragment except `README.md`. Each is a Keep a
   Changelog section heading followed by its bullets.
2. Insert a new `## [X.Y.Z] YYYY-MM-DD` section into `CHANGELOG.md` directly
   above the previous version's section, dated today. The heading form is the
   one this file has used for every release since 1.1.0 - the bracketed
   version, a single space, then the date, **with no `-` separator between
   them**. (Keep a Changelog's own form has the dash, and `1.0.0` and `0.1.0`
   still carry it; the file moved off it at 1.1.0 and a release is not the
   place to move sixteen headings back.)
3. Write a short lead paragraph between the heading and the first `### `
   sub-heading saying what the release is. This is the usual shape here -
   `2.4.0`, `2.3.0`, `2.2.0` and `2.1.1` each carry one - but it is not
   mandatory: `2.2.1` has none, because its two bullets said everything there
   was to say. Write one when there is something the bullets do not say, and
   keep the reasoning for the version choice in the commit body, where
   `e739263` put it.
4. Then the fragments' bullets, grouped by heading and ordered `Added`,
   `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
   **Carry every bullet over byte for byte.** The lead paragraph is the only
   prose written at release time; reordering, consolidating or rewording a
   fragment's bullet is an editorial pass a human does separately, before the
   release.
5. **No link reference.** This `CHANGELOG.md` has no link-reference block at
   the end of the file and no `[X.Y.Z]:` definitions anywhere - the bracketed
   versions in the headings are deliberately unlinked, in every section back
   to `0.1.0`. Do not add one for the new version, and do not "repair" the
   file by adding the whole block.
6. Delete the promoted fragment files in the same commit. `README.md` stays.

Whether the release is major, minor or patch is not decided here - the version
is explicit input to the skill. This repo adheres to SemVer from 2.0.0 on
(ADR-0066), and `CLAUDE.md` says so; the fragments' headings are evidence for
that judgement, not a rule that computes it.

## The README install pin

`release.readme_pin` is `true`. `README.md`'s `def deps` snippet carries
`{:statifier, "~> X.Y"}` - the major/minor form with the patch component
dropped that the skill's step 2 bumps. `e739263` shows the previous release
moving it that way (`~> 2.3` to `~> 2.4`), and that is the commit the skill's
"check a previous release commit rather than inventing the format" step should
be read against here.

It is named here only so that the carriers a release moves are all listed in
one place; the skill's own step covers it without help.

## The files a release commit touches

Exactly these, and a release commit that touches anything else is wrong:

| File | Moved by |
|---|---|
| `mix.exs` | the recipe's `version_file` |
| `README.md` | the recipe's `readme_pin` |
| `CHANGELOG.md` | step B |
| `changelog.d/*.md` (deleted) | step B |

No `lib/` file appears in that table, and step A explains why. `e739263`
touched exactly this set.

## What a release here still is not

The skill does not tag, push, open a request or publish, and this extension
does not either. `CLAUDE.md` is explicit on both halves of the boundary:

- *a release (tag, `mix hex.publish`, GitHub release)* - trigger **never**,
  still unauthorized **always**: "publishing is the operator's, in every
  campaign".
- *a version bump on a release bead's branch* - allowed only on "an
  operator-authorized release bead, inside a campaign carrying the operator's
  explicit consent", and still unauthorized "on any other bead, on main, or
  when the operator has not named this repo's release bead". The recorded
  exception says the same in prose: "on a release bead the operator has named
  (in the campaign plan or their own words), the bump commit is release prep,
  not a release."

So the one thing this recipe performs - the bump plus the step B promotion, on
a named release bead's branch, under a campaign consent that names it - is
release *prep*. `CLAUDE.md`'s changelog rule describes the whole arc, of which
this recipe is the first two thirds: "a release assembles the fragments,
deletes them, and tags." The assembling and the deleting are step B. The
tagging is the operator's, here and in every campaign.

`.claude/wurk/commit.md`'s version-bump section records the same boundary from
the commit side: the version field moves only through a release bead, never as
a convenience, and a diff that touches it alongside other work is a bug in the
diff.
