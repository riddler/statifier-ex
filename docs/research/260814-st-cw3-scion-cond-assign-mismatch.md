---
date: 2026-08-14T04:23:41-0600
researcher: Claude
git_commit: 8df2c50dc40807e6070e82a4779d670e114427bd
branch: st-cw3-scion-cond-assign-mismatch
repository: statifier-ex
beads_issue: st-cw3
topic: "Why five SCION corpus files mismatch on cond/assign evaluation after the conditional_transitions flip"
tags: [research, codebase, interpreter, datamodel, corpus]
status: complete
last_updated: 2026-08-14
last_updated_by: Claude
---

# Research: Five SCION corpus files mismatch on cond/assign evaluation (st-cw3)

**Date**: 2026-08-14T04:23:41-0600
**Git Commit**: 8df2c50dc40807e6070e82a4779d670e114427bd
**Branch**: st-cw3-scion-cond-assign-mismatch
**Bead**: st-cw3

## Research Question

st-af3.8 flipped `conditional_transitions` to `:supported`. Five SCION corpus
files now pass the feature gate but fail their own active-state assertions:

- `test/scion_tests/targetless_transition/test1_test.exs` - expected `["done"]`, got `["a"]`
- `test/scion_tests/targetless_transition/test2_test.exs` - expected `["done"]`, got `["a"]`
- `test/scion_tests/targetless_transition/test3_test.exs` - expected `["done"]`, got `["a2","b2","c"]`
- `test/scion_tests/more_parallel/test10_test.exs` - expected `["a","b"]`, got `["c"]`
- `test/scion_tests/more_parallel/test10b_test.exs` - expected `["c"]`, got `["a","b"]`

Map the codebase as it exists today so a plan can be written: the macrostep /
eventless loop, targetless transition handling, `<assign>` and onentry/onexit
ordering for parallel regions, and what the predicator-backed datamodel does
with `===`, `Math.pow(i,3)`, and arithmetic assign expressions. Determine
empirically which layer produces each divergence.

## Summary

The five failures are **two independent root causes**, and neither is the
eventless / targetless re-evaluation loop. Both were reproduced empirically.

**Group A - the three `targetless_transition` files: a float-vs-integer
strict-equality mismatch in the datamodel layer.**
`Math.pow` is a *registered predicator builtin* (`deps/predicator/lib/predicator/functions/math_functions.ex:47-55`)
backed by Erlang `:math.pow/2`, which always returns a **float**. Predicator's
`===` compiles to `["compare", "STRICT_EQ"]` and is implemented as Elixir
`left === right` (`deps/predicator/lib/predicator/evaluator.ex:757`), which is
type-strict: `8.0 === 8` is `false`. In ECMAScript there is one `Number` type,
so `Math.pow(2,3) === 8` is `true`. Every one of the three documents routes its
accumulator through `Math.pow` before comparing with `===`, so the guard is
silently false - no parse error, no `error.execution`, no
`{:non_boolean_cond, _}`. The eventless transition is correctly re-evaluated;
its `cond` simply returns `false`.

**Group B - the two `more_parallel` files: one extra exit/entry of the
`<parallel>` element, coming from a spec-literal `findLCCA`.**
Both documents carry `<transition target="a" event="t1" cond="x === 2"/>` on
state `a`, which is a region of `<parallel id="p">`. Appendix D's `findLCCA`
filters candidate ancestors through `isCompoundStateOrScxmlElement`, and the
REC's normative definition of a compound state excludes `<parallel>`. So
`findLCCA([a, a])` skips `p` and returns the `<scxml>` root; the exit set is
every active descendant of the root, i.e. `{p, a, b}`; `p` is exited and
re-entered, running its `<onexit>` and `<onentry>` `<assign>`s. `x` reaches
**6** where SCION's expectations assume **4**. `Statifier.Machine.lcca/2`
([`lib/statifier/machine.ex:268-276`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L268-L276)) implements exactly the pseudocode filter,
so the divergence is spec-vs-SCION, not a porting bug. Verified directly:
`Machine.lcca(m, [a, a]) == 0` (the `:scxml` root), and `Machine.compound?(m, p)`
is `false`.

