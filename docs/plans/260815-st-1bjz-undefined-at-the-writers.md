# Respell unbound as `:undefined` at the writers Implementation Plan

## Overview

Implements `docs/adr/0037-unbound-spelled-undefined-at-the-writer.md`: every
writer that means "declared but no value yet" spells `:undefined` itself,
`Statifier.Evaluator.undefine_nils/1` is retired, and `nil` comes to mean
exactly one thing - predicator's null. Observable corpus answers are unchanged
by design; the branch proves that with a full conformance run against a
baseline captured before the first edit. Bead: st-1bjz.

The plan also answers, in code and in tests, the two open questions ADR-0037
defers to this bead (the outbound payload boundary, and where
`Statifier.Event.data`'s absent spelling lives). Both answers are recorded here
with their grounding, and Phase 2 is the phase that lands them.

## Current State Analysis

`machine_state.datamodel` spells "declared but no value yet" as a raw `nil` at
five writers, and `Statifier.Evaluator.bind/3`
(`lib/statifier/evaluator.ex:254-258`) rewrites every `nil` it sees to
`:undefined` recursively via the private `undefine_nils/1`
(`lib/statifier/evaluator.ex:220-228`) before handing off to
`Predicator.Context.bind/3`. `context/1`'s `bind_roots/2`
(`lib/statifier/evaluator.ex:194-198`) folds `bind/3` over every top-level
datamodel key, so the rewrite reaches `_event` and every author root alike.

The five writers:

| Writer | Site | Writes |
|---|---|---|
| `SystemVariables.initial/2` | `lib/statifier/evaluator/system_variables.ex:69-77` | `"_event" => nil` |
| `SystemVariables.event/1` | `lib/statifier/evaluator/system_variables.ex:84-94` | `event.sendid`/`origin`/`origintype`/`invokeid`/`data` verbatim, each `nil` when absent |
| `Interpreter.Datamodel.seed/2` | `lib/statifier/interpreter/datamodel.ex:264-268` | `Map.put_new(datamodel, data.id, nil)` per declared `<data>` |
| `Foreach.declare/2` | `lib/statifier/machine/content/foreach.ex:205-216` | `Map.put_new(datamodel, item, nil)`, same for `index` |
| `EventData.coerce/1`'s empty rungs | `lib/statifier/event_data.ex:66-69` (`from_text("")`), `:93` (`from_params([])`) | `nil` |

The collapse this produces is the bead's finding: `coerce({:text, ~s({"foo":
null})})` preserves `%{"foo" => nil}`, and one layer later `bind/3` rewrites it
to `%{"foo" => :undefined}`, so a present-and-null field is indistinguishable
from an absent one at expression time.

**The mechanism was probed in this worktree against the pinned predicator 8.x**
(`mix run -e ...`, this session), and predicator answers exactly as ADR-0037
claims - this is the load-bearing fact the whole plan rests on:

```
normalized: %{"a" => :undefined, "b" => nil, "d" => %{"n" => nil, "u" => :undefined}}
{"a === undefined", {:ok, true}}    {"a === null", {:ok, false}}
{"b === null", {:ok, true}}          {"b === undefined", {:ok, false}}
{"d.n === null", {:ok, true}}        {"d.u === undefined", {:ok, true}}
```

`Predicator.Context.new/2` (and therefore `bind/3`) passes both `nil` and
`:undefined` through `normalize_value/1` unchanged, at every nesting depth. So
a writer that spells `:undefined` gets the same answer today's `nil` +
`undefine_nils/1` produces, which is why the respell can land **before** the
retirement with the gate green in between.

Two comment complexes exist only to police the `nil`/`:undefined` seam and
dissolve with it: `run_program/2`'s "never write the post-context back
wholesale" reasoning (`lib/statifier/evaluator.ex:346-364`) and
`Interpreter.Datamodel`'s step-4 raw-map note
(`lib/statifier/interpreter/datamodel.ex:192-197`).

### The outbound payload boundary, as it actually stands today

ADR-0037 open question 1 asks whether `:undefined` should escape into
`Effect.Send.data`. **It already does, today, before this bead changes
anything**, and that is the fact the answer turns on:

- `namelist` entries and `<param location>` are not a separate read path.
  `Statifier.Compiler.build_param/6` (`lib/statifier/compiler.ex:1414-1437`)
  and `build_send_namelist/3` (`:1146-1151`) compile the location string as an
  ordinary predicator expression with `kind: :location`
  (`lib/statifier/machine/param.ex:9-16`).
- At execute time both go through
  `Statifier.Machine.Content.Send`'s `resolve_params/2`
  (`lib/statifier/machine/content/send.ex:181-194`), which calls
  `Evaluator.evaluate(datamodel_context, expr)` - i.e. it reads the
  **normalized context**, not the raw datamodel map.
- A root that is declared-but-unbound is therefore already `{:ok, :undefined}`
  and lands verbatim in `Effect.Send.data` via `data/3`
  (`lib/statifier/machine/content/send.ex:227-232`) and `build_effect/6`
  (`:276-321`). `Statifier.Interpreter`'s invoke pass (`:1324-1349`) and
  `ExitEntry`'s donedata path (`lib/statifier/interpreter/exit_entry.ex:1003-1099`)
  are structurally identical.
- A root that is genuinely **undeclared** is a different case: `on_unbound:
  :error` (`lib/statifier/evaluator/functions.ex:58-62`) makes it
  `{:error, _}`, which for `<send>`/`<invoke>` is ADR-0036/ADR-0031's
  element-level discard and for `<donedata><param>` is 5.7's per-param drop
  plus `error.execution`.
- Nothing downstream inspects the value: `Session.Effects` copies
  `send.data` into `Event.data` verbatim (`lib/statifier/session/effects.ex:213,237`),
  `Session` delivers it by raw message send (`lib/statifier/session.ex:820`),
  and no JSON/wire encoder for events or effects exists anywhere in `lib/`.
  `Effect.Send.data`, `Effect.Invoke.params`/`.content` are typed bare
  `term()`.

### `Statifier.Event.data` as it stands today

`lib/statifier/event.ex:44-67`: `data: nil` default, `data: term()` in the
typespec; `external/2`, `internal/3`, `platform/3` all read `Keyword.get(opts,
:data)` with no default of their own, so "no data" is `nil`. Readers of
`event.data` in `lib/` are:

- `SystemVariables.event/1` (`lib/statifier/evaluator/system_variables.ex:92`) - verbatim copy into `_event.data`.
- `Statifier.Session.deliver/5` (`lib/statifier/session.ex:682`) - verbatim pass-through.
- `Interpreter.auto_assign_finalize/5` (`lib/statifier/interpreter.ex:731-732`) - guarded `when is_map(data)`, with a no-op fallback clause for everything else.

No `nil` check, no `||` default, no `is_nil/1` anywhere on `event.data` in
`lib/`. `:undefined` therefore travels the same path `nil` travels today, and
`auto_assign_finalize/5`'s `is_map/1` guard rejects it exactly as it rejects
`nil`.

## Desired End State

`Statifier.Evaluator.undefine_nils/1` does not exist; `bind/3` hands values to
`Predicator.Context.bind/3` verbatim; every writer above spells `:undefined`;
`nil` in `machine_state.datamodel` means predicator's null and nothing else.
`bind(ctx, "_event", %{"data" => %{"foo" => nil}})` preserves the `nil`, so
`_event.data.foo === null` is `true` and `=== undefined` is `false`.

Verified by: a full conformance run (`mix test --include scion --include
scxml_w3`) matching the baseline counts captured in Phase 0, a green `mix
test.regression`, a green full `mix quality`, and the new pinning tests each
phase adds.

### Key Discoveries:

- `Predicator.Context.bind/3`/`new/2` pass both `nil` and `:undefined` through
  unchanged at every depth (probed this session, output quoted above) - so
  respelling the writers is behavior-preserving **while `undefine_nils/1` is
  still in place**, which is what makes the phase split safe.
- `namelist`/`<param location>` already read the normalized context, so
  `:undefined` already reaches `Effect.Send.data` today
  (`lib/statifier/machine/content/send.ex:181-194`, `lib/statifier/compiler.ex:1414-1437`).
- No `nil` check on `event.data` exists in `lib/`; the one shape-sensitive
  reader guards on `is_map/1` (`lib/statifier/interpreter.ex:731`).
- No JSON or wire encoder for events/effects exists in `lib/`, so no
  serialization decision is forced by either open question (ADR-0003's I/O
  boundary; BasicHTTP is excluded per `tools/corpus/scxml_w3/exclusions.exs`).
- Zero corpus files under `test/scxml_tests/` or `test/scion_tests/` contain
  the token `null` (ADR-0037's Context, re-grepped for that record), and no
  corpus file observes either open question's difference.
- Constraint: ADR-0012 / `docs/observability.md` constraint 1 wants
  `MachineState` to be a complete, inspectable, resumable position.
  `:undefined` is a plain serializable atom, so the respell disturbs nothing
  there (ADR-0037's own Consequences).
- Constraint: ADR-0002's Appendix D rule. Nothing in this plan touches an
  Appendix D procedure body - `Interpreter.Datamodel`'s own moduledoc records
  that `initializeDatamodel` has no pseudocode body to port
  (`lib/statifier/interpreter/datamodel.ex:6-20`), and the seed's spelling is
  a 5.3.2/B.2.1 prose question, not a pseudocode one. **No deviation from
  Appendix D is introduced or removed by this plan.**

### Open question 1 (outbound payload boundary): ANSWERED - `:undefined` escapes untranslated

**Decision: no translation at the effect boundary. `:undefined` flows into
`Effect.Send.data`, `Effect.Invoke.params`/`.content`, and `Effect.Done.donedata`
exactly as any other value does.** Phase 2 lands a test that pins it rather
than any code change, because the code already behaves this way.

Grounds, in order of weight:

1. **It is already the shipped behavior**, and ADR-0037 does not change it. A
   namelist entry over a declared-but-unbound root reads `{:ok, :undefined}`
   off the normalized context today. Adding a translation would be a *new*
   behavior change smuggled in under a record that explicitly says its
   observable answers are unchanged.
2. **Translating would recreate the collapse ADR-0037 retires, one layer out.**
   Mapping `:undefined -> nil` at the effect boundary makes a payload member
   that was unbound indistinguishable from one that was assigned null - the
   exact conflation the record exists to end. Dropping the member instead
   (ECMAScript's `JSON.stringify` behavior, which the record names) is a
   different collapse: it makes `_event.data.foo === undefined` true on the
   receiving side, which happens to be right, but only by accident of there
   being no JSON wire here to justify it.
3. **Passing the atom through gives the receiving session the correct answer
   directly.** `Session.Effects.delivered_event/2`
   (`lib/statifier/session/effects.ex:209-217`) copies `send.data` into
   `Event.data`, `SystemVariables.event/1` copies that into `_event.data`, and
   predicator answers `=== undefined` true / `=== null` false on it (probed
   above). A cross-session round trip preserves undefined-ness with no
   translation at either end.
4. **There is no wire to serialize for.** B.2.8.1 is silent for a non-JSON
   wire, BasicHTTP is out of scope (`tools/corpus/scxml_w3/exclusions.exs`),
   and no encoder exists in `lib/`. A translation rule written now would be
   written against a hypothetical consumer.

**Scope of the answer**: it settles the `#_internal`, same-session, and
`#_scxml_<sessionid>` routes that exist today. If a BasicHTTP or other
external-wire processor is ever built, that processor owns its own
`:undefined` encoding decision at its own boundary - which is where a wire
format's rules belong, not in the core. Phase 2 records that boundary in
`Statifier.Effect.Send`'s moduledoc so the next author finds it.

