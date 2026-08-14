# ADR-0025: Cross-repo tracker authority and the mirror obligation

Status: accepted (2026-08-14)

## Context

Three repositories share one language and three different answers to "where is
the work recorded": predicator-ex (`bd`, `px-` prefix), this repo (`bd`, `st-`
prefix), and the `riddler/predicator` monorepo (no tracker at all). How their
trackers relate was settled on the predicator side in
[riddler/predicator-ex ADR-0010, "Tracker authority follows the artifact, and
mirrors pull"](https://github.com/riddler/predicator-ex/blob/main/docs/adr/0010-tracker-authority-and-the-mirror-obligation.md).
That record derives three rules - who owns a decision recorded in two trackers,
what a `mirrors:` note obliges and in which direction, and how trackerless
monorepo work is held - and it verifies `bd`'s `--external-ref` behavior
rather than assuming it. This ADR cites that argument; it does not re-make it.

Predicator's decision is explicitly half a decision. Its Consequences say the
rule "is only half-recorded until that repo carries the same rule and points at
this ADR", and its first open question - does statifier adopt the same rule, or
a different one? - is one "nothing in this repo can ask": rule 2's symmetry was
an assumption predicator could not verify from its side. Meanwhile this repo
already lives the rules without recording them. Its beads carry `mirrors:`
first lines (st-c07 <-> px-xsk); a 2026-08-14 triage session pulled on two
mirrored pairs (st-qey/px-ucu, st-7ft/px-o9v) and closed them against the
other tracker by hand, which is rule 2 in action with nothing in this repo
stating the obligation; and the `st2-` -> `st-` prefix rename left
non-resolving ids in live beads on both sides, the exact defect rule 2's id
exception names.

Two shapes were weighed for recording the adoption here: a CLAUDE.md section
citing predicator's ADR-0010 and nothing else, or that section backed by an
ADR of this repo's own. The section alone loses on three grounds:

- **A reader here should not need a checkout of another repo** to learn why
  this one is built the way it is. Predicator's ADR README makes that argument
  as policy (its px-4lz corollary: reasoning that overlaps a sibling repo's
  ADR still gets its own record, crediting the prior art in a sentence), and
  the two repos already practice it at each other - this repo's ADR-0007 and
  predicator's ADR-0007 both record the beads decision, each from its own side.
- **This record is not a duplicate.** It carries content predicator could not
  write: the confirmation that rule 2's pull obligation actually binds from
  this side, the statifier-side reading of which artifacts are whose, and the
  observation that rule 3 is a narrow case here. A CLAUDE.md rule states the
  obligation; only an ADR answers the sibling's open question durably.
- **CLAUDE.md here separates enforcement from reasoning.** Its authority table
  cites the reversibility principle rather than re-deriving it; a cross-repo
  section should do the same, which requires a record on this side to cite.

The drift risk of a second record is real and is answered by construction: this
ADR states which rules are adopted and how they read from this side, and cites
predicator's ADR-0010 for every argument (why a push obligation is
unenforceable across two offline embedded databases, what `--external-ref`
does and does not index, why closed beads are history). Nothing below is a
restatement a reader must diff against the original.

## Decision

**This repo adopts the three rules of riddler/predicator-ex ADR-0010. Rules 1
and 2 are adopted verbatim; rule 3 is adopted with a statifier-side reading of
its scope. Rule 2's pull obligation is symmetric and binding here - this is the
answer to that ADR's open question, and it means predicator's record is whole
rather than superseded.**

### 1. Authority follows the artifact the decision changes - adopted verbatim

A decision is owned by the repository whose files change if it goes the other
way, and the bead in that repository is authoritative; where two trackers
disagree, the owning side is correct by construction. The language, the
grammar, the ISA, the compiled format, the conformance corpus format, and
predicator's release schedule are predicator's. How this repo consumes any of
them is this repo's: the SCXML mapping, which corpus tests join the regression
ratchet, when the `~>` pin moves, and what the converter does with an upstream
value or error shape. st-t3f is the model predicator's ADR already cites -
`execute/2`'s error semantics were predicator's call (px-h66), the converter's
handling of the third tuple element was this repo's - and ADR-0023 is the same
split seen from this side: the numeric-type fix is predicator's artifact, the
refusal to coerce at the boundary is this repo's.

A requirement discovered here but owned there is raised as a bead here,
decided there, and mirrored - the px-h66 path, in this repo's `upstream`
convention (ADR-0007).

### 2. Mirrors pull; nobody pushes - adopted verbatim, and symmetric

