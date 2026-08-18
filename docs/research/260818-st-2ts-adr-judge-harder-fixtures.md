---
date: 2026-08-18T15:13:24-0600
researcher: Claude
git_commit: ee532313b9fab59db7996abfa32456f81dcfd686
branch: st-2ts-adr-judge-harder-fixtures
repository: statifier-ex
beads_issue: st-2ts
topic: "How to harden the ADR judge fixture corpus with subtler violating fixtures, and whether the model default still holds"
tags: [research, codebase, gate-tooling, adr-judge]
status: complete
last_updated: 2026-08-18
last_updated_by: Claude
---

# Research: Harden the ADR judge corpus with subtler fixtures

**Date**: 2026-08-18T15:13:24-0600
**Git Commit**: ee532313b9fab59db7996abfa32456f81dcfd686
**Branch**: st-2ts-adr-judge-harder-fixtures
**Bead**: st-2ts

## Research Question

st-2ts asks for violating fixtures whose violation is real but not obvious -
changes the deterministic `AdrGuard`/`GateGuard` cannot see - with matching
clean fixtures so each pair differentiates the judge rather than rewarding a
verdict bias, and for a re-run of the `claude-sonnet-5` versus
`claude-haiku-4-5-20251001` comparison once the corpus is harder. This document
records how the judge, the corpus, the ADRs, the guards, and the recorded
baselines stand today, and which subtle-violation shapes are expressible as
plausible diffs against real files in this repo.

## Summary

The judge is a two-call pipeline over a diff already sliced per judged ADR. For
each registry entry it builds one propose prompt (ADR text + that entry's
in-scope diff hunks) and, for every candidate the propose pass returns, one
refute prompt carrying the same hunks. Only a candidate the refute pass
explicitly fails to overturn becomes a finding. Every parse failure and every
ambiguity fails closed toward "not a violation".

The corpus is eight hand-written unified-diff files bound to registry keys by
`test/fixtures/adr_judge/manifest.exs`. They are *not* captured `git diff`
output: they are text shaped like `git diff --unified=0 --src-prefix=a/
--dst-prefix=b/`, using real repository paths, and they need only parse through
`AdrJudge.scoped_chunks/2` and land in the scope their row claims. One of the
eight (`0014_*.diff`) names a path that does not exist in the tree
(`lib/statifier/compiler/expression.ex`) and an API that does not exist
(`Predicator.compile_with_spans/1` returning a bare tuple) - the corpus has
never depended on fixtures being applicable or current.

Three registry entries exist. Two share the `lib/statifier` scope (ADR-0012,
ADR-0014); the third scopes to `.claude/wurk` and, despite its key
`adr-0015-swallowed-judgment`, ships **ADR-0017**'s text, since ADR-0015 is
superseded. Every fixture and manifest note still speaks of "0015".

The four candidate shapes the bead names are all expressible against real files:
one-branch location drops in the lowering builders and validator checks,
`Effect.trace/3` call sites moved across a phase boundary inside
`exit_states/2`/`enter_states/2`/`execute_block/3`, a span table that stays
valid but whose anchor invariant (`Parser.Location.resolve_span/3`) is broken by
trimming the source before compile, and `.claude/wurk/*.md` steps that keep the
prose while making a script's output the only input the judgment can act on.

The model question is genuinely open. Both models scored 0/4 false negatives and
0/4 false positives on the current corpus; the decision fell to wall time
(91.4s sonnet vs 272.4s haiku) and was made by the user directly. Nothing about
that decision holds if a harder corpus separates them on accuracy.

## Detailed Findings

### The judge: prompt, call, parse, model knobs

`lib/mix/statifier/adr_judge.ex` (732 lines) and `lib/mix/tasks/adr.judge.ex`
(148 lines).

**The registry** ([`lib/mix/statifier/adr_judge.ex:173-211`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L173-L211)) is three maps, each
with `key`, `label`, `adr_path`, `scope` (`%{prefix:, suffix:, describe:}`) and
`focus` (the one-line failure vocabulary pasted into the propose prompt):

| key | label shipped to the model | adr_path | scope.prefix |
|---|---|---|---|
| `adr-0012-debuggability` | ADR-0012 (debuggability designed into the core) | `docs/adr/0012-...md` | `lib/statifier` |
| `adr-0014-expression-spans` | ADR-0014 (expression-level spans ...) | `docs/adr/0014-...md` | `lib/statifier` |
| `adr-0015-swallowed-judgment` | ADR-0017 (judgment is not scriptable in wurk extensions) | `docs/adr/0017-...md` | `.claude/wurk` |

