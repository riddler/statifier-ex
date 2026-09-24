# ADR-0070: statifier-ex emits a language-neutral conformance corpus under `conformance/`

Status: accepted (2026-09-19) - extends ADR-0006 without amending it:
`test/passing_tests.json` stays the ratchet file and `mix test.baseline`
its only grower; the corpus and its registry are derived from the tooling
ADR-0006 committed

## Context

[ADR-0006](0006-reuse-conformance-corpus-and-regression-ratchet.md)
carried over the SCION and W3C suites, "the regression registry, and the
ratchet tasks", and committed a generator under `tools/corpus/` whose
generated test files "are committed so regeneration is a reviewable
diff". That is the state today (read at `abf713c`): `tools/corpus/`
fetches the upstream suites into a gitignored `scratch/` tree, rewrites
each W3C `.txml` for the predicator datamodel with
`tools/corpus/scxml_w3/conf_predicator.xsl`, and emits one Elixir test
module per case into `test/scion_tests/` and `test/scxml_tests/`, each
holding its SCXML inline and one `test_scxml/4` call. The ratchet is
`test/passing_tests.json`: three lists of test file paths or globs
(`internal_tests`, `scion_tests`, `w3c_tests`), enforced by
`mix test.regression` and grown only by `mix test.baseline` (its
`--add` flag, or its `add` subcommand naming files; both verify a file
passes before writing it).

Everything this repository decided on its own about the suites lives
only in that Elixir tooling and its output: the predicator transform,
the two exclusion lists with their reason atoms
(`tools/corpus/scion/exclusions.exs`, `tools/corpus/scxml_w3/exclusions.exs`),
and the sub-document set (`tools/corpus/scxml_w3/sub_documents.exs`).
[ADR-0004](0004-predicator-as-the-datamodel.md) says W3C tests that
irreducibly require ECMAScript "are excluded by the corpus tooling with
the exclusion recorded in the manifest"; today that record is an Elixir
map. An implementation of the same engine in another language has
nothing to make a claim against: it would have to re-run the fetch and
the transform, re-derive the exclusions, and read Elixir to learn which
cases the reference passes.

predicator-ex already solved the same problem for its language: an
in-repository `conformance/` directory (the corpus, its JSON schemas and
a manifest) and a registry contract that each sibling implementation
writes against, `conformance/RATCHET.md` in that repository (public,
cited by path). This record takes that model for SCXML.

**The licences.** Committing the transformed documents in a
language-neutral form is a redistribution of upstream text, so the
terms decide the artifact. They were read from the licence texts on
2026-09-19, not from memory.

