---
date: 2026-08-18T19:48:30-0600
researcher: Claude
git_commit: 463fb453d27237ebf2bf329647d2518700ac847a
branch: st-xsb1-adr-0012-pre-mutation-fixture
repository: statifier-ex
beads_issue: st-xsb1
topic: "What a new ADR-0012 pre-mutation fixture pair must satisfy: judge plumbing, rubric composition, gate wiring, and the st-2ts measurement policy"
tags: [research, codebase, adr-judge, test-harness, adr-0012]
status: complete
last_updated: 2026-08-18
last_updated_by: Claude
---

# Research: what an ADR-0012 pre-mutation fixture pair has to satisfy today

**Date**: 2026-08-18T19:48:30-0600
**Git Commit**: 463fb453d27237ebf2bf329647d2518700ac847a
**Branch**: st-xsb1-adr-0012-pre-mutation-fixture
**Bead**: st-xsb1

## Research Question

st-xsb1 asks for a new ADR-0012 judge fixture pair in `test/fixtures/adr_judge/`
covering a payload field that is *deliberately* post-mutation - the
`configuration` field read from post-departure state in
`exit_states/2` - so a judge that learned "anything read after the reduce is a
violation" is caught. The bead's note records that the natural violation half of
that pair (keep the six-line ADR-0012 comment, delete only the `pre_exit_state`
binding) was hand-measured as a FALSE NEGATIVE against the real CLI.

Document, as the codebase exists today:

1. How a fixture reaches the judge - manifest schema, tiers, expected verdicts,
   how the corpus tests consume them.
2. Where the ADR-0012 rubric text actually lives and how it is composed into the
   judge prompt.
3. How the ADR judge stage is wired into `mix quality` and the `merge` profile.
4. What st-2ts's Phase 5 established as the measurement policy, spend ceiling and
   scorecard shape, and what "re-measure to include them" mechanically requires.
5. Which files a change to the rubric or judge would touch.

## Summary

The path from a `.diff` file to a judged verdict is short and has no schema
enforcement of its own. `test/fixtures/adr_judge/manifest.exs` is a plain Elixir
list literal, `Code.eval_file/1`-ed by `Mix.Statifier.AdrJudgeCorpus`; a
compile-time comprehension in `test/mix/statifier/adr_judge_corpus_test.exs`
turns each row into one ExUnit test that calls `AdrJudge.analyze/2` with the real
`claude` caller injected explicitly. Everything a manifest row is *required* to
look like is asserted by a separate, free companion,
`test/mix/statifier/adr_judge_corpus_shape_test.exs`, which runs in the ordinary
suite.

The ADR-0012 "rubric" is not a rubric in the sense of curated criteria. It is the
whole of `docs/adr/0012-debuggability-designed-into-the-core.md`, read verbatim
by `File.read/1` and interpolated into both prompts as one block, alongside a
single one-line `focus` string held in the `@judged` registry inside
`lib/mix/statifier/adr_judge.ex`. There is no per-clause slicing, no separate
rubric file, and no ADR-0012-specific prompt text anywhere.

The judge stage is a `kind: :reader` ExQuality custom stage, `enabled: false` at
the bare gate, re-enabled only by the `merge` profile. It runs `mix adr.judge`
against the branch diff - not against the fixture corpus. The fixture corpus is a
separate, hand-run, money-spending path: `mix test --only adr_judge_corpus`, or a
tier/fixture slice of it.

st-2ts fixed the measurement policy (three runs at three seeds, majority verdict,
flaps reported separately and never folded in), the scorecard shape (two tables
per model pasted into the plan's own `#### Phase 5 measurement (recorded)`
subsection and mirrored into `docs/testing.md`), and a spend ceiling of eight
corpus-equivalents with an explicit stop-and-report-partial rule. Its own run
consumed 4.2 of 8, leaving the 1.2-run reserve unspent.

Two findings bear directly on st-xsb1's acceptance criteria and are recorded
under Open Questions rather than decided here. First, the violation half is
already known to fail, so landing it turns `mix test --only tier:subtle` red on a
row that has never been green - which is the point of the fixture, but is also a
judge or rubric change rather than a corpus addition. Second, a literal reading
of st-2ts's Decision 2 (a measurement is three runs *of the tier*) puts the cost
of re-measuring the subtle tier with two extra fixtures well past the reserve
Decision 3 left standing.

## Detailed Findings

### 1. How a fixture reaches the judge

**The manifest is a bare list literal with no loader-side validation.**

[`test/support/adr_judge_corpus.ex:17-18`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L17-L18) pins the paths:

