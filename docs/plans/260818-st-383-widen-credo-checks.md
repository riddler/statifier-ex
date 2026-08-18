# Widen the enabled credo check set - Implementation Plan

## Overview

`.credo.exs` was generated with `mix credo gen.config` under st-vbu, so the repo
owns the full check list and nothing turns itself on. Most of what sits in
`disabled:` is there because gen.config put it there, not because this project
decided against it. Bead st-383 walks that list and moves everything this repo
already satisfies (or can cheaply be made to satisfy) into `enabled:`, adopts
the grouped multi-alias style across the tree, and writes down a reason for
every candidate that stays out.

Bead: st-383.

**Review status**: drafted 2026-08-18 against `24c85ae`, structurally validated,
and reviewed by the plan critic (two findings applied: the LeakyEnvironment
decision folded into Phase 8 rather than standing as its own commit-less phase,
and Phase 1's exclusion judgment moved out of the Automated list). It has **not**
been reviewed by a human - it was authored in a session with none available, so
every judgment call it makes is recorded in "## Open Questions" for a reviewer
to overturn cheaply.

The whole job is gated by one thing that is not code: `.credo.exs` is a
gate-guarded path under ADR-0011, so `mix gate.check` fails any branch that
edits it without an entry in `docs/quality-gate-changes.md` naming that path,
and CLAUDE.md makes that entry a human's call. This plan therefore pushes every
edit to `.credo.exs` into a single phase at the end, so that six of the eight
phases commit freely and exactly one hits the guard.

## Current State Analysis

### The baseline is clean

`mix credo --strict` reports zero findings on `24c85ae`. That matters twice
over: it means every count below is a count of new findings a candidate check
would introduce, and it means each cleanup phase's own verification is
unambiguous.

### The bead's counts have drifted, and one of them changes a decision

The bead measured its counts against `456d28e`. HEAD is 206 commits later.
Re-measured on `24c85ae` with a trial config (every candidate moved to
`enabled:`, `--strict`, `lib/` and `test/` both in scope), the picture is:

| Check | Bead (456d28e) | Now (24c85ae) |
|---|---|---|
| Design.SkipTestWithoutComment | 0 | 0 |
| Readability.SeparateAliasRequire | 0 | 0 |
| Readability.WithCustomTaggedTuple | 0 | 0 |
| Refactor.MapMap | 0 | 0 |
| Refactor.DoubleBooleanNegation | 0 | 0 |
| Refactor.RejectFilter | 0 | 0 |
| Refactor.PreferDateTimeShift | 0 | 0 |
| Warning.LazyLogging | 0 | 0 |
| Warning.MapGetUnsafePass | 0 | 0 |
| Readability.SingleFunctionToBlockPipe | 1 | 1 |
| Refactor.FilterReject | 2 | 2 |
| Readability.BlockPipe | 2 | **5** |
| Refactor.NegatedIsNil | 4 | **24** |
| Warning.LeakyEnvironment | 8 | 8 |
| Refactor.ABCSize | 12 | **28** |
| Refactor.AppendSingleItem | 17 | **23** |
| Readability.UnusedFunctionParameterPattern | 21 | **22** |
| Consistency.MultiAliasImportRequireUse | 1 (`:single` direction) | 1 (`:single` direction) |

Step 1's nine checks are still free. The step 3 list grew, and `Refactor.ABCSize`
grew enough to settle its open question in the opposite direction from the one
the bead sketched - see "Key Discoveries".

### The alias picture

1424 single `alias` directives across `lib/` and `test/` against exactly one
grouped directive (`lib/statifier/document.ex:89`). 573 of the singles are in
`lib/`, 851 in hand-written `test/`, and **zero** in the generated corpus
(`test/scxml_tests/`, `test/scion_tests/`) - the bead's claim that the corpus
emits no aliases is confirmed, so the regression ratchet is not involved. A
crude per-file grouping pass (two or more singles sharing a base namespace)
finds 178 files, 996 collapsible lines, 238 resulting grouped directives. That
is an upper bound, not a target: it counts aliases inside function bodies, which
the consistency collector ignores, and it applies none of the bead's judgment
exclusions. 63 directives carry `, as: ` and cannot be grouped at all.

### The guard

`lib/mix/statifier/gate_guard.ex:36` lists `.credo.exs` in `@guarded_paths`.
`lib/mix/statifier/gate_guard.ex:182` raises a finding for any guarded path in
the diff, cleared only by an entry in `docs/quality-gate-changes.md` naming that
path with an `Approved-by:` line. The stage runs as `Gate guard` inside
`mix quality`, so a `.credo.exs` edit makes the *full gate red*, not just a
policy stop - which is why it cannot be smuggled past by committing carefully.

## Desired End State

- Every check named in the bead's steps 1-3 is in `.credo.exs`'s `enabled:`
  list, or stays in `disabled:` with a comment in the file giving the reason.
- `Credo.Check.Consistency.MultiAliasImportRequireUse` is enabled and reports
  the `:multi` direction, because the grouped form now dominates the tree.
- `Credo.Check.Readability.MultiAlias` is still in `disabled:`, with a comment
  saying it is the direct contradiction of this bead rather than a companion to
  it.
- `docs/quality-gate-changes.md` carries a human-written, human-approved entry
  naming `.credo.exs`.
- A bare `mix quality` is green, attested by `mix gate.verify`.

Verify with:

```bash
mix quality                       # bare, unscoped
mix gate.verify                   # proves the run was a full gate
mix credo --strict                # zero findings
```

and by reading `.credo.exs` for the four written-reason comments
(`Readability.MultiAlias`, `Refactor.ABCSize`, `Refactor.AppendSingleItem`, and
`Warning.LeakyEnvironment`'s path exclusion).

Sixteen checks end up enabled; three end up staying out with a reason in the
file. The bead's acceptance criterion is satisfied either way - "in `enabled:`,
**or** has a written reason in the file for staying out" - but the reasons are
measured, not assumed, in all three cases.

### Key Discoveries

- **`mix credo --strict --enable-disabled-checks <pattern>` exists and works.**
  This is the mechanism that makes this plan possible. Every cleanup phase can
  be verified against the check it is cleaning up *without touching
  `.credo.exs`*, so no cleanup phase is blocked on the ledger entry. Confirmed
  by running `mix credo --strict --enable-disabled-checks Refactor.NegatedIsNil`,
  which returns the 24 sites the trial config found.
- **`Refactor.ABCSize` does not duplicate `Refactor.CyclomaticComplexity` here -
  it is entirely disjoint from it.** The bead offers "if the same functions are
  flagged by both, enabling it buys little" as a possible reason to leave ABCSize
  out. That premise is false on this tree: `CyclomaticComplexity` (already
  enabled, `max_complexity: 9`) reports **zero** findings, so the 28 ABCSize
  findings overlap nothing. Enabling it would be 28 real refactors, and they
  concentrate exactly where spec fidelity lives -
  `lib/statifier/lowering/builders.ex` (5), `lib/statifier/interpreter.ex` (4),
  `lib/statifier/compiler.ex` (4), plus `interpreter/datamodel.ex`,
  `interpreter/exit_entry.ex`. That is the same territory ADR-0002 protects and
  the same argument that already keeps `Design.DuplicatedCode` and
  `Refactor.CondInsteadOfIfElse` out. The reason changes, the conclusion holds:
  ABCSize stays out, with the *measured* reason written into `.credo.exs`.
- **All 8 `Warning.LeakyEnvironment` sites are dev-only tooling, and none are in
  `lib/statifier/`.** They are `lib/mix/statifier/adr_judge.ex:406` and `:700`,
  `lib/mix/statifier/adr_guard.ex:256`, `lib/mix/statifier/gate_guard.ex:177`,
  `lib/mix/tasks/gate.verify.ex:140`, `lib/mix/tasks/test.baseline.ex:205`,
  `test/mix/tasks/adr_judge_test.exs:96`, and
  `test/statifier/compiler/acceptance_test.exs:300`. Every one shells out to
  `git`, `mix`, `grep`, or the `claude` CLI - subprocesses that *need* the
  inherited environment (`PATH`, `HOME`, mise shims, the developer's Claude
  auth). The leak is not real, and clearing the environment would break them.
- **`Readability.UnusedFunctionParameterPattern`'s 22 findings are one deliberate
  idiom, repeated.** They are all `defp f(..., true = _json?)` /
  `false = _json?` heads in `lib/mix/tasks/adr.check.ex` (7),
  `lib/mix/tasks/adr.judge.ex` (7), `lib/mix/tasks/gate.check.ex` (7) and
  `lib/mix/statifier/adr_guard.ex` (1) - the underscored name is documentation
  for what the boolean means. The only fix credo accepts is dropping the name
  (naming it without the underscore raises an unused-variable warning). This is
  a convention change, small but real, and the plan makes it explicitly rather
  than filing it under "mechanical".
- **The consistency check enforces the dominant style, not a configured one.**
  `deps/credo/lib/credo/check/consistency/multi_alias_import_require_use/collector.ex`
  counts `:multi` directives against groups of two-or-more `:single` directives
  sharing a base name, per module, and
  `deps/credo/lib/credo/check/consistency/multi_alias_import_require_use.ex:44`
  emits whichever message the majority implies. Today it emits *"Most of the
  time you are using the multiple single line ... directives"* against
  `lib/statifier/document.ex:89` - i.e. it currently enforces `:single`.
  Enabling it before the rewrite would enforce the exact opposite of what is
  wanted.
- **The collector ignores aliases inside functions.** `collector.ex` returns
  `{nil, acc}` on `:def` / `:defp` (line 37), so aliases declared in a function
  body are invisible to it. And a namespace appearing once in a module is
  invisible too (`multiple_single_locations/1` filters to `count > 1`), so the
  singles this plan deliberately leaves alone never become violations.
- **17 of `Refactor.AppendSingleItem`'s 23 findings are correct as written.**
  Classified site by site (the table is in Phase 5): 6 hot appends inside folds
  or recursive walks, 11 one-shot appends to short bounded lists, 6 where the
  append order is load-bearing - the datamodel-write-before-effect rule
  (`interpreter.ex:1388`, `machine/content/send.ex:193`), Appendix D's
  `removeConflictingTransitions` (`interpreter/selection.ex:570`), the FIFO
  deferred queue under ADR-0044 (`session.ex:1442`), and spec 6.3 scheduling
  order (`session/timers.ex:41`). This flips the bead's expectation: the check
  cannot be enabled, and the six real fixes land independently of it.
- **The regression ratchet is not involved.** Zero aliases in
  `test/scxml_tests/` and `test/scion_tests/`, and no phase changes interpreter
  semantics, so `test/passing_tests.json` does not move.

## What We're NOT Doing

- **Not enabling `Refactor.ABCSize`.** Reason measured and recorded above; the
  reason goes into `.credo.exs` in Phase 8. Not enabling it with a raised
  `max_size` either - inventing a threshold that happens to clear the current
  tree is the "go green by weakening" shape CLAUDE.md forbids, even for a check
  that is off today.
- **Not enabling `Refactor.AppendSingleItem`, and not rewriting 17 of its 23
  sites.** Every site was classified (Phase 5): six are genuinely hot appends
  and get rewritten, eleven are one-shot appends to short bounded lists, and six
  are order-critical where a rewrite changes behavior. The check stays disabled
  with that classification written into `.credo.exs`. Not enabling it behind a
  nine-file exclusion list either - the list would be longer and less
  informative than the paragraph.
- **Not touching the eight checks the bead deliberately left out** -
  `Readability.CaptureOperator`, `NestedFunctionCalls`, `OnePipePerLine`,
  `SinglePipe`, `AliasAs`, `Refactor.VariableRebinding`, `CondInsteadOfIfElse`,
  `PipeChainStart`. The bead argues each one; re-arguing them is a different
  bead.
- **Not touching `Refactor.PassAsyncInTestCases`** (st-dwn) or
  `Credo.Check.Design.DeprecatedChecksConfig` (the credo 1.8.0-dev false
  positive, st-xhb).
- **Not writing the ledger entry.** Phase 7 drafts text for a human to review
  and adopt. An agent drafting is fine; an agent writing it into
  `docs/quality-gate-changes.md` and committing is not (CLAUDE.md, ADR-0011).
- **Not grouping `alias X.Y, as: Z`** - 63 directives carry `as:`, which the
  grouped form cannot express.
- **Not regenerating the conformance corpus** and not touching
  `test/passing_tests.json`.

## Implementation Approach

Two ideas carry the whole plan.

**One guarded edit, at the end.** The bead's four steps interleave code changes
and `.credo.exs` changes. Interleaved, every step would stop at the guard.
Reordered so that all code work lands first and `.credo.exs` is edited exactly
once, seven phases commit under the normal authority table and one waits on a
human. That also gives the human a single ledger entry describing one coherent
change, rather than four entries describing quarters of it.

**`--enable-disabled-checks` as the per-phase bar.** Because each cleanup phase
can run the check it is cleaning up without enabling it in config, every phase
has a real automated criterion of its own. Without this the cleanup phases would
be unverifiable until the config flip, which would collapse them into one
untestable lump.

Phase order within the code work runs cheap-to-expensive, with the alias rewrite
first because it is the largest diff and the one most likely to collide with
sibling branches.

The `Consistency.MultiAliasImportRequireUse` ordering constraint from the bead is
honored structurally: Phase 1 does the rewrite, Phase 8 enables the check. They
are 8 phases apart, so the ordering cannot be lost.

None of these phases changes interpreter semantics; the Appendix D rule
(ADR-0002) applies as a *conservation* requirement - the ported functions must
still read line-for-line against the pseudocode after the refactor, which is a
manual criterion on Phases 4, 5 and 6.

---

## Phase 1: Collapse single aliases into the grouped form

### Overview

Rewrite runs of two or more single `alias` directives sharing a base namespace
into one grouped directive, across `lib/` and hand-written `test/`. Config
untouched, so this commits freely. This is the largest diff in the plan.

### Changes Required:

#### 1. Every module with two or more single aliases sharing a base

**Files**: roughly 178 files under `lib/` and `test/` (573 single directives in
`lib/`, 851 in `test/`; zero in `test/scxml_tests/` and `test/scion_tests/`).

**Changes**: for each module, group by base namespace and collapse.

```elixir
# before
alias Statifier.Document
alias Statifier.Evaluator
alias Statifier.Machine

# after
alias Statifier.{Document, Evaluator, Machine}
```

Names inside a group must be sorted - `Credo.Check.Readability.AliasOrder` is
already enabled and will catch it.

**Leave alone** (the bead's exclusions, all four load-bearing):

- A base namespace with only one alias in the module. Grouping a single name is
  what `Readability.UnnecessaryAliasExpansion` (already enabled) rejects.
- Any grouping that would exceed 120 columns.
  `Readability.MaxLineLength` is already enabled at `max_length: 120`; prefer
  two directives over a wrapped one.
- Any `alias X.Y, as: Z` directive - the grouped form cannot carry `as:`. If a
  namespace mixes plain and `as:` aliases, group the plain ones only, and only
  if two or more remain.
- Any grouping that would hide a name a reader greps for. Grouping is exactly
  the tradeoff `Readability.MultiAlias` names, and this project is accepting it
  deliberately; that acceptance does not extend to hiding a name nobody would
  then find. Concretely: if a module aliases many names from one base and the
  group would run to a dozen entries, split it or leave it.
- Aliases declared inside a function body. The collector skips `def`/`defp`
  (`collector.ex:37`), so they are neither violations nor wins.

**Assumption recorded**: "wherever it makes sense" is read as *group by default,
exclude by the four rules above*. If a reviewer disagrees with a specific
grouping, that is a review comment on the diff, not a re-plan.

### Success Criteria:

#### Automated Verification:
- [x] `mix credo --strict --enable-disabled-checks Consistency.MultiAliasImportRequireUse`
      emits the **`:multi`** direction. Confirm by reading a message: it must say
      *"Most of the time you are using the multi-alias/require/import/use
      syntax"*. If it still says *"multiple single line"*, the rewrite has not
      reached majority and the phase is not done.
- [x] The same command reports zero remaining findings. If it reports any, the
      count and the module of each is recorded in the commit message - whether
      each one is a legitimate exclusion is a Manual criterion below, not this
      one.
- [x] Full `mix quality` passes - which is where `Readability.AliasOrder`,
      `Readability.UnnecessaryAliasExpansion` and `Readability.MaxLineLength`
      check the rewrite's shape.
- [x] `mix credo --strict` still reports zero findings.
- [x] `git diff --stat -- test/scxml_tests test/scion_tests` is empty (the
      generated corpus is untouched, so the ratchet is not involved).
- [x] `mix test.regression` passes.
- [x] `mix gate.check` is green - this phase touches no guarded path.
- [x] Use `mix quality --profile loop` between edits; it does not satisfy the
      phase.

#### Manual Verification:
- [ ] Every finding the consistency check still reports is a legitimate
      exclusion - it matches one of the four stated rules (single-alias base,
      over 120 columns, `as:` mixed in, or greppability) and not merely a module
      the rewrite missed. This is prose judgment against prose criteria, which
      is why it is here and not in the Automated list.
- [ ] Spot-check ten grouped directives for greppability: a name a reader would
      search for is still findable, or the grouping was skipped.
- [ ] No `alias X, as: Y` directive was folded into a group.
- [ ] No behavior change anywhere: the diff is directives only, and every
      changed line is an `alias`.
- [ ] Spec conformance (required by `.claude/wurk/plan.md` for every phase
      touching `lib/statifier/`): the interpreter modules this phase edits are
      Appendix D ports, and an alias rewrite must leave their bodies byte-
      identical. Confirm with
      `git diff -U0 -- lib/statifier/interpreter* | grep '^[-+]' | grep -v '^[-+][-+]' | grep -v 'alias '`
      returning nothing - if it returns a line, something other than an alias
      moved, and the Appendix D reading has to be redone by hand (ADR-0002).

**Implementation Note**: `mix quality --profile loop` while iterating; full
`mix quality` as the phase gate. In `--loop` execution the Automated
Verification list gates advancement via `/wurk:commit --auto`; Manual items are
deferred and surfaced at the end.

---

## Phase 2: Clean up the pipe-and-filter findings

### Overview

The three cheapest step-3 checks: 1 + 2 + 5 findings. Code only, commits
freely.

### Changes Required:

#### 1. `Readability.SingleFunctionToBlockPipe` (1 site)
**File**: `lib/statifier/interpreter/selection.ex:589`
**Changes**: the `|> case do ... end` after a single `Enum.reduce_while/3`.
Bind the reduce result to a variable and `case` on it.

#### 2. `Readability.BlockPipe` (5 sites)
**Files**: `lib/mix/statifier/adr_guard.ex:472`,
`lib/statifier/interpreter/selection.ex:589`,
`lib/statifier/replay.ex:188`,
`lib/statifier/machine/content/send.ex:274`,
`lib/statifier/interpreter.ex:1425`
**Changes**: same shape - replace `|> case do`/`|> if do` with a bound variable
or an extracted function. The `selection.ex:589` site clears both checks at
once.

#### 3. `Refactor.FilterReject` (2 sites)
**Files**: `lib/statifier/validator/checks/initial_targets.ex:127`,
`lib/statifier/validator/checks/history.ex:98`
**Changes**: `Enum.filter(a) |> Enum.reject(b)` becomes one
`Enum.filter(&(a.(&1) and not b.(&1)))`. Keep the predicates readable - if
inlining makes the guard unreadable, extract a named `defp`.

### Success Criteria:

#### Automated Verification:
- [x] `mix credo --strict --enable-disabled-checks Readability.SingleFunctionToBlockPipe`
      reports zero findings.
- [x] `mix credo --strict --enable-disabled-checks Readability.BlockPipe`
      reports zero findings.
- [x] `mix credo --strict --enable-disabled-checks Refactor.FilterReject`
      reports zero findings.
- [x] Full `mix quality` passes.
- [x] `mix test.regression` passes.
- [x] `mix gate.check` is green - no guarded path touched.

#### Manual Verification:
- [ ] `interpreter.ex:1425` and `selection.ex:589` are Appendix D ports: the
      rewritten functions still read line-for-line against the pseudocode, and
      any deviation carries an inline comment naming the mechanical reason
      (ADR-0002).
- [ ] The two `FilterReject` rewrites preserve the exact predicate semantics -
      `filter(a) |> reject(b)` is `a and not b`, and the combined predicate has
      not accidentally become `a and b` or short-circuited differently on nil.

**Implementation Note**: loop gate while iterating; full gate as the phase gate.
`--loop` defers the Manual items.

---

## Phase 3: Drop the ignored pattern matches in the Mix tooling

### Overview

`Readability.UnusedFunctionParameterPattern`, 22 sites, all under `lib/mix/`.
Code only, commits freely. Small diff, but it retires a documentation idiom, so
it is its own phase rather than folded into Phase 2.

### Changes Required:

#### 1. The `true = _json?` heads
**Files**: `lib/mix/tasks/adr.check.ex` (7 sites: lines 96, 104, 106, 121, 124,
126, 134), `lib/mix/tasks/adr.judge.ex` (7), `lib/mix/tasks/gate.check.ex` (7),
`lib/mix/statifier/adr_guard.ex` (1).

**Changes**: drop the ignored name.

```elixir
# before
defp document(summary, findings, true = _json?) do
defp document(summary, [], false = _json?), do: summary

# after
defp document(summary, findings, true) do
defp document(summary, [], false), do: summary
```

Naming the parameter without the underscore is not an option - it would raise an
unused-variable warning, and `warnings_as_errors` is on.

**Decision recorded**: the `_json?` label is documentation, and dropping it
loses something real. Compensate by adding one short comment above the *first*
clause of each affected function naming what the boolean means
(`# third arg: JSON output?`), rather than by leaving the check out. Rationale:
the check is worth having on new code, the loss is one word per function, and
the compensation is cheaper than the alternative of a written exemption. If a
reviewer prefers the exemption, that is a one-line change to Phase 8's config
and a sentence in the comment - flagged in "Open questions".

### Success Criteria:

#### Automated Verification:
- [ ] `mix credo --strict --enable-disabled-checks Readability.UnusedFunctionParameterPattern`
      reports zero findings.
- [ ] Full `mix quality` passes (this is also what proves no unused-variable
      warning was introduced, since `warnings_as_errors` is on).
- [ ] `mix gate.check` is green - no guarded path touched. Note
      `lib/mix/statifier/gate_guard.ex` is *not* itself guarded, and this phase
      does not change its behavior.

#### Manual Verification:
- [ ] Each affected function still reads unambiguously: a reader can tell what
      the bare `true` / `false` means from the added comment or from the call
      sites.
- [ ] No clause ordering changed - dropping a name must not reorder heads.

**Implementation Note**: loop gate while iterating; full gate as the phase gate.

---

## Phase 4: Retire the negated `is_nil` guards

### Overview

`Refactor.NegatedIsNil`, 24 sites. Code only, commits freely. This is the
highest-risk cleanup in the plan: the fix is clause restructuring in
`lib/statifier/compiler.ex` and seven validator check modules, and clause order
is semantic.

### Changes Required:

#### 1. `lib/statifier/compiler.ex` (9 sites)
**Lines**: 1066, 1100, 1127, 1132, 1388, 1393, 1520, 1560, 1565
**Changes**: convert `when not is_nil(x)` into a nil-matching head plus a
general head, in that order.

```elixir
# before
defp build_cancel_sendid(%DCancel{sendid: sendid}, _owner) when not is_nil(sendid) do
  {:ok, Expressions.static(sendid)}
end

# after
defp build_cancel_sendid(%DCancel{sendid: nil}, _owner), do: ...   # the existing nil path
defp build_cancel_sendid(%DCancel{sendid: sendid}, _owner) do
  {:ok, Expressions.static(sendid)}
end
```

The nil-matching head must come **first**, and it must do exactly what the
existing fallback clause did for a nil value - read the fallback before writing
the new head.

#### 2. The validator checks (13 sites)
**Files**: `lib/statifier/validator/checks/send.ex` (172, 179, 186, 193, 200),
`checks/invoke.ex` (79, 86, 93, 100), `checks/param.ex:65`,
`checks/if.ex:118`, `checks/cancel.ex:107`, `checks/script.ex:97`
**Changes**: same shape.

#### 3. Conjunction guards - 9 of the 24 sites, and they are the regular ones

All five `send.ex` sites (172, 179, 186, 193, 200) and all four `invoke.ex`
sites (79, 86, 93, 100) are the same "attribute and attribute-expr both present"
validation idiom: a two-clause `defp` where the first head guards
`when not is_nil(a) and not is_nil(b)` and returns an error, and the second
returns `[]`. A single head cannot express "both non-nil", but **three heads
can, with no guard at all**, and the result reads better than the original:

```elixir
# before
defp event_and_eventexpr(%DSend{event: event, eventexpr: eventexpr}, location)
     when not is_nil(event) and not is_nil(eventexpr) do
  [Error.send_event_and_eventexpr(location)]
end

defp event_and_eventexpr(%DSend{}, _location), do: []

# after
defp event_and_eventexpr(%DSend{event: nil}, _location), do: []
defp event_and_eventexpr(%DSend{eventexpr: nil}, _location), do: []
defp event_and_eventexpr(%DSend{}, location),
  do: [Error.send_event_and_eventexpr(location)]
```

Net cost: one extra clause per site, nine in total. Order is load-bearing - the
two nil heads must precede the error head, or every `<send>` gains a spurious
error.

Do **not** rewrite any of these as `a != nil and b != nil`. Credo would go
quiet, but nothing would have been fixed, and that is the "go green by weakening
the check" shape CLAUDE.md forbids.

One site is a three-way rather than a pair: `invoke.ex:93` guards
`when not is_nil(content) and (not is_nil(src) or not is_nil(srcexpr))`. It
still resolves to three heads, but the second one matches *both* nil at once:

```elixir
defp content_and_src(%DInvoke{content: nil}, _location), do: []
defp content_and_src(%DInvoke{src: nil, srcexpr: nil}, _location), do: []
defp content_and_src(%DInvoke{}, location), do: [Error.invoke_content_and_src(location)]
```

Note that `send.ex:219`, `:226` and `:233` also contain `not is_nil` and are
**not** flagged (credo tolerates the shapes there). Leave them alone; a file
that still greps for `not is_nil` after this phase is expected, not a miss.

#### 4. `lib/statifier/parser/location.ex:581` and `lib/statifier/invoke/source.ex:90`
**Changes**: same shape; these two are isolated.

### Success Criteria:

#### Automated Verification:
- [ ] `mix credo --strict --enable-disabled-checks Refactor.NegatedIsNil`
      reports zero findings.
- [ ] Full `mix quality` passes, including the full test suite with coverage -
      the compiler and validator are the most heavily covered modules in the
      repo, so a clause-order mistake shows up as a red test, not a silent
      behavior change.
- [ ] `mix test --include scion --include scxml_w3` passes at the same counts as
      before the phase.
- [ ] `mix test.regression` passes - no ratchet entry regresses.
- [ ] `mix gate.check` is green - no guarded path touched.
- [ ] Grep confirms no `!= nil` was introduced as a silencing rewrite:
      `git diff -U0 | grep '^+' | grep '!= nil'` is empty.

#### Manual Verification:
- [ ] Every new nil-matching head does what the previous fallback did for nil.
      This is the failure mode with no test to catch it: if the old code fell
      through to a clause that returned `{:ok, nil}` and the new head returns
      `{:error, ...}`, that is a behavior change dressed as a refactor.
- [ ] Clause ordering: the nil heads precede the general heads in every case.
- [ ] No conjunction guard was flattened into `!= nil`.
- [ ] `compiler.ex` is not an Appendix D port, but the validator checks feed the
      interpreter's error events - confirm the error-event shapes are unchanged
      (errors are events, `{:ok, v} | {:error, e}`, ADR-0003).

**Implementation Note**: loop gate while iterating; full gate as the phase gate.
If a site cannot be restructured without changing behavior, leave that site
alone, and carry the check's fate into Phase 8 as a path exclusion with a stated
reason - never as a silencing rewrite.

---

## Phase 5: Fix the six real `list ++ [x]` hot spots, and leave the other seventeen

### Overview

`Refactor.AppendSingleItem`, 23 sites, all in `lib/`. Code only, commits freely.
This is not a formatting cleanup: in an interpreter that walks state sets,
`list ++ [x]` inside a fold is an O(n) append per iteration, while a one-shot
append to a short list is fine as written and an order-critical one is *correct*
as written. **Every site was classified before this plan was written** (below);
only six get rewritten, and the outcome for the check itself is that it stays
disabled with a written reason, because 17 of its 23 findings are wrong for this
codebase.

### Changes Required:

#### 1. The classification (already done - do not re-derive it, but do verify it)

| Site | Class | Why |
|---|---|---|
| `lib/statifier/validator/context.ex:105` | **A** | `walk/3` recurses the state tree; `ancestor_ids ++ [state.id]` per level. Consumers only test membership, so order carries no semantics |
| `lib/statifier/interpreter/content.ex:197` | **A** | `effects ++ node_effects` inside `run_nodes/2`'s `Enum.reduce_while` fold |
| `lib/statifier/interpreter/content.ex:201` | **A** | `executed ++ [c_index]`, same fold, error-halt arm |
| `lib/statifier/interpreter/content.ex:204` | **A** | `executed ++ [c_index]`, same fold, `{:error, reason}` arm |
| `lib/statifier/interpreter/exit_entry.ex:321` | **A** | `effects ++ [effect]` inside `cancel_invocations_for_state/2`'s `Enum.reduce` over a state's invokes |
| `lib/statifier/interpreter/selection.ex:514` | **A** | `cond_errors ++ [{transition, reason}]` in `cond_enabled/3`, called from nested folds across the whole configuration scan |
| `lib/statifier/parser/markup.ex:49` | B | module attribute, built once at compile time from a fixed list |
| `lib/mix/tasks/test.baseline.ex:139` | B | fresh small `test_args ++ [&1]` per file, not a growing accumulator |
| `lib/mix/tasks/test.baseline.ex:170` | B | same shape |
| `lib/mix/statifier/regression_registry.ex:371` | B | one call per `stats_lines/3`, bounded by category count |
| `lib/statifier/lowering/builders.ex:230,317,466,524,571,619,791` | B (7) | the same `errors ++ [Error....]` missing/unsupported-attribute idiom, once per element build |
| `lib/statifier/machine/content/send.ex:193` | C | the datamodel write's effects must precede the `:send` effect |
| `lib/statifier/interpreter.ex:1388` | C | same write-before-effect rule for `<invoke>` |
| `lib/statifier/interpreter.ex:1690` | C | final `exit_interpreter` assembly, mirrors Appendix D's exit/done step order |
| `lib/statifier/interpreter/selection.ex:570` | C | literal port of Appendix D's `removeConflictingTransitions`; `filtered` is selectively pruned in the same fold, so prepend+reverse risks the removal semantics, not just order |
| `lib/statifier/session.ex:1442` | C | `state.deferred` is a FIFO queue paired with `drain_deferred/1`'s head-pop (ADR-0044 ordering) |
| `lib/statifier/session/timers.ex:41` | C | refs under one `send_id` must stay in scheduling order for cancel-all and `take/2` (spec 6.3) |

Totals: **6 A, 11 B, 6 C.**

#### 2. Rewrite the six class-A sites, and only those

```elixir
# before, inside a fold
Enum.reduce(nodes, [], fn n, acc -> acc ++ [build(n)] end)

# after
nodes |> Enum.reduce([], fn n, acc -> [build(n) | acc] end) |> Enum.reverse()
```

The three `content.ex` sites are all in `run_nodes/2`'s single fold and are one
rewrite, not three. `selection.ex:514` and `exit_entry.ex:321` are pure
accumulation - reverse at the end and the order is identical.

Leave the eleven B and six C sites exactly as they are. Do not "improve" a C
site: `selection.ex:570` and `session.ex:1442` are the two where a naive
prepend+reverse changes behavior, not just cost.

#### 3. The consequence for the check itself

`Refactor.AppendSingleItem` **stays in `disabled:`, with a written reason**
(Phase 8). Enabling it after this phase would still report 17 findings, every
one of which is correct as written. The alternatives were considered and
rejected:

- *Rewrite all 23* - would make eleven sites less readable for no measurable
  gain and would change behavior at six.
- *Enable with a `files: %{excluded: [...]}`* - the exclusion would need to name
  nine files (`markup.ex`, `test.baseline.ex`, `regression_registry.ex`,
  `builders.ex`, `machine/content/send.ex`, `interpreter.ex`, `selection.ex`,
  `session.ex`, `session/timers.ex`), leaving the check running over a handful
  of files it has nothing to say about. A nine-path exclusion list is a worse
  record than one honest paragraph saying the check is wrong for this codebase.

This is the escape hatch CLAUDE.md names - "if a finding is genuinely wrong for
this project, say so and let the user decide" - and the bead's acceptance
criterion explicitly allows a check to stay out with a written reason. The six
class-A rewrites still land, because they are a real improvement independent of
whether any check is watching.

### Success Criteria:

#### Automated Verification:
- [ ] `mix credo --strict --enable-disabled-checks Refactor.AppendSingleItem`
      reports exactly the 17 sites classified B or C above - no more (nothing
      new introduced) and no fewer (no class-B or C site quietly rewritten).
- [ ] Full `mix quality` passes.
- [ ] `mix test --include scion --include scxml_w3` passes at the same counts as
      before the phase.
- [ ] `mix test.regression` passes.
- [ ] `mix gate.check` is green - no guarded path touched.

#### Manual Verification:
- [ ] The classification table above was re-read against the code before any
      edit, and any disagreement with it was resolved by reading, not by
      defaulting to "rewrite".
- [ ] The rewritten sites in `interpreter/content.ex`,
      `interpreter/selection.ex` and `interpreter/exit_entry.ex` still read
      line-for-line against the W3C Appendix D pseudocode; any deviation carries
      an inline comment naming the mechanical reason (ADR-0002).
      `prepend + reverse` in place of `++ [x]` is a mechanical deviation and
      needs that comment where the pseudocode says "append". Quote the clause
      from the local cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`),
      not from memory.
- [ ] Order is preserved at all six rewrites: the conformance suites are the
      evidence, but read `exit_entry.ex:321` and `selection.ex:514` directly,
      because a reversed list can still pass a test that only checks membership.
- [ ] No class-C site was touched. `selection.ex:570`, `session.ex:1442` and
      `session/timers.ex:41` are the three where a rewrite changes behavior.

**Implementation Note**: loop gate while iterating; full gate as the phase gate.
Six sites, three files. If the implementer's own reading disagrees with a
classification, that is a finding to report - not a licence to widen the
rewrite.

---

## Phase 6: Confirm the tree is clean for every step-1 check

### Overview

A cheap, fast phase that exists to catch drift: the nine step-1 checks were
measured at zero findings on `24c85ae`, but Phases 1-5 changed roughly 200 files
between then and here. This phase re-measures, fixes anything the earlier phases
introduced, and commits only if there is something to fix.

### Changes Required:

#### 1. Re-run the nine zero-violation checks

```bash
mix credo --strict --enable-disabled-checks \
  Design.SkipTestWithoutComment,Readability.SeparateAliasRequire,\
Readability.WithCustomTaggedTuple,Refactor.MapMap,Refactor.DoubleBooleanNegation,\
Refactor.RejectFilter,Refactor.PreferDateTimeShift,Warning.LazyLogging,\
Warning.MapGetUnsafePass
```

The comma-separated form is confirmed working on credo 1.8.0-dev - verified by
running `--enable-disabled-checks "Refactor.NegatedIsNil,Refactor.FilterReject"`
and getting both check's findings back in one run.

**Changes**: whatever the re-run turns up, which is expected to be nothing.
`Readability.SeparateAliasRequire` is the one plausible casualty of Phase 1 -
it flags `alias`/`require` groups run together, and the alias rewrite moves
alias lines around.

**If the re-run is clean, this phase produces no commit.** Say so in the phase
report rather than manufacturing a change.

**Why this is a phase rather than redundant with Phase 8.** Phase 8's bare
`mix quality` would catch the same drift - but it would catch it *after* a human
has already written and committed the ledger entry, turning a two-minute fix
into a second round trip through a human gate. This phase moves the discovery to
the last point where it costs nothing. That is also why it sits after Phase 5
and before the two human phases, rather than at the very end.

### Success Criteria:

#### Automated Verification:
- [ ] Each of the nine checks reports zero findings under
      `--enable-disabled-checks`.
- [ ] Full `mix quality` passes.
- [ ] `mix gate.check` is green - no guarded path touched.

#### Manual Verification:
- [ ] If the phase produced no commit, that is recorded as the outcome rather
      than skipped silently.

**Implementation Note**: this phase may legitimately be a no-op. In `--loop`
execution, a no-op phase advances on the green gate with no commit.

---

## Phase 7: The ledger entry - a human ask, and the only blocking step

### Overview

**This phase cannot be done by an agent.** `.credo.exs` is a guarded path
(`lib/mix/statifier/gate_guard.ex:36`); `mix gate.check` fails any branch that
edits it without an entry in `docs/quality-gate-changes.md` naming that path
with an `Approved-by:` line; and CLAUDE.md states that entry is a human's call
on the record, not one an agent writes for itself. An agent reaching this phase
**stops and asks**.

Draft text is below for a human to review, edit and adopt. Drafting is fine;
writing it into the ledger and committing is not.

### Changes Required:

#### 1. Draft entry for `docs/quality-gate-changes.md`

To be reviewed by a human, edited as they see fit, and added by them at the top
of the file (newest first):

**One formatting note before copying**: the date heading below is written as
`###` so that this plan's own section parser (`plan_state.rb validate`, which
splits on `^## `) does not read it as a new plan section. In
`docs/quality-gate-changes.md` it must be `##`, matching every other entry.

```markdown
### 2026-08-18 - st-383

Approved-by: <human name> (in session)

- .credo.exs: moves fifteen checks from `disabled:` to `enabled:` -
  Design.SkipTestWithoutComment, Readability.SeparateAliasRequire,
  Readability.WithCustomTaggedTuple, Readability.SingleFunctionToBlockPipe,
  Readability.BlockPipe, Readability.UnusedFunctionParameterPattern,
  Refactor.MapMap, Refactor.DoubleBooleanNegation, Refactor.RejectFilter,
  Refactor.PreferDateTimeShift, Refactor.FilterReject, Refactor.NegatedIsNil,
  Warning.LazyLogging, Warning.MapGetUnsafePass, and
  Consistency.MultiAliasImportRequireUse - the last of which now reports the
  multi-alias direction because st-383 rewrote the tree to the grouped form
- .credo.exs: enables Warning.LeakyEnvironment with `files: %{excluded:
  ["lib/mix/", "test/"]}` and a comment giving the reason
- .credo.exs: adds explanatory comments to three entries that STAY in
  `disabled:` - Readability.MultiAlias, Refactor.ABCSize and
  Refactor.AppendSingleItem

Reason: `.credo.exs` was generated with `mix credo gen.config` under st-vbu, so
the repo owns the full check list and nothing turns itself on. Most of what sat
in `disabled:` was there because gen.config put it there, not because this
project decided against it. **Every edit in this diff is a widening of what the
gate checks. No threshold moves, no check is removed, no test is skipped, and
no scope is narrowed** - which is the direction ADR-0011's guard exists to allow
freely. The guard fired because it is mechanical about the path, not because a
check was weakened.

The two path exclusions are the file's sanctioned mechanism ("Checks are
excluded by path or by check parameter, with a comment giving the reason"), and
both add coverage rather than removing it, since both checks were entirely off
before this diff. Warning.LeakyEnvironment's 8 findings are all dev-only Mix
tooling and test helpers shelling out to `git`, `mix`, `grep` and the `claude`
CLI - subprocesses that need the inherited environment to run at all - and none
is in `lib/statifier/`, where the check now runs and where ADR-0003 already
means no `System.cmd` should appear.

Three checks stay disabled with their reasons written into the file.
Readability.MultiAlias forbids the grouped alias form outright, so it is the
direct contradiction of this bead rather than a companion to it.
Refactor.AppendSingleItem was classified site by site rather than swept: 17 of
its 23 findings are correct as written (eleven one-shot appends to short bounded
lists, six order-critical - the write-before-effect rule, Appendix D's
removeConflictingTransitions, session.ex's FIFO deferred queue under ADR-0044,
and timers.ex's spec 6.3 scheduling order). The six genuinely hot appends were
rewritten anyway, as a real improvement independent of any check; enabling the
check would leave 17 standing findings and would need a nine-file exclusion list
to silence them, which is a worse record than the paragraph now in the file.
Refactor.ABCSize was measured rather than assumed: Refactor.CyclomaticComplexity
(already enabled, max 9) reports zero findings on this tree, so ABCSize's 28
findings overlap nothing and would be 28 real refactors concentrated in
lib/statifier/lowering/builders.ex, interpreter.ex and compiler.ex - the literal
Appendix D port ADR-0002 protects, and the same argument that already keeps
Design.DuplicatedCode and Refactor.CondInsteadOfIfElse out. It is left out
rather than enabled with a raised max_size, because inventing a threshold that
happens to clear the current tree is the shape CLAUDE.md forbids.
```

#### 2. Nothing else

No file in this phase is written by an agent.

### Success Criteria:

#### Automated Verification:
- [ ] None. There is nothing an agent can run that decides this phase.
- [ ] (After the human commits the entry) `mix quality` is still green -
      a ledger entry naming a path the diff does not yet change is not a
      finding, so the branch stays green while it waits for Phase 8.

#### Manual Verification:
- [ ] A human has read the draft, edited it as they see fit, and written the
      final entry into `docs/quality-gate-changes.md` under their own
      `Approved-by:` line.
- [ ] The entry names `.credo.exs` literally - the guard matches on the path
      string.
- [ ] The human agrees with Phase 8's LeakyEnvironment judgment and with the
      ABCSize exclusion, since the entry asserts both.

**Implementation Note**: **this phase will block `/wurk:implement --loop`.** A
looped run reaching Phase 7 must stop and report the ask rather than write the
entry itself. Phase 8 cannot start until this one is done: without the entry,
Phase 8's edit makes the `Gate guard` stage red, and a red gate is not a commit
trigger under this repo's authority table.

---

## Phase 8: Flip `.credo.exs` - the one guarded edit

### Overview

Move every check the earlier phases cleared into `enabled:`, enable
`Consistency.MultiAliasImportRequireUse` (which now sees the grouped form as the
majority), and write the reasons for the two that stay out. **This is the only
phase that touches a guarded path**, and it is unblocked exactly when Phase 7's
ledger entry exists on the branch.

### Changes Required:

#### 1. Move to `enabled:` (alphabetical within each section)
**File**: `.credo.exs`

Design: `SkipTestWithoutComment`.
Consistency: `MultiAliasImportRequireUse`.
Readability: `SeparateAliasRequire`, `WithCustomTaggedTuple`, `BlockPipe`,
`SingleFunctionToBlockPipe`, `UnusedFunctionParameterPattern`.
Refactor: `MapMap`, `DoubleBooleanNegation`, `RejectFilter`,
`PreferDateTimeShift`, `FilterReject`, `NegatedIsNil`.
Warning: `LazyLogging`, `MapGetUnsafePass`, `LeakyEnvironment`.

That is **sixteen** checks moved. `NegatedIsNil` carries a
`files: %{excluded: [...]}` with a comment **only if** Phase 4 left a site
standing; otherwise it goes in bare. `Refactor.AppendSingleItem` is **not** in
this list - see step 2.

```elixir
# Excluded where clearing the environment would break the subprocess rather
# than protect it: every System.cmd/3 under lib/mix/ and test/ shells out to
# git, mix, grep or the claude CLI, which need PATH, HOME and the developer's
# own auth to run at all. None of the 8 sites is in lib/statifier/, where this
# check now runs and where ADR-0003 already means no System.cmd should appear
# (st-383).
{Credo.Check.Warning.LeakyEnvironment, [files: %{excluded: ["lib/mix/", "test/"]}]},
```

**The `Warning.LeakyEnvironment` judgment, made here rather than as its own
phase.** The bead is explicit that this check must be *read* before it is
*fixed*, so the reasoning is set out in full - but it produces no diff of its
own, so it belongs in the phase that writes it down rather than in a phase that
commits nothing.

| Site | Subprocess |
|---|---|
| `lib/mix/statifier/adr_judge.ex:406` | `git` |
| `lib/mix/statifier/adr_judge.ex:700` | the `claude` CLI |
| `lib/mix/statifier/adr_guard.ex:256` | `git` |
| `lib/mix/statifier/gate_guard.ex:177` | `git` |
| `lib/mix/tasks/gate.verify.ex:140` | `mix` |
| `lib/mix/tasks/test.baseline.ex:205` | `mix test` |
| `test/mix/tasks/adr_judge_test.exs:96` | `git` |
| `test/statifier/compiler/acceptance_test.exs:300` | `grep` |

All 8 are dev-only Mix tooling and test helpers. None is in `lib/statifier/`,
none ships in the released library, and every subprocess needs the inherited
environment to function (`PATH` and mise shims for `mix` and `git`, the
developer's own auth for the `claude` CLI). Clearing the environment would break
them, so the leak is not real at any of the 8.

Excluding `lib/mix/` and `test/` still leaves the check live over
`lib/statifier/` - the shipped library and the pure functional core, where
ADR-0003 means no `System.cmd` should ever appear in the first place. That is
strictly more coverage than today, where the check is off everywhere. The shape
matches the existing `Refactor.IoPuts` and `Warning.MixEnv` entries in
`.credo.exs`, and matches `.sobelow-conf`'s path exclusions for the same Mix
support modules.

**Explicitly rejected**: adding `env: []` to the 8 call sites. `env: []` merges
nothing into the inherited environment, so it clears nothing - it satisfies the
check's `Keyword.has_key?(opts, :env)` test
(`deps/credo/lib/credo/check/warning/leaky_environment.ex:55`) without
addressing a single thing the check exists to catch. That is silencing, not
fixing.

#### 2. Comment the three entries that stay in `disabled:`

```elixir
# Stays disabled deliberately: this check forbids the grouped alias form
# outright, which is the direct contradiction of st-383 rather than a
# companion to it - the tree was rewritten to the grouped form on purpose and
# Consistency.MultiAliasImportRequireUse above now enforces it. Enabling this
# would fight that decision, not reinforce it.
{Credo.Check.Readability.MultiAlias, []},
```

```elixir
# Left out on measurement, not on assumption (st-383): the obvious argument
# for skipping it - that it duplicates Refactor.CyclomaticComplexity, already
# enabled - does not hold here. CyclomaticComplexity (max 9) reports zero
# findings on this tree, so ABCSize's 28 findings overlap nothing. They
# concentrate in lowering/builders.ex, interpreter.ex, compiler.ex and
# interpreter/datamodel.ex - the literal W3C Appendix D port - so enabling it
# would trade spec fidelity for a size metric, the same trade that already
# keeps Design.DuplicatedCode and Refactor.CondInsteadOfIfElse out (ADR-0002).
# Not enabled with a raised max_size either: a threshold picked to clear the
# current tree is a weakening dressed as a widening.
{Credo.Check.Refactor.ABCSize, []},
```

```elixir
# Left out after classifying all 23 findings, not by default (st-383): 17 of
# them are correct as written. Eleven are one-shot appends to short, bounded
# lists (the `errors ++ [Error....]` idiom repeated across lowering/builders.ex,
# a compile-time module attribute in parser/markup.ex, per-call argument lists
# in the mix tooling), and six are order-critical - the datamodel-write-before-
# effect rule in interpreter.ex and machine/content/send.ex, Appendix D's
# removeConflictingTransitions in interpreter/selection.ex, session.ex's FIFO
# deferred queue (ADR-0044), and timers.ex's scheduling order (spec 6.3) - where
# prepend-and-reverse changes behavior rather than cost. The six genuinely hot
# appends were rewritten under st-383; enabling the check would leave 17
# standing findings, and the path exclusion that silenced them would have to
# name nine files, which is a worse record than this paragraph.
{Credo.Check.Refactor.AppendSingleItem, []},
```

#### 3. Confirm the consistency check's direction

After the flip, `mix credo --strict` must be silent. If it reports
`MultiAliasImportRequireUse` findings whose message begins *"Most of the time
you are using the multiple single line ..."*, the Phase 1 rewrite did not reach
majority and the fix is more rewriting - never disabling the check again.

### Success Criteria:

#### Automated Verification:
- [ ] `mix credo --strict` reports zero findings with the new config.
- [ ] `mix credo --strict --enable-disabled-checks Consistency.MultiAliasImportRequireUse`
      is redundant now; instead confirm the check is in `enabled:` and the bare
      run is silent.
- [ ] `mix gate.check` is green. **This is the criterion that will fail if
      Phase 7 is not done** - it is the only phase in the plan where that is
      true.
- [ ] Bare, unscoped `mix quality` is green.
- [ ] `mix gate.verify` exits zero, proving the run was a full gate and not a
      profiled, scoped, `--quick` or `--skip`-ed one.
- [ ] `mix test.regression` passes.
- [ ] `Credo.Check.Design.MissingCheckInConfig` (already enabled) stays green -
      every check credo ships is still in exactly one of the two lists.
- [ ] `mix credo --strict --enable-disabled-checks Warning.LeakyEnvironment`
      reported the same 8 sites and no more before the flip - confirming the
      earlier phases introduced no new `System.cmd` call that the path
      exclusion would then hide.

#### Manual Verification:
- [ ] `Readability.MultiAlias` is still in `disabled:`, with its comment.
- [ ] `Refactor.ABCSize` is still in `disabled:`, with its measured reason.
- [ ] Every check the bead's steps 1-3 name is either in `enabled:` or has a
      written reason in the file. That is the bead's acceptance criterion, and
      it is a read of the file, not a command.
- [ ] The committed ledger entry still describes what the diff actually does -
      if Phases 4/5 left sites standing and added path exclusions the draft did
      not anticipate, the human amends the entry before this commit lands.
- [ ] No check was configured with a loosened parameter to make the tree pass.
- [ ] **The `Warning.LeakyEnvironment` judgment above is confirmed by a human
      before the comment is written.** A human agrees the leak is not real at
      all 8 sites, or names the ones where it is, and agrees the recommended
      scope (`lib/mix/`, `test/` excluded) is the scope to adopt rather than a
      narrower one. This is a security judgment about what a subprocess
      inherits - it belongs with the same human who signs the ledger entry.

**Implementation Note**: this phase's commit and Phase 7's ledger entry may land
in one commit or two; the guard only requires both to be present on the branch
when `mix gate.check` runs.

---

## Testing Strategy

### Unit Tests:

This plan adds no new behavior, so it adds no new tests. Every phase is a
refactor or a config change verified by the checks themselves plus the existing
suite.

The project's sabotage convention (CLAUDE.md, `docs/testing.md`) therefore has
nothing to attach to in the normal case: it applies to *new tests asserting
`lib/` behavior*, and there are none. **If any phase does add a test** - the
most likely case is Phase 5 adding an order-preservation test for a rewritten
document-order append - that test must be sabotaged: break the code it covers,
confirm it goes red, revert, and note the mutation in one line above the test
(`# sabotage: build_children/1 prepends without reversing -> red`).

The existing suite is the real safety net, and Phases 4 and 5 are the two that
need it:

- `lib/statifier/compiler.ex` and `lib/statifier/validator/checks/*` (Phase 4)
  are among the most heavily covered modules in the repo; a clause-ordering
  mistake surfaces as a red test.
- `lib/statifier/interpreter*` and `lib/statifier/lowering/builders.ex`
  (Phase 5) are covered by the SCION and W3C conformance suites, which must be
  run explicitly: `mix test --include scion --include scxml_w3`.

### Manual Testing Steps:

1. After Phase 1, grep for five names that were folded into groups and confirm a
   reader can still find them.
2. After Phase 4, read every new nil-matching head against the fallback clause
   it replaced, and confirm the nil path returns what it returned before.
3. After Phase 5, read the document-order and exit/entry append sites directly.
   A reversed list can pass a membership assertion; only reading the code (and
   the Appendix D text at
   `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`)
   catches it.
4. After Phase 8, run a bare `mix quality` followed by `mix gate.verify`, and
   read the `○` lines: the only expected skips are the four
   `gate.not_applicable_skips` patterns (gettext, `.po`, and the ADR judge
   disabled in `.quality.exs`). `gate.project_level_skips` is empty and must
   stay empty.

## Corpus/Ratchet Notes

Nothing in this plan touches the generated corpus or the ratchet.
`test/scxml_tests/` and `test/scion_tests/` contain **zero** `alias` directives
(verified), so Phase 1's rewrite cannot reach them, and no phase changes
interpreter semantics, so no conformance test changes status. `mix
test.regression` is listed as an automated criterion on every code phase
precisely so that a surprise here is caught rather than assumed away, and
`test/passing_tests.json` is expected to be byte-identical at the end of the
plan. Shrinking it would trip the same ADR-0011 guard as `.credo.exs`.

## Open Questions

These are recorded rather than resolved, because this plan was authored without
a human available to answer them. Each has a decision made in the plan; these
are the ones a reviewer should check rather than skim.

1. **The `_json?` label (Phase 3).** The plan drops the underscored name and
   compensates with a comment. The alternative is leaving
   `Readability.UnusedFunctionParameterPattern` disabled with a written reason -
   the idiom is deliberate and self-documenting, and 22 of 22 findings are the
   same idiom. Chosen the fix over the exemption on the grounds that the check
   is worth having on new code; a reviewer who values the label more should say
   so, and Phase 8's config plus the ledger entry both change by a line.
2. **`Refactor.ABCSize` (Phase 8).** The plan leaves it out on a measured
   argument the bead did not anticipate (zero cyclomatic overlap, 28 findings in
   the Appendix D port). The bead's acceptance criterion allows a written reason
   in place of enabling, so this satisfies it - but it is a judgment call about
   what this project checks, and the ledger entry asserts it.
3. **`Refactor.AppendSingleItem` (Phases 5 and 9).** The plan leaves it out
   because 17 of 23 findings are correct as written. The alternative a reviewer
   might prefer is enabling it with a nine-file `files: %{excluded: [...]}`,
   which keeps the check live for new code in the files it *can* police. The
   plan judged that list worse than a paragraph; a reviewer who wants the check
   watching new code should say so, and Phase 8 gains an entry.
4. **`Warning.LeakyEnvironment` scope (Phase 8).** Excluding `lib/mix/` and
   `test/` leaves the check covering `lib/statifier/` only, where it currently
   has nothing to find. A reviewer may consider that too little value for a
   config entry and prefer leaving the check disabled with a reason. Either is
   defensible; the plan picks the widening.
5. **Phase 1's grouping judgment.** "Wherever it makes sense" is read as *group
   by default, exclude by four stated rules*. A reviewer who wants a stricter
   default (say, only group three or more) should say so before Phase 1 runs -
   it is a ~200 file diff and re-running it is expensive.
6. **The bead's counts are stale.** `NegatedIsNil` 4 -> 24, `ABCSize` 12 -> 28,
   `AppendSingleItem` 17 -> 23, `BlockPipe` 2 -> 5, alias singles 910 -> 1424.
   The bead's own description should probably be refreshed to the measured
   numbers so the next reader does not plan against 456d28e.

## References

- Bead: `st-383`
- Related beads: `st-dwn` (PassAsyncInTestCases - all 275 findings are generated
  corpus, a corpus-generator change), `st-xhb` (jump_credo_checks, deferred on
  the credo 1.8 dep conflict), `st-vbu` (generated `.credo.exs` in the first
  place)
- ADR: `docs/adr/0011-quality-gate-config-not-agent-editable.md` - the policy
  the `.credo.exs` guard enforces
- ADR: `docs/adr/0002-*` - the literal Appendix D port, the reason ABCSize and
  CondInsteadOfIfElse stay out
- ADR: `docs/adr/0003-*` - effects out, the reason `lib/statifier/` has no
  `System.cmd` for LeakyEnvironment to find
- Config: `.credo.exs` - the file this bead edits, and its header stating that
  exclusions are by path or parameter with a reason, never by weakening
- Guard: `lib/mix/statifier/gate_guard.ex:36` (`@guarded_paths`), `:182`
  (the guarded-path finding)
- Ledger: `docs/quality-gate-changes.md` - the entry format, and st-4hk's
  precedent for a `.credo.exs` comment-only edit recorded rather than exempted
- Credo internals: `deps/credo/lib/credo/check/consistency/multi_alias_import_require_use/collector.ex`
  (the dominant-style collector), `.../multi_alias_import_require_use.ex:44`
  (the two direction messages),
  `deps/credo/lib/credo/check/warning/leaky_environment.ex:55`
  (`Keyword.has_key?(opts, :env)` is the whole test)
- Project rules: `CLAUDE.md` - the authority table, the never-go-green-by-
  weakening rule, and the sabotage convention

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Every finding the consistency check still reports is a legitimate
      exclusion - it matches one of the four stated rules (single-alias base,
      over 120 columns, `as:` mixed in, or greppability) and not merely a module
      the rewrite missed. This is prose judgment against prose criteria, which
      is why it is here and not in the Automated list.
- [ ] Spot-check ten grouped directives for greppability: a name a reader would
      search for is still findable, or the grouping was skipped.
- [ ] No `alias X, as: Y` directive was folded into a group.
- [ ] No behavior change anywhere: the diff is directives only, and every
      changed line is an `alias`.
- [ ] Spec conformance (required by `.claude/wurk/plan.md` for every phase
      touching `lib/statifier/`): the interpreter modules this phase edits are
      Appendix D ports, and an alias rewrite must leave their bodies byte-
      identical. Confirm with
      `git diff -U0 -- lib/statifier/interpreter* | grep '^[-+]' | grep -v '^[-+][-+]' | grep -v 'alias '`
      returning nothing - if it returns a line, something other than an alias
      moved, and the Appendix D reading has to be redone by hand (ADR-0002).

**Implementation Note**: `mix quality --profile loop` while iterating; full
`mix quality` as the phase gate. In `--loop` execution the Automated
Verification list gates advancement via `/wurk:commit --auto`; Manual items are
deferred and surfaced at the end.

---

### Phase 2

- [ ] `interpreter.ex:1425` and `selection.ex:589` are Appendix D ports: the
      rewritten functions still read line-for-line against the pseudocode, and
      any deviation carries an inline comment naming the mechanical reason
      (ADR-0002).
- [ ] The two `FilterReject` rewrites preserve the exact predicate semantics -
      `filter(a) |> reject(b)` is `a and not b`, and the combined predicate has
      not accidentally become `a and b` or short-circuited differently on nil.

**Implementation Note**: loop gate while iterating; full gate as the phase gate.
`--loop` defers the Manual items.

---
