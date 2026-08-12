---
date: 2026-08-12T15:45:18-0600
researcher: Claude
git_commit: fff279bf2add606288c70cbb6ea8e4d2441cf0b5
branch: st-unt-boundness-sentinel-collision
repository: statifier-ex
beads_issue: st-unt
topic: "Which boundness-sentinel conds the predicator 5.0 undefined literal fixes, and what the root-shaped remainder costs"
tags: [research, codebase, datamodel, corpus, predicator]
status: complete
last_updated: 2026-08-12
last_updated_by: Claude
---

# Research: Which boundness-sentinel conds the predicator 5.0 `undefined` literal fixes, and what the root-shaped remainder costs

**Date**: 2026-08-12T15:45:18-0600
**Git Commit**: fff279bf2add606288c70cbb6ea8e4d2441cf0b5
**Branch**: st-unt-boundness-sentinel-collision
**Bead**: st-unt

## Research Question

The conformance corpus writes boundness as a comparison against
`_statifier_unbound`, an identifier no generated document binds
([`tools/corpus/scxml_w3/conf_predicator.xsl:5-10`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L5-L10)). Under
`on_unbound: :error` (ADR-0014 item 5, set by
[`lib/statifier/evaluator.ex:101`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator.ex#L101)), loading that sentinel is itself an
`UndefinedVariableError`. predicator 5.0.0 - already locked on this branch -
adds an `undefined` literal, so `x === undefined` is a direct boundness test
that never consults `on_unbound`. But a genuinely unbound **root** load still
errors before the comparison runs.

That splits the seven sentinel-emitting XSL templates two ways. The core
question is which template falls on which side, and specifically: **is a
`<data id="Var1"/>` declared without an `expr` seeded into the datamodel as
bound-but-undefined (the way `_event` now is), or is it genuinely absent?**

Secondary: the full inventory of sentinel conds in the checked-in corpus, the
regeneration mechanics and blast radius, what the regression ratchet obliges,
and whether a fix needs an ADR amendment.

## Summary

**The property/root split is real, and it is cleaner than the bead assumed:
every property-shaped cond is fixed by a one-line-per-template XSL respelling,
and every root-shaped `Var<n>` cond is blocked on a decision that does not
exist yet.**

Four findings carry the answer.

1. **Property-shaped conds work under `undefined` today, verified.** Against a
   context built exactly as `Statifier.Evaluator.context/1` builds one
   (`on_unbound: :error`, real `SystemVariables.initial/2` data),
   `_event.data === undefined` -> `{:ok, true}` both before any event
   (`_event` seeded `nil` -> `:undefined`) and after one. Nine of the 25
   sentinel conds are property-shaped, in eight files, none of which contains
   a single `<data>` element.

2. **The root-shaped `Var<n>` question has no answer in the code, because
   `<data>` is not implemented at all.** `data` and `datamodel` are absent
   from the lowering dispatch map ([`lib/statifier/lowering.ex:52-67`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L52-L67)); there
   is no `build_data/2`, no `Statifier.Document.Data`, and an unrecognized
   element is a hard lowering error, not a silent drop
   ([`lib/statifier/lowering.ex:144`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L144)). So a document containing
   `<data id="Var1"/>` does not lower today - the question "is it seeded
   bound-but-undefined or genuinely absent?" is a decision the `<data>`
   lowering/initialization work will make, and nothing in `lib/` has made it.
   [`docs/datamodel.md:22-23`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/docs/datamodel.md#L22-L23) describes `<data>` with `expr`/content/`src` and
   both binding modes as what the datamodel provides; that is the commitment,
   not shipped code.

3. **Both answers to that decision were probed empirically, so the plan stage
   does not have to guess.** With `Var1` present in the datamodel map bound to
   `nil` or `:undefined`, `Var1 === undefined` -> `{:ok, true}` and
   `Var1 !== undefined` -> `{:ok, false}` - exactly the `conf:isBound` /
   `conf:unboundVar` / `conf:noValue` semantics. With `Var1` absent from the
   map, both spellings -> `{:error, UndefinedVariableError}`. **Seeding
   declared-but-unassigned `<data>` the way `_event` is seeded makes the
   root-shaped templates work as-is under ADR-0014 item 5, with no ADR
   amendment and no respelling beyond `_statifier_unbound` -> `undefined`.**

4. **The one root-shaped *system-variable* cond already works.** The only
   `conf:systemVarIsBound` occurrence in the corpus is test319's
   `_event !== _statifier_unbound`, and `_event` is seeded by
   `SystemVariables.initial/2` ([`lib/statifier/evaluator/system_variables.ex:55`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L55)).
   Respelled, `_event !== undefined` -> `{:ok, false}`, which takes the
   `<else>` branch and passes - the answer test319 asserts. `_sessionid`,
   `_name`, and `_ioprocessors` are also always seeded; `_x` is not seeded and
   never appears in the corpus.

Consequences for scope: the XSL edit is seven template bodies, mechanical and
identical in shape (`_statifier_unbound` -> `undefined`, `===`/`!==` already
correct everywhere). It fixes 9 conds outright, 1 more (test319) outright, and
converts the remaining 15 from "errors on the sentinel" to "errors on the
`Var<n>` root" - a strictly better failure that the `<data>` work then
resolves. No ADR amendment is required for any of it, and no `passing_tests.json`
change is obliged, since none of the 24 affected files is in the ratchet.

The bead's headline count ("26 conds across 25 files") is off by one in each
term against the checked-in corpus: `grep -rn _statifier_unbound test/` returns
**25 lines across 24 files** (test330 carries two).

## Detailed Findings

### 1. The evaluation context, and what `on_unbound: :error` actually gates

`Statifier.Evaluator.context/1` is the single construction site
([`lib/statifier/evaluator.ex:98-103`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator.ex#L98-L103)):

```elixir
Predicator.Context.new(machine_state.datamodel,
  functions: %{"In" => {1, in_function(machine_state)}},
  on_unbound: :error
)
```

`on_unbound: :error` is ADR-0014 item 5 ("Unbound variables are errors, not
sentinels"), chosen so a cond referencing a missing datamodel location fails
with an `UndefinedVariableError` naming the variable and carrying its span
rather than silently evaluating `:undefined`.

The policy fires **on root loads only**. A property access on a bound root
never consults it: the root loads, and a missing key yields `:undefined`
without error. That is the entire mechanism behind the property/root split.

### 2. Verified predicator 5.0 behavior (probe, this worktree)

[`mix.lock:19`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mix.lock#L19) locks `predicator 5.0.0`; [`mix.exs:41`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mix.exs#L41) pins `~> 5.0`. Probed via
`mix run` in this worktree against contexts built exactly like `context/1`
builds them, with the real `SystemVariables.initial/2` shape as the datamodel.
This supplements - it does not repeat - what
`docs/research/260812-st-p3t-predicator-5-bump.md` section 5 already
established for `_event.data`.

**Property-shaped, `_event` seeded `nil` (the pre-event state):**

| Expression | Result |
|---|---|
| `_event.data === undefined` | `{:ok, true}` |
| `_event.origintype === undefined` | `{:ok, true}` |
| `_event === undefined` | `{:ok, true}` |
| `_event !== undefined` | `{:ok, false}` |
| `_event.data === _statifier_unbound` | `{:error, UndefinedVariableError: "Undefined variable: _statifier_unbound"}` |

**Property-shaped, `_event` holding a real event map (post-event):**

| Expression | Result |
|---|---|
| `_event.data === undefined` (data `nil`) | `{:ok, true}` |
| `_event.name !== undefined` | `{:ok, true}` |
| `_event.sendid === undefined` (absent field) | `{:ok, true}` |

**Root-shaped, bare `Var1` - the decisive table:**

| Datamodel map | Expression | Result |
|---|---|---|
| `Var1` absent | `Var1 === undefined` | `{:error, UndefinedVariableError: "Undefined variable: Var1"}` |
| `Var1` absent | `Var1 !== undefined` | `{:error, UndefinedVariableError}` |
| `%{"Var1" => :undefined}` | `Var1 === undefined` | `{:ok, true}` |
| `%{"Var1" => :undefined}` | `Var1 !== undefined` | `{:ok, false}` |
| `%{"Var1" => nil}` | `Var1 === undefined` | `{:ok, true}` |
| `%{"Var1" => 1}` | `Var1 === undefined` | `{:ok, false}` |
| `%{"Var1" => 1}` | `Var1 !== undefined` | `{:ok, true}` |

**Root-shaped system variables, against `SystemVariables.initial/2`'s map:**

| Expression | Result |
|---|---|
| `_sessionid !== undefined` | `{:ok, true}` |
| `_name !== undefined` | `{:ok, true}` |
| `_ioprocessors !== undefined` | `{:ok, true}` |
| `_x !== undefined` | `{:error, UndefinedVariableError}` (not seeded; not used by the corpus) |
| `_ioprocessors.absent === undefined` | `{:ok, true}` (property on a bound root) |

**Boundary behaviors worth recording:**

- `nil` and `:undefined` are indistinguishable to `=== undefined` (both
  `true`), because `Predicator.Context.new/2` normalizes `nil` to `:undefined`
  recursively - the mechanism `SystemVariables`' moduledoc already documents
  ([`lib/statifier/evaluator/system_variables.ex:9-14`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L9-L14)). A `<data>` element that
  legitimately holds a null would therefore report as unbound. Nothing in the
  corpus assigns a null.
- `false`, `0`, and `""` are all `!== undefined`, so no falsy value is
  mistaken for unbound.
- Non-strict `==` propagates: `_event.data == undefined` -> `{:ok, :undefined}`,
  not a boolean. **The XSL must keep emitting `===`/`!==`.** All seven
  templates already do.
- Nested property access on an undefined root chains safely:
  `_event.data.Var1 === undefined` -> `{:ok, true}` with `_event` seeded `nil`.
- `Predicator.Context.bound?/2` distinguishes what `=== undefined` cannot:
  `bound?(ctx, "Var1")` is `true` for `%{"Var1" => :undefined}` and `false`
  when absent. ADR-0014 item 6 keeps it out of cond diagnostics; noted only
  because it is the one API that separates the two states.

The probe scripts were written to the session scratchpad, not to the repo.

### 3. Where the datamodel comes from, and why `<data>` has no answer yet

`MachineState.datamodel` is seeded exactly once, in `MachineState.new/2`
([`lib/statifier/machine_state.ex:198-215`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/machine_state.ex#L198-L215)):

```elixir
datamodel: Map.merge(author_datamodel, SystemVariables.initial(machine, session_id)),
```

`author_datamodel` is `opts[:datamodel]`, defaulting to `%{}`. Nothing derives
datamodel content from the document.

`SystemVariables.initial/2` ([`lib/statifier/evaluator/system_variables.ex:51-60`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L51-L60))
is the whole initial datamodel: four keys.

```elixir
%{
  "_sessionid" => session_id,
  "_name" => machine.name,
  "_event" => nil,
  "_ioprocessors" => %{@scxml_event_processor => %{"location" => session_id}}
}
```

`"_event" => nil` is the st-af3.1 engine fix (commit 8e5f7f0). Its own
moduledoc states the reasoning and cites test319 as the evidence
([`lib/statifier/evaluator/system_variables.ex:31-48`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L31-L48)): a datamodel is a plain
map, so the only way to say "declared, no value yet" is to bind the key to
`nil` and let `Context.new/2` normalize it. `MachineState.put_event/2`
([`lib/statifier/machine_state.ex:274-277`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/machine_state.ex#L274-L277)) is the only later writer.

**`<data>` and `<datamodel>` are not implemented.** The lowering dispatch map
has thirteen entries and neither name is among them
([`lib/statifier/lowering.ex:52-67`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L52-L67)): `scxml`, `state`, `parallel`, `final`,
`history`, `initial`, `transition`, `onentry`, `onexit`, `raise`, `log`,
`donedata`, `content`. There is no `build_data/2` in
`lib/statifier/lowering/builders.ex` and no `Statifier.Document.Data` struct. An
unrecognized element produces `Error.unsupported/2`
([`lib/statifier/lowering.ex:144`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L144)), and any non-empty error list makes `lower/1`
return `{:error, errors}` ([`lib/statifier/lowering.ex:151-155`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L151-L155)) - the whole
document fails to lower.

`Document.binding` (`:early | :late`) *is* lowered from `<scxml binding="...">`
(`lib/statifier/lowering/builders.ex:53,62`), but nothing reads it.
`Interpreter.initialize/2` says so in a comment
([`lib/statifier/interpreter.ex:156-158`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/interpreter.ex#L156-L158)): "interpret's skipped preamble: early
datamodel binding and executeGlobalScriptElement(doc) are st-af3's, with no
datamodel evaluation in this core yet."

So the bead's question - seeded bound-but-undefined, or genuinely absent? -
**is not yet decided anywhere in `lib/`.** It is a decision the `<data>`
lowering + initialization work owns. Finding 3 in the summary is the evidence
that shows which way that decision makes the corpus work.

### 4. Complete sentinel inventory in the checked-in corpus

`grep -rn _statifier_unbound test/` -> **25 lines, 24 files, 37 raw tokens**
(test330 has two lines of seven tokens each). All under
`test/scxml_tests/mandatory/`. Nothing in `test/scion_tests/`.

#### Property-shaped: 9 conds, 8 files

Left operand is a property access on `_event`, which is always seeded.

| File | Line | Cond | Template |
|---|---|---|---|
| `test/scxml_tests/mandatory/content/test528_test.exs` | 36 | `_event.data === _statifier_unbound` | `conf:emptyEventData` |
| `test/scxml_tests/mandatory/param/test343_test.exs` | 37 | `_event.data === _statifier_unbound` | `conf:emptyEventData` |
| `test/scxml_tests/mandatory/param/test488_test.exs` | 37 | `_event.data === _statifier_unbound` | `conf:emptyEventData` |
| `test/scxml_tests/mandatory/system_variables/test333_test.exs` | 24 | `_event.sendid === _statifier_unbound` | `conf:eventFieldHasNoValue` |
| `test/scxml_tests/mandatory/system_variables/test335_test.exs` | 24 | `_event.origin === _statifier_unbound` | `conf:eventFieldHasNoValue` |
| `test/scxml_tests/mandatory/system_variables/test337_test.exs` | 24 | `_event.origintype === _statifier_unbound` | `conf:eventFieldHasNoValue` |
| `test/scxml_tests/mandatory/system_variables/test339_test.exs` | 24 | `_event.invokeid === _statifier_unbound` | `conf:eventFieldHasNoValue` |
| `test/scxml_tests/mandatory/system_variables/test330_test.exs` | 26 | 7-way `_event.<field> !== ...` conjunction | `conf:eventFieldsAreBound` |
| `test/scxml_tests/mandatory/system_variables/test330_test.exs` | 33 | same conjunction | `conf:eventFieldsAreBound` |

**None of these eight files contains a single `<data>` element.** They are the
subset reachable by the evaluator without `<data>` lowering.

#### Root-shaped: 16 conds, 16 files

| File | Line | Cond | Template | Root |
|---|---|---|---|---|
| `test/scxml_tests/mandatory/system_variables/test319_test.exs` | 22 | `_event !== _statifier_unbound` | `conf:systemVarIsBound` | `_event` (seeded) |
| `test/scxml_tests/mandatory/foreach/test150_test.exs` | 47 | `Var4 !== _statifier_unbound` | `conf:isBound` | `Var4` |
| `test/scxml_tests/mandatory/foreach/test151_test.exs` | 47 | `Var5 !== _statifier_unbound` | `conf:isBound` | `Var5` |
| `test/scxml_tests/mandatory/invoke/test223_test.exs` | 45 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/invoke/test245_test.exs` | 38 | `Var2 !== _statifier_unbound` | `conf:isBound` | `Var2` |
| `test/scxml_tests/mandatory/send/test183_test.exs` | 30 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/system_variables/test321_test.exs` | 25 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/system_variables/test323_test.exs` | 25 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/system_variables/test325_test.exs` | 25 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/system_variables/test326_test.exs` | 30 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/scxml_event_processor/test500_test.exs` | 25 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/data/test551_test.exs` | 23 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/data/test552_test.exs` | 25 | `Var1 !== _statifier_unbound` | `conf:isBound` | `Var1` |
| `test/scxml_tests/mandatory/data/test277_test.exs` | 32 | `Var1 === _statifier_unbound` | `conf:unboundVar` / `conf:noValue` | `Var1` |
| `test/scxml_tests/mandatory/data/test280_test.exs` | 27 | `Var2 === _statifier_unbound` | `conf:unboundVar` / `conf:noValue` | `Var2` |
| `test/scxml_tests/mandatory/scxml_event_processor/test351_test.exs` | 55 | `Var2 === _statifier_unbound` | `conf:unboundVar` / `conf:noValue` | `Var2` |

`conf:unboundVar` (`conf_predicator.xsl:482`) and `conf:noValue` (`:492`) emit
byte-identical strings, so the three `=== _statifier_unbound` root conds cannot
be attributed to one or the other from the emitted corpus alone; the `.txml`
sources in `tools/corpus/scratch/` would disambiguate, and that scratch tree is
absent here (see section 5).

**Template tallies by line:** `conf:isBound` 12, `conf:unboundVar`/`conf:noValue`
3, `conf:systemVarIsBound` 1, `conf:emptyEventData` 3, `conf:eventFieldHasNoValue`
4, `conf:eventFieldsAreBound` 2.

#### The `<data>` correlation is exact

Counting `<data ` per sentinel file: every property-shaped file has **zero**;
every root-shaped `Var<n>` file has **one to three**; test319 (the root-shaped
system-variable one) has zero. The split by shape and the split by "does this
file need `<data>` lowering" are the same split.

Declaration forms among the root-shaped files, which matter for what "seeded"
would have to mean:

- **Empty `<data id="VarN" />`** - no `expr`, no content: test223, test351,
  test183, and test280's outer `Var1`. This is the exact shape the bead asks
  about.
- **`expr` attribute**: test321 (`_sessionid`), test323 (`_name`), test325 and
  test326 (`_ioprocessors`), test500 (`_ioprocessors[...].location`), test245
  (`3`), test280's nested `Var2` (`1`), and test277 (`expr="return"` -
  deliberately illegal, so the test *wants* `Var1` to end up unbound).
- **Child content**: test551, `<data id="Var1">[1,2,3]</data>` in a nested
  `<datamodel>`, with `binding="early"` on the root.
- **`src` attribute**: test552, `src="file:test552.txt"`.
- **Never declared in the scope where the cond runs**: test150 `Var4` and
  test151 `Var5` are created by `<foreach item=... index=...>`; test245's cond
  lives in the *invoked child* session, which has no `<datamodel>` at all -
  `Var2` arrives via `namelist="Var2"`. These three need boundness to work for
  roots created by something other than `<data>`.

#### The exclusions comment is narrower than the real scope

[`tools/corpus/scxml_w3/exclusions.exs:8-11`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/exclusions.exs#L8-L11) names only the
`conf:emptyEventData` trio (test343/488/528) as the sentinel-dependent set. The
inventory above is 24 files. The trio is not excluded today, and the exclusions
map's 14 entries are all `:needs_script` (3) or `:needs_basichttp` (11).

### 5. Corpus regeneration: mechanics and blast radius

`mise run corpus` ([`mise.toml:60-62`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L60-L62)) is an aggregator over three stages.

| Stage | Location | What it does |
|---|---|---|
| `corpus:fetch:w3` | [`mise.toml:68-98`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L68-L98) | Optional `CORPUS_W3_MIRROR` seed, else `curl` the manifest and download 198 `.txml` + `.description` via `tools/corpus/scxml_w3/manifest.exs` |
| `corpus:fetch:saxon` | [`mise.toml:100-110`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L100-L110) | `curl` + `unzip` SaxonHE 9.7.0.14J from SourceForge; no-op if the jar exists |
| `corpus:fetch:scion` | [`mise.toml:112-127`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L112-L127) | `git clone --depth 1` jbeard4/scxml-test-framework |
| `corpus:transform` | [`mise.toml:129-146`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L129-L146) | Saxon applies `conf_predicator.xsl` to each `.txml` |
| `corpus:emit` | [`mise.toml:148-165`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L148-L165) | `rm -rf` both output roots, then re-emit `test/scxml_tests/**` and `test/scion_tests/**` |
| `corpus:check` | [`mise.toml:167-171`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L167-L171) | Not part of `corpus`; asserts every transformed mandatory expression compiles |

The XSL is applied at [`mise.toml:141-142`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L141-L142):

```
java -jar "$CORPUS_SAXON_DIR/saxon9he.jar" --suppressXsltNamespaceCheck:on \
  -s:"$txml" -xsl:"$CORPUS_XSL" -o:"$scxml"
```

The mtime guard at [`mise.toml:138`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L138) retransforms when the `.scxml` is missing,
the `.txml` is newer, **or the XSL is newer** - so an XSL edit forces a full
retransform of all ~198 documents (but not a refetch).

**State of this worktree, checked empirically:**

- `tools/corpus/scratch/` **does not exist**. No cached `.txml`, no Saxon jar,
  no SCION clone.
- A JRE **is** present: mise provides Temurin 21.0.11 ([`mise.toml:13`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L13)).
- Saxon would be downloaded from SourceForge.
- The W3C sources would be fetched - 198 sequential `curl`s that
  [`tools/corpus/README.md:31-45`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/README.md#L31-L45) warns can 429. **A usable local mirror exists
  on this machine**: `~/repos/github/ex_statechart/test/scxml_w3/cases` holds
  `manifest.xml` plus 198 `.txml`/`.description` pairs in exactly the layout
  `CORPUS_W3_MIRROR` expects.
- SCION would need a network clone.

**Blast radius of a regeneration:** only `test/scxml_tests/` (159 files) and
`test/scion_tests/` (118 files) are written; everything fetched lands in
gitignored scratch. Generation is deterministic: `corpus:emit` wipes both roots
first, input ordering is `find | sort -z | xargs` ([`mise.toml:160-164`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L160-L164)), emitted
files carry no timestamp or generator stamp, and source is run through
`Code.format_string!/1` ([`tools/corpus/scxml_w3/cases.exs:151-171`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/cases.exs#L151-L171)).
[`tools/corpus/README.md:108-115`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/README.md#L108-L115) records a verified byte-identical zero diff
from a cold run on 2026-08-05. So a sentinel-only XSL change diffs exactly the
24 affected heredocs (plus any `@tag required_features` that shifts), and
nothing else.

**Scoping is not really available.** `corpus:emit` is a single stage that wipes
and regenerates *both* corpora - there is no `corpus:emit:w3`. Running an
emitter by hand on a subset self-defeats: both emitters end with a
stale-exclusions check that `System.halt(1)`s when an `exclusions.exs` key
matched nothing in the input set ([`tools/corpus/scxml_w3/cases.exs:225-234`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/cases.exs#L225-L234),
[`tools/corpus/scion/cases.exs:107-117`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scion/cases.exs#L107-L117)), and a partial input makes every
unmatched exclusion look stale.

**`exclusions.exs` feeds generation, not test-time filtering.** Excluded tests
are never emitted ([`tools/corpus/scxml_w3/cases.exs:179-223`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/cases.exs#L179-L223)); moving a test to
exclusions therefore *deletes* its generated file.

### 6. The regression ratchet, and what a corpus change obliges

`test/passing_tests.json` (5628 bytes, 104 lines) has three list-valued keys:
`internal_tests` (2 globs), `scion_tests` (87 literal paths), `w3c_tests` (5
literal paths: `on_entry/test375`, `on_exit/test377`, `raise/test144`,
`scxml/test355`, `selecting_transitions/test404`).

**None of the 24 sentinel files is in the ratchet.** Verified by grepping each
test id against the registry: zero hits.

`mix test.regression` (`lib/mix/tasks/test.regression.ex`) expands the registry
and shells one `mix test` over the result with `--include scion --include
scxml_w3`. It hard-fails on an entry matching no file on disk
(`:62-75`) - deliberately, per [`docs/testing.md:145-151`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/docs/testing.md#L145-L151), because silently
dropping a deleted entry would shrink the ratchet. It never writes the registry.
`mix test.baseline` is the only supported way to grow it, and it verifies a test
passes before ratcheting it in.

**Gate guard: only shrinking trips it.** [`lib/mix/statifier/gate_guard.ex:36-38`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/mix/statifier/gate_guard.ex#L36-L38)
keeps the registry on its own `@registry_path`, out of `@guarded_paths`. The
ratchet check compares parsed pattern sets, not diff lines
(`gate_guard.ex:206-236`), computing `base -- head` per list-valued key. So
additions, reordering, reformatting, and a bumped `last_updated` produce no
finding; only a removed pattern does, and it is cleared only by a
`docs/quality-gate-changes.md` entry added in the same diff naming the path and
carrying an `Approved-by:` line (`gate_guard.ex:261-265`). That entry is a
human's call, not an agent's (ADR-0011; CLAUDE.md's gate-guard section).
[`docs/quality-gate-changes.md:168-184`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/docs/quality-gate-changes.md#L168-L184) is the one existing ratchet-shrink entry
(st-l42) and the worked example.

**What this particular change obliges:**

- A **cond-string-only** XSL change moves no path, so `passing_tests.json` is
  untouched and the gate guard stays silent. No ledger entry.
- **Newly passing tests** may be ratcheted in with `mix test.baseline --add`.
  That is a growth, not a shrink - no ledger entry.
- **Moving a test into `exclusions.exs`** deletes its generated file. For the
  24 files here that is still free, since none is tracked; for any tracked file
  it would red `mix test.regression`, and removing the entry would be a shrink
  needing a ledger entry.
- `test/corpus/emitted_paths_test.exs` runs in the ordinary suite and guards
  path shape and module-name uniqueness across both corpora independently.

### 7. Does the fix need an ADR amendment?

**No amendment is required for any option that keeps `on_unbound: :error`.**

The bead's option 2 (switch cond to `on_unbound: :undefined`) is the only one
that touches ADR-0014, and it gives up item 5's named-variable diagnostic -
which item 5 exists specifically to provide, and which ADR-0012 item 3's
"expression failure names what failed" payoff depends on. Recorded as an option,
not evaluated here.

The options as they stand after this research, with what each costs. **The plan
stage picks; this document does not.**

| Option | What it is | Cost | Covers |
|---|---|---|---|
| **A. Respell to `undefined`** | Seven XSL template bodies: `_statifier_unbound` -> `undefined`, `===`/`!==` unchanged. Regenerate, re-ratchet. | One XSL edit; a full corpus regeneration (Saxon + JRE + W3C sources, mirror available locally); no ADR change; no ledger entry. | 9 property conds + test319 outright. The other 15 change failure mode from "unbound sentinel" to "unbound `Var<n>`". |
| **B. A + seed declared `<data>` as bound-but-undefined** | A, plus the `<data>` lowering/initialization work binds a declared-but-unassigned `<data id="VarN"/>` to `nil`, exactly as `SystemVariables.initial/2` does for `_event`. | A's cost, plus a decision inside the (not-yet-existing) `<data>` implementation. Verified sufficient: `%{"Var1" => nil}` makes `Var1 === undefined` -> `{:ok, true}`. | All 25 conds, keeping ADR-0014 item 5 intact. |
| **C. Respell root-shaped against a bound root** | The bead's original option 1: rewrite `conf:isBound`/`unboundVar`/`noValue` as a property of a guaranteed-bound map, e.g. via `_ioprocessors`. | An XSL edit that diverges from the upstream template's meaning, and a spelling that no longer reads as the boundness test it is. Does not need `<data>` to exist. | All 25 conds without the `<data>` decision, at the cost of a contrived notation. |
| **D. Amend ADR-0014 item 5 to `on_unbound: :undefined`** | Cond evaluation stops erroring on unbound roots. | An ADR amendment; loses the named-variable diagnostic that item 5 and ADR-0012 item 3 are built around; makes every typo'd variable silently `:undefined`. | All 25 conds, plus every future unbound root. |
| **E. Exclude the root-shaped tests** | Move the 15 `Var<n>` files into `exclusions.exs` with a reason. | Deletes 15 generated files; shrinks conformance coverage; the exclusions comment at `:8-11` would need rewriting to match the real scope. | Nothing; defers. |

Note that A is a strict prerequisite of B and is independently correct, so the
options are not mutually exclusive in the way the bead's original list implied.

### 8. Two things a sentinel fix alone will not make pass

Recorded so the plan stage does not size the work off the cond rewrite alone.

- **test330 fails for a second, independent reason.** Its 7-way conjunction
  requires `_event.sendid`, `.origin`, `.origintype`, and `.invokeid` to be
  bound, but `SystemVariables.event/1` sets all four to `nil` because
  `Statifier.Event` does not carry them yet
  ([`lib/statifier/evaluator/system_variables.ex:62-79`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L62-L79)). Probed: with a real
  event map shaped as `event/1` builds it, the respelled conjunction ->
  `{:ok, false}`. test330 also uses `<send>`.
- **Nothing here is red today, and nothing here goes green today.** `cond` is
  still stubbed - `Selection.condition_match/2` returns
  `{:error, {:unsupported, :cond}}` for any written cond; st-af3.2 is the bead
  that wires it. And the 16 root-shaped files cannot lower at all until
  `<data>` exists. The corpus change is a prerequisite being put in place, not
  a fix that flips a test count.

## Code References

- [`lib/statifier/evaluator.ex:98-103`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator.ex#L98-L103) - `context/1`, the single `Context.new/2` call site, sets `on_unbound: :error`
- [`lib/statifier/evaluator.ex:121-133`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator.ex#L121-L133) - `evaluate/2`, the `{:ok, v} | {:error, e}` membrane
- [`lib/statifier/evaluator/system_variables.ex:51-60`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L51-L60) - `initial/2`, the entire initial datamodel; `_event` seeded `nil` at `:55`
- [`lib/statifier/evaluator/system_variables.ex:9-14`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L9-L14) - why `nil` (normalized to `:undefined` by `Context.new/2`)
- [`lib/statifier/evaluator/system_variables.ex:31-48`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L31-L48) - why `_event` is seeded rather than left absent, citing test319
- [`lib/statifier/evaluator/system_variables.ex:62-79`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/evaluator/system_variables.ex#L62-L79) - `event/1`; `sendid`/`origin`/`origintype`/`invokeid` still `nil`
- [`lib/statifier/machine_state.ex:198-215`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/machine_state.ex#L198-L215) - `MachineState.new/2`, the sole datamodel constructor
- [`lib/statifier/machine_state.ex:274-277`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/machine_state.ex#L274-L277) - `put_event/2`, the only later `_event` writer
- [`lib/statifier/lowering.ex:52-67`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L52-L67) - the 13-entry dispatch map; no `data`, no `datamodel`
- [`lib/statifier/lowering.ex:144`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L144) - unrecognized element becomes a lowering error
- [`lib/statifier/lowering.ex:151-155`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering.ex#L151-L155) - any error makes `lower/1` return `{:error, errors}`
- [`lib/statifier/lowering/builders.ex:44-70`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/lowering/builders.ex#L44-L70) - `build_scxml/2`; `datamodel` and `binding` attributes lowered, `<data>` children not
- [`lib/statifier/interpreter.ex:156-158`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/statifier/interpreter.ex#L156-L158) - "early datamodel binding ... with no datamodel evaluation in this core yet"
- [`tools/corpus/scxml_w3/conf_predicator.xsl:3-15`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L3-L15) - the header comment naming the sentinel design and its intended replacement
- [`tools/corpus/scxml_w3/conf_predicator.xsl:448`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L448) - `conf:emptyEventData`
- [`tools/corpus/scxml_w3/conf_predicator.xsl:477`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L477) - `conf:isBound`
- [`tools/corpus/scxml_w3/conf_predicator.xsl:482`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L482) - `conf:unboundVar`
- [`tools/corpus/scxml_w3/conf_predicator.xsl:487`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L487) - `conf:systemVarIsBound`
- [`tools/corpus/scxml_w3/conf_predicator.xsl:492`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L492) - `conf:noValue`
- [`tools/corpus/scxml_w3/conf_predicator.xsl:507`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L507) - `conf:eventFieldsAreBound`
- [`tools/corpus/scxml_w3/conf_predicator.xsl:517`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/conf_predicator.xsl#L517) - `conf:eventFieldHasNoValue`
- [`tools/corpus/scxml_w3/exclusions.exs:8-11`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/exclusions.exs#L8-L11) - the comment naming only the `conf:emptyEventData` trio
- [`tools/corpus/scxml_w3/cases.exs:179-223`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/cases.exs#L179-L223) - exclusions applied at generation time
- [`tools/corpus/scxml_w3/cases.exs:225-234`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/cases.exs#L225-L234) - the stale-exclusions `System.halt(1)`
- [`tools/corpus/scxml_w3/cases.exs:151-171`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/tools/corpus/scxml_w3/cases.exs#L151-L171) - emitted-file shape, formatted by `Code.format_string!/1`
- [`mise.toml:129-146`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L129-L146) - `corpus:transform`, the Saxon invocation and the XSL mtime guard
- [`mise.toml:148-165`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mise.toml#L148-L165) - `corpus:emit`, wipes and regenerates both corpora
- [`lib/mix/statifier/gate_guard.ex:36-38`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/mix/statifier/gate_guard.ex#L36-L38) - the registry is on its own path, not in `@guarded_paths`
- [`lib/mix/statifier/gate_guard.ex:206-236`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/mix/statifier/gate_guard.ex#L206-L236) - `ratchet_findings/1`; only removals are findings
- [`lib/mix/tasks/test.regression.ex:62-75`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/lib/mix/tasks/test.regression.ex#L62-L75) - an entry matching no file hard-fails the run
- [`docs/testing.md:138-166`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/docs/testing.md#L138-L166) - the ratchet section
- [`docs/testing.md:196-229`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/docs/testing.md#L196-L229) - corpus generation; generated output committed so regeneration is a diffable PR
- [`docs/datamodel.md:22-23`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/docs/datamodel.md#L22-L23) - what the datamodel provides, including `<data>` and both binding modes
- [`docs/datamodel.md:79-85`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/docs/datamodel.md#L79-L85) - upstream seam 3, "A typed undefined", naming st-unt's work
- [`mix.exs:41`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mix.exs#L41) / [`mix.lock:19`](https://github.com/riddler/statifier-ex/blob/fff279bf2add606288c70cbb6ea8e4d2441cf0b5/mix.lock#L19) - `~> 5.0` and `predicator 5.0.0`

## Architecture Documentation

- **ADR-0014 item 5** is the constraint this bead collides with: cond
  evaluation passes `on_unbound: :error` so an unbound root names the variable
  and carries its span, superseding after-the-fact `unbound_loads/1`
  inspection. Item 6 keeps `Context.bound?/2` out of cond diagnostics. Items
  1-4 (spans, the `%Predicator.Compiled{}` envelope, always-on, what a failure
  names) are untouched by anything here. Options A, B, C, and E above all leave
  ADR-0014 intact; only D amends it.
- **ADR-0004** commits the datamodel to predicator and rules out ECMAScript;
  the sentinel idiom exists at all because the corpus must be rewritten into
  predicator rather than run as ECMAScript. The XSL header
  (`conf_predicator.xsl:12-15`) makes the same point negatively: do not "fix" a
  stubbed template by emitting ECMAScript, which is what v1 did.
- **ADR-0006** makes the conformance corpus plus the regression ratchet the
  contract for the rewrite, with `Statifier.Case.test_scxml/4` as the single
  coupling surface.
- **ADR-0011** makes the gate-config ledger mechanical; the relevant half here
  is that shrinking `test/passing_tests.json` needs a human-authored ledger
  entry. This change does not shrink it.
- **ADR-0012 item 3** (retained locations) is what ADR-0014 item 5's diagnostic
  serves; option D's cost is measured against it.

## Historical Context

- `docs/research/260803-st2-qjs-predicator-path-assign.md` - origin of the
  `_statifier_unbound` idiom, proving it worked under predicator 3.5 because a
  never-bound identifier evaluated to `:undefined` and `===`/`!==` were the only
  operators that compared it. Already flagged the engine contract that
  `conf:emptyEventData` needs `_event.data` absent-as-undefined rather than
  `%{}`.
- `docs/plans/260802-st2-00p.5-w3c-xsl-predicator-datamodel.md` section 5 - the
  implementation spec for the seven sentinel-emitting templates.
- `docs/plans/260811-st-af3.1-evaluator-and-macrostep-context.md` - where the
  collision was discovered and written up, including the narrowing fact that
  `:error` fires on root loads only. The engine half (seeding `_event`) landed
  from this plan as commit 8e5f7f0.
- `docs/research/260812-st-p3t-predicator-5-bump.md` section 5 - established,
  against the real 5.0 package, that `_event.data === undefined` -> `{:ok, true}`,
  `_event.data == undefined` -> `{:ok, :undefined}` (so the XSL must emit `===`),
  and `nosuch === undefined` -> `{:error, UndefinedVariableError}`. Also records
  that `undefined` appears zero times in the current corpus, so introducing it
  collides with nothing. This document does not re-derive those; it extends them
  to bare `Var<n>` roots and to the seeded system variables.
- `docs/plans/260812-st-p3t-predicator-5-bump.md` - explicitly defers seam 3 to
  st-unt.
- `docs/plans/260810-st-wju.6-microstep-macrostep-and-interpreter-entry.md` -
  records that `interpret`'s `if doc.binding == "early": initializeDatamodel(...)`
  preamble was deliberately skipped, which is why section 3's answer is "not
  decided yet" rather than "decided one way".

## Related Research

- `docs/research/260812-st-p3t-predicator-5-bump.md` - predicator 5.0 ground
  truth; the direct predecessor to this document
- `docs/research/260803-st2-qjs-predicator-path-assign.md` - where the sentinel
  came from

## Open Questions

Recorded rather than resolved; no human was available during this research
stage.

1. **When does the `<data>` seeding decision get made, and by which bead?**
   Section 3 establishes that it is undecided and that seeding
   declared-but-unassigned data to `nil` makes 15 of the 25 conds work. Nothing
   in `lib/` or in the plans read here assigns that decision to a named bead.
   If st-unt lands option A alone, the decision is inherited by whoever
   implements `<data>`, and this document is the record of what the corpus
   needs from it.
2. **`conf:unboundVar` versus `conf:noValue` for the three
   `=== _statifier_unbound` root conds.** The two templates emit identical
   strings, so the emitted corpus cannot attribute them. The `.txml` sources
   would settle it. Immaterial if both templates are respelled identically,
   which the current XSL implies; it matters only if a fix treats the two
   differently.
3. **Roots created by something other than `<data>`.** test150 `Var4` and
   test151 `Var5` come from `<foreach item=/index=>`, and test245's `Var2`
   arrives in an invoked child session via `namelist`. Whatever "seeded"
   means for `<data>`, these three need the same guarantee from `<foreach>`
   and from `<invoke>`'s namelist handling. Not investigated here.
4. **`nil` as a legitimate value.** Because `Context.new/2` normalizes `nil` to
   `:undefined`, a datamodel location holding a genuine null is indistinguishable
   from unbound under `=== undefined`. No corpus test assigns a null, so this is
   latent, not live.
5. **Whether the `exclusions.exs:8-11` comment gets corrected as part of this
   work.** It names three tests where the real sentinel scope is 24 files. That
   is a prose fix in a generation-time file, not a behavior change.