Everything else in the path is faithful to Appendix D: the eventless fixpoint
loop re-probes `select_eventless_transitions/1` on the mutated `machine_state`
every round, targetless transitions run their content with an empty exit and
entry set, and `<assign>` rebuilds the block's evaluation context so later
nodes see the write.

## Detailed Findings

### 1. Observed failures (reproduced)

`mix test --include scion <the five files>` at commit `8df2c50` - 5 tests, 5
failures, each raised by `assert_configuration/3`
([`test/support/case.ex:120-129`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/test/support/case.ex#L120-L129)) inside the `Enum.reduce` fold of
`Statifier.Case.test_scxml/4` ([`test/support/case.ex:90-97`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/test/support/case.ex#L90-L97)). The fold asserts
after every event, so the reported mismatch is the **first** diverging step.

A throwaway driver over the four-function public API
(`Statifier.compile/1`, `initialize/2`, `send_event/2`, `active_leaf_states/1`)
dumping `machine_state.datamodel` after each event gives the whole picture:

| file | step | leaves observed | expected | datamodel |
|---|---|---|---|---|
| targetless test1 | init | `["a"]` | `["a"]` | `i = 1` |
| | `foo` | `["a"]` | `["a"]` | `i = 2` (integer) |
| | `bar` | `["a"]` | `["done"]` | `i = 8.0` (**float**) |
| targetless test2 | `foo` | `["a"]` | `["a"]` | `i = 3` |
| | `bar` | `["a"]` | `["done"]` | `i = 27.0` (**float**) |
| targetless test3 | `foo` | `["a2","b2","c"]` | `["a2","b2","c"]` | `i = 5.0` (**float**) |
| | `bar` | `["a2","b2","c"]` | `["done"]` | `i = 100.0` (**float**) |
| more_parallel test10 | init | `["a","b"]` | `["a","b"]` | `x = 2` |
| | `t1` | `["a","b"]` | `["a","b"]` | `x = 6` (SCION assumes 4) |
| | `t2` | `["c"]` | `["a","b"]` | `x = 8` |
| more_parallel test10b | `t1` | `["a","b"]` | `["a","b"]` | `x = 6` (SCION assumes 4) |
| | `t2` | `["a","b"]` | `["c"]` | `x = 6` |

The two `more_parallel` symptoms are mirror images of a single fact: `x` is 6
where SCION expects 4. test10's `cond="x === 6"` fires when it should not;
test10b's `cond="x === 4"` does not fire when it should.

The targetless numbers are all float, and every guard uses `===`.

### 2. Group A root cause: `Math.pow` returns a float, `===` is type-strict

Predicator 5.0.0 is pinned at [`mix.exs:41`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/mix.exs#L41) (`{:predicator, "~> 5.0"}`) and
locked at [`mix.lock:19`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/mix.lock#L19).

Compilation happens once, at Machine-build time, through
`Statifier.Compiler.Expressions.compile/3`
([`lib/statifier/compiler/expressions.ex:64-73`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler/expressions.ex#L64-L73)), which calls
`Predicator.compile_with_spans/1` and stores
`{:compiled, %Predicator.Compiled{}, source}`. Transition `cond` compiles at
[`lib/statifier/compiler.ex:710`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L710); `<assign expr>` at [`lib/statifier/compiler.ex:862`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L862);
`<data expr>` at [`lib/statifier/compiler.ex:1198`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L1198); `<log expr>` at
[`lib/statifier/compiler.ex:808`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L808).

Inspecting the compiled machine for test1 directly:

- `cond="i === 8"` -> `[["load","i"], ["lit",8], ["compare","STRICT_EQ"]]`
- `expr="i * 2"` -> `[["load","i"], ["lit",2], ["multiply"]]`
- `expr="Math.pow(i,3)"` -> `[["load","i"], ["lit",3], ["call","Math.pow",2]]`

So `Math.pow(i,3)` parses as a **function call**, not a property access or an
undefined identifier. `"Math.pow" => {2, {Predicator.Functions.MathFunctions, :call_pow}}`
is registered in the default context
(`deps/predicator/lib/predicator/functions/math_functions.ex:47-55`), and
`call_pow` is `:math.pow/2` (`math_functions.ex:60`) - always a float.

`===` is a genuine predicator operator (`:strict_eq` -> `"STRICT_EQ"`,
`deps/predicator/lib/predicator/visitors/instructions_visitor.ex:519`),
implemented as Elixir `left === right`
(`deps/predicator/lib/predicator/evaluator.ex:757`).

Direct evaluation against a context of `%{"i" => 2, "x" => 2}`:

```
Math.pow(i,3)          -> {:ok, 8.0}
Math.pow(i,3) === 8    -> {:ok, false}
8.0 === 8              -> {:ok, false}
8.0 == 8               -> {:ok, true}
i * 2                  -> {:ok, 4}
x +1                   -> {:ok, 3}     # no space before 1: no tokenizer quirk
i - 3                  -> {:ok, -1}
Math.floor(3.7)        -> {:ok, 3}
Math.sqrt(4)           -> {:ok, 2.0}
```

Note `Math.floor` returns an integer while `Math.pow` and `Math.sqrt` return
floats - the float-ness is per-builtin, not uniform.

**Isolating control experiment.** Replacing only `Math.pow(i,3)` with `i * 4`
in test1's document (same states, same eventless guard `i === 8`) makes the
chart reach `["done"]` with `i = 8` (integer). The eventless transition, the
targetless microstep, and the re-evaluation point are therefore all correct;
the only difference is the numeric type of the accumulator.

Arithmetic on integers stays integer throughout (`i * 2`, `i + 2`, `x + 1`,
`i - 3`, `i * 20`), so a document that never touches `Math.pow` never trips
this.

Each of the three documents is float-poisoned before its guard:

- test1: `i` = 1 -> `i * 2` = 2 -> `Math.pow(2,3)` = **8.0**; guard `i === 8`.
- test2: `i` = 1 -> `i + 2` = 3 (state `a`'s `foo` transition preempts `A`'s,
  Appendix D `selectTransitions` breaking out of the ancestor walk at the first
  match) -> `Math.pow(3,3)` = **27.0**; guard `i === 27`.
- test3: `i` = 1 -> `i * 2` = 2 -> `Math.pow(2,3)` = 8.0 -> `8.0 - 3` = 5.0
  -> on `bar`, `5.0 * 20` = **100.0**; guard `i === 100`.

No error is raised in any case: `evaluate_cond/2`
([`lib/statifier/interpreter/selection.ex:296-311`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L296-L311)) only converts a non-boolean
or an evaluation error into `{:error, _}`; a well-formed `false` is just a
disabled transition. The empirical run confirms an empty non-trace effect list
and an empty internal queue at every step.

The `datamodel="ecmascript"` attribute is read, validated against an allow-list
(`lib/statifier/validator/checks/enums.ex:57,91-93` - `"ecmascript"` is an
accepted value), copied onto `machine.datamodel`
([`lib/statifier/compiler.ex:252`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L252)), and **never consulted at runtime**. There is
no warning and no feature-detector gate on it; ADR-0004 fixes predicator as the
one datamodel, and `<invoke>` as the escape hatch.

### 3. Group B root cause: `findLCCA` skips the `<parallel>` ancestor

The normative REC text (Appendix D, `findLCCA`):

> ```
> function findLCCA(stateList):
>     for anc in getProperAncestors(stateList.head(),null).filter(isCompoundStateOrScxmlElement):
>         if stateList.tail().every(lambda s: isDescendant(s,anc)):
>             return anc
> ```

and the REC's definition of "compound state":

> [Definition: A compound state is a `<state>` that has `<state>`,
> `<parallel>`, or `<final>` children (or a combination of these).]

and, from 3.1.5 'Type' and Transitions:

> The behavior of a transition with 'type' of "external" (the default) is
> defined in terms of the transition's source state ..., the transition's
> target state(or states), and the Least Common Compound Ancestor (LCCA) of the
> source and target states (which is the closest compound state that is an
> ancestor of all the source and target states). When a transition is taken,
> the state machine will exit all active states that are proper descendants of
> the LCCA ...

A `<parallel>` is therefore **not** a compound state and is not an LCCA
candidate.

`Statifier.Machine.compound?/2` ([`lib/statifier/machine.ex:189-193`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L189-L193)) implements
this: `kind in [:state, :scxml] and children != []`, with the moduledoc stating
"A `:parallel` is never compound even though it has children". `Machine.lcca/2`
([`lib/statifier/machine.ex:268-276`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L268-L276)) filters proper ancestors through it, and
`Selection.find_lcca/2` is a `defdelegate` to it
([`lib/statifier/interpreter/selection.ex:75`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L75)).

`Selection.get_transition_domain/2` ([`lib/statifier/interpreter/selection.ex:156-169`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L156-L169),
tail at `:180-187`) returns `nil` when there are no effective targets, `source`
for the internal-and-compound-and-all-descendants case, and otherwise
`find_lcca(machine, [source | effective_targets])`.
`Selection.compute_exit_set/2` ([`lib/statifier/interpreter/selection.ex:206-212`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L206-L212))
unions the configuration members that are **proper** descendants of each
domain.

For test10 / test10b, the transition is `source = a`, `targets = [a]`,
`type = :external`. Verified directly on the compiled machine:

```
a=2 p=1 compound?(p)=false parallel?(p)=true
lcca([a, a]) = 0     # 0 is the :scxml root
```

Domain = root, so the exit set is every active descendant of the root:
`{p, a, b}`. Exit order is descending index (`Machine.exit_order/2`,
[`lib/statifier/machine.ex:294-296`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L294-L296)), so `a`'s `<onexit>` runs before `p`'s.
Entry order is ascending index (`Machine.document_order/2`,
[`lib/statifier/machine.ex:292`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L292)), so `p`'s `<onentry>` runs before `a`'s. Index
assignment is depth-first document order ([`lib/statifier/compiler.ex:304`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L304)), so
a parallel's index is always lower than its regions'.

The arithmetic, all confirmed empirically:

| step | handlers run | `x` |
|---|---|---|
| initialize | onentry `p`, onentry `a` | 2 |
| `t1` (target `a`) | onexit `a`, onexit `p`, onentry `p`, onentry `a` | **6** |

SCION's inline comments assume the other reading: test10b says "we've exited
and re-entered a, without exiting and re-entering p, so x === 4 here", i.e.
domain = `p`, exit set = `{a, b}`, `p` untouched. That is the answer you get if
`findLCCA` admits a `<parallel>` ancestor as a candidate. test10's expectations
are the same document with guards that never match under `x = 4`.

**v1 comparison.** The read-only reference at `../statifier` computes its LCCA
as the deepest common ancestor with no compound filter
(`../statifier/lib/statifier/state_hierarchy.ex:91-103`,
`find_deepest_common_ancestor/3`), which yields `p`. Its
`test/passing_tests.json` lists `test/scion_tests/more_parallel/test10_test.exs`
as passing (line 57) - so the corpus expectation was previously satisfied by a
non-spec-literal LCCA. v1 does **not** list test10b, nor any of
`targetless_transition/test1..3` (only `targetless_transition/test0`).

### 4. The macrostep / eventless loop (not implicated, but the surface a plan touches)

Appendix D `mainEventLoop`'s inner `while running and not macrostepDone` loop
is hoisted into a resumable value rather than a call stack. Per round:

1. `Statifier.Interpreter.microstep/1` ([`lib/statifier/interpreter.ex:350-361`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L350-L361))
   calls `Selection.select_eventless_transitions/1` **first**, every round.
2. If any are enabled, `run_selected/3` runs one Appendix D `microstep`
   ([`lib/statifier/interpreter.ex:267-286`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L267-L286): `exit_states` ->
   `execute_transition_content` -> `enter_states`, "nothing between them").
3. If none are enabled, `internal_round/1` ([`lib/statifier/interpreter.ex:504-528`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L504-L528))
   dequeues **one** internal event and selects on it; empty queue means
   quiescent.
4. The fold `macrostep/3` ([`lib/statifier/interpreter.ex:472-479`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L472-L479)) calls
   `microstep/1` again on the returned `machine_state`, bounded by
   `max_macrostep_rounds` (ADR-0019, [`lib/statifier/interpreter.ex:452-462`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L452-L462)).

`Statifier.handle_event/2` ([`lib/statifier/interpreter.ex:249-265`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L249-L265)) selects on
the external event, runs the microstep, then calls `main_event_loop/1`
([`lib/statifier/interpreter.ex:591-622`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L591-L622)), which folds the macrostep to
quiescence - so an eventless transition enabled by an `<assign>` performed
during external-event processing **is** taken before the caller observes the
configuration. The control experiment in section 2 exercises exactly this and
reaches `["done"]`.

`cond` is evaluated in `cond_enabled/3` -> `evaluate_cond/2`
([`lib/statifier/interpreter/selection.ex:505-516`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L505-L516), `:296-311`) against a
`Predicator.Context` built **once per selection call**
(`lib/statifier/interpreter/selection.ex:332,364`, via
`Statifier.Evaluator.context/1`, [`lib/statifier/evaluator.ex:98-103`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/evaluator.ex#L98-L103), which
sets `on_unbound: :error`). Because every round re-enters
`select_eventless_transitions/1`, the context is rebuilt from the current
`machine_state.datamodel`, so datamodel mutations from earlier in the same
macrostep are visible. There is no cross-round staleness.

A transition is classified eventless purely by `transition.events == []`
([`lib/statifier/interpreter/selection.ex:466-486`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L466-L486)); such a transition is only
ever a candidate on the eventless walk and is never reached by the
event-matched walk, matching Appendix D's `not t.event` test. A `cond` with no
`event` therefore behaves as the spec requires.

### 5. Targetless transitions (not implicated)

Targetless is not a flag; it is `targets == []`
([`lib/statifier/machine/transition.ex:55-66`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine/transition.ex#L55-L66),
[`lib/statifier/document/transition.ex:44-52`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/document/transition.ex#L44-L52)). Three mechanical consequences,
no special case anywhere:

- `get_effective_target_states/2` ([`lib/statifier/interpreter/selection.ex:107`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L107))
  returns `[]`, so `get_transition_domain/2` hits its `[] -> nil` branch
  (`:163-164`) and never calls `find_lcca`.
- `compute_exit_set/2` rejects transitions with `targets == []` up front
  ([`lib/statifier/interpreter/selection.ex:210`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L210)), matching the spec's "If the
  transition does not contain a 'target', its exit set is empty."
- `compute_entry_set/2` ([`lib/statifier/interpreter/exit_entry.ex:283-309`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/exit_entry.ex#L283-L309))
  adds nothing, since both its written-target and effective-target walks
  iterate an empty list.

`execute_transition_content/2` ([`lib/statifier/interpreter.ex:568-579`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L568-L579))
iterates the enabled transition list, not either set, so the content runs
regardless. Empirically confirmed: `foo` in test1 mutates `i` to 2 while the
configuration stays `["a"]`.

### 6. `<assign>` and onentry/onexit ordering for parallel regions

`Statifier.Machine.Content.Assign.execute/2`
([`lib/statifier/machine/content/assign.ex:76-91`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine/content/assign.ex#L76-L91)) is a five-step `with`:
evaluate the value (`:99-105`), resolve the location via
`Predicator.context_location/2` (`:113-122`), reject a `_`-prefixed system
variable per spec 5.10 (`:143-153`), require the resolved root to already be a
datamodel key (`:162-173`, `{:error, {:unbound_location, _}}` otherwise), then
write through `Predicator.ContextLocation.put/3` (`:182-193`). On success it
rebuilds `datamodel_context` immediately (`:88`), so a later node in the same
block sees the write. Failure returns `{:error, reason}`;
`Interpreter.Content.run_nodes/2` ([`lib/statifier/interpreter/content.ex:174-193`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/content.ex#L174-L193))
halts the block and `raise_execution_error/4` (`:229-239`) turns it into
`error.execution` - never a rescue-to-default.

Ordering, all derived from index sorts rather than hand-written rules:

- `exit_states/2` ([`lib/statifier/interpreter/exit_entry.ex:133-150`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/exit_entry.ex#L133-L150)) sorts the
  exit set descending (`Machine.exit_order/2`), records history over the whole
  untouched configuration first (`:141`, `:157-168`), then runs each state's
  `<onexit>` before removing it from the configuration (`depart/2`, `:216-225`).
- `enter_states/2` ([`lib/statifier/interpreter/exit_entry.ex:596-613`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/exit_entry.ex#L596-L613)) sorts the
  entry set ascending (`Machine.document_order/2`), adds each state to the
  configuration, then runs its `<onentry>` (`arrive/3`, `:628-662`).
- Because indexes are depth-first document order, **a parallel's regions run
  their `<onexit>` before the parallel's own**, and the parallel runs its
  `<onentry>` before its regions'. That is the ordering the two `more_parallel`
  documents assume, and it is what the engine does - the divergence there is in
  *how many times* the parallel is exited and entered, not in what order.
- Transition content runs strictly after the whole `exit_states/2` call and
  strictly before the whole `enter_states/2` call
  ([`lib/statifier/interpreter.ex:277-285`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L277-L285)).

### 7. Grouping by root cause

| file | root cause | layer |
|---|---|---|
| `targetless_transition/test1_test.exs` | `Math.pow` -> float, `===` type-strict | datamodel (predicator) |
| `targetless_transition/test2_test.exs` | same | datamodel (predicator) |
| `targetless_transition/test3_test.exs` | same | datamodel (predicator) |
| `more_parallel/test10_test.exs` | `findLCCA` skips `<parallel>`; `p` exited/re-entered | interpreter (selection) |
| `more_parallel/test10b_test.exs` | same | interpreter (selection) |

Neither group is caused by eventless re-evaluation timing, nor by `<assign>`
side-effect ordering within a block, nor by onentry/onexit ordering.

## Code References

- [`test/support/case.ex:90-97`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/test/support/case.ex#L90-L97) - the corpus fold that asserts after every event
- [`test/support/case.ex:120-129`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/test/support/case.ex#L120-L129) - `assert_configuration/3`, the failing assertion
- [`lib/statifier/interpreter.ex:249-265`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L249-L265) - `handle_event/2`, external event then macrostep to quiescence
- [`lib/statifier/interpreter.ex:267-286`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L267-L286) - `microstep/2`, the Appendix D three-call sequence
- [`lib/statifier/interpreter.ex:350-361`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L350-L361) - `microstep/1`, the eventless-first round
- [`lib/statifier/interpreter.ex:472-479`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L472-L479) - the bounded macrostep fold (ADR-0019)
- [`lib/statifier/interpreter.ex:504-528`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L504-L528) - `internal_round/1`, one internal event per round
- [`lib/statifier/interpreter.ex:568-579`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L568-L579) - `execute_transition_content/2`
- [`lib/statifier/interpreter.ex:591-622`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter.ex#L591-L622) - `main_event_loop/1`
- [`lib/statifier/interpreter/selection.ex:75`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L75) - `find_lcca/2` delegate
- [`lib/statifier/interpreter/selection.ex:156-187`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L156-L187) - `get_transition_domain/2`
- [`lib/statifier/interpreter/selection.ex:206-212`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L206-L212) - `compute_exit_set/2`, targetless rejected here
- [`lib/statifier/interpreter/selection.ex:296-311`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L296-L311) - `evaluate_cond/2`, non-boolean/error handling
- [`lib/statifier/interpreter/selection.ex:328-378`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L328-L378) - the two selection entry points
- [`lib/statifier/interpreter/selection.ex:466-486`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/selection.ex#L466-L486) - eventless vs event-driven classification
- [`lib/statifier/interpreter/exit_entry.ex:133-150`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/exit_entry.ex#L133-L150) - `exit_states/2`
- [`lib/statifier/interpreter/exit_entry.ex:283-309`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/exit_entry.ex#L283-L309) - `compute_entry_set/2`
- [`lib/statifier/interpreter/exit_entry.ex:596-613`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/exit_entry.ex#L596-L613) - `enter_states/2`
- [`lib/statifier/machine.ex:189-193`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L189-L193) - `compound?/2`, parallel excluded
- [`lib/statifier/machine.ex:268-276`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L268-L276) - `lcca/2`, the compound filter
- [`lib/statifier/machine.ex:292-296`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine.ex#L292-L296) - `document_order/2` and `exit_order/2`
- [`lib/statifier/compiler.ex:252`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L252) - `machine.datamodel` set from the attribute, never read back
- [`lib/statifier/compiler.ex:304`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler.ex#L304) - depth-first document-order index assignment
- `lib/statifier/compiler.ex:710,808,862,1198` - `cond`, `<log>`, `<assign>`, `<data>` compile sites
- [`lib/statifier/compiler/expressions.ex:64-73`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler/expressions.ex#L64-L73) - `compile/3`; note the stale "predicator 4.0.0" comment at `:54`
- [`lib/statifier/evaluator.ex:98-103`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/evaluator.ex#L98-L103) - `context/1`, `on_unbound: :error`
- [`lib/statifier/machine/content/assign.ex:76-193`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/machine/content/assign.ex#L76-L193) - the `<assign>` evaluate/resolve/write chain
- [`lib/statifier/interpreter/content.ex:174-239`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/interpreter/content.ex#L174-L239) - block runner and `error.execution` conversion
- `lib/statifier/validator/checks/enums.ex:57,91-93` - `"ecmascript"` is an accepted `datamodel` value
- [`mix.exs:41`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/mix.exs#L41), [`mix.lock:19`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/mix.lock#L19) - predicator `~> 5.0`, locked at 5.0.0
- `test/passing_tests.json` - the ratchet; none of the five is listed

Dependency and reference-checkout references (outside this repo, for evidence).
These are deliberately left unlinked - they resolve in a local checkout, not on
the forge, so a permalink would 404:

- `deps/predicator/lib/predicator/functions/math_functions.ex:47-60` - `Math.pow` registration, `:math.pow/2`
- `deps/predicator/lib/predicator/evaluator.ex:757` - `STRICT_EQ` as Elixir `===`
- `deps/predicator/lib/predicator/visitors/instructions_visitor.ex:519` - `:strict_eq` -> `"STRICT_EQ"`
- `deps/predicator/lib/predicator/lexer.ex:499-520` - reserved words; `undefined` is a literal, `null` is not
- `../statifier/lib/statifier/state_hierarchy.ex:91-103` - v1's unfiltered deepest-common-ancestor LCCA
- `../statifier/test/passing_tests.json:57` - v1 passed `more_parallel/test10`

## Architecture Documentation

- **ADR-0002 (literal W3C Appendix D port)** - the reason `Machine.lcca/2` filters
  by `compound?/2`. Any change to the LCCA candidate set is a deliberate
  deviation and needs an inline comment citing a mechanical reason, or an ADR.
- **ADR-0004 (predicator as the datamodel)** - settles that expressions are
  predicator, never ECMAScript and never `eval`; `<invoke>` is the escape hatch.
  `datamodel="ecmascript"` is accepted as a document attribute but has no
  runtime meaning here.
- **ADR-0005 (interned indexes)** - ids are strings only at the `Statifier`
  boundary; `lcca/2`, `compound?/2`, and the order helpers all work on indexes,
  and the index range `index..last` is what makes `descendant?/3` O(1).
- **ADR-0003 (pure core)** - the interpreter takes one external event per call
  and returns `{machine_state, [effect]}`; the outer `while running` loop is the
  caller's.
- **ADR-0006 (conformance corpus and regression ratchet)** - the corpus is
  generated and the ratchet is `test/passing_tests.json`; a corpus file may not
  be ratcheted until it passes.
- **ADR-0011 / `docs/quality-gate-changes.md`** - no `@tag :skip`, no exclusion,
  no ratchet shrink without a human-written ledger entry. st-cw3 explicitly
  forbids skip-tagging these five.
- **ADR-0019 / ADR-0020** - the macrostep round budget and round ordinal; the
  eventless fixpoint here terminates well inside the default 10000 rounds.
- **ADR-0012 / ADR-0014** - observability and expression spans; compiled
  expressions retain `%Parser.Location{}` spans (`cond_location`,
  `expr_location`), which is what would let a diagnostic name the exact `cond`
  that silently returned `false`.
- `docs/testing.md` - `@tag required_features` gating and the ratchet.
- `docs/datamodel.md` - the predicator commitment and its upstream seams
  (`predicator` is an upstream this project also maintains, so a float/int
  fix has an upstream option as well as a local one).

## Historical Context

- `docs/plans/260813-st-af3.8-corpus-flip-conditional-detector-split-ratchet.md` -
  the branch that flipped `conditional_transitions` to `:supported` and
  ratcheted 66 files; st-cw3 is its Phase 3 triage residue.
- `docs/plans/260812-st-af3.2-condition-match-cond-gates-selection.md` - real
  `condition_match/2`; introduced `cond`-gated selection and the eventless
  cond-error livelock discussion that ADR-0019 answers.
- `docs/research/260812-st-unt-boundness-sentinel-vs-on-unbound-error.md` and
  `docs/plans/260812-st-unt-boundness-sentinel-respell-to-undefined.md` - why
  `Evaluator.context/1` uses `on_unbound: :error` rather than predicator's
  `undefined` literal. Relevant background: unknown identifiers error here, they
  do not silently become `undefined`.
- `docs/plans/260812-st-p3t-predicator-5-bump.md` - the predicator 5.0 bump.
- `docs/research/260813-st-af3.4-assign-deep-path-vivification.md` and its plan -
  `<assign>` path semantics.
- `docs/plans/260810-st-wju.3-ports-transition-selection.md` and
  `260810-st-wju.4-ports-exit-and-entry-sets.md` - the original ports of the two
  functions Group B lands in.
- `docs/plans/260802-st2-00p.5-w3c-xsl-predicator-datamodel.md` - the W3C corpus
  is XSL-transformed toward the predicator datamodel. The SCION corpus is
  **not** transformed the same way, which is why raw ECMAScript idioms reach the
  engine verbatim in `test/scion_tests/`.
- No project document covers onentry/onexit ordering for parallel states
  specifically, and no ADR settles the LCCA-vs-parallel question.

## Related Research

- `docs/research/260813-st-ux0-livelock-round-trace-identity.md` - macrostep
  round loop diagnosis.
- `docs/research/260812-st-af3.3-datamodel-data-early-late-binding.md` - onentry
  timing relative to datamodel initialization.
- `docs/research/260809-st-wju.1-compile-document-to-interned-machine.md` -
  how onentry/onexit blocks are interned.

## Open Questions

1. **Is SCION or Appendix D right about `findLCCA` and `<parallel>`?** The
   pseudocode and the REC's compound-state definition both exclude `<parallel>`
   from LCCA candidacy, and this engine follows them. SCION's test10/test10b
   comments assume the opposite. Deciding this is a spec-conformance call with
   consequences well beyond these two files (every external transition whose
   LCCA search passes through a parallel), and it is a human's call, not an
   agent's. Options visible from the code: leave the engine spec-literal and
   record the corpus deviation; or admit `<parallel>` as an LCCA candidate with
   an ADR-0002 deviation comment. No third option was found in the codebase.
2. **Where should the float/int fix live, if there is to be one?** Predicator is
   an upstream this project also maintains (`docs/datamodel.md`). Making
   `Math.pow` return an integer for integer-valued results, or making `===`
   numeric-tolerant across int/float, are upstream changes; coercing at the
   statifier evaluator boundary is a local one. Each has a different blast
   radius, and either would change the meaning of `===` for documents that
   deliberately rely on Elixir's type-strict `===`. Not decided here.
3. **Is the float/int mismatch broader than `Math.pow`?** `Math.sqrt` also
   returns a float while `Math.floor` returns an integer, and `/` was not
   probed for its return type. Only the corpus files in this bead were checked;
   a sweep of the excluded corpus for other `Math.*`/`===` combinations was not
   done.
4. **Does `Math.pow`'s float-ness affect the W3C corpus too?** The W3C corpus is
   XSL-transformed toward the predicator datamodel and the SCION corpus is not,
   so the exposure is probably SCION-only, but this was not verified.
5. **[`lib/statifier/compiler/expressions.ex:54`](https://github.com/riddler/statifier-ex/blob/8df2c50dc40807e6070e82a4779d670e114427bd/lib/statifier/compiler/expressions.ex#L54) says "verified against the
   installed predicator 4.0.0 dependency"** while the lock is 5.0.0. Stale
   comment, noted but not touched (this bead may not edit `lib/`).