Both halves of a pair carry `mirrors: <id>` as the first line of the
description. A dated reconciliation note is a snapshot; age alone is never a
defect, and the authority side owes the mirror nothing on any schedule. The
note becomes a defect the moment someone schedules, claims, plans against,
adds or drops a dependency on, or cites the status of a mirrored bead without
re-reading the other tracker first: refresh, write a new dated note above the
old one, then act. Two exceptions, both adopted:

- **A `mirrors:` id that does not resolve is broken immediately**, not stale -
  it makes the pull unperformable. Whoever notices fixes it with one
  `bd update`, in whichever repo they are standing in.
- **Closed beads are out of scope.** They will never be pulled on, and
  rewriting them edits the record of what was believed at the time.

The symmetry predicator could not verify holds, checked from this side on
2026-08-14: a session in this repo has the predicator checkout and its `bd`
tracker readable (the pull is performable - `px-xsk` resolves from here), this
repo's beads already carry the `mirrors:` first line the rule ratifies, and
the obligation has already been exercised here in practice (the triage session
in Context). Nothing on this side wants a different obligation; in particular
this repo does not want a push obligation it would mostly be on the receiving
end of, for exactly the enforceability reasons predicator's ADR records.
Because this repo is usually the consuming side, refresh-before-acting is a
cost paid here more often than there; that is the correct side to charge, since
it is the side about to benefit from the answer.

### 3. Trackerless-repo work is a bead here plus an `external-ref` - adopted, narrow here

Work in `riddler/predicator` (the Ruby and JavaScript siblings, no tracker) is
held by an `upstream` bead in the repo that is waiting on it, with the GitHub
issue in `bd`'s `external_ref` field once a human has opened it. The field is
a handle, not an index - single-valued, unsearchable, absent from
`bd list --json`, verified on the predicator side - so the searchable
`mirrors:` line and any prose stay in the description, and an empty
`external_ref` means the issue has not been raised, never a gap to fill with a
plausible value. Opening the issue is publish-tier work under this repo's
authority table (CLAUDE.md): it is visible to other people, so it takes a
human ask.

The statifier-side reading: this repo's `upstream` beads almost always target
predicator-ex, which has a tracker, so they are rule 2 pairs and rule 3 does
not reach them. Rule 3 applies here only when this repo waits on the monorepo
directly, which is rare but takes the same mechanism unchanged.

## Consequences

- **CLAUDE.md owes an enforcement section citing this ADR**, in the shape of
  predicator's "Beads that span repositories" table: reasoning in the ADR,
  rules in the table, no duplication of the argument. The section states the
  three rules as adopted above - authority follows the artifact (with the
  statifier-side artifact list from rule 1); mirrors pull, with the
  refresh-before-acting trigger list, the id exception, and the closed-bead
  exclusion; and the trackerless-monorepo handle (`upstream` bead plus
  `--external-ref`, empty field meaningful, opening the issue is a human ask).
  Writing that section is the remaining work of st-c07, not of this record.
- **The live id fixes ride with st-c07**, under rule 2's id exception:
  st-9u4 carries `st2-08x` twice (description and notes) where `st-08x` is the
  id that resolves. The bead's originally named offenders - st-bfq's notes and
  st-t3f - closed before this ADR was written and are left alone under the
  closed-bead exclusion, deliberately.
- **st-c07's own quoted `st2-2pj` is left as it stands.** It is a quotation of
  st-bfq's stale note inside the bead that exists to record the drift, not a
  `mirrors:` line anyone will pull on; rewording it would edit the evidence it
  quotes.
- **Reciprocation already holds.** st-c07 carries `mirrors: px-xsk` and px-xsk
  carries `mirrors: st-c07`; no tracker write is owed for it.
- **Predicator's ADR-0010 is made whole, not superseded.** Its open question
  about this repo is answered "same rule"; its status (`proposed`, per that
  repo's convention - this repo writes ADRs directly as accepted, per
  `docs/workflow.md`) is its maintainer's to advance. If its decision text
  changes materially at acceptance, or either repo later changes rule 2's
  obligation, the two records must move together: predicator's ADR says it is
  superseded rather than quietly half-true in that case, and this ADR is
  amended in the same breath.
- **Nothing here detects a rule 2 violation**, exactly as on the predicator
  side: an agent that acts on an unrefreshed note produces a plan built on
  stale status and no gate catches it. The mitigation is inherited - the
  failure is loud when it lands rather than silent, which the push version
  would have been.
- Reversing any of this - a push obligation, a mirror registry, a shared
  tracker - means superseding this ADR and predicator's ADR-0010 together, not
  adding a mechanism beside them.