```elixir
@fixture_dir "test/fixtures/adr_judge"
@manifest_path Path.join(@fixture_dir, "manifest.exs")
```

and [`test/support/adr_judge_corpus.ex:37`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L37) is the entire loader:

```elixir
def manifest, do: @manifest_path |> Code.eval_file() |> elem(0)
```

No `Map.take`, no key-presence check, no type check. An extra key on a row is
carried along unused; a missing key raises a `KeyError` at the point a consumer
dereferences it. A missing `.diff` file is not caught at load time either -
`source_for/1` reaches `File.read!/1` at [`test/support/adr_judge_corpus.ex:48`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L48)
and raises `File.Error` there, while the shape test catches the same condition
politely with `File.exists?/1`.

**The row schema, as documented at [`test/support/adr_judge_corpus.ex:28-35`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L28-L35)**, is
five keys: `:key` (a judged-ADR registry key string), `:file` (relative to
`fixture_dir/0`), `:expect` (`:violation` | `:clean`), `:tier` (`:blatant` |
`:subtle`), `:note` (free prose). All 18 rows in
`test/fixtures/adr_judge/manifest.exs` follow it.

**`source_for/1` slices the diff to exactly one ADR.**
[`test/support/adr_judge_corpus.ex:46-62`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L46-L62) looks `entry.key` up in the live
registry (`AdrJudge.judged()`), then builds an `AdrJudge.source()` whose single
`adrs` entry carries `chunks: AdrJudge.scoped_chunks(diff, registry.scope)`. The
scope comes from the registry, never from the fixture row - a fixture cannot
declare its own scope.

**Tiers are a tag, not a threshold.** Nothing in the loader, `analyze/2`, or
`source_for/1` branches on `:tier`. It exists mechanically as an ExUnit tag
(`@tag tier: entry.tier`, [`test/mix/statifier/adr_judge_corpus_test.exs:33`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L33) and
`:48`) so `mix test --only tier:subtle` selects a slice of the paid corpus. The
prose meaning sits in a comment at [`test/support/adr_judge_corpus.ex:33-34`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L33-L34):
`:blatant` is a deletion or omission the deterministic guards would also catch;
`:subtle` preserves the shape of the change it fakes and breaks only its meaning.

**The paid corpus test.** [`test/mix/statifier/adr_judge_corpus_test.exs:13-14`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L13-L14)
carries `@moduletag :adr_judge_corpus` and `@moduletag timeout: :infinity`. A
compile-time `for entry <- AdrJudgeCorpus.manifest()` (`:29-60`) with `@entry
entry` (`:30`) generates one test per row, branching on `entry.expect` at
generation time so the unreached branch is dead code rather than a runtime
`case`. The assertions:

- `:violation` rows (`:32-46`): `findings != []` (false negative), and
  `Enum.any?(findings, &(&1.check == @entry.key))` (wrong-ADR attribution).
- `:clean` rows (`:47-58`): `findings == []` (false positive).

`judge/1` at [`test/mix/statifier/adr_judge_corpus_test.exs:65-67`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L65-L67) is the single
place in the whole suite that passes the real caller:

```elixir
AdrJudge.analyze(AdrJudgeCorpus.source_for(entry), caller: &AdrJudge.call_claude_cli/1)
```

Both generated tests carry `# sabotage: n/a` with the stated reason that they
score real model output and the implementation under test is the prompt, not a
pure function (`:35-36`, `:50-51`).

**The free companion.** `test/mix/statifier/adr_judge_corpus_shape_test.exs` runs
`async: true` in the ordinary suite and never passes a caller. Its six checks are
the real schema enforcement, and a new fixture pair must satisfy all of them:

| Check | Line | What it demands of a new pair |
|---|---|---|
| Fixture file exists | `:13-18` | Both `.diff` files present under `test/fixtures/adr_judge/` |
| Key is a real registry key | `:21-27` | `key: "adr-0012-debuggability"` |
| Tier is `:blatant` or `:subtle` | `:30-36` | No third tier without editing this assertion |
| Both verdicts per `{key, tier}` | `:39-49` | The pair must be a pair, in one tier |
| Diff lands in its own scope and no other | `:53-72` | Non-empty `scoped_chunks` under `lib/statifier`, empty under `.claude/wurk` |
| No literal `@tag :skip` | `:75-82` | The diff text must not contain that string |