### Open question 2 (`Statifier.Event.data`): ANSWERED - the struct carries `:undefined`

**Decision: `Statifier.Event`'s `data` field defaults to `:undefined` and
carries it for "no data". `nil` on that field means a null payload.** The
sibling fields `sendid`/`origin`/`origintype`/`invokeid` keep `nil` in the
struct and are translated to `:undefined` by `SystemVariables.event/1`.

Grounds:

1. **Keeping `nil` on `data` would recreate ADR-0037's collapse one layer up.**
   `EventData.coerce/1` can produce a genuinely null payload (a
   `<content>null</content>`, or a `<param expr="null">`), and `<send>` can
   produce no payload at all. If both are `nil` on the struct, the struct is
   the new site of the conflation and `event/1` cannot translate correctly -
   it would have to guess. The record's whole point is that the writer knows
   which state it means, and `coerce/1` is that writer.
2. **The split with `sendid`/`origin`/`origintype`/`invokeid` is principled,
   not arbitrary.** Those four are `String.t() | nil` - a datamodel null can
   never be one of them, so the two states cannot collide and `nil` is
   unambiguous in the struct. Translate where collision is impossible; carry
   the atom where it is possible. This is also exactly what the bead text
   directs ("`event/1` writes `:undefined` for the sendid/origin/origintype
   fields `Statifier.Event` does not carry").
3. **Nothing breaks.** `lib/` has no `nil` check on `event.data`; the one
   shape-sensitive reader guards `is_map/1` (`lib/statifier/interpreter.ex:731`).
4. **It keeps one spelling end to end**, which is the property that makes the
   convention checkable by reading a writer rather than by tracing a value.

`data`'s typespec stays `term()`; the moduledoc gains the sentence that
`:undefined` is "no data" and `nil` is a null payload.

## What We're NOT Doing

- **Not translating `:undefined` at any effect or session boundary** (open
  question 1's answer above). No `:undefined -> nil` mapping, no member
  dropping, no new encoder.
- **Not adding a BasicHTTP or other external-wire processor**, and not
  pre-deciding its encoding. Out of scope per
  `tools/corpus/scxml_w3/exclusions.exs`.
- **Not rewording ADR-0024.** It gets a one-sentence pointer naming
  ADR-0037's record, the way ADR-0036 annotated ADR-0021
  (`docs/adr/0021-*.md:103`). Accepted records are not silently reworded.
- **Not changing `<data src>`, `binding` semantics, or any failure branch's
  shape.** The keep-the-seed failure branches in
  `lib/statifier/interpreter/datamodel.ex` keep their shape exactly; only the
  seed's spelling moves.
- **Not adding corpus files.** ADR-0037 records that no corpus document
  distinguishes null from undefined, and inventing one is a corpus decision
  (`area:corpus`) that belongs to its own bead, not to this respell.
- **Not resolving the ADR number collision.** `docs/adr/0037-session-detected-send-failures-re-enter-the-core.md`
  and `docs/adr/0037-unbound-spelled-undefined-at-the-writer.md` are both on
  `origin/main` with the number 0037, and `docs/adr/README.md`'s table lists
  only the second. Two branches picked the same next number concurrently. That
  is a real defect and it makes the bare citation "ADR-0037" ambiguous - this
  plan therefore cites the *filename* wherever precision matters - but
  renumbering an accepted record is a direction-level call for a human, on its
  own bead. **Recorded here rather than acted on.**
- **Not re-running the Phase 4 send/cancel corpus re-check.** ADR-0037 and the
  bead both ask for a re-check once st-cmq.3's corpus atoms flip; that flip has
  not happened, so Phase 5 leaves a dated bead note asking for it rather than
  pretending to have done it.

## Implementation Approach

Three ordered code phases with a strictly behavior-preserving middle, so every
intermediate commit is gate-green:

1. Respell the writers **while `undefine_nils/1` is still in place**. Because
   predicator passes `:undefined` through unchanged (probed above), each
   respelled writer produces a bit-identical bound context. Only tests that
   inspect the *raw* datamodel map need updating.
2. Then retire `undefine_nils/1`. At that point every raw-map entry already
   agrees with what the bound context should hold, so removing the rewrite is
   the no-op it needs to be for the corpus - and the one thing it *does*
   change (a bound `nil` now reads `=== null`) is the record's whole purpose.
3. Docs and the record-keeping the acceptance criteria name.

Phase 0 exists because the acceptance criterion is a *comparison* against a
baseline, and a baseline captured after the first edit proves nothing.

**Phases 0 and 5 are tracker-only by design, and that is a deliberate
deviation from the "independently committable" phase standard, signed off
here rather than left implicit** (the plan critic raised it). Both are
gate-verifiable and neither produces a diff: Phase 0's artifact is a recorded
baseline, Phase 5's is a set of bead notes. CLAUDE.md's authority table
already carves out "a change touching no Elixir code has no gate to run", and
`/wurk:commit` is simply skipped on a clean tree. A `--loop` run will show two
phases with nothing in `git log`; that is expected, not a stall. They are kept
as phases rather than folded into their neighbours because a baseline that is
captured in the same commit as the first edit is not a baseline, and because
the bead notes are named acceptance criteria in their own right.

The writer phases split along the pipeline boundary `.claude/wurk/plan.md`
names: Phase 1 is datamodel-internal (nothing leaves `machine_state`), Phase 2
is the event/payload boundary (values that leave as effects). They are
independently committable in that order and, because Phase 1's writers are not
read by Phase 2's code paths, could be worked in either order if a later
re-plan wants to.

## Phase 0: Capture the conformance baseline

### Overview

Record the pre-change conformance and ratchet numbers so every later phase's
"unchanged" claim is checkable rather than remembered. No source changes.

### Changes Required:

#### 1. Baseline capture (no committed source change)

**File**: none in `lib/` or `test/`

**Changes**: run and record, in the bead's notes via `bd note`, the exact
output tail of:

```
mix test --include scion --include scxml_w3
mix test.regression
```

Record the test/failure counts verbatim, plus the `git rev-parse HEAD` they
were taken at. `test/passing_tests.json` is the ratchet's own record and is
**not** edited here.

### Success Criteria:

#### Automated Verification:
- [x] `mix test --include scion --include scxml_w3` completes and its counts are recorded on the bead.
- [x] `mix test.regression` is green.
- [x] Full `mix quality` is green on an unmodified tree (confirms the baseline is a clean one).

#### Manual Verification:
- [ ] The recorded counts name the commit SHA they were taken at.
- [ ] No file in the worktree was modified by this phase (`git status` clean).

**Implementation Note**: This phase produces a bead note, not a commit. If the
tree is clean there is nothing to commit and `/wurk:commit` is skipped; the
note is the artifact. Use `mix quality --profile loop` between edits in later
phases; the full gate is each phase's bar.

---

## Phase 1: The datamodel-internal writers spell `:undefined`

### Overview

`SystemVariables.initial/2`, `Interpreter.Datamodel.seed/2`, and
`Foreach.declare/2` write `:undefined` instead of `nil`. `undefine_nils/1`
stays in place, so every bound context is bit-identical and the corpus cannot
move. Only tests that inspect the raw `machine_state.datamodel` map change.

### Changes Required:

#### 1. `_event`'s seed

**File**: `lib/statifier/evaluator/system_variables.ex`

**Changes**: `initial/2` (`:69-77`) writes `"_event" => :undefined`. The
moduledoc's opening paragraph (`:9-14`) - which currently explains that `nil`
is deliberate *because* `undefine_nils/1` normalizes it - is rewritten to say
the writer spells unbound directly, citing
`docs/adr/0037-unbound-spelled-undefined-at-the-writer.md`. The "Why `_event`
is seeded rather than left absent" section (`:48-65`) keeps its argument
(seeded-vs-absent, test319, `on_unbound: :error`) and drops only its "bind the
key to `nil` and let `Predicator.Context.new/2` normalize it" clause.

```elixir
"_event" => :undefined,
```

#### 2. The `<data>` seed

**File**: `lib/statifier/interpreter/datamodel.ex`

**Changes**: `seed/2` (`:264-268`) becomes `Map.put_new(ms.datamodel, data.id,
:undefined)`. Step 2 of the moduledoc's algorithm (`:54-59`) is reworded off
"and `Predicator.Context.new/2` normalizes `nil` to `:undefined`" onto the
writer spelling it. The failure branches (`bind_value/4`'s `{:invalid, _}` and
`{:src, _}` clauses, `:311-317`, and `raise_binding_error/3`, `:433-435`) are
**unchanged in shape** - they still never write, so 5.3.2's "MUST create an
empty data element" is still satisfied by not overwriting the seed. The
moduledoc's references to keeping the seeded `nil` (`:66`, `:75`, `:286`,
`:427`) become `:undefined`.

#### 3. `<foreach>`'s declarations

**File**: `lib/statifier/machine/content/foreach.ex`

**Changes**: `declare/2` (`:205-212`) and `maybe_put_new/2` (`:215-216`) use
`:undefined` instead of `nil`. The comment at `:192-203` (step 5) drops its
"`nil`-versus-`:undefined` round-trip" framing and says the writer spells it.
`bind_names/4`'s comment (`:287-294`) drops the "`declare/2`'s `nil` default
... go through `Evaluator.bind/3`'s own `nil` -> `:undefined` normalization"
sentence - after this phase both paths bind a value that needs no
normalization.

#### 4. Tests that inspect the raw datamodel

**Files**: `test/statifier/interpreter/datamodel_test.exs`,
`test/statifier/evaluator_test.exs`,
`test/statifier/machine/content/assign_test.exs` (comment at `:55` only),
plus any test asserting a seeded/declared raw value.

**Changes**: assertions on raw seeded values move from `nil` to `:undefined`.
Known sites to check: `datamodel_test.exs:52` and `:239-240` (comments plus
their assertions), and `evaluator_test.exs:283-291`'s
`assert new_ms.datamodel["_event"] == nil`, which becomes `:undefined` because
`_event` now arrives from `initial/2` respelled. Assertions on
`new_machine_state(datamodel: %{"x" => nil})` roots stay `nil` - those are
environment-supplied and this phase does not touch them.

Each changed test's **sabotage line is rewritten** to describe the mutation
against the new code (per `docs/testing.md` and CLAUDE.md's convention), and
the sabotage is re-run: break, confirm red, revert.

Add one new test in `test/statifier/interpreter/datamodel_test.exs` pinning
that a `<data>` with no value and no `expr` reads `=== undefined` and
`!== null` through `Evaluator.evaluate/2` - the writer-level statement of
what the seed means, which survives Phase 2 and Phase 3 unchanged.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix gate.verify` confirms the run was a full, unscoped gate).
- [x] `mix test --include scion --include scxml_w3` matches Phase 0's recorded counts exactly.
- [x] `mix test.regression` is green.
- [x] `grep -rnE '=> nil[,)]|, nil\)' lib/statifier/evaluator/system_variables.ex lib/statifier/interpreter/datamodel.ex lib/statifier/machine/content/foreach.ex` finds no remaining seed/declare write of `nil` in any of the three writers this phase respells (the pattern must cover `"_event" => nil,` as well as `Map.put_new(datamodel, item, nil)`).

#### Manual Verification:
- [ ] Spec-conformance judgment: the touched functions still match their W3C basis - 5.3.2/5.3.3 for `seed/2` (no Appendix D pseudocode body exists to diff against, per the module's own moduledoc), 4.6.3 for `<foreach>`'s declarations, 5.10/B.2.1 for `_event`'s seed. No Appendix D deviation is introduced.
- [ ] Every changed test's sabotage line was actually re-run (break -> red -> revert), not just reworded.
- [ ] The failure branches in `Interpreter.Datamodel` still write nothing, and their prose still quotes 5.3.2's "MUST create an empty data element".
- [ ] No regressions in related features.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The event and payload boundary (open questions 1 and 2)

### Overview

Lands both of ADR-0037's deferred answers. `EventData.coerce/1`'s empty rungs
return `:undefined`; `Statifier.Event`'s `data` defaults to `:undefined`;
`SystemVariables.event/1` translates the four absent-string fields to
`:undefined`; and the untranslated escape of `:undefined` into
`Effect.Send.data` is pinned by test and recorded in prose.
`undefine_nils/1` is still in place, so every *bound* answer is unchanged.

### Changes Required:

#### 1. `coerce/1`'s empty rungs

**File**: `lib/statifier/event_data.ex`

**Changes**: `from_text/1`'s `"" ->` branch (`:67-69`) and `from_params([])`
(`:93`) return `:undefined`. `coerce/1`'s `@spec` (`:52`) drops `| nil` -
`term()` already covers `:undefined`, and the `| nil` was there to advertise
the empty rung. `from_params/1`'s `@spec` (`:92`) likewise. The comment at
`:90-91` keeps its `conf:emptyEventData` (test343/488/528) citation and says
`:undefined` where it says `nil`. Add a moduledoc paragraph stating the new
invariant: **an empty rung returns `:undefined` (no data); a genuinely null
value returns `nil` (`<content>null</content>`, `<param expr="null"/>`), and
the two are now distinguishable end to end** - ADR-0037's "a genuinely null
payload becomes representable end to end" consequence, made concrete at the
one function that produces it.

#### 2. `Statifier.Event`'s `data` field

**File**: `lib/statifier/event.ex`

**Changes**: `defstruct` (`:44-53`) gets `data: :undefined`; `external/2`
(`:80-90`), `internal/3` (`:106-115`), and `platform/3` (`:127-136`) each read
`Keyword.get(opts, :data, :undefined)`. The `@type` stays `data: term()`.
`external/2`'s `@doc` sentence "`data` defaults to `nil` (\"no data\"),
distinct from `%{}` (\"data, empty\")" (`:70-71`) becomes the three-way
statement: `:undefined` is "no data", `nil` is a null payload, `%{}` is "data,
empty". Add a moduledoc section recording open question 2's answer and its
reason - `data` can be a null payload so it carries the atom; the four
`String.t() | nil` fields cannot, so they stay `nil` here and are translated at
`event/1`.

`sendid`/`origin`/`origintype`/`invokeid` defaults are **unchanged** (`nil`).

Two callers inherit the new default without any edit of their own, and both
are behavior-preserving: `Statifier.Machine.Content.Raise`
(`lib/statifier/machine/content/raise.ex:36-40`) passes no `:data` at all, and
`ExitEntry`'s grandparent `done.state.*` raise
(`lib/statifier/interpreter/exit_entry.ex:937-941`) likewise. Both produced
`nil` -> `:undefined` at bind time before and produce `:undefined` directly
now. The `raise_platform/4` sites that pass `data: reason` (a diagnostic Elixir
term, not spec event data) are untouched.

#### 3. `SystemVariables.event/1` translates the four string fields

**File**: `lib/statifier/evaluator/system_variables.ex`

**Changes**: `event/1` (`:84-94`) writes `:undefined` for a `nil`
`sendid`/`origin`/`origintype`/`invokeid`, and passes `event.data` through
**verbatim** (it is already correctly spelled after change 2). A small private
helper (`defp absent(nil), do: :undefined` / `defp absent(value), do: value`)
keeps the map literal readable. Its comment states the bounded reason: these
four are `String.t() | nil` on `Statifier.Event`, so a null and an absent
cannot collide, and translating here keeps the struct idiomatic - the
narrow exception open question 2's answer carves out, named as such.

```elixir
"sendid" => absent(event.sendid),
"origin" => absent(event.origin),
"origintype" => absent(event.origintype),
"invokeid" => absent(event.invokeid),
"data" => event.data
```

#### 4. Record the outbound boundary decision

**File**: `lib/statifier/machine/content/send.ex`

**Changes**: `data/3`'s comment (`:219-226`) currently justifies keying the
dispatch on the node's shape by saying "a blank `<content/>` legitimately
coerces to `nil` too". The reasoning is unchanged and the dispatch is
unchanged - only the spelling: a blank `<content/>` now coerces to
`:undefined`. Update the sentence rather than the code.

**File**: `lib/statifier/effect/send.ex` (moduledoc)

**Changes**: a short section stating open question 1's answer: a `namelist`
entry or `<param location>` over a declared-but-unbound root resolves to
`:undefined` and travels in `data` untranslated; an *undeclared* root is an
argument failure that discards the message (ADR-0036); and a future external
wire processor owns its own encoding of `:undefined` at its own boundary.
Cites `docs/adr/0037-unbound-spelled-undefined-at-the-writer.md` by filename.

#### 5. Tests

**Files**: `test/statifier/evaluator/system_variables_test.exs`,
`test/statifier/event_data_test.exs`, `test/statifier/event_test.exs`,
`test/statifier/interpreter/exit_entry_enter_test.exs`,
`test/statifier/session/effects_test.exs`,
`test/statifier/machine/content/send_test.exs`, `test/statifier/session_test.exs`

The exact existing assertions that move from `nil` to `:undefined`, all of
which inspect a struct field directly rather than an evaluated answer:

| Site | What it asserts today |
|---|---|
| `test/statifier/event_test.exs:23` | `Event.external("go").data == nil` |
| `test/statifier/event_data_test.exs:15,58,68` | `coerce({:value, nil})`, blank text, empty params all `nil` - **note `:15` is `{:value, nil}` and must STAY `nil`**; only the two empty rungs move |
| `test/statifier/interpreter/exit_entry_enter_test.exs:438,497,516,518,799,850` | `done.state.*` events with no/failed donedata carrying `data == nil` |
| `test/statifier/session/effects_test.exs:49,131` | expected-output fixtures built as `Event.internal(..., data: nil, ...)` |
| `test/statifier/evaluator_test.exs:232` | builds `Event.external("go", data: nil)`; keep the constructor call as-is (it now means a null payload) but its companion assertion at `:238` (`_event.data` is `:undefined`) **must be revisited** - with `data: nil` explicitly passed, the correct post-ADR-0037 answer becomes `{:ok, nil}` once Phase 3 lands. Change the fixture to `Event.external("go")` in **this** phase so the test keeps asserting what it means to assert (absent data reads undefined), and add a sibling asserting the `data: nil` case reads `=== null` in Phase 3. |

**Changes**:

- `system_variables_test.exs:70-82` ("maps an event with no data to a map whose
  \"data\" is nil") becomes the `:undefined` shape for all five absent fields;
  its title and sabotage line are rewritten to match.
- `system_variables_test.exs:106-137`'s `conf:emptyEventData` describe block
  keeps both its assertions verbatim - they are the observable contract and
  must not move. Its sabotage lines are rewritten (the mutation is now
  `event/1` writing `event.data || %{}`, reached through a differently spelled
  input).
- **New test (open question 1's pin)**: a `<send>` whose `namelist` names a
  declared-but-unbound `<data>` id produces an `Effect.Send` whose
  `data` is `%{"Var1" => :undefined}` - the escape, asserted rather than
  assumed. Its companion asserts that a `namelist` over an *undeclared* name
  produces no effect at all (ADR-0036 discard).
- **New test (open question 1's end-to-end pin)**: through
  `Statifier.Session`, a `<send>` with such a `namelist` delivered back to the
  same session leaves `_event.data.Var1 === undefined` true and `=== null`
  false. This is the property that would break under either candidate
  translation, so it is the test that makes the answer non-reversible by
  accident.
- **New test (open question 2's pin)**: `Event.external("go")` has
  `data: :undefined`, and `Event.external("go", data: nil)` has `data: nil` -
  the struct-level statement that the two are distinct.
- **New test (coerce)**: `coerce({:params, []}) == :undefined` and
  `coerce({:value, nil}) == nil`, side by side.
- Any existing assertion of `data: nil` on an `Effect.Send`/`Effect.Invoke`/
  `Effect.Done` for a no-payload element moves to `:undefined`.

Every new test asserting `lib/` behavior gets a sabotage line and a real
break/red/revert cycle; every reworded one gets its cycle re-run.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix gate.verify` confirms an unscoped run).
- [x] `mix test --include scion --include scxml_w3` matches Phase 0's recorded counts exactly.
- [x] `mix test.regression` is green.
- [x] The new namelist-over-unbound-root test asserts `%{"Var1" => :undefined}` in `Effect.Send.data` and passes.
- [x] The new session round-trip test asserts `_event.data.Var1 === undefined` true and `=== null` false and passes.
- [x] `Event.external("go").data == :undefined` and `Event.external("go", data: nil).data == nil` both pass.

#### Manual Verification:
- [ ] Spec-conformance judgment: `coerce/1` still implements B.2.8.1's ladder as its moduledoc table claims, and `event/1` still writes spec 5.10.1's field set. No Appendix D procedure body is touched, so no Appendix D deviation is introduced.
- [ ] The two answers are readable from the code alone - a reader of `lib/statifier/effect/send.ex` and `lib/statifier/event.ex` finds both decisions and their reasons without opening the ADR.
- [ ] Every changed and new test's sabotage was actually run.
- [ ] No regressions in `<send>`, `<invoke>`, `<donedata>`, or session delivery behavior.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: Retire `undefine_nils/1`

### Overview

`Evaluator.bind/3` hands values to `Predicator.Context.bind/3` verbatim;
`undefine_nils/1` is deleted; the two comment complexes that existed only to
police the seam dissolve. This is the phase where a bound `nil` starts reading
`=== null`, which is the record's purpose and the acceptance criterion's
subject.

### Changes Required:

#### 1. `Statifier.Evaluator`

**File**: `lib/statifier/evaluator.ex`

**Changes**:

- Delete `undefine_nils/1` and its four clauses (`:220-228`) and the long
  comment above them (`:200-219`).
- `bind/3` (`:254-258`) becomes
  `Predicator.Context.bind(context, root, value)`.
- `bind/3`'s `@doc` (`:230-253`) drops the normalization paragraph and the
  `Predicator.Context.assign/3` contrast's normalization clause, keeping the
  within-block/across-block safety argument and the O(size of value) note
  unchanged. It gains one sentence naming the new invariant: values are handed
  over verbatim; the only remaining normalization is predicator's own, and
  `nil` means null.
- `bind_roots/2`'s comment (`:186-193`) drops "applies `undefine_nils/1` per
  root and"; the equivalence claim it makes is now simply that folding `bind/3`
  produces what `new/2` would, which is *more* directly true than before.
- `run_program/2`'s `@doc` (`:346-364`): the "normalized (`undefine_nils/1`),
  so it is never written back wholesale (that would permanently rewrite every
  untouched `nil` root to `:undefined`)" reason dissolves. **The top-level
  diff-merge itself stays** - it still carries the system-variable write check
  (ADR-0037's Consequences say so in as many words). The doc is rewritten to
  give the surviving reasons for the diff: the system-root check, and merging
  only changed roots. The "a seeded-but-unbound `<data>` id still reads `nil`"
  sentence becomes `:undefined` (which after Phase 1 is what it actually
  holds).

#### 2. `Interpreter.Datamodel.write_location/4`'s round-trip prose

**File**: `lib/statifier/interpreter/datamodel.ex`

**Changes**: step 4's comment (`:192-197`) loses its raw-versus-normalized
justification - the raw map and the bound context now agree on the unbound
spelling. The **write still goes to the raw map** and step 4 still says so;
what changes is the reason, which becomes the simple one (the raw map is
`MachineState`'s resumable truth, ADR-0012) rather than the seam-policing one.
The `@doc`'s numbered step 4 (`:107-108`) loses its "(`nil`s intact)"
parenthetical.

#### 3. Tests

**File**: `test/statifier/evaluator_test.exs`

**Changes**:

- `bind/3`'s "normalizes a bound nil to :undefined, matching context/1"
  (`:334-346`) **inverts**: it becomes the ADR-0037 acceptance criterion -
  `Evaluator.bind(context, "y", nil)` then `y === null` is `{:ok, true}` and
  `y === undefined` is `{:ok, false}`. New title, new sabotage line.
- "binding a value with a nested nil normalizes the nested nil too"
  (`:404-416`) inverts the same way at depth: `obj.inner === null` true.
- **New test, the bead's named acceptance criterion verbatim**:
  `bind(ctx, "_event", %{"data" => %{"foo" => nil}})` preserves the `nil`, and
  `_event.data.foo === null` is true while `=== undefined` is false.
- The `context/1` equivalence test (`:493-518`) drops `deep_undefine_nils/1`
  from its reference construction and passes `ms.datamodel` directly to
  `Predicator.Context.new/2`. The private `deep_undefine_nils/1` helper
  (`:521-532`) is deleted. Its sabotage line is rewritten; note this test gets
  *stronger*, since the reference is now the datamodel itself rather than a
  hand-mirrored transform of it. Its `datamodel` fixture (`:494-501`) keeps its
  `nil`s - they are now meaningful nulls and exercise exactly the shape that
  used to be collapsed.
- "an untouched nil root stays nil after a successful program" (`:293-302`)
  keeps its assertion; only its sabotage line's mechanism sentence changes.
- Every sabotage line in the file that names `undefine_nils/1` (`:336`, `:349`,
  `:375`, `:390`, `:404`, `:490`) is rewritten against the new code and re-run.

**File**: `test/statifier/evaluator/system_variables_test.exs`

**Changes**: the `conf:emptyEventData` assertions (`:121-122`) are unchanged -
after Phases 1-2 they answer `:undefined` because the writer spelled it, not
because a rewrite produced it. The sabotage lines are rewritten to name the new
mechanism.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix gate.verify` confirms an unscoped run).
- [x] `grep -rn 'undefine_nils' lib/ test/` returns nothing.
- [x] `mix test --include scion --include scxml_w3` matches Phase 0's recorded counts exactly. **This is the acceptance criterion's central check.**
- [x] `mix test.regression` is green.
- [x] The new `bind(ctx, "_event", %{"data" => %{"foo" => nil}})` test asserts `=== null` true and `=== undefined` false and passes.
- [x] W3C test319, test333, test335, test337, test339, test343, test488, test528, test150, test151 all keep their prior pass/fail status (check them individually against Phase 0's per-test record, not just against the aggregate count).

#### Manual Verification:
- [ ] Spec-conformance judgment: `bind/3`, `bind_roots/2`, `context/1`, and `run_program/2` still match their documented contracts, and `write_location/4`'s five steps are unchanged in behavior. No Appendix D procedure body is touched by this phase, so no Appendix D deviation is introduced or removed.
- [ ] `run_program/2`'s remaining diff-merge reasoning reads correctly on its own - the system-variable check survives as the reason, and no sentence still references a rewrite that no longer exists.
- [ ] A `grep` for "normaliz" across the four touched modules finds no prose still claiming this repo normalizes `nil`.
- [ ] Every rewritten sabotage line was actually re-run.
- [ ] No regressions in related features.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 4: Documentation, the ADR-0024 pointer, and the changelog

### Overview

The record-keeping ADR-0037's Consequences name: the embedder-visible
`:datamodel` change, ADR-0024's pointer, `docs/datamodel.md`'s seam note, and a
changelog fragment.

### Changes Required:

#### 1. The embedder-visible `:datamodel` change

**File**: `lib/statifier/machine_state.ex`

**Changes**: `new/2`'s `@doc` (around `:407-414`, where the `:datamodel` option
is documented) gains the sentence ADR-0037's Consequences require: an
environment-supplied `:datamodel` value of `nil` now means predicator's null;
an embedder that means "declared, no value" passes `:undefined`. The
"System variables live in the datamodel" moduledoc section (`:266-300`) gains
the same one-line statement if it reads as the natural home.

#### 2. ADR-0024's pointer

**File**: `docs/adr/0024-data-src-is-never-fetched.md`

**Changes**: one sentence, appended where the record says "leaves the id as an
empty (nil) data element" (`:90`), naming
`docs/adr/0037-unbound-spelled-undefined-at-the-writer.md` as the record that
respells that seed `:undefined`. **A pointer, not a reword** - the surrounding
prose and the decision are untouched, exactly as ADR-0036 annotated ADR-0021
(`docs/adr/0021-*.md:103`). The same one-sentence pointer goes at `:42`'s
"leaving the id seeded to `nil`" if a reader of that paragraph alone would
otherwise be misled.

#### 3. `docs/datamodel.md`

**File**: `docs/datamodel.md`

**Changes**: seam 3 ("A typed undefined", `:171-180`) gains a closing sentence:
this repo's own `nil`->`:undefined` shim is retired as of
`docs/adr/0037-unbound-spelled-undefined-at-the-writer.md`; writers spell
`:undefined` and `nil` is predicator's null.

#### 4. Changelog fragment

**File**: `changelog.d/st-1bjz.md` (new)

**Changes**: a user-facing entry. This qualifies under
`changelog.d/README.md`'s "a change in observable behavior" and "a public API
change": `Statifier.Event`'s `data` default moves from `nil` to `:undefined`,
and an environment-supplied `:datamodel` `nil` now means null. Written in the
project's fragment style; **`CHANGELOG.md` itself is not edited**.

#### 5. House-style note for the implementer

The files in this phase are em-dash-using prose (`docs/adr/*`,
`docs/datamodel.md`, the Elixir moduledocs). Per the user's standing style
rule, **match the surrounding file's typography** rather than converting it -
these are edits to existing content, not new files. The one genuinely new file
is `changelog.d/st-1bjz.md`; check its neighbors in `changelog.d/` and follow
whatever they do.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix gate.verify` confirms an unscoped run) - `machine_state.ex`'s moduledoc change means this phase has Elixir in it and the gate applies.
- [x] `mix quality --profile merge` is green, so the ADR judge stage actually runs over the ADR-0024 edit (the bare gate skips it by design - CLAUDE.md's not-applicable list).
- [x] `changelog.d/st-1bjz.md` exists and `CHANGELOG.md` is unmodified (`git diff --name-only origin/main -- CHANGELOG.md` is empty).
- [x] `mix test.regression` is green.

#### Manual Verification:
- [ ] Spec-conformance judgment (the extension file's always-required item, discharged for a doc-only phase): this phase's `lib/statifier/` change is `@doc`/moduledoc prose in `machine_state.ex` and touches no function body, so there is no Appendix D pseudocode to diff line for line - the same discharge Phase 1 gives for `seed/2`. Confirm by reading the diff that no expression outside a docstring moved.
- [ ] ADR-0024's edit is genuinely a pointer: `git diff docs/adr/0024-*.md` adds sentences and changes no existing argument.
- [ ] The `:datamodel` option's documentation now tells an embedder, unambiguously, how to express "declared, no value".
- [ ] Typography in each edited file matches that file's existing convention; no incidental em-dash-to-hyphen conversion appears in the diff.
- [ ] The changelog fragment describes the change from the point of view of someone who only calls the public API.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 5: Record the answers and the deferred re-check on the bead

### Overview

The acceptance criterion "Both ADR-0037 open questions are answered in the
branch, in code or in a note on this bead" is satisfied in code by Phase 2, and
this phase makes it findable from the tracker. It also leaves the dated note
ADR-0037 and the bead both ask for about st-cmq.3's corpus flip.

### Changes Required:

#### 1. The answers, on the bead

**File**: none (tracker only)

**Changes**: `bd note st-1bjz` with (a) open question 1's answer -
`:undefined` escapes into `Effect.Send.data` untranslated, already the shipped
behavior, now pinned by test and recorded in `lib/statifier/effect/send.ex`'s
moduledoc; a future external-wire processor owns its own encoding - and (b)
open question 2's answer - `Statifier.Event.data` carries `:undefined`,
`sendid`/`origin`/`origintype`/`invokeid` stay `nil` in the struct and are
translated at `SystemVariables.event/1`. Each names the file the reasoning
lives in, so the note is an index rather than a second copy.

#### 2. The deferred re-check

**File**: none (tracker only)

**Changes**: a dated `bd note` recording that the conformance comparison in
Phases 1-3 was taken **before** st-cmq.3's Phase 4 send/cancel corpus atoms
flipped, and that ADR-0037 and this bead both ask for a re-run of
`mix test --include scion --include scxml_w3` against this branch's numbers
once they do. Read st-cmq.3's current state first and say what it was at the
time of writing.

#### 3. The ADR number collision

**File**: none (tracker only)

**Changes**: file a separate bead (`area:docs`) recording that
`docs/adr/0037-session-detected-send-failures-re-enter-the-core.md` and
`docs/adr/0037-unbound-spelled-undefined-at-the-writer.md` share the number
0037 on `origin/main`, and that `docs/adr/README.md` lists only the latter.
This branch does not renumber either - renumbering an accepted record is a
human's call.

### Success Criteria:

#### Automated Verification:
- [ ] `bd show st-1bjz` returns notes containing both open questions' answers.
- [ ] `bd show st-1bjz` returns a dated note naming st-cmq.3 and the deferred conformance re-check.
- [ ] A new bead exists for the ADR-0037 number collision and is linked from st-1bjz.
- [ ] Full `mix quality` is still green on the branch tip.

#### Manual Verification:
- [ ] Each answer note points at the file where its reasoning lives, and the two do not disagree with the code.
- [ ] The deferred-re-check note states st-cmq.3's status as of the day it was written, per CLAUDE.md's cross-tracker freshness rule.

**Implementation Note**: This phase produces bead state, not a commit. If the
worktree is clean there is nothing to commit. `bd dolt push` waits until the
git side of this branch has reached `origin`, per CLAUDE.md's authority table.

---

## Testing Strategy

### Unit Tests:

- **`test/statifier/evaluator_test.exs`** - the null-versus-undefined contract
  at the `bind/3` seam: a bound `nil` reads `=== null` true / `=== undefined`
  false, at the root and nested; the bead's named
  `bind(ctx, "_event", %{"data" => %{"foo" => nil}})` case; `context/1`'s
  equivalence to a direct `Predicator.Context.new/2` over the raw datamodel
  (strengthened by dropping the mirrored helper).
- **`test/statifier/evaluator/system_variables_test.exs`** - `initial/2` seeds
  `:undefined`; `event/1`'s five absent fields; the `conf:emptyEventData`
  assertions unchanged.
- **`test/statifier/interpreter/datamodel_test.exs`** - a declared `<data>` with
  no value reads `=== undefined` / `!== null`; the failure branches still keep
  the seed.
- **`test/statifier/machine/content/foreach_test.exs`** - `item`/`index` declared
  before an empty collection's loop read `=== undefined`.
- **`test/statifier/event_data_test.exs`** - `coerce({:params, []})` and
  `coerce({:text, "  "})` are `:undefined`; `coerce({:value, nil})` and
  `coerce({:text, ~s({"foo": null})})` preserve `nil`, side by side.
- **`test/statifier/machine/content/send_test.exs`** - a `namelist` over a
  declared-but-unbound root puts `:undefined` in `Effect.Send.data`; over an
  undeclared name, no effect at all.
- **`test/statifier/session_test.exs`** - the end-to-end round trip:
  `_event.data.Var1 === undefined` true, `=== null` false, after a `<send>`
  whose `namelist` named an unbound root.
- **Key edge cases**: a present-and-null JSON field surviving `coerce/1` and
  `bind/3` together (the bead's finding); a `<data>` failure branch keeping its
  seed; a program that never touches a `nil` root leaving it `nil`; a
  `<foreach>` over an empty collection.

Every new test asserting `lib/` behavior carries a sabotage line and its
break/red/revert cycle is actually performed (`docs/testing.md`). Generated
corpus files under `test/scxml_tests/` and `test/scion_tests/` are exempt.

### Manual Testing Steps:

1. After each phase, run `mix test --include scion --include scxml_w3` and
   diff the counts against Phase 0's recorded baseline. A move in either
   direction is a finding, not a win.
2. After Phase 3, check the ten named W3C tests individually
   (test319/333/335/337/339, test343/488/528, test150/151) rather than trusting
   the aggregate.
3. Read `lib/statifier/evaluator.ex` end to end after Phase 3 and confirm no
   prose still describes a normalization this module no longer performs.
4. Read `lib/statifier/effect/send.ex` and `lib/statifier/event.ex` after
   Phase 2 and confirm a fresh reader can find both open questions' answers
   without opening the ADR.
5. Confirm `git diff docs/adr/0024-*.md` shows only added pointer sentences.

## Corpus/Ratchet Notes

**No corpus regeneration and no `test/passing_tests.json` change is expected
or intended.** ADR-0037's design property is that observable corpus answers do
not move, and every phase's automated criteria assert exactly that against
Phase 0's baseline.

If the conformance counts *do* move, that is a finding to report, not a
number to ratchet. In particular: **do not run `mix test.baseline add` to
absorb a change on this branch.** A newly passing test here would mean the
respell changed an observable answer, which contradicts the record and needs a
human's judgment before it is recorded as progress. `test/passing_tests.json`
is a gate-guarded file (CLAUDE.md's ledger rule: shrinking it needs an entry in
`docs/quality-gate-changes.md`), and neither growing nor shrinking it is this
bead's work.

No guarded file (`.quality.exs`, `.credo.exs`, `coveralls.json`,
`.sobelow-conf`, `.doctor.exs`, gate-relevant `mix.exs` lines) is touched by
any phase, so no `docs/quality-gate-changes.md` entry is owed. No `@tag :skip`
is added anywhere.

## References

- Source ADR: `docs/adr/0037-unbound-spelled-undefined-at-the-writer.md` (cited by filename throughout, because the number 0037 is ambiguous on `origin/main` - see "What We're NOT Doing")
- Related ADRs: `docs/adr/0024-data-src-is-never-fetched.md` (gets a pointer), `docs/adr/0028-executable-content-blocks-thread-one-context.md` (its `<script>` null note is the gap this closes generally), `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md` (`context/1`'s shape), `docs/adr/0036-send-argument-failure-discards-the-message.md` and `docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md` (the undeclared-root failure path), `docs/adr/0012-*` via `docs/observability.md` (resumable truth), `docs/adr/0002-*` (Appendix D port rule; no procedure body is touched here)
- Prior research: `docs/research/260813-st-af3.4-assign-deep-path-vivification.md` (open question 2 there is the same seam), `docs/plans/260815-st-cmq.3-send-cancel-content-nodes-and-effects.md` (Decision 3, the second verification of the collapse)
- Design docs: `docs/datamodel.md` seam 3, `docs/testing.md` (sabotage rule), `docs/architecture.md` principle 3
- Predicator behavior probed this session against the pinned 8.x, output quoted under "Current State Analysis"
- Bead: st-1bjz

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spec-conformance judgment: the touched functions still match their W3C basis - 5.3.2/5.3.3 for `seed/2` (no Appendix D pseudocode body exists to diff against, per the module's own moduledoc), 4.6.3 for `<foreach>`'s declarations, 5.10/B.2.1 for `_event`'s seed. No Appendix D deviation is introduced.
- [ ] Every changed test's sabotage line was actually re-run (break -> red -> revert), not just reworded.
- [ ] The failure branches in `Interpreter.Datamodel` still write nothing, and their prose still quotes 5.3.2's "MUST create an empty data element".
- [ ] No regressions in related features.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [ ] Spec-conformance judgment: `coerce/1` still implements B.2.8.1's ladder as its moduledoc table claims, and `event/1` still writes spec 5.10.1's field set. No Appendix D procedure body is touched, so no Appendix D deviation is introduced.
- [ ] The two answers are readable from the code alone - a reader of `lib/statifier/effect/send.ex` and `lib/statifier/event.ex` finds both decisions and their reasons without opening the ADR.
- [ ] Every changed and new test's sabotage was actually run.
- [ ] No regressions in `<send>`, `<invoke>`, `<donedata>`, or session delivery behavior.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 3

- [ ] Spec-conformance judgment: `bind/3`, `bind_roots/2`, `context/1`, and `run_program/2` still match their documented contracts, and `write_location/4`'s five steps are unchanged in behavior. No Appendix D procedure body is touched by this phase, so no Appendix D deviation is introduced or removed.
- [ ] `run_program/2`'s remaining diff-merge reasoning reads correctly on its own - the system-variable check survives as the reason, and no sentence still references a rewrite that no longer exists.
- [ ] A `grep` for "normaliz" across the four touched modules finds no prose still claiming this repo normalizes `nil`.
- [ ] Every rewritten sabotage line was actually re-run.
- [ ] No regressions in related features.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 4

- [ ] Spec-conformance judgment (the extension file's always-required item, discharged for a doc-only phase): this phase's `lib/statifier/` change is `@doc`/moduledoc prose in `machine_state.ex` and touches no function body, so there is no Appendix D pseudocode to diff line for line - the same discharge Phase 1 gives for `seed/2`. Confirm by reading the diff that no expression outside a docstring moved.
- [ ] ADR-0024's edit is genuinely a pointer: `git diff docs/adr/0024-*.md` adds sentences and changes no existing argument.
- [ ] The `:datamodel` option's documentation now tells an embedder, unambiguously, how to express "declared, no value".
- [ ] Typography in each edited file matches that file's existing convention; no incidental em-dash-to-hyphen conversion appears in the diff.
- [ ] The changelog fragment describes the change from the point of view of someone who only calls the public API.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---