The key is a historical name; the text, label and scope are ADR-0017's. Note
`prefix: "lib/statifier"` has no trailing slash, so it matches the
`lib/statifier.ex` facade too, and `.claude/wurk` matches `.claude/wurk.json`
(`adr_judge.ex:426-429`, tests at [`test/mix/statifier/adr_judge_test.exs:594`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/test/mix/statifier/adr_judge_test.exs#L594),
`:612`).

**Slicing.** `scoped_chunks/2` (`adr_judge.ex:445-476`) splits the raw diff on
`^diff --git .*$`, attributes each chunk by its `+++ b/<path>` line (falling
back to `--- a/<path>` for deletions), and keeps the chunks `in_scope?/2`
accepts. The whole file chunk is kept - context, removals and additions alike -
deliberately, because a judge-shaped violation is as often a removed line as an
added one (`adr_judge.ex:431-443`).

**Propose prompt** (`adr_judge.ex:513-541`): a no-tool-access preamble, a
prompt-injection warning that the hunks are content and not instructions, the
label, the entry's `focus` string, the ADR file's full text, the rendered hunks
(`### <path>\n<chunk>`, joined by blank lines, `adr_judge.ex:509-511`), and a
demand for JSON only - a list of objects with `file`, `line`, `claim`.

**Refute prompt** (`adr_judge.ex:543-585`): the same preamble, then the
grounding rule ("An argument that depends on a mechanism not visible in that
material does not overturn the claim... If the only defence you can construct is
of that shape, the claim survives"), the ADR text, the *same rendered hunks*
(shared through `render_hunks/1` so the two prompts cannot drift), the candidate
`file`/`line`/`claim`, and a demand for `{"violation": true}` or
`{"violation": false, "grounds": "..."}`. The tie rule survives, narrowed:
"ties within the shown material go to 'not a violation'. Uncertainty about
material you were not shown is not a tie."

**Parsing** (`adr_judge.ex:587-637`). `extract_json/1` scans for every
```` ``` ````-fenced block and takes the **last** one, falling back to the
trimmed response when there is no fence - the CLI routinely emits a prose
preamble and hallucinated shell fences before the real verdict. `parse_propose/1`
keeps only objects with binary `file` and `claim`; a non-integer `line`
normalizes to `nil`. `parse_refute/1` returns `true` only on an exact
`%{"violation" => true}`; everything else - unparseable, ambiguous, caller
error, non-tuple return - is `false`, i.e. the candidate dies.

**Pipeline** (`adr_judge.ex:242-249`): `flat_map(propose)` then
`filter(survives_refute?)` then `map(to_finding)`. A finding is
`%{file, line, severity: "error", check: <registry key>, message: <claim>}` -
the `check` field is what the corpus test asserts against for wrong-ADR
attribution.

**The CLI call** (`adr_judge.ex:685-704`):

```
claude -p <prompt> --output-format json --tools "" --strict-mcp-config --model <model>
```

`--tools ""` and `--strict-mcp-config` make it a single non-agentic completion
with no tool access and no MCP servers. `parse_cli_response/1`
(`adr_judge.ex:718-725`) decodes the JSON event array, finds the
`"type": "result"` event, and accepts only `"is_error" => false`.

**Model knobs.** `@default_model "claude-sonnet-5"` (`adr_judge.ex:214`), read
through `System.get_env("STATIFIER_ADR_JUDGE_MODEL", @default_model)`
(`adr_judge.ex:215`, `:686`). The env var is the only per-run knob; there is no
CLI flag and no per-registry-entry model. `@default_caller` (`adr_judge.ex:223-225`)
is `refuse_real_call/1` in `Mix.env() == :test` and `call_claude_cli/1`
otherwise, so a test that forgets `opts[:caller]` raises rather than spends.

**The task** (`lib/mix/tasks/adr.judge.ex`) exits 0 on no findings, 1 on a
surviving finding, and 2 for three distinct skips: no `claude` on `PATH`, no
base ref, or no in-scope changes. `.quality.exs:33` disables the `adr_judge`
stage by default; `.quality.exs:40-42`'s `merge` profile re-enables it, and
`.claude/wurk/mr.md:12-14` runs `mix quality --profile merge` unconditionally
before every push.

### The corpus: fixture format, manifest, scoring, exclusion, shape test

**Fixture format.** Hand-written text in `git diff --unified=0 --src-prefix=a/
--dst-prefix=b/` shape ([`docs/plans/260808-st-6f7-adr-judge-refute-grounding.md:178-181`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/docs/plans/260808-st-6f7-adr-judge-refute-grounding.md#L178-L181):
"They do not need to apply - they need to parse through
`AdrJudge.scoped_chunks/2` and land in the scope their row claims"). What is
actually required by the parser:

- a `diff --git a/<path> b/<path>` line to split on;
- a `+++ b/<path>` line (or `--- a/<path>`) to attribute the chunk;
- `@@` hunk headers and `+`/`-`/context lines are passed to the model verbatim
  and are not parsed by anything - only the model reads them.

Existing fixtures run 7-14 lines each. `0012_dropped_location.diff` was modeled
on the st-laz live repro but is still hand-written; the real
`lib/statifier/document/content.ex` has since moved on, and
`0014_*.diff`'s `lib/statifier/compiler/expression.ex` does not exist at all.
Fixture realism is therefore a property of the *prose plausibility* of the diff,
not of it matching HEAD.

**Manifest** (`test/fixtures/adr_judge/manifest.exs`): a plain `.exs` list of
`%{key:, file:, expect: :violation | :clean, note:}`, loaded with
`Code.eval_file/1` by `Mix.Statifier.AdrJudgeCorpus.manifest/0`
([`test/support/adr_judge_corpus.ex:34`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/test/support/adr_judge_corpus.ex#L34)). `source_for/1`
([`test/support/adr_judge_corpus.ex:43-59`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/test/support/adr_judge_corpus.ex#L43-L59)) looks the row's key up in
`AdrJudge.judged()`, reads the fixture and the registry entry's `adr_path`, and
builds a one-ADR `source()` - so a fixture is judged against exactly one
registry entry, never the whole registry.

**Scoring and reporting** (`test/mix/statifier/adr_judge_corpus_test.exs`). One
generated ExUnit test per manifest row, branch chosen at *generation* time so no
unreachable clause is compiled. A `:violation` row asserts `findings != []`
("FALSE NEGATIVE: ...") and then `Enum.any?(findings, &(&1.check == key))`
("WRONG ADR: ..."). A `:clean` row asserts `findings == []`
("FALSE POSITIVE: ..."). There is no aggregate scorer - ExUnit's pass/fail *is*
the score, which is why each message names its own failure class.
`@moduletag :adr_judge_corpus`, `@moduletag timeout: :infinity`,
`async: false`, and `caller: &AdrJudge.call_claude_cli/1` passed explicitly at
the one call site (`:56`).

**Tag exclusion.** `test/test_helper.exs`'s
`ExUnit.start(exclude: [:scion, :scxml_w3, :adr_judge_corpus])`. Recorded
voluntarily in [`docs/quality-gate-changes.md:251-279`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/docs/quality-gate-changes.md#L251-L279) (2026-08-08, st-6f7),
which notes `mix gate.check` does not guard `test/test_helper.exs`, so the entry
was written because narrowing what the suite runs is a human's call in spirit
even where the mechanical guard does not reach, and flags "whether
`test/test_helper.exs` should become a guarded path" as worth a maintainer's eye.

**Shape test** (`test/mix/statifier/adr_judge_corpus_shape_test.exs`, caller-free,
runs in the ordinary suite, spends nothing). Five invariants any new fixture
must satisfy:

1. every manifest row's file exists under `test/fixtures/adr_judge/`;
2. every row's `key` is a real registry key;
3. every registry entry has at least one `:violation` and one `:clean` row;
4. every fixture's diff produces non-empty `scoped_chunks/2` in its own scope
   **and empty chunks in a differing scope** - "differing" is found as the first
   registry scope not `==` its own, which today is always the `.claude/wurk`
   scope for a `lib/statifier` fixture and vice versa, because ADR-0012's and
   ADR-0014's scope maps are structurally equal;
5. no fixture contains the literal `@tag :skip` (it would trip `GateGuard`'s
   skip-tag scan, since fixtures live under `test/`).

Invariant 4 is the one with a hidden edge: a fixture whose diff touches files in
*both* scopes fails it, so a cross-cutting fixture is not expressible under the
current shape test.

### The ADRs: which claims a diff could violate

**ADR-0012** (`docs/adr/0012-debuggability-designed-into-the-core.md`), four
numbered constraints, all reader-in-context by nature:

1. microsteps are resumable values - machine_state fully reifies the
   between-microsteps position; "mid-macrostep state never lives only in loop
   variables or on the call stack";
2. trace is part of the effect vocabulary - structured trace effects at the
   phase boundaries Appendix D names (event dequeued, transitions selected, exit
   set, executable content, entry set, macrostep stable, done), gated by an
   option;
3. the Machine retains source locations and stable identities - locations on
   states, transitions, executable content, plus document-order indexes
   `t_index`, `c_index` and (2026-08-17 amendment, st-1xwh) `d_index`;
4. steps are counted and causes are stamped - monotonic macrostep/microstep
   counters; trace effects and internally raised events carry the step and the
   identity of what raised them.

Its Consequences section is effectively the judge's rubric: "a change that moves
microstep state off the struct, drops locations in the compiler, or raises an
internal event without cause metadata violates this ADR" (`:74-76`).

`docs/observability.md` is where the binding detail lives, and it holds the
subtlest checkable claims in the repo: constraint 2's "delivery order to a
subscriber is non-decreasing in `(macrostep, round)` across the whole run", its
"either selection function... with no exception - including the terminal
eventless probe", and constraint 4's "they advance in exactly one place each",
"`begin_macrostep/1` resets both child counters", and "exactly one
`MacrostepStable` per `(macrostep, round)`".

**ADR-0014** (`docs/adr/0014-expression-spans-in-cond-diagnostics.md`), six
items plus two amendments:

1. spans, not point positions (`compile_with_spans/1`, `spans: true`, `:span` on
   errors; the 3.7/3.8 point API is skipped, with a stopgap clause storing the
   table in the same field);
2. the table travels with the instructions - `%Predicator.Compiled{}` returned
   whole; the compiled-expression value widens to
   `{:compiled, %Predicator.Compiled{}, source}` rather than growing a fourth
   element; `evaluate/3` never gets an explicit `:positions` alongside a
   `%Compiled{}` (that raises `ArgumentError`);
3. spans are always on - "no gate, no option";
4. what an expression failure names - owning-node constraint-3 identity, the
   expression source string, the predicator error struct verbatim, and its
   `:span`. The 2026-08-15 amendment puts the boundary at the predicator seam
   (an engine policy check after predicator succeeded is not an expression
   failure) and the 2026-08-18 amendment adds that a `protected_roots:` refusal
   is a policy check, not a predicator error - explicitly a judgment the earlier
   mechanical test can no longer make;
5. `on_unbound: :error` for cond evaluation, superseding after-the-fact
   `unbound_loads/1` inspection;
6. `Context.bound?/2` is not part of cond diagnostics.

**ADR-0017** (`docs/adr/0017-judgment-not-scriptable-in-wurk-extensions.md`),
the live policy; ADR-0015 is superseded and "no tool should read it as current"
(`:108-112`). Point 1: a `.claude/wurk/*.md` extension may name a script, a
`mix` task or a generic skill step for mechanics, and must state the policy
itself wherever a step is a policy call, a human gate, or a verification
discipline; "Handing such a step to a script - or deleting it rather than
restating it - is the violation", and "the tell is prose that turns a discipline
into a check on its own artifact". Point 6 (st-8nj) extends the scope to
`.claude/wurk.json`: a manifest key that encodes a policy call must have the
policy stated in prose it points back to, while "Adding or changing a genuine
constant - a command, a path, a name, a threshold that is a project fact rather
than a choice about what blocks - is not a violation and must not be reported as
one."

**Other plausible corpus subjects.** The judge's own survey
(`adr_judge.ex:88-118`) discusses ADR-0001 through ADR-0015 only. The repo now
holds 47 ADRs; ADR-0016 and ADR-0018 through ADR-0047 have no recorded verdict
either way in that survey. Of those, the ones that state a positive, code-shaped
constraint whose violation needs a reader in context are: the round-counter
family (ADR-0019 round budget, ADR-0020 round ordinal, ADR-0032 the budget spans
the invoke re-entry, ADR-0046 every core effect carries `round`), the
failure-mode family (ADR-0021 donedata, ADR-0031 invoke argument, ADR-0036 send
argument - each specifying exactly which error is raised, with what metadata, and
what does *not* happen), ADR-0034 (replay is not a live session; "the session
gains no replay mode"), ADR-0038/0041/0042 (single-seam claims about invoke
source resolution and content slices), and ADR-0044 (monotone arrival order for
re-entry effects). ADR-0018 (no process jargon in comments) is already partly
mechanical in `AdrGuard`.

### The deterministic guards, and what they cannot see

`Mix.Statifier.AdrGuard` (`lib/mix/statifier/adr_guard.ex`) covers ADR-0002
(near-miss Appendix D names, Jaro >= 0.84, scoped to
`^lib/statifier/interpreter`), ADR-0003 (a fixed list of effect call patterns -
`GenServer.`, `Process.send`, `File.\w+!?(`, `System.cmd(`, `spawn`, `receive do`
and friends - under `lib/statifier/` minus `session.ex`, `supervisor.ex`,
`session/telemetry.ex`), ADR-0004 (`Code.eval_string|quoted(` anywhere under
`lib/`), ADR-0008 (`:crypto.strong_rand_bytes(`, `UUID.uuid4(`,
`System.unique_integer(` etc. under `lib/statifier/`) and ADR-0018 (`st-<id>`
inside comment/doc text under `lib/` or `test/`). The escape hatch is
`ADR-0\d{3}|deviation` on the flagged line or the added line above it; ADR-0018
has its own, narrower `ADR-0018-exempt`.

`Mix.Statifier.GateGuard` (`lib/mix/statifier/gate_guard.ex`) flags any hunk in
`.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf`, `.doctor.exs`;
added `mix.exs` lines matching a fixed keyword regex; added `test/` lines
matching `@(module)?tag :skip|:pending`; and a `test/passing_tests.json` shrink
computed by comparing *parsed* JSON at the merge base against the working tree.
A finding clears when the same diff adds a `docs/quality-gate-changes.md` line
containing `Approved-by:` and some added ledger line contains the finding's file
path as a substring.

What both are blind to, which is exactly the design space for harder fixtures:

- **Removed lines are invisible to `AdrGuard` entirely.** `parse_diff/1`
  (`adr_guard.ex:511-535`) has no `-` case. Deleting a safeguard, a threading
  step, or the line that made something compliant produces no entry.
- **No data flow, no call graph, no AST.** Every check is a single-line regex
  over added text. Threading a value through one branch but not another,
  reordering two statements, or rebuilding a value from a different source is
  outside the model entirely.
- **Reordering is invisible to both.** Moving an `Effect.trace/3` call from
  before a fold to after it adds and removes lines whose text matches nothing in
  either pattern list.
- **Semantics of a preserved shape are invisible.** A tuple that still has three
  elements, a struct that still has a `:location` key, a span table that still
  exists - none of these are things the guards inspect for meaning.
- **`GateGuard`'s scope is a fixed list of five filenames** plus `mix.exs`
  keywords; a threshold moved into any other file is unrecognized.
- **`@tag :skip` is the only "disable a test" shape `GateGuard` knows.** A test
  body hollowed out to a tautology is not detected.

### Recorded baselines and the refute-pass fix (st-6f7)

From `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` and mirrored in
[`docs/testing.md:26-79`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/docs/testing.md#L26-L79):

| Run | Model | FN | FP | Wall |
|---|---|---|---|---|
| Phase 1 baseline (ungrounded refute prompt) | haiku-4-5-20251001 | 4/4 | 0/4 | 357.9s |
| Confirmatory rerun, same prompt, seed 675107 | haiku-4-5-20251001 | 3/4 | 0/4 | 329.9s |
| Phase 2 (grounded refute prompt) | haiku-4-5-20251001 | 0/4 | 0/4 | 272.4s |
| Phase 4 (same grounded prompt) | claude-sonnet-5 | 0/4 | 0/4 | 91.4s |

Per-fixture Phase 4 timings ran 5.4s-15.1s; Phase 1's ran 11.2s-78.1s. A real
three-entry `mix adr.judge` on a comment-only scratch diff took 54.4s (haiku)
against 19.6s (sonnet).

The bug was three compounding parts of the old `refute_prompt/1`: no tool
access, an unconditional instruction to construct a defence ("Only conclude it
survives if you cannot construct that argument"), and a tie-break to
"not a violation" - plus the refute pass never seeing the diff. The live st-laz
incident overturned a real dropped-`:location` violation on a hypothesized
"side table, index, or other data structure keyed by content ID" that does not
exist. The fix showed the hunks, named that exact hypothesis shape as
non-refuting, and narrowed the tie rule to material actually shown. Phase 3 (a
mechanical rule promoting an ungrounded `false`) was specified but skipped,
because Phase 2 alone reached 0/0.

The plan's confirmatory rerun is the important methodological note for st-2ts:
**the live judge is not deterministic run to run.** One fixture
(`0015_delegated_judgment.diff`) false-negatived on the first baseline run and
passed on the second under identical prompts. A single run of a harder corpus is
not a measurement.

**Open Question 6**, verbatim from the plan:

> **Fixture count and hand-authored realism.** *Assumed eight fixtures,
> hand-written.* "Real diffs cut from git history would be more faithful but pin
> the corpus to specific commits and drift as the repository grows. If the
> hand-written diffs turn out to be too clean to be a fair test (every violating
> fixture caught trivially, every clean one obviously clean), the corpus needs
> harder cases before its score means anything - that judgment happens at the
> Phase 1 baseline."

Phase 1's own answer deferred it: "each of the four violating fixtures is a
deletion or an omission that the deterministic guards would catch instantly, and
the judge suppressed all four. If anything the fixtures are on the blatant end,
which makes a 0/4 detection rate the strongest possible form of the finding.
Harder cases can wait until the stage detects the easy ones." st-2ts is the
bead where that wait ends.

Open Question 3 also set the only recorded time bound: under 6 minutes for a
three-entry `mix adr.judge` run. It bounds the *stage*, not the corpus.

### Cost and latency reality

Each fixture costs one propose call plus one refute call per proposed candidate
(so a clean fixture that proposes nothing costs one call; a violating fixture
costs two or more). The corpus as it stands is 91.4s on sonnet and 272.4s on
haiku, against real spend. [`docs/testing.md:44-48`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/docs/testing.md#L44-L48) records "~15-20 minutes for
the full corpus" as the conservative figure, and the bead's notes say
"90-360 seconds".

Scaling arithmetic for planning: doubling the corpus to 16 fixtures roughly
doubles a run, so ~3 minutes (sonnet) or ~9 minutes (haiku). A model comparison
needs one run of each; the non-determinism observed at baseline argues for more
than one run per model, which multiplies again. Nothing in the repo budgets this
beyond "hand-run, tag-excluded, and the plan runs it a bounded number of times
rather than in a loop" (`docs/plans/260808-...:847-860`).

### Candidate subtle-violation shapes, grounded in real files

All four shapes the bead names are expressible. Each is invisible to both
guards for the reasons in the guard section above.

**Shape A - location preserved but not threaded through one branch.**

- [`lib/statifier/lowering/builders.ex:1187-1197`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/lowering/builders.ex#L1187-L1197): `place/3`'s two catch-all
  clauses each build `Error.misplaced(_, _, location)` from a different
  expression (`node.location`, `Map.fetch!(value, :location)`), and sit directly
  after an `%Assign{}` clause (`:1161-1170`) that deliberately reads
  `node_location` instead. A diff that changes one clause's location expression
  leaves the struct field, the `Error.misplaced/3` signature
  ([`lib/statifier/lowering/error.ex:55-61`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/lowering/error.ex#L55-L61)) and the sibling clauses untouched.
- [`lib/statifier/lowering/builders.ex:656-669`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/lowering/builders.ex#L656-L669): `build_else/2`'s
  `attribute.location || element.location` fallback inside one arm of a
  two-clause `case`. Dropping the `||` half is a one-token diff.
- [`lib/statifier/validator/checks/data.ex:80-125`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/validator/checks/data.ex#L80-L125): three callers
  (`expr_and_src_errors/1`, `value_and_children_errors/1`,
  `reserved_id_errors/1`) share `id_location/1`
  (`Map.get(attribute_locations, :id, location)`). Changing exactly one call
  site to pass `data.location` directly loses the attribute-level precision the
  moduledoc states for all three.

The matching clean fixture is the same refactor done right: extract the helper,
or rename the field, with every branch still threading the location - the
existing `0012_rename_keeps_location.diff` is the blunt version of that idea.

**Shape B - trace effect on the wrong side of a phase boundary.**

`Effect.trace/3` ([`lib/statifier/effect.ex:51-84`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/effect.ex#L51-L84)) stamps macrostep, microstep
and round from the `machine_state` it is handed at call time, so *which*
`machine_state` reaches it is the whole semantics.

- [`lib/statifier/interpreter/exit_entry.ex:136-157`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter/exit_entry.ex#L136-L157): `exit_states/2` builds
  `Trace.ExitSet` **before** `record_history_values/2` and before the `depart/2`
  reduce, and its moduledoc (`:109-133`) says so deliberately. Moving that one
  line below the reduce keeps the identical struct and `indexes:` list while
  stamping it against post-departure state.
- [`lib/statifier/interpreter/exit_entry.ex:671-688`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter/exit_entry.ex#L671-L688): `enter_states/2` is the
  mirror image, documented at `:662-663` as stamped "over the *original*
  `machine_state`".
- [`lib/statifier/interpreter/content.ex:155-177`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter/content.ex#L155-L177): `execute_block/3` is
  deliberately the *opposite* convention - `Trace.ContentExecuted` is stamped
  from the block's final `machine_state` and appended last. Swapping it to the
  pre-fold local, while leaving list position unchanged, is the same bug in the
  other direction.

[`lib/statifier/interpreter.ex:60-90`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter.ex#L60-L90) documents the counter contract these
fixtures would violate in prose the model can be shown: the initial entry is
microstep 1, an external event's `EventDequeued`/`TransitionsSelected` carry
microstep 0, selection-round traces are "always stamped *one microstep behind*
the `Trace.ExitSet` that follows them", and `begin_round/1` has exactly one call
site. Any of those sentences is a clean-fixture opportunity too: a refactor that
visibly preserves the ordering is the pair.

**Shape C - span table retained but rebuilt from data that lost its positions.**

[`lib/statifier/compiler/expressions.ex:86-97`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/compiler/expressions.ex#L86-L97) (`compile/3`) and `:202-211`
(`compile_program/3`) hand `source` straight to
`Predicator.compile_with_spans/1` and store `{:compiled, compiled, source}`. The
invariant that makes the stored table meaningful lives elsewhere, in
[`lib/statifier/parser/location.ex:94-97`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/parser/location.ex#L94-L97):

> Requires `value`'s position `{1, 1}` to be `value_location`'s start - true of
> every attribute-sourced expression, since
> `Statifier.Compiler.Expressions.compile/3` does not trim. A caller that
> trimmed before compiling must adjust the anchor itself.

So a diff at any of `compile/3`'s roughly eleven call sites in
`lib/statifier/compiler.ex` (`:792`, `:843`, `:893`, `:947`, `:1073`, `:1107`,
`:1258`, `:1423`, `:1529`, `:1648`, `:1722`) that passes a trimmed or normalized
source keeps a perfectly well-formed `positions` table over the trimmed string,
keeps the tuple shape ADR-0014 item 2 demands, and silently offsets every span
`resolve_span/3` later produces. `expressions.ex:149-160` (`inline_value/1`)
already trims before compiling in this same module, which makes the change read
as consistency rather than a bug - which is exactly the property a hard fixture
wants. [`lib/statifier/evaluator/error.ex:29-44`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/evaluator/error.ex#L29-L44) is the downstream site if the
fixture prefers the error-payload half of item 4.

**Shape D - a wurk extension whose judgment step is hollowed out.**

Seven files under `.claude/wurk/` (`codebase.md` 95 lines, `commit.md` 68,
`implement.md` 99, `iterate.md` 21, `mr.md` 43, `plan.md` 68, `research.md` 63).
Three real steps that pair mechanics with a policy call:

- `.claude/wurk/commit.md:15-23`: the sabotage refusal - "what is never fine is
  committing a test with no note. Refuse and report which tests are unverified
  rather than inventing a note for a mutation that was never run". A rewrite that
  keeps the mechanical steps and makes `data.sabotage.missing` being empty the
  sufficient condition drops the refuse-on-fabrication clause while the prose
  around it still reads like policy.
- `.claude/wurk/implement.md:30-37`: "A test that stays green under sabotage is
  broken... Deleting a function body or raising unconditionally is not a
  mutation." This is a judgment rule about what *counts* as a mutation, adjacent
  to numbered mechanical steps; hollowing it into "run the mutation, check the
  gate reports red" loses the disqualification entirely.
- `.claude/wurk/mr.md:24-26`: "**A finding is a hard refuse.** Treat it exactly
  as a red gate... Do not push past an ADR judge finding in the hope it is a
  false positive." Hollowing this to "push if the command exits 0" keeps a step
  that names the script and loses the refusal.

ADR-0017 point 6 opens a second sub-shape here that has no fixture today: a
`.claude/wurk.json` key that encodes a policy call with no prose pointing back
at it. The manifest's own `gate.project_level_skips`,
`gate.not_applicable_skips`, `gate.sabotage.exempt_prefixes` and
`beads.areas.lands_alone` are the named policy-bearing keys, and `CLAUDE.md`'s
"Which skipped stages are gaps and which will never apply" section is the prose
they point back to - so both the violating fixture (a new skip pattern with no
prose) and the clean one (a genuine constant like a changed command array) are
directly expressible.

### Constraints any new fixture has to satisfy

1. It must parse into `scoped_chunks/2` - `diff --git` line plus `+++ b/<path>`.
2. Its path must fall in exactly one registry scope and produce empty chunks in
   the differing scope (shape test invariant 4). No cross-scope fixture.
3. It must not contain the literal `@tag :skip`.
4. Its `key` must already exist in the registry, or the branch must add a
   registry entry **and** a matching literal-path `read_adr_source/1` clause
   (`adr_judge.ex:346-356`, one clause per entry for Sobelow's benefit).
5. Its `note` should say what the violation is, since the note is interpolated
   into the false-negative failure message.
6. Per the bead: every violating fixture wants a matching clean fixture of the
   same *shape*, not merely of the same ADR, or the pair rewards a verdict bias
   rather than differentiating.

## Code References

- [`lib/mix/statifier/adr_judge.ex:173-211`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L173-L211) - the three-entry judged registry
- [`lib/mix/statifier/adr_judge.ex:214-215`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L214-L215) - `@default_model`, `@model_env`
- [`lib/mix/statifier/adr_judge.ex:242-249`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L242-L249) - propose/refute/finding pipeline
- [`lib/mix/statifier/adr_judge.ex:346-356`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L346-L356) - one literal `read_adr_source/1` clause per entry
- [`lib/mix/statifier/adr_judge.ex:445-476`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L445-L476) - `scoped_chunks/2` and chunk attribution
- [`lib/mix/statifier/adr_judge.ex:509-541`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L509-L541) - `render_hunks/1` and the propose prompt
- [`lib/mix/statifier/adr_judge.ex:543-585`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L543-L585) - the grounded refute prompt
- [`lib/mix/statifier/adr_judge.ex:587-637`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L587-L637) - propose/refute parsing and `extract_json/1`
- [`lib/mix/statifier/adr_judge.ex:685-704`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_judge.ex#L685-L704) - the `claude` CLI invocation
- [`lib/mix/tasks/adr.judge.ex:44-47`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/tasks/adr.judge.ex#L44-L47) - the three skip reasons
- [`test/support/adr_judge_corpus.ex:43-59`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/test/support/adr_judge_corpus.ex#L43-L59) - `source_for/1`
- [`test/mix/statifier/adr_judge_corpus_test.exs:23-57`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/test/mix/statifier/adr_judge_corpus_test.exs#L23-L57) - generated scoring tests
- [`test/mix/statifier/adr_judge_corpus_shape_test.exs:14-76`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/test/mix/statifier/adr_judge_corpus_shape_test.exs#L14-L76) - the five cheap invariants
- [`test/fixtures/adr_judge/manifest.exs:1-50`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/test/fixtures/adr_judge/manifest.exs#L1-L50) - the eight rows
- [`lib/mix/statifier/adr_guard.ex:511-535`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/adr_guard.ex#L511-L535) - added-lines-only diff parsing
- [`lib/mix/statifier/gate_guard.ex:36-52`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/gate_guard.ex#L36-L52) - guarded paths, mix.exs keywords, skip-tag pattern
- [`lib/mix/statifier/gate_guard.ex:206-236`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/mix/statifier/gate_guard.ex#L206-L236) - the ratchet shrink comparison
- [`lib/statifier/effect.ex:51-84`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/effect.ex#L51-L84) - `Effect.trace/3`'s counter stamping
- [`lib/statifier/interpreter.ex:60-90`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter.ex#L60-L90) - the counter contract for trace stamping
- [`lib/statifier/interpreter/exit_entry.ex:136-157`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter/exit_entry.ex#L136-L157) - `Trace.ExitSet` before departure
- [`lib/statifier/interpreter/exit_entry.ex:671-688`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter/exit_entry.ex#L671-L688) - `Trace.EntrySet` before arrival
- [`lib/statifier/interpreter/content.ex:155-177`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/interpreter/content.ex#L155-L177) - `Trace.ContentExecuted` after the block
- [`lib/statifier/compiler/expressions.ex:86-97`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/compiler/expressions.ex#L86-L97) - `compile/3`, no trimming
- [`lib/statifier/parser/location.ex:94-97`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/parser/location.ex#L94-L97) - the anchor invariant a trim would break
- [`lib/statifier/evaluator.ex:271-289`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/evaluator.ex#L271-L289) - `%Compiled{}` passed whole, never with `:positions`
- [`lib/statifier/evaluator/error.ex:29-44`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/evaluator/error.ex#L29-L44) - the ADR-0014 item 4 payload
- [`lib/statifier/lowering/builders.ex:656-669`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/lowering/builders.ex#L656-L669), `:1187-1197` - one-branch location sites
- [`lib/statifier/validator/checks/data.ex:80-125`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/lib/statifier/validator/checks/data.ex#L80-L125) - three callers of one location helper
- `.claude/wurk/commit.md:15-23`, `.claude/wurk/implement.md:30-37`, `.claude/wurk/mr.md:24-26` - judgment steps
- `.quality.exs:33`, `:40-42`, `:100-114` - the disabled-by-default stage and the merge profile
- `test/test_helper.exs` - the `:adr_judge_corpus` exclusion

## Architecture Documentation

The judge exists because ADR-0012, ADR-0014 and ADR-0017 state rules that are
judgment calls rather than name or call-site patterns; `AdrGuard`'s moduledoc
carries the mirror-image survey for the mechanically checkable ADRs, and the two
are meant to be read as a pair (`adr_judge.ex:120-123`). ADR-0011 is why the
stage may not be weakened to go green, and why `mix gate.check` guards the
gate's own config; ADR-0017 point 2 is why the `adr-0015-swallowed-judgment`
entry ships ADR-0017's text rather than the superseded ADR-0015's. ADR-0009
places the whole thing inside `mix quality`. `docs/observability.md` is the
binding detail behind ADR-0012 and is where the finest-grained checkable claims
live (counter advancement sites, `(macrostep, round)` monotonicity, one
`MacrostepStable` per round).

## Historical Context

- `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` - the corpus's origin,
  the four recorded runs, the refute-grounding fix, and Open Questions 1-6.
- `docs/plans/260804-st2-meo-adr-enforcement-stage.md` - the stage's original
  design, including `STATIFIER_ADR_JUDGE_MODEL`.
- [`docs/quality-gate-changes.md:251-279`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/docs/quality-gate-changes.md#L251-L279) - the voluntary 2026-08-08 st-6f7 entry
  for the tag exclusion.
- [`docs/testing.md:26-79`](https://github.com/riddler/statifier-ex/blob/ee532313b9fab59db7996abfa32456f81dcfd686/docs/testing.md#L26-L79) - the corpus as a fourth suite, the recorded score
  table, and how to read a failure.
- st-laz (2026-08-07) is the live incident the refute-grounding fix answers;
  st-c8c is the incident behind `refuse_real_call/1`.

## Related Research

No prior research document in `docs/research/` covers the ADR judge; the
material is all in the two plans above.

## Open Questions

1. **How many runs make a measurement?** The Phase 1 confirmatory rerun showed
   one fixture flipping verdicts between two runs of an identical prompt. A
   harder corpus will sit closer to the model's decision boundary, so
   single-run scoring is likely to be noise. Nothing in the repo records a
   policy for repeated runs, and the cost of repeating scales linearly. Recorded
   here rather than decided: how many runs per model a model comparison needs is
   a spend decision.
2. **Does the corpus grow or split?** The shape test requires each registry
   entry to have both verdicts, but nothing distinguishes "blatant" from
   "subtle" rows. If the harder fixtures join the existing eight, a green score
   no longer says which tier passed; if they replace them, the recorded
   baselines stop being comparable. A third option - a `tier:` field on the
   manifest row - would need the corpus test's failure messages to carry it.
   Not decided here.
3. **Is a cross-scope fixture wanted?** Shape test invariant 4 forbids a fixture
   touching both `lib/statifier` and `.claude/wurk`. A real branch often touches
   both, and the judge handles it by running one propose call per entry - but no
   fixture exercises that path.
4. **Do the ADRs added since the judge's survey want verdicts?** ADR-0016 and
   ADR-0018 through ADR-0047 are unaddressed by `adr_judge.ex:88-118`. The
   round-counter family (0019/0020/0032/0046) and ADR-0044's arrival-order
   invariant are the strongest judge-shaped candidates, and adding either as a
   registry entry would also give the corpus a scope that is neither of today's
   two - which would change what invariant 4's "differing scope" resolves to.
   Whether to widen the registry at all is out of st-2ts's stated scope.
5. **Should `@default_model` move if haiku wins on accuracy?** The bead
   anticipates the tradeoff reversing. The recorded decision was the user's own,
   made on wall time with accuracy tied; a harder corpus that separates the
   models on accuracy would re-open a call the record says a human made.
6. **Fixture prose realism has no test.** The bead warns that "a fixture that is
   ambiguous to a human reviewer is not a known-violating fixture". Nothing
   mechanical can check that, and the shape test deliberately does not try - so
   the review of each new fixture's unambiguity is a human read, and the only
   evidence available cheaply is the corpus score itself.