The last one exists because fixtures live under `test/`, which is exactly the
prefix `Mix.Statifier.GateGuard`'s skip-tag scan walks
([`lib/mix/statifier/gate_guard.ex:141`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/gate_guard.ex#L141), `:194-197`).

**Which command spends money.** [`test/test_helper.exs:9`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/test_helper.exs#L9) reads
`ExUnit.start(exclude: [:scion, :scxml_w3, :adr_judge_corpus])`, so `mix test`,
`mix quality`, and `mix quality --profile loop` never run the corpus. Only an
explicit `mix test --only adr_judge_corpus`, `--only tier:<tier>`, or `--only
fixture:<file>` does. In `:test` builds `@default_caller` is
`refuse_real_call/1` ([`lib/mix/statifier/adr_judge.ex:223-225`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L223-L225), `:660-667`),
which raises - so a test that forgets `opts[:caller]` fails loudly instead of
billing quietly. The mix-task tests
(`test/mix/tasks/adr_judge_test.exs`) all inject stubs, and the one test that
reaches the real `collect/1` path is arranged around a scratch repo with no
`lib/statifier/` files so it hits `:no_scoped_changes` before any caller runs
(comment at `:311-317`).

### 2. Where the ADR-0012 rubric lives, and how it is composed

There is no rubric file and no `@adr_rubrics` attribute. The registry
`@judged` at [`lib/mix/statifier/adr_judge.ex:173-211`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L173-L211) holds *metadata only* -
`key`, `label`, `adr_path`, `scope`, and a one-line `focus`. The ADR-0012 entry
(`:174-182`) scopes `lib/statifier` with a nil suffix and carries this `focus`:

> a microstep-resumability regression, a dropped trace effect at a phase
> boundary, a lost source location, or an uncounted or unstamped step

That string is the only ADR-0012-specific prompt text in `lib/`. The rest of the
rubric is the ADR file itself. `read_adr_source/1`
([`lib/mix/statifier/adr_judge.ex:346-356`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L346-L356)) is three literal `File.read/1`
clauses, one per registry key - written that way because Sobelow's
`Traversal.FileModule` check only treats `File.read/1` as safe with a source
literal, explained at `:338-345`. Each clause reads the **entire** markdown file;
there is no section extraction. A read failure degrades to the string `"(unable
to read ...)"` (`:331-336`) rather than raising.

Both prompts interpolate that whole file as one block:

- `propose_prompt/1`, [`lib/mix/statifier/adr_judge.ex:513-541`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L513-L541) - a no-tool-access
  preamble, a prompt-injection guard treating hunks as content, then
  `"You are reviewing a code change against #{judged.label} ... list any changes
  that likely violate it: #{judged.focus}."`, then
  `"#{judged.label} full text:\n#{judged.adr_text}"`, then the rendered hunks,
  then a JSON-only instruction asking for `file` / `line` / `claim` objects.
- `refute_prompt/1`, [`lib/mix/statifier/adr_judge.ex:543-585`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L543-L585) - the adversarial
  pass. It sees the same ADR text and the same hunks (attached to every candidate
  by `judged_identity/1` at `:488-495`), plus the one-sentence claim. Its
  grounding rule (`:555-563`) excludes "the change does not show X, but X might
  exist elsewhere - a side table, an index, a helper, a caller that compensates",
  and its tie rule (`:580-583`) resolves ambiguity *within the shown material* to
  `{"violation": false}` while stating that "Uncertainty about material you were
  not shown is not a tie."

`analyze/2` (`:242-249`) is the two-pass pipeline: `propose/2` (`:480-486`) then
`survives_refute?/2` (`:497-503`) per candidate, then `to_finding/1` (`:639-647`)
producing `%{file, line, severity: "error", check: <registry key>, message:
<claim>}`. Both passes fail closed: an error, an unparseable response, or an
absent explicit `"violation": true` yields no finding. The refute prompt asks for
a `"grounds"` field, but `parse_refute/1` (`:606-611`) does not read it - st-6f7
Phase 3 (a mechanical grounds requirement) was deliberately skipped because Phase
2's prompt change alone closed every measured false negative.

**Consequence for this bead.** Because the entire ADR is the rubric and the only
per-ADR steering is one `focus` line, the two places a judge-side fix for the
measured false negative could land are (a) the ADR-0012 markdown itself and (b)
the ADR-0012 `focus` string, with (c) the shared prompt templates as the
non-ADR-specific option. The current ADR text says nothing about *which* state a
trace payload's counters are stamped against - item 4 says only that
"machine_state carries monotonic macrostep/microstep counters; trace effects and
internally raised events ... carry the step and the identity of what raised
them". The distinction the fixture pair turns on is stated only in the
`exit_states/2` doc comment
([`lib/statifier/interpreter/exit_entry.ex:114-127`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L114-L127)) and in the six-line inline
comment (`:143-150`) the false-negative variant preserves.

**The CLI call.** `call_claude_cli/1` ([`lib/mix/statifier/adr_judge.ex:684-704`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L684-L704))
shells out to:

```
claude -p <prompt> --output-format json --tools "" --strict-mcp-config --model <model>
```

`--tools ""` and `--strict-mcp-config` make it a single non-agentic completion
with no repo access; the model is `STATIFIER_ADR_JUDGE_MODEL` or `@default_model`
= `"claude-sonnet-5"` (`:214-215`). No timeout flag is passed.

### 3. How the stage is wired into `mix quality`

`.quality.exs:33` disables it at the base:

```elixir
adr_judge: [enabled: false],
```

with the comment at `:29-32` saying it is absent from both a bare `mix quality`
and `--profile loop` because it makes real `claude` CLI calls, and that the
`:merge` profile re-enables it. The profiles block at `:35-43`:

```elixir
profiles: [
  loop: [
    stages: [:format, :compile, :credo, :test],
    test: [scope: :changed, coverage: false]
  ],
  merge: [
    adr_judge: [enabled: true]
  ]
]
```

The `loop` profile is an allow-list of four stages, so no custom reader stage runs
there regardless of its `enabled:` flag. The `merge` profile touches only
`adr_judge`, so `mix quality --profile merge` is the full default stage set plus
the judge.

The stage definition itself, `.quality.exs:107-114`:

```elixir
[
  key: :adr_judge,
  name: "ADR judge",
  command: "mix",
  args: ["adr.judge", "--format", "json"],
  kind: :reader,
  skip_exit_code: 2
]
```

`skip_exit_code: 2` maps `mix adr.judge`'s three skip atoms - `:no_cli`,
`:no_base_ref`, `:no_scoped_changes` ([`lib/mix/tasks/adr.judge.ex:44-47`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/tasks/adr.judge.ex#L44-L47),
`:81-83`) - onto a clean stage skip rather than a failure. That skip line is what
`CLAUDE.md`'s `^disabled in \.quality\.exs$` not-applicable pattern classifies at
the bare gate.

**This stage never runs the fixture corpus.** It runs `mix adr.judge` against the
branch's own diff. Landing a fixture pair on this branch therefore has no effect
on `mix quality --profile merge` beyond the diff the branch itself presents to
the judge - and since fixture `.diff` files live under `test/`, not
`lib/statifier/`, they are outside ADR-0012's scope and the judge will not read
them. `.quality.exs` is a guarded path
([`lib/mix/statifier/gate_guard.ex:36`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/gate_guard.ex#L36)), but adding a fixture touches none of the
guarded paths, so no `docs/quality-gate-changes.md` entry is mechanically
required for the corpus addition alone.

### 4. What st-2ts Phase 5 established, and what re-measuring requires

**The scorecard is a subsection of the plan, not a file.** It lives at
`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md` under a heading literally
named `#### Phase 5 measurement (recorded)` (`:946`). The plan's own spec for it
(`:877-882`):

> **File**: this plan, a `#### Phase 5 measurement (recorded)` subsection
> **Changes**: Two tables per model - a per-fixture verdict matrix across the
> three seeds, and a summary row of majority-verdict false negatives, false
> positives, and flap count, per tier.

The summary table shape (`:884-887`) is `| Tier | Model | FN (majority) | FP
(majority) | Flaps | Wall (mean) |`. The per-fixture matrix (`:970-984`) is one
row per fixture with columns `sonnet 101/202/303` and `haiku 101/202/303`, cells
`ok` / `FN` / `FP`. The summary rows are mirrored into `docs/testing.md`'s
recorded-scores section ([`docs/testing.md:92-111`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/testing.md#L92-L111)), which also carries the
caveat (`:105-111`) that the blatant-tier rows are single-run observations and
that the 2026-08-18 control runs each produced one false positive against a
recorded 0/4 baseline.

**The measurement policy** is Decision 2 (`:241-259`):

> A measurement is **three runs of the same tier on the same model, at three
> distinct seeds**. A fixture's verdict is the majority of its three; a fixture
> whose three runs are not unanimous is additionally reported in a *flap* column.
> The headline score is the majority-verdict score; the flap count is reported
> next to it and never folded into it.

**The spend ceiling** is Decision 3 (`:261-282`):

> ### Decision 3: the spend ceiling is eight corpus-equivalent runs
>
> The whole bead is budgeted at **eight full-corpus-equivalent runs**, where one
> corpus-equivalent is one pass over all 18 fixtures.

with the allocation table at `:266-273` (2 for fixture authoring, 1.7 per model
for subtle measurement, 1.4 for the blatant comparability check, 1.2 reserve
"for one re-measurement if a fixture is rewritten") and the stop rule at
`:279-282`:

> **If the ceiling is reached before Phase 5's measurement is complete, stop and
> report the partial scorecard.** Continuing to spend past a stated ceiling
> because the numbers are almost in is the decision this line exists to prevent,
> and raising the ceiling is a human's call.

st-2ts's actual spend (`:1015-1019`) was 76 fixture-runs = 4.2 of 8, with the
1.2-run reserve unspent. A blanket guardrail at `:176-177` states that no phase's
Automated Verification includes a corpus run and no CI or gate path gains one.

**Mechanically, re-measuring means** (from `:861-876` and the checklist at
`:1053-1075`):

1. `STATIFIER_ADR_JUDGE_MODEL=claude-sonnet-5 mix test --only tier:subtle --seed
   <s> --trace`, three times at three distinct seeds (st-2ts used 101/202/303).
2. The same three runs under `STATIFIER_ADR_JUDGE_MODEL=claude-haiku-4-5-20251001`.
3. `mix test --only tier:blatant --seed <s1> --trace` once per model as a control,
   not majority-scored.
4. Record per run: per-fixture verdict, per-fixture wall time, total wall time,
   model id, seed.
5. Compute majority-of-three per fixture and flag any non-unanimous fixture as a
   flap.
6. Paste both tables into the plan's `#### Phase 5 measurement (recorded)`
   subsection and mirror the summary rows into `docs/testing.md`.
7. Record the spend in corpus-equivalents against the ceiling of 8.

`--only tier:<tier>` reaches the excluded module because ExUnit's include beats
exclude (`:86-91`, `:341-347`); the plan explicitly warns "do **not** use
`--include adr_judge_corpus`, which runs every row" (`:670-672`).

**What st-2ts measured.** Subtle tier, three-seed majority, 10 fixtures (5
violation + 5 clean): sonnet 3/5 FN, 0/5 FP, 3/10 flaps, 145.7s mean; haiku 1/5
FN, 0/5 FP, 3/10 flaps, 890.6s mean. The subtle tier separates the two models
where the blatant tier does not, and separates them against the current
`@default_model` - haiku is more accurate at roughly six times the wall time. The
plan deliberately does not move `@default_model`; it records the recommendation
(`:141-146`, `:902-918`).

**st-2ts explicitly did not touch the judge.** `:164-166`: "**Not changing any
prompt, parser, or judge behavior.** This plan touches `lib/` not at all."

**A precedent finding on ADR-0012 text.** Phase 5 found
`0012_location_precision_one_caller.diff` missed by majority on both models, and
concluded (`:1005-1013`) that this may indict the ADR's wording rather than the
judge - the record "commits to nodes retaining 'their source location' and never
states that a location must be the finest-grained one available ... Either the
ADR grows a sentence about precision or this fixture is reclassified; both are a
human's call and neither is made here." That is the same shape of decision
st-xsb1's violation half presents.

### 5. Where st-xsb1 came from, and the current shape of the code

The current `exit_states/2` in
[`lib/statifier/interpreter/exit_entry.ex:135-167`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L135-L167) is the three-shape form st-ntf5
introduced: `pre_exit_state = machine_state` captured before the departure reduce
(`:151`), the trace call sitting *below* the reduce (`:159-163`), counters
stamped from `pre_exit_state`, and `configuration:` read from the post-departure
`machine_state`. The six-line inline comment at `:143-150` names the rule; the
`@doc` at `:105-127` restates it at length and names
`test/fixtures/adr_judge/0012_trace_prestate_captured.diff` as "the sanctioned
shape".

The two shipped ADR-0012 subtle fixtures were both re-anchored against this code
on 2026-08-18 (st-ntf5 Phase 3,
[`docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md:557-576`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md#L557-L576)),
using the established method: apply a real edit to current source, `git diff
--unified=3`, revert. Both currently share the base blob `b594e64`.

- `0012_trace_after_departure.diff` (`:violation`, `:subtle`) deletes the whole
  six-line comment *and* the `pre_exit_state` binding, and swaps the trace's
  first argument to the post-departure `machine_state`.
- `0012_trace_prestate_captured.diff` (`:clean`, `:subtle`) renames
  `pre_exit_state` to `exit_set_state` and hoists the post-departure
  configuration read into a local `resulting_configuration`, changing neither the
  state the payload is stamped against nor the carried configuration.

st-ntf5's optional hand-run verification
([`docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md:665-682`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md#L665-L682))
tested a third variant that keeps the comment and deletes only the binding, found
it a false negative, and concluded that "part of the shipped row's signal is the
deleted comment naming the rule rather than the stamp swap alone. The shipped
fixture is unchanged; the gap is filed as **st-xsb1**." st-ntf5 declined to add a
pair itself (`:168-176`, `:751-756`) because "a new pair obliges a real-`claude`
measurement pass against the corpus scorecard that st-2ts owns, and this branch
is not the place to spend that."

The manifest note on `0012_trace_after_departure.diff` records the same
measurement and names this bead as holding the gap.

### 6. Which files a rubric or judge change would touch

| File | What lives there | Guarded? |
|---|---|---|
| `docs/adr/0012-debuggability-designed-into-the-core.md` | The entire ADR-0012 rubric, read verbatim into both prompts. Two prior amendments (st-1xwh, st-9i5r) establish the convention: append an `**Amendment (<bead>):**` block, leave the original sentence unedited | No |
| [`lib/mix/statifier/adr_judge.ex:174-182`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L174-L182) | The ADR-0012 `@judged` entry's `focus` string - the only per-ADR steering text | No |
| [`lib/mix/statifier/adr_judge.ex:513-541`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L513-L541) | `propose_prompt/1` - shared by all three judged ADRs | No |
| [`lib/mix/statifier/adr_judge.ex:543-585`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L543-L585) | `refute_prompt/1` - the grounding and tie rules | No |
| [`lib/mix/statifier/adr_judge.ex:214`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L214) | `@default_model` (st-2ts recommended reconsidering it; the recommendation stands unacted) | No |
| [`lib/mix/statifier/adr_judge.ex:606-611`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L606-L611) | `parse_refute/1` - two-outcome today; the skipped st-6f7 Phase 3 would make it three | No |
| `test/mix/statifier/adr_judge_test.exs` | Stubbed unit tests keyed on the literal strings `"PROPOSE PASS"` / `"REFUTE PASS"` (`:45`, `:145`, `:284`, …) and on `@adr_0012.focus`; `:799` asserts `adr_0012.adr_text =~ "Debuggability"` | No |
| `test/fixtures/adr_judge/manifest.exs` | The rows themselves | Under `test/`, scanned only for `@tag :skip` |
| `test/fixtures/adr_judge/*.diff` | The fixture diffs | Same |
| `test/mix/statifier/adr_judge_corpus_shape_test.exs` | The six shape assertions any new row must satisfy | Same |
| [`docs/testing.md:92-111`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/testing.md#L92-L111) | The mirrored subtle-tier summary rows and the repeat-policy sentence | No |
| `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:946+` | The `#### Phase 5 measurement (recorded)` subsection - the scorecard's physical home | No |
| `.quality.exs:33`, `:107-114` | The stage's enablement and definition. Untouched by a rubric or fixture change; any edit here does need a `docs/quality-gate-changes.md` entry (ADR-0011, [`lib/mix/statifier/gate_guard.ex:36`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/gate_guard.ex#L36)) | **Yes** |

A changelog fragment is not indicated: `changelog.d/README.md` scopes fragments to
"people who use the library" - public API, observable behavior, SCXML support,
user-visible bug fixes - and none of the above is one.

## Code References

- [`lib/statifier/interpreter/exit_entry.ex:105-127`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L105-L127) - `exit_states/2`'s `@doc`,
  step 6 naming `pre_exit_state` and the sanctioned-shape fixture
- [`lib/statifier/interpreter/exit_entry.ex:143-150`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L143-L150) - the six-line ADR-0012
  comment the false-negative variant preserves
- [`lib/statifier/interpreter/exit_entry.ex:151`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L151) - `pre_exit_state = machine_state`
- [`lib/statifier/interpreter/exit_entry.ex:159-163`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L159-L163) - the trace call, stamped from
  `pre_exit_state`, `configuration:` read post-departure
- [`lib/mix/statifier/adr_judge.ex:173-211`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L173-L211) - the `@judged` registry
- [`lib/mix/statifier/adr_judge.ex:174-182`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L174-L182) - the ADR-0012 entry and its `focus`
- [`lib/mix/statifier/adr_judge.ex:214-215`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L214-L215) - `@default_model`,
  `STATIFIER_ADR_JUDGE_MODEL`
- [`lib/mix/statifier/adr_judge.ex:242-249`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L242-L249) - `analyze/2`, the propose/refute pipeline
- [`lib/mix/statifier/adr_judge.ex:267-312`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L267-L312) - `collect/1`, base-ref resolution, scoping
- [`lib/mix/statifier/adr_judge.ex:346-356`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L346-L356) - `read_adr_source/1`, whole-file reads
- [`lib/mix/statifier/adr_judge.ex:425-449`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L425-L449) - `in_scope?/2`, `scoped_chunks/2`
- [`lib/mix/statifier/adr_judge.ex:480-503`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L480-L503) - `propose/2`, `survives_refute?/2`,
  both fail-closed
- [`lib/mix/statifier/adr_judge.ex:513-541`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L513-L541) - `propose_prompt/1`
- [`lib/mix/statifier/adr_judge.ex:543-585`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L543-L585) - `refute_prompt/1`
- [`lib/mix/statifier/adr_judge.ex:606-611`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L606-L611) - `parse_refute/1`
- [`lib/mix/statifier/adr_judge.ex:639-647`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L639-L647) - `to_finding/1`
- [`lib/mix/statifier/adr_judge.ex:660-667`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L660-L667) - `refuse_real_call/1`
- [`lib/mix/statifier/adr_judge.ex:684-704`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L684-L704) - `call_claude_cli/1` and its argv
- [`lib/mix/tasks/adr.judge.ex:44-47`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/tasks/adr.judge.ex#L44-L47) - the three skip reasons
- [`lib/mix/tasks/adr.judge.ex:92-94`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/tasks/adr.judge.ex#L92-L94) - findings to exit status
- [`lib/mix/statifier/gate_guard.ex:36`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/gate_guard.ex#L36) - `@guarded_paths`
- [`lib/mix/statifier/gate_guard.ex:141`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/gate_guard.ex#L141) - `interesting?/1`, why `test/` is scanned
- [`test/support/adr_judge_corpus.ex:17-18`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L17-L18) - manifest and fixture-dir paths
- [`test/support/adr_judge_corpus.ex:28-35`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L28-L35) - the row schema, in prose
- [`test/support/adr_judge_corpus.ex:37`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L37) - the whole loader
- [`test/support/adr_judge_corpus.ex:46-62`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L46-L62) - `source_for/1`
- [`test/mix/statifier/adr_judge_corpus_test.exs:13-14`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L13-L14) - moduletag and infinite timeout
- [`test/mix/statifier/adr_judge_corpus_test.exs:29-60`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L29-L60) - the generated tests
- [`test/mix/statifier/adr_judge_corpus_test.exs:65-67`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L65-L67) - the one real-caller call site
- [`test/mix/statifier/adr_judge_corpus_shape_test.exs:13-82`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_shape_test.exs#L13-L82) - the six shape checks
- [`test/test_helper.exs:9`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/test_helper.exs#L9) - the exclusion list
- `.quality.exs:29-33` - the disabled base stage
- `.quality.exs:35-43` - the `loop` and `merge` profiles
- `.quality.exs:107-114` - the `adr_judge` stage definition
- `test/fixtures/adr_judge/manifest.exs` - the 18 rows, including both ADR-0012
  subtle rows and their re-anchoring notes

## Architecture Documentation

- **ADR-0012** is the judged record. Its items 1-4 are constraints on interpreter
  shape; item 4 covers step counting and cause stamping, which is the family the
  pre-mutation stamping rule belongs to, but the ADR does not itself state which
  state a trace payload's counters are read from. Its two amendments (st-1xwh,
  st-9i5r) establish the convention for widening it: append an amendment block,
  leave the original sentence standing unedited, and say why it is an amendment
  rather than a new record.
- **ADR-0011** makes the gate's config non-agent-editable and mechanical:
  `mix gate.check` fails when a branch edits a guarded path without a
  `docs/quality-gate-changes.md` entry. Fixture files under `test/` are not a
  guarded path; the only thing scanned there is the `@tag :skip` pattern.
- **ADR-0017** point 6 governs the manifest-key classification prose in
  `CLAUDE.md`, and is itself the third judged ADR (registry key
  `adr-0015-swallowed-judgment`, scope `.claude/wurk`).
- **The fail-closed convention** runs through both judge passes: an error, an
  unparseable response, or an ambiguous refutation all resolve to "no finding".
  A judge change that made the pre-mutation rule detectable has to work with
  that, not around it.
- **The sabotage convention** (`docs/testing.md`, `CLAUDE.md`) exempts the corpus
  tests explicitly with a stated `# sabotage: n/a` reason rather than omitting
  the line - the shape any new generated test would follow.

## Historical Context

- `docs/plans/260804-st2-meo-adr-enforcement-stage.md` - origin of both guards.
  Phase 2 built `AdrJudge` for ADR-0012 alone, with the propose/refute two-pass
  design and the disabled-by-default `.quality.exs` posture.
- `docs/plans/260807-st-laz-adr-judge-multi-adr.md` - generalized to a registry,
  made the real caller unreachable from the ordinary suite after an incident
  where a test forgot `opts[:caller]` and billed on every gate run, and added
  ADR-0014.
- `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` - the refute-grounding
  fix and the four recorded baseline runs still cited in `docs/testing.md`. Its
  Phase 3 (mechanical `grounds` requirement) is recorded as skipped.
- `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md` - the `:subtle` tier,
  Decisions 1-3 (tier field, three-seed majority, eight-corpus-equivalent
  ceiling), and the Phase 5 scorecard. Touched `lib/` not at all.
- `docs/research/260818-st-2ts-adr-judge-harder-fixtures.md` - the research behind
  it, including the corpus scoring vocabulary (false negative, false positive,
  wrong-ADR attribution) and the note that `docs/quality-gate-changes.md` carries
  a voluntary entry for the `:adr_judge_corpus` tag exclusion because
  `mix gate.check` does not guard `test/test_helper.exs`.
- `docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md` - the
  third trace-site shape, the re-anchoring of both ADR-0012 fixtures, and the
  hand-run that measured the false negative and filed st-xsb1.

## Related Research

- `docs/research/260818-st-2ts-adr-judge-harder-fixtures.md`
- `docs/research/260815-st-0ej-bench-results-under-adr-0018.md` (AdrGuard side,
  not the judge)

## Open Questions

1. **Landing the violation half turns a paid run red on a row that has never been
   green.** The bead's acceptance criteria say "a fixture pair ... lands ... with
   expected verdicts in manifest.exs, and the st-2ts scorecard is re-measured to
   include them." The measured variant is a false negative today, so a row with
   `expect: :violation` will fail `mix test --only tier:subtle` at whatever
   verdict the manifest declares. Three shapes exist for resolving that, and
   st-2ts set the precedent that choosing among them is a human's call
   ([`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:1005-1013`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md#L1005-L1013)): amend
   ADR-0012 with a sentence about which state a trace payload's counters are
   stamped against; widen the ADR-0012 `focus` string at
   [`lib/mix/statifier/adr_judge.ex:174-182`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L174-L182); or land the row as a recorded known
   failure and reclassify. No option is taken here.
2. **The re-measurement cost appears to exceed the reserve.** Decision 2 defines a
   measurement as three runs *of the tier*, not of the added rows. A subtle tier
   of 12 fixtures at three seeds across two models is 72 fixture-runs = 4.0
   corpus-equivalents against a 1.2-run reserve. Whether "re-measure to include
   them" means a full-tier re-measurement, a two-fixture delta measurement folded
   into the existing matrix, or a ceiling raise is not settled by either
   document, and Decision 3 says raising the ceiling is a human's call
   (`:279-282`).
3. **Which tier the new pair joins.** The shape test requires both verdicts per
   `{key, tier}` ([`test/mix/statifier/adr_judge_corpus_shape_test.exs:39-49`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_shape_test.exs#L39-L49)), and
   the tier assertion admits only `:blatant` and `:subtle` (`:30-36`). The pair is
   subtle by the prose definition, but adding it to `:subtle` is what makes the
   re-measurement question above bite. A third tier would require editing that
   assertion and the `docs/testing.md` tier prose.
4. **Whether the clean half is a second fixture or the existing one.** The bead
   asks for a pair covering the deliberately post-mutation `configuration` read.
   `0012_trace_prestate_captured.diff` already exercises exactly that field
   surviving a meaning-preserving move (it hoists the post-departure read into
   `resulting_configuration`). Whether the new clean half must be distinct from
   it, and what it would vary that the existing one does not, is not determined
   by anything in the codebase.
5. **`docs/testing.md`'s recorded-scores table would need two edits, not one.**
   The subtle-tier rows (`:97-100`) and the blatant caveat paragraph
   (`:105-111`) both describe a 10-fixture subtle tier and an 18-fixture corpus.
   Whether the old numbers are superseded or annotated as measured against the
   smaller tier is a presentation decision the plan does not prescribe.