- The W3C SCXML IRP test suite page
  (https://www.w3.org/Voice/2013/scxml-irp/) says, under "License":
  "This test suite is licensed under both the W3C Test Suite License and
  the W3C 3-clause BSD License."
- The W3C Test Suite License (2008,
  https://www.w3.org/Consortium/Legal/2008/04-testsuite-license) forbids
  what the transform does: "No right to create modifications or
  derivatives of W3C documents is granted pursuant to this license", and
  "The tests themselves shall NOT be changed in any way."
- The W3C 3-clause BSD License
  (https://www.w3.org/Consortium/Legal/2008/03-bsd-license) permits it:
  "Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are
  met: Redistributions of works must retain the original copyright
  notice, this list of conditions and the following disclaimer.
  Redistributions in binary form must reproduce the original copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.
  Neither the name of W3C nor the names of its contributors may be used
  to endorse or promote products derived from this work without specific
  prior written permission."
- None of the upstream `.txml` documents fetched on 2026-09-19 carries a
  copyright line of its own (a grep over the fetched tree). The copyright
  notice the suite carries is the IRP page's: "Copyright © 2015 W3C®
  (MIT, ERCIM, Keio, Beihang), All Rights Reserved."
- SCION's `scxml-test-framework` (github.com/jbeard4/scxml-test-framework,
  read at `b46a10a1`) ships the Apache License 2.0 as its `LICENSE.txt`
  and no `NOTICE` file.

The generated test modules committed today already carry transformed W3C
text and SCION text. The W3C-derived modules carry no notice. The
SCION-derived modules hold their upstream document's source unmodified,
so a module whose upstream document carries an Apache License 2.0
header comment keeps it inline in its SCXML, with the copyright line
when the header has one; a module whose upstream document has no header
carries none, and no module carries the licence text itself.

## Decision

**1. The W3C suite is redistributed under its 3-clause BSD arm, with
the notice.** The predicator transform is a modification, which the W3C
Test Suite License does not grant and the 3-clause BSD License does, so
this repository elects the BSD arm for every W3C-derived document it
commits. Retaining the notice, the conditions and the disclaimer is
therefore a condition of the redistribution, not a courtesy. SCION text
is redistributed under the Apache License 2.0, whose section 4(c)
requires a redistribution to "retain, in the Source form of any
Derivative Works that You distribute, all copyright, patent, trademark,
and attribution notices from the Source form of the Work". Concretely:

- `conformance/LICENSES/` holds the full text of the W3C 3-clause BSD
  License with the IRP page's copyright notice, and the Apache
  License 2.0 text.
- Every case taken from W3C or SCION carries an `upstream` field naming
  its upstream document, its licence, and the notice it is redistributed
  under in `conformance/LICENSES/`.
- The generated Elixir test modules carry the same notice for the
  upstream text they hold.
- A SCION document's own notice is never dropped: the emitter keeps each
  SCION document's copyright and licence notice with its case, either
  in the case's source or reachable from its `upstream` field, and the
  generated test module keeps it too. Where the notice travels in the
  case is the corpus schema's to decide.

**2. The corpus is the source.** An emitter writes the corpus as JSON
under `conformance/corpus/`, one file per suite, from the transformed
upstream documents and this repository's exclusion and sub-document
rules. The existing test generators under `tools/corpus/` are retargeted
to read the corpus instead of the scratch tree, so a generated Elixir
module and its corpus case are the same case by construction. A case
carries what `Statifier.Testing.Case.test_scxml/4` asserts: the SCXML
source for the predicator datamodel, the active leaf states expected
after initialization, and the event steps with the active leaf states
expected after each. The emitter RUNS every case through statifier in
the same process before it writes it. The exclusions are emitted too,
each with its reason atom and its reason, which gives ADR-0004's
"exclusion recorded in the manifest" a language-neutral form. Generated files - the
corpus, the manifest, the registry, the exclusions, and the generated
test modules - are never edited by hand; a change to one is a change to
its generator or its input, regenerated.

**3. The registry is derived from the ratchet.** The emitter writes
`conformance/registry.json` from `test/passing_tests.json`'s SCION and
W3C lists, keyed by corpus case id; the `internal_tests` globs stay out,
because they name this repository's unit tests, not corpus cases.
`test/passing_tests.json` remains ADR-0006's ratchet file, and
`mix test.baseline` remains the only thing that grows it; nothing writes
the registry except the emitter. A case in the corpus but not in the
ratchet is in the corpus and out of the registry: it stays listed and
runnable, and its absence from the registry is the claim that
statifier-ex does not pass it. A case that cannot pass by design - for
example one that needs an `<invoke src>` resolver, which the library
never supplies ([ADR-0038](0038-invoke-source-resolves-at-the-session-boundary.md):
"The library never dereferences `src`") - is either an exclusion with
its reason or stays listed and failing; which one is the exclusions
file's to say, not this record's.

**4. Claims are per suite, with no tiers.** SCXML has no instruction set
to tier by, so a claim names a suite, with the W3C suite split by its
manifest's conformance class: `scion`, `w3c-mandatory`,
`w3c-optional`, or `statifier` (decision 5). A claim's content is the
set of registry entries for that suite, and it is pinned by the
corpus hash in the manifest and the statifier-ex tag the corpus was
vendored from. Each registry entry repeats its case's suite even though
the corpus already records it - the redundancy predicator-ex's
`conformance/RATCHET.md` gives its `tier` field, for the same reason: if
an upstream change moves a case between suites or removes it, the stale
entry disagrees with the corpus and the check fails naming the case.

**5. The case shape reserves a `host` object and a `statifier` suite.**
A case may carry an OPTIONAL `host` object with two optional members,
`send_types` (the send types the case registers, in
[ADR-0069](0069-host-registered-send-types.md)'s sense) and
`expect_sends` (the sends the case expects handed to the host). No W3C
or SCION case carries it: upstream cases run with no registration. The
fourth claim, `statifier`, is for cases this repository authors itself.
This record reserves the object and the suite and nothing more: the
detailed shape of `expect_sends` is written by the change that authors
the first case using it, and the corpus schema is tightened in that
change.

This is how the corpus answers ADR-0069's reopen trigger, "a corpus
document naming a non-built-in send type". An upstream document that
names such a type is judged with no registration, which ADR-0069 says is
byte-identical to today's behaviour; a document that names a
host-registered type enters only as a `statifier` case whose `host`
object declares the registration it depends on. This record authors no
`statifier` case naming a host-registered type. One observation for
the record's reader: ADR-0069 gives "the corpus names no type outside
the built-in set" as the reason no conformance result moves, but at
`abf713c` two generated W3C modules name a type outside it in a literal
`type` attribute - `test/scxml_tests/mandatory/send/test199_test.exs`
(an unsupported type the test expects refused) and
`test/scxml_tests/optional/send/test201_test.exs` (the BasicHTTP Event
I/O Processor). Both run with no registration, so the result ADR-0069
predicts holds on its byte-identical ground; this record decides nothing
about whether those two documents bear on that trigger.

**6. A check that checks nothing fails.** The emitter has a `--check`
mode that writes nothing and fails when a committed generated file
differs from what the emitter would write. It also fails when there is
nothing to compare: an empty corpus file, an empty registry, or a
comparison that visited no case. A green result on absence is a defect,
not a pass.

**7. What is not in it.** The internal tests are not corpus cases. The
network fetch is not part of the emitter or of `--check`: fetching and
transforming stay the separate `tools/corpus/` stages. `conformance/` is
not shipped in the Hex package; a sibling implementation vendors it from
a statifier-ex tag.

**8. The record states rules; the artifacts carry the enumerations.**
Which cases exist, which are excluded and why, which pass, and how many
of each are read from the emitted files and verified by `--check`. This
record carries no case list, exclusion list or count that could drift
from them.

## Consequences

- The work this record needs, none of which exists at `abf713c`: the
  corpus schemas under `conformance/schema/`; the emitter and its
  `--check`; `conformance/corpus/`, `conformance/manifest.json`,
  `conformance/registry.json`, `conformance/exclusions.json` and
  `conformance/LICENSES/`; the `tools/corpus/` generators retargeted to
  read the corpus; the notices in the generated test modules.
- `mix test.regression` and `mix test.baseline` are unchanged. Ratcheting
  a case in is still one line in `test/passing_tests.json`; the registry
  follows at the next emit, and `--check` fails until it does.
- The generated test modules change once, when the notices are added and
  the generators read the corpus; after that a regeneration diff is still
  the review surface ADR-0006 committed to.
- A sibling implementation's claim is a registry it writes against a
  vendored corpus and hash, on the model of predicator-ex's
  `conformance/RATCHET.md`; this repository's own registry is the
  reference implementation's claim against the same corpus.
- The `statifier` suite has no cases until the change that implements
  ADR-0069 authors them; decision 6 means no empty `statifier` corpus
  file is committed before then.
- What would reopen this record: a licence change on either upstream; an
  upstream suite this record does not name joining the corpus; or a
  second grower for `test/passing_tests.json`.

## Related

- [ADR-0006](0006-reuse-conformance-corpus-and-regression-ratchet.md) (the ratchet and the committed generator; extended, not amended)
- [ADR-0004](0004-predicator-as-the-datamodel.md) (exclusions recorded by the corpus tooling)
- [ADR-0038](0038-invoke-source-resolves-at-the-session-boundary.md) (the library never dereferences `<invoke src>`)
- [ADR-0069](0069-host-registered-send-types.md) (host-registered send types; the reserved `host` object and its reopen trigger)
- predicator-ex `conformance/README.md` and `conformance/RATCHET.md` (the model: an in-repository corpus, a manifest hash as the pin, a redundant field on each registry entry)

## Note (2026-09-19): one fetched SCION document is changed, and `--check` is not what holds the generated modules

This note decides nothing. It states two facts about the implementation
that two sentences of this record read past, so a reader is not left to
discover them from the files. No decision, consequence or Related entry
changes, and the Status line's extends clause stands as written. Every
anchor below was read on `main` at `f976629`.

**One SCION document is not carried unmodified.** The Context says the
SCION-derived modules hold their upstream document's source unmodified.
One document is an exception: the `corpus:fetch:scion` task in `mise.toml`
deletes four lines of `internal-transitions/test0.scxml` after the clone,
under its own comment "The root transition is not supported." The Apache
License 2.0's section 4(b) asks a changed file to say it changed, and the
corpus says it: `conformance/schema/case.json` defines `upstream.modified`
as the field a case carries when this repository changed the upstream
document before carrying it, and the case built from that document is the
only one that carries it. Decision 1's requirement that a SCION document's
own notice is never dropped is unaffected: the notice travels as it does
for every other SCION case.

**The generated test modules are held byte for byte by a test, not by
`--check`.** Decision 6 says `--check` fails when a committed generated
file differs from what the emitter would write.
`Mix.Statifier.Corpus.Emitter.check/1` compares the files under
`conformance/` - the corpus files, the manifest, the exclusions and the
registry - and the generated Elixir test modules are not among them. Those
modules are compared instead by
`Corpus.CorpusFilesTest`'s "every generated module is byte for byte what
its generator writes from the committed corpus", which re-runs each
generator over the committed corpus into a temporary directory and fails
on any committed module that differs, and which fails when there is
nothing to compare. Decision 6's own green-on-absence rule therefore holds
across both surfaces; only the mechanism differs from what its sentence
suggests.

## Note (2026-09-19): accepted

The operator accepted this record on 2026-09-19. The acceptance is the
record's: no decision, consequence or Related entry changes here, and the
Status line's extends clause stands as written. It rests on the note
above, which records the two sentences whose implementation is narrower
than the sentence reads; every other claim in this record was verified
against `main` at `f976629` before the flip, the statements this record
pins to `abf713c` included, which are read as of that commit and not as of
today's tree.

## Note (2026-09-23): the ratchet has a `statifier` list, so authored cases are claimed like any other

This note decides nothing new. Decision 3 says the emitter writes the
registry from `test/passing_tests.json`'s SCION and W3C lists; read with
decision 4's `statifier` claim, that left the claim unreachable, because
an authored case has no generated test module for either list to name. At
`716c4d9` the registry made no `statifier` claim although every authored
case agreed when run. No decision, consequence or Related entry changes,
and the Status line's extends clause stands as written: the ratchet file
is still `test/passing_tests.json`, `mix test.baseline` still its only
grower, and the emitter still the registry's only writer.

**The ratchet names an authored case by its JSON file.** The ratchet file
gains a fourth list, `statifier_tests`, whose entries are the authored
cases' `.json` files under `conformance/cases/`
(`Mix.Statifier.Corpus.Authored.case_path/1`). The emitter maps a corpus
case to the path the ratchet names it by through
`Mix.Statifier.Corpus.Emitter.ratchet_path/2`, and derives the registry
from all three conformance lists, so decision 3's "SCION and W3C lists"
now reads as the SCION, W3C and statifier lists.

**The ratchet's rules hold for them unchanged.** `mix test.baseline` adds
an authored case only after running it and seeing it agree, and `mix
test.regression` re-runs every listed case and fails on one that
disagrees. Both run an authored case through
`Mix.Statifier.Corpus.Runner.run_paths/2`, as `mix statifier.corpus`
runs it, since `mix test` has no module to run. Which authored cases are
claimed, and how many, is read from `conformance/registry.json`, per
decision 8.
