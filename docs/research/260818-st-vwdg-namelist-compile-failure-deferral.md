---
date: 2026-08-18T19:49:48-0600
researcher: Claude
git_commit: 463fb453d27237ebf2bf329647d2518700ac847a
branch: st-vwdg-namelist-not-expression
repository: statifier-ex
beads_issue: st-vwdg
topic: "How namelist flows from parser to execution, which error paths a namelist compile failure takes for <send> vs <invoke>, and the existing precedents for deferring a compile failure to execute time"
tags: [research, codebase, compiler, send, invoke, namelist, error-handling]
status: complete
last_updated: 2026-08-18
last_updated_by: Claude
---

# Research: `namelist` compile failure, and the precedents for deferring it to execute time

**Date**: 2026-08-18T19:49:48-0600
**Git Commit**: 463fb453d27237ebf2bf329647d2518700ac847a
**Branch**: st-vwdg-namelist-not-expression
**Bead**: st-vwdg

## Research Question

st-vwdg reports that `test/scxml_tests/mandatory/send/test553_test.exs` and
`test/scxml_tests/mandatory/invoke/test554_test.exs` fail because a
deliberately malformed `namelist="&quot;foo"` makes the whole document fail to
compile, where the spec requires the send/invoke to be discarded at execution
time. Document, as the codebase exists today: how `namelist` flows end to end;
which error paths a namelist compile failure takes for `<send>` versus
`<invoke>`; the existing precedents for deferring a compile failure to execute
time; what the validator says about `namelist`; what the two corpus tests
assert and how the ratchet treats them; and what prior research and ADRs
already settled.

## Summary

`namelist` is split into tokens at **lowering** time, then each token is
compiled as a **predicator expression** at **compile** time, then evaluated at
**execution** time. All three stages exist and work. The failure the bead
reports comes entirely from the middle stage: a token that will not compile
fails `Statifier.Compiler.compile/1`, so the document never loads and the
execution-time behavior the two tests assert is never reached.

Three findings shape the picture:

1. **The bead's framing needs one correction.** The bead states `namelist` is
   "a space-separated list of *location names* ... not an expression to be
   evaluated - it should never reach the predicator compiler as an expression
   string at all." The spec says otherwise. 6.2.2's and 6.4.1's attribute
   tables both give `namelist` the datatype **"List of location expressions"**
   with the constraint "List of valid location expressions", and both point at
   **5.9.2 Location Expressions**. So compiling each token as an expression is
   not itself the deviation; the entries genuinely are location expressions.
   The gap is *when* a bad one is rejected, not *that* it is compiled.

2. **The engine already implements the exact runtime behavior both tests
   want**, and two accepted ADRs name `namelist` explicitly while doing it.
   ADR-0036 ("A failed `<send>` argument discards the message") and ADR-0031
   ("A failed invoke argument evaluation aborts the invocation") both list "a
   `namelist` location" among the arguments whose *evaluation* failure
   discards the message / aborts the invocation with `error.execution`. The
   interpreter and `Machine.Content.Send` both do this today. Nothing about
   the runtime half is missing. The compile-time rejection simply preempts it.

3. **The deferral precedent is well established, is named, and `docs/datamodel.md`
   already predicted this exact case.** `{:invalid, error}` captured on the
   compiled node is used by `<data expr>`, `<assign expr>`, executable-content
   `<script>`, and global `<script>`. [`docs/datamodel.md:71-91`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/datamodel.md#L71-L91) records the
   per-element-class policy, cites 5.9.4's explicit MAY permitting either
   choice, and states: *"If this is ever unified, it unifies toward deferral
   rather than away from it: deferral loads strictly more documents, and no
   corpus file requires load-time rejection."* It then names the trigger to
   watch for - a corpus document with an unparseable expression plus an
   `error.execution` handler. test553 and test554 are that shape for
   `namelist`.

Neither test is in `test/passing_tests.json`, neither is excluded or silenced,
and both are already mapped to st-vwdg by the st-cmq.9 plan's "every remaining
red maps to a bead" ledger.

## Detailed Findings

### 1. How `namelist` flows end to end

**Lowering - the split.** `namelist` is whitespace-split before the compiler
ever runs. `Attributes.list/2` ([`lib/statifier/lowering/attributes.ex:39-44`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/lowering/attributes.ex#L39-L44))
calls the private `split/1` ([`lib/statifier/lowering/attributes.ex:46-48`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/lowering/attributes.ex#L46-L48)),
which is plain `String.split(raw)`: runs of Unicode whitespace, empty pieces
dropped, `nil` mapped to `[]`. Call sites are
[`lib/statifier/lowering/builders.ex:837`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/lowering/builders.ex#L837) (`<invoke>`) and
[`lib/statifier/lowering/builders.ex:892`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/lowering/builders.ex#L892) (`<send>`). The whole attribute's
value span is recorded **once**, not per token
([`lib/statifier/lowering/builders.ex:826`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/lowering/builders.ex#L826) and `:878`, into
`attribute_locations[:namelist]`).

For the fixture value `namelist="&quot;foo"` this yields exactly one token,
the 4-character string `"foo`.

The result is `[String.t()]` on both document structs:
[`lib/statifier/document/send.ex:51`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/document/send.ex#L51) / `:69` and
[`lib/statifier/document/invoke.ex:49`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/document/invoke.ex#L49) / `:65`. Both moduledocs describe it as
"`[String.t()]` from a whitespace-split `namelist` attribute"
([`lib/statifier/document/send.ex:20-22`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/document/send.ex#L20-L22),
[`lib/statifier/document/invoke.ex:20-21`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/document/invoke.ex#L20-L21)). No syntax check is applied to a
token at this stage.

**Compile - `<send>`.** `build_content_node/2`'s `%DSend{}` clause
([`lib/statifier/compiler.ex:1007-1037`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1007-L1037)) calls `build_send_namelist/3` at
[`lib/statifier/compiler.ex:1020`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1020) with owner `{:content, c_index}`.
`build_send_namelist/3` ([`lib/statifier/compiler.ex:1153-1164`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1153-L1164)) resolves one
shared location ([`lib/statifier/compiler.ex:1159`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1159)) and maps each raw entry
through `build_param/6` at [`lib/statifier/compiler.ex:1162`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1162), passing the entry
string **twice** - once as `name`, once as `source` - with `kind: :location`.

**Compile - `<invoke>`.** `build_invoke/3`
([`lib/statifier/compiler.ex:1488-1522`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1488-L1522)) calls `build_invoke_namelist/4` at
[`lib/statifier/compiler.ex:1502`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1502) with owner `{:invoke, state_index,
invoke_index}`. `build_invoke_namelist/4`
([`lib/statifier/compiler.ex:1600-1618`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1600-L1618)) does the same double-duty call to
`build_param/6` at [`lib/statifier/compiler.ex:1612`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1612), wrapped in
`collect_invoke_param/2` rather than returning an error tuple.

**Compile - the shared bottom.** `build_param/6`
([`lib/statifier/compiler.ex:1431-1454`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1431-L1454)) is the single site an `MParam` is
built. It calls `Expressions.compile(source, owner, expr_location)` at
[`lib/statifier/compiler.ex:1440`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1440), which calls
`Predicator.compile_with_spans/1` ([`lib/statifier/compiler/expressions.ex:90`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler/expressions.ex#L90))
and returns `{:ok, {:compiled, compiled, source}}`
([`lib/statifier/compiler/expressions.ex:91-92`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler/expressions.ex#L91-L92)). There is no separate
"compile as a location" predicator entry point: `kind` is a descriptive tag
only. [`lib/statifier/machine/param.ex:7-16`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/param.ex#L7-L16) says so directly:

> `kind` records which of `expr`/`location` the author wrote ... Both kinds are
> read through `expr`/`expr_location` today: a `<param location>` compiles its
> path string the same way a `<param expr>` compiles its expression (Decision
> 4), which is only sound because a bound datamodel location is itself a legal
> value-producing expression in this engine's predicator value space. `kind` is
> kept anyway so a later read-only location-resolve switch ... is a one-site
> change in the interpreter fold, not a lowering, `Document`, or validator
> change.

The compiled `[%MParam{}]` lands on `MSend.namelist`
([`lib/statifier/compiler.ex:1031`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1031)) and `MInvoke.namelist`
([`lib/statifier/compiler.ex:1512`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1512)), kept as a list separate from `params`.

**Execution - `<send>`.** Note the send path does **not** live in
`interpreter.ex`. `Statifier.Machine.Content.Send.execute/2`
([`lib/statifier/machine/content/send.ex:111-147`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/send.ex#L111-L147)) calls its own private
`resolve_params(datamodel_context, node.namelist ++ node.params)` at
[`lib/statifier/machine/content/send.ex:118`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/send.ex#L118). `resolve_params/2`
([`lib/statifier/machine/content/send.ex:297-312`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/send.ex#L297-L312)) folds with
`Enum.reduce_while`, calling `Evaluator.evaluate/2` per param at
[`lib/statifier/machine/content/send.ex:302`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/send.ex#L302) and **halting on the first
`{:error, reason}`** (`:304`). The `with` then returns the bare two-element
`{:error, reason}`, which `Interpreter.Content.run_nodes/2` matches at
[`lib/statifier/interpreter/content.ex:219-220`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/content.ex#L219-L220) and `execute_block/3` converts
into `error.execution` via `raise_execution_error/4`
([`lib/statifier/interpreter/content.ex:170-177`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/content.ex#L170-L177), `:283-299`). No
`Effect.Send`/`Effect.SendDelayed` is produced, and the send's own id-minting
and `idlocation` write (later in the `with`, `:120-141`) never happen.

**Execution - `<invoke>`.** `invoke_one/6`
([`lib/statifier/interpreter.ex:1362-1418`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L1362-L1418)) calls
`resolve_params(context, invoke.namelist ++ invoke.params)` at
[`lib/statifier/interpreter.ex:1365`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L1365). That `resolve_params/2`
([`lib/statifier/interpreter.ex:1434-1449`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L1434-L1449)) is the same halt-on-first-failure
shape (`:1439`, `:1441`). Its `else` at
[`lib/statifier/interpreter.ex:1414-1416`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L1414-L1416) calls `abort_invocation/4`
(`:1618-1631`), which raises `error.execution` through
`MachineState.raise_platform/4` with origin `{:invoke, state_index,
invoke_index}` (`:1624-1630`) and emits no `Effect.Invoke` at all. Sibling
invokes on the same state are unaffected, since `invoke_state/3`'s fold
(`:1322-1334`) accumulates rather than halting.

**Execution - `finalize`.** `auto_assign_finalize/5`
([`lib/statifier/interpreter.ex:735-759`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L735-L759)) implements 6.5's empty-`<finalize>`
auto-assign: `invoke.namelist ++ invoke.params` filtered to `kind == :location`
(`:740`), each surviving param looked up by `Map.fetch(data, param.name)`, a
hit written through `write_finalize_target/6` (`:784`), a miss silently
skipped. `write_finalize_target/6` reads `param.expr`'s `{:compiled, _,
source}` (`:789-799`) - the comment there notes this field is always
`{:compiled, ...}` for a `kind: :location` entry, never `{:static, _}`.

### 2. Which error path a namelist compile failure takes today

Both end at a failed `compile/1`; the mechanics differ.

**`<send>` - the `with` short-circuit.** `build_send_namelist/3`'s `collect/1`
([`lib/statifier/compiler.ex:1163`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1163), defined `:1793-1806`) turns any per-entry
`{:error, %Error{}}` into `{:error, [Error.t()]}`. That is the last step of
the `with` at [`lib/statifier/compiler.ex:1010-1020`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1010-L1020); there is no `else`, so
the failing branch's value passes straight out and `build_content_node/2`
returns `{:error, errors}` instead of `{:ok, %MSend{}}`. This propagates
through `build_contents/2` ([`lib/statifier/compiler.ex:818-828`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L818-L828)) into
`contents_result`, which `compile/1` flat-maps into its combined error list at
[`lib/statifier/compiler.ex:263-270`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L263-L270), sorts by `location.start_offset`
(`:270`), and returns as `{:error, errors}` at
[`lib/statifier/compiler.ex:304-306`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L304-L306).

The clause comment at [`lib/statifier/compiler.ex:1002-1006`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1002-L1006) states the design
intent:

> Any single compile failure - `event`/`target`/`type`/`delay`, `<content
> expr>`, a `<param>`, or a `namelist` entry - stops the `with` and is
> returned whole, mirroring `%DLog{}`'s own single-error shape rather than
> `%DIf{}`'s multi-error `collect/1` merge: unlike an `<if>`'s independent
> branches, `<send>`'s own attributes have no reason to keep compiling once
> one of them is already known bad.

**`<invoke>` - the `invoke_errors` accumulator.** A failing entry is caught by
`collect_invoke_param/2`'s error clause
([`lib/statifier/compiler.ex:1626-1627`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1626-L1627)), which prepends the error onto
`acc.invoke_errors` and returns `{nil, acc}`. The failing entry is dropped
from that invoke's `namelist` by `Enum.reject(&is_nil/1)`
([`lib/statifier/compiler.ex:1617`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1617)), and every **other** field of the
`%MInvoke{}` still finishes building; a partially-built `%MInvoke{}` is still
attached to its owning state. `compile/1` then concatenates
`acc.invoke_errors` into the same error list at
[`lib/statifier/compiler.ex:269`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L269), sorts identically at `:270`, and returns
`{:error, errors}` at `:304-306`.

The moduledoc explains why `<invoke>` cannot use the deferred merge
([`lib/statifier/compiler.ex:143-157`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L143-L157)):

> `invoke_acc`/`invoke_errors` belong to the `<invoke>` pass - the one pass
> that does not fit the "numbered during the walk, compiled in a deferred
> pass" split every other field above follows. A `Machine.Invoke`'s
> `<finalize>` is executable content, so its `Machine.Block` needs the same
> `c_next` counter every `<onentry>`/`<onexit>` block draws from
> (`assign_blocks/2`), which only exists while the walk is threading `acc`
> through `walk_siblings/4` ... Building inline means a
> `typeexpr`/`srcexpr`/`<content>`/`<param>`/namelist compile failure cannot
> join the deferred passes' own `collect/1` merge the way
> `build_transitions/3`'s and `build_contents/2`'s do - `invoke_errors` is
> where those land instead, concatenated into `compile/1`'s own error merge
> before the final sort.

**One documented tension.** `compile/1`'s own `@doc`
([`lib/statifier/compiler.ex:193-198`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L193-L198)) says:

> A `Document` that reached this stage is expected to already be structurally
> valid - `compile/1` does not re-run validator checks - so `{:error, errors}`
> here signals a compiler defect (an id that fails to resolve during the
> numbering walk) rather than a malformed input document; callers should treat
> it as unexpected, not as routine error-event handling.

A malformed `namelist` token is a malformed *input document*, and it produces
exactly the `{:error, errors}` this doc says means "compiler defect". That is
a discrepancy in the stated contract, recorded here as an observation.

### 3. The `{:invalid, error}` deferral precedent

The shape is: capture the compile failure **on the compiled node** instead of
returning it, so `compile/1` still returns `{:ok, machine}`, and let execution
turn it into `error.execution`.

**Producers** (four, each with an inline authority citation):

| Site | File:line | Cited authority |
|---|---|---|
| `<data expr>` | [`lib/statifier/compiler.ex:1744-1747`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1744-L1747) | "Decision 2", `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md` |
| `<assign expr>` | [`lib/statifier/compiler.ex:949-954`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L949-L954) | "Decision 6", `docs/plans/260813-st-af3.4-assign-deep-path-vivification.md` |
| `<script>` (executable content) | [`lib/statifier/compiler.ex:976-981`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L976-L981) | ADR-0026 |
| `<script>` (global) | [`lib/statifier/compiler.ex:1194-1202`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1194-L1202) | "Decision 1" / "Decision 7, Phase 3" |

The "Decision 1" the bead's prompt asks about is
[`docs/plans/260814-st-af3.17-script-statement-bodies.md:163-178`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260814-st-af3.17-script-statement-bodies.md#L163-L178), titled
*"Decision 1 (research OQ 1): an unparseable body defers to runtime"*:

> Compilation happens at load (`compile_program/3`, Phase 1). On failure the
> node stores `{:invalid, Compiler.Error.t()}` - the exact deferral shape
> `<assign expr>` ... and `<data expr>` ... already use - and `execute/2`
> short-circuits it into `{:error, error}` (the two-element arm: nothing ran,
> so there is no partial context to keep), which the runner converts to
> `error.execution`.
>
> Why deferral rather than load rejection: `docs/datamodel.md` records that if
> the split is ever unified it unifies *toward* deferral; load rejection would
> make every ECMAScript-bodied `<script>` document unloadable ... and
> `execute/3` returns the same error shape for a parse failure anyway, so
> deferral costs nothing in handling.

That decision was subsequently promoted into **ADR-0026**, whose own resolved
open question ([`docs/adr/0026-script-as-predicator-statement-programs.md:176-183`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/adr/0026-script-as-predicator-statement-programs.md#L176-L183))
records that 5.9.4 "sanctions the queued form outright ... so decision 3
exercises a spec MAY, not a deviation."

**Consumers** - and yes, every one of them produces `error.execution`:

1. `Machine.Content.Assign` ([`lib/statifier/machine/content/assign.ex:118`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/assign.ex#L118)) -
   `defp evaluate_value(%Assign{value: {:invalid, error}}, %Context{}), do:
   {:error, error}`. Short-circuits before the evaluator; the block runner
   converts it ([`lib/statifier/interpreter/content.ex:219-220`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/content.ex#L219-L220), `:283-299`).
2. `Machine.Content.Script` ([`lib/statifier/machine/content/script.ex:68`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/script.ex#L68)) -
   `def execute(%Script{program: {:invalid, error}}, %Context{}), do: {:error,
   error}`. Same conversion site.
3. `Interpreter.Datamodel.bind_value/4`
   ([`lib/statifier/interpreter/datamodel.ex:379-381`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/datamodel.ex#L379-L381)) - `<data>` binding has
   no block runner, so it calls `raise_binding_error/3`, which raises
   `error.execution` directly through `MachineState.raise_platform/4`.
4. `Interpreter.run_global_script/3`
   ([`lib/statifier/interpreter.ex:378-383`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L378-L383)) - a top-level `<script>` also has
   no block runner; raises `error.execution` with origin `{:global_script,
   index}` directly.

`Evaluator.evaluate/2` ([`lib/statifier/evaluator.ex:277-287`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/evaluator.ex#L277-L287)) and
`run_program/2` (`:415-429`) have **no** `{:invalid, _}` clause at all - every
consumer intercepts the shape before the evaluator would see it
([`lib/statifier/evaluator.ex:399-402`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/evaluator.ex#L399-L402)).

**`%Machine.Param{}` is not a producer.** Neither a `namelist` entry nor a
`<param>` ever carries `{:invalid, error}`, on either element. Nor do
`<transition cond>`, `<if>`/`<elseif>` `cond`, `<foreach array>`, `<log expr>`,
`<content expr>`, or `<donedata>` `<param>`. The `<if>` clause comment
([`lib/statifier/compiler.ex:1251-1253`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1251-L1253)) draws the contrast explicitly: "a bad
`cond` fails `compile/1`, never deferred the way `<assign expr>` is".

**The policy is written down, and it forecast this case.**
[`docs/datamodel.md:71-91`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/datamodel.md#L71-L91):

> **An expression that fails to compile is rejected at load time everywhere
> except `<data expr>` and `<assign expr>`, which defer to runtime.** Spec
> 5.9.4 permits either ... so both halves conform - but the clause frames the
> choice as one processor-wide policy, and this engine currently makes it per
> element class. The asymmetry is deliberate, not an oversight:
> `test/scion_tests/data/data_invalid_test.exs` declares an unparseable `<data
> expr="{p1: 'v1'"/>` and asserts `pass` by *catching* the resulting
> `error.execution`, so load-time rejection would make that document
> unloadable and the test unpassable. ...
>
> If this is ever unified, it unifies toward deferral rather than away from it:
> deferral loads strictly more documents, and no corpus file requires load-time
> rejection. The trigger to watch for is a corpus document with an unparseable
> `cond` plus an `error.execution` handler - none exists today, and test344 is
> not one (its `cond="1"` compiles, then fails boolean coercion at evaluation).

test553 and test554 are the `namelist` analogue of the `data_invalid` /
`assign_invalid` precedent this paragraph rests on: a deliberately unparseable
expression in a document whose expected outcome is `pass`.

### 4. What the validator says about `namelist`

Exactly two checks, both **error**-tier (in `@checks`, not `@warning_checks` -
[`lib/statifier/validator.ex:85-86`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator.ex#L85-L86)), and both **co-occurrence only**:

- `Checks.Invoke.namelist_and_param/2`
  ([`lib/statifier/validator/checks/invoke.ex:100-105`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator/checks/invoke.ex#L100-L105)) - rejects `namelist !=
  []` together with `params != []` (6.4.1: "namelist: Must not occur with the
  `<param>` element"). Constructor
  [`lib/statifier/validator/error.ex:779-786`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator/error.ex#L779-L786).
- `Checks.Send.namelist_and_content/2`
  ([`lib/statifier/validator/checks/send.ex:217-222`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator/checks/send.ex#L217-L222)) - rejects `namelist != []`
  together with a `<content>` child (6.2.3). Constructor
  [`lib/statifier/validator/error.ex:899-906`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator/error.ex#L899-L906).

**Nothing validates namelist entry syntax.** Both checks test list emptiness
against a sibling; neither walks the strings. Under this project's layering
that is consistent: the validator owns document-shape and co-occurrence
constraints from the spec's own attribute tables and gates compilation
([`docs/architecture.md:36-41`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/architecture.md#L36-L41), [`lib/statifier/validator.ex:2-8`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator.ex#L2-L8)); the compiler
owns turning already-well-shaped strings into compiled predicator expressions;
the interpreter owns errors that only exist once expressions meet live data
([`docs/architecture.md:31-33`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/architecture.md#L31-L33), "Errors are events").

So a malformed `namelist` **entry** is not a validation concern under this
layering. It is a compile concern today, and the question st-vwdg raises is
whether it should instead be a runtime concern - which is precisely the axis
5.9.4 leaves to the processor and `docs/datamodel.md` has a stated leaning on.

Warnings never gate: `validate/2` returns `{:ok, document, warnings} |
{:error, errors, warnings}` ([`lib/statifier/validator.ex:113-114`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator.ex#L113-L114)) and the
branch is chosen purely by the error list (`:122-125`), per ADR-0033.

### 5. What the two corpus tests assert, and how the ratchet treats them

**test553** (`test/scxml_tests/mandatory/send/test553_test.exs`) - state `s0`
fires two sends on entry: `<send event="timeout" delayexpr="'1s'"/>` and
`<send event="event1" namelist="&quot;foo"/>`. A `timeout` transition targets
`pass`; an `event1` transition targets `fail`. Expected final configuration
`["pass"]`. The document passes only if the malformed send is discarded and
never delivers `event1`, letting the 1s timer win.

**test554** (`test/scxml_tests/mandatory/invoke/test554_test.exs`) - `s0` fires
a `timer` send, and carries `<invoke type="http://www.w3.org/TR/scxml/"
namelist="&quot;foo">` with an inline `<content><scxml>` child whose only state
is `subFinal`. A `timer` transition targets `pass`; `done.invoke` targets
`fail`. Expected `["pass"]`. The document passes only if the invocation is
abandoned, so no `done.invoke` ever arrives.

Both call `Statifier.Case.test_scxml/4`, and both die in the harness's very
first library call. `parse_document/1` ([`test/support/case.ex:362-367`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/case.ex#L362-L367)) is:

```elixir
case Statifier.compile(xml) do
  {:ok, machine} -> machine
  {:error, errors} -> flunk("Document did not compile:\n#{format_errors(errors)}")
end
```

Verbatim current output (`mix test ... --include scxml_w3`, this commit):

```
  1) test test553 (SCXMLTest.Send.Test553)
     test/scxml_tests/mandatory/send/test553_test.exs:15
     Document did not compile:
     failed to compile expression "\"foo": Unterminated double-quoted string literal (predicator line 1, column 1)
     code: test_scxml(xml, description, ["pass"], [])
     stacktrace:
       (statifier 2.0.0-dev) test/support/case.ex:179: Statifier.Case.drive_through_session/3
       test/scxml_tests/mandatory/send/test553_test.exs:43: (test)

  2) test test554 (SCXMLTest.Invoke.Test554)
     test/scxml_tests/mandatory/invoke/test554_test.exs:17
     Document did not compile:
     failed to compile expression "\"foo": Unterminated double-quoted string literal (predicator line 1, column 1)
     code: test_scxml(xml, description, ["pass"], [])
     stacktrace:
       (statifier 2.0.0-dev) test/support/case.ex:179: Statifier.Case.drive_through_session/3
       test/scxml_tests/mandatory/invoke/test554_test.exs:51: (test)

Finished in 0.03 seconds (0.03s async, 0.00s sync)
2 tests, 2 failures
```

Note both failures are byte-identical, and both fire before any state chart is
initialized. The `<send>` and `<invoke>` compile paths differ mechanically
(§2) but converge on the same `compile/1` `{:error, errors}` return.

The message itself is built by `Error.expression_compile_error/4`
([`lib/statifier/compiler/error.ex:62-76`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler/error.ex#L62-L76)) from the `%Predicator.Errors.ParseError{}`
that [`deps/predicator/lib/predicator/lexer.ex:684-687`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/deps/predicator/lib/predicator/lexer.ex#L684-L687) raises for an
unterminated string literal. `format_errors/1` ([`test/support/case.ex:386`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/case.ex#L386)) is
`Enum.map_join(errors, "\n", & &1.message)`, so the harness prints the
compiler's message verbatim.

**Ratchet status: not tracked, not excluded, not silenced.**
`test/passing_tests.json` has three list keys - `internal_tests` (2 globs),
`scion_tests` (119 entries), `w3c_tests` (149 entries). Neither `test553` nor
`test554` appears anywhere in the file. Per [`docs/testing.md:220-236`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/testing.md#L220-L236), the
conformance lists "start empty and are grown one verified test at a time" by
`mix test.baseline`, which "runs every conformance test the registry does not
track yet ... Nothing enters the registry without passing first." So an
untracked failing test is simply an untracked failing test: `mix
test.regression` never runs it, and `mix quality`'s `Regression ratchet` stage
stays green. The generated corpus tests carry `@moduletag :scxml_w3`, excluded
by default in `test/test_helper.exs`.

There is also no expected-failure list, and the corpus's own filters do not
touch either file. [`tools/corpus/README.md:129-166`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/tools/corpus/README.md#L129-L166) documents the three W3C
filters - datamodel, `tools/corpus/scxml_w3/exclusions.exs`, and
`sub_documents.exs`. Neither `test553` nor `test554` appears in
`exclusions.exs`; both carry `datamodel="predicator"` and are ordinary
`mandatory/` cases rather than `<dep>` sub-documents, so both are emitted
normally. They are simply untracked failing tests, not suppressed ones.

Both are already accounted for in the record.
[`docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md:1301-1310`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md#L1301-L1310),
under "Every remaining red maps to a bead", lists 34 red files and names
`st-vwdg (test553, test554)` among them, closing with "Nothing is silenced and
no atom gates any of them out (ADR-0011)". The same pairing appears at
[`docs/plans/260816-st-u2h4-start-session-init-deadlock-deferred-invoke.md:743`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260816-st-u2h4-start-session-init-deadlock-deferred-invoke.md#L743).
Independently,
[`docs/plans/260816-st-53ys-inline-content-markup-lowering.md:785-787`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260816-st-53ys-inline-content-markup-lowering.md#L785-L787) recorded
a sweep result: "23 of the 24 compile; `test554` fails on its deliberately
malformed `namelist="&quot;foo"`" - i.e. the compile failure was observed and
scoped out during that bead rather than being new information.

### 6. Prior research and ADRs that already settled the surrounding questions

**ADR-0036 - "A failed `<send>` argument discards the message"** (accepted
2026-08-15). Its opening sentence enumerates the arguments, `namelist`
included:

> `<send>` can carry several kinds of argument that need evaluation before the
> message is dispatched: `eventexpr`, `targetexpr`, `typeexpr`, `delayexpr`,
> `idlocation`, a `namelist` location, each `<param>`'s `expr` or `location`,
> and `<content expr>`.

Its Decision:

> **A failure while evaluating any of `<send>`'s arguments - `eventexpr`,
> `targetexpr`, `typeexpr`, `delayexpr`, `idlocation`, a `namelist` location, a
> `<param>`'s `expr` or `location`, or `<content expr>` - raises
> `error.execution` and discards the message: `execute/2` returns `{:error,
> reason}`, the block runner converts it to `error.execution` (its sole such
> site), and no `Effect.Send` or `Effect.SendDelayed` is produced for that
> `<send>`.**
>
> The first failing argument stops evaluation of the rest ... There is no
> partial message: 6.2.2's "discard the message" names an all-or-nothing
> outcome, not a message assembled from whichever arguments happened to
> succeed.

**ADR-0031 - "A failed invoke argument evaluation aborts the invocation"**
(accepted 2026-08-15). Same shape, same explicit mention:

> That MUST covers every argument an `<invoke>` element can carry: `type` or
> `typeexpr`, `src` or `srcexpr`, `id` or `idlocation`, `namelist`, each
> `<param>`'s `expr` or `location`, and `<content expr>`.

Decision:

> **A failure while evaluating any of an invocation's arguments - `typeexpr`,
> `srcexpr`, `idlocation`, a `<param>`'s `expr` or `location`, a `namelist`
> location, or `<content expr>` - raises `error.execution` via
> `MachineState.raise_platform/4` with origin `{:invoke, state_index,
> invoke_index}`, and produces no `Effect.Invoke` for that invocation.**

ADR-0031 also records why the element-level MUST beats 5.7's per-`<param>`
"ignore the name and value", and ADR-0036 adopts that resolution method for
`<send>` while noting `<send>` has its own controlling clause (6.2.2).

**ADR-0026 - `<script>` as predicator statement programs.** The record that
promoted "Decision 1" deferral into settled policy, and that quotes 5.9.4 to
establish deferral is a spec MAY rather than a deviation.

**ADR-0021 / ADR-0047 / ADR-0033.** ADR-0021 is the `<donedata>` `<content
expr>` answer whose scope limit ADR-0036 amended. ADR-0047 covers static send
target/type invalidity rejecting *in the core* - a different `{:invalid, _}`
usage (a classified target, not a captured compile error), worth not confusing
with the deferral shape. ADR-0033 is the validator warning tier.

**Research documents.**
`docs/research/260815-st-cmq.3-send-cancel-content-nodes-and-effects.md` is the
`<send>` half: it quotes 6.2.2's discard MUST at `:330-340`, states at
`:343-345` that "an argument-evaluation failure means **no effect is produced
at all** for that `<send>`", and its open question 3 (`:677-684`) is the
per-param-versus-per-element tension that ADR-0036 later settled.
`docs/research/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md` is the
`<invoke>` lowering half, covering `namelist`'s whitespace-split shape
(`:594`, `:833`) and 6.4.1's attribute table (`:224`).
`docs/research/260815-st-cmq.7-invoke-scxml-child-sessions.md` covers seeding
the child datamodel from `namelist ++ params` (`:92`, `:142`, `:248`).
`docs/research/260816-st-cmq.9-corpus-flip-send-invoke-ratchet.md` is the
corpus flip these two reds fell out of.

None of these three cmq documents addresses compile-time versus load-time
rejection for `namelist`; all three assume the entries compile and reason
about evaluation. That question is untouched by them, and is what st-vwdg adds.

### 7. Spec clauses, quoted from the local cache

Read from `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`.

**6.2.2, `namelist`'s datatype row** (the correction to the bead's framing):

> namelist / false / Must not be specified in conjunction with `<content>`
> element. / **List of location expressions** / none / **List of valid location
> expressions** / A space-separated list of one or more data model locations to
> be included as attribute/value pairs with the message. (The name of the
> location is the attribute and the value stored at the location is the value.)
> See 5.9.2 Location Expressions for details.

6.4.1's `<invoke>` row is the same shape, pointing at "6.4.4 Data Sharing and
5.9.2 Location Expressions".

**6.2.2, the discard MUST** (test553's rule):

> The Processor MUST evaluate all arguments to `<send>` when the `<send>`
> element is evaluated, and not when the message is actually dispatched. If the
> evaluation of `<send>`'s arguments produces an error, the Processor MUST
> discard the message without attempting to deliver it.

**6.4, the terminate MUST** (test554's rule):

> When the `<invoke>` element is executed, if the evaluation of its arguments
> produces an error, the SCXML Processor MUST terminate the processing of the
> element without further action.

**5.9.2, Location Expressions:**

> Location expressions are used to specify a location in the data model, e.g.
> as part of the `<assign>`, `<param>`, `<send>` or `<invoke>` elements. The
> exact nature of a location depends on the data model. If a location
> expression cannot be evaluated to yield a valid location, the SCXML processor
> MUST place the error 'error.execution' in the internal event queue.

**5.9.4, Errors in Expressions** - the clause that makes both timings
conformant, and therefore the one this whole question turns on:

> The SCXML Processor MAY reject documents containing syntactically ill-formed
> expressions at document load time, or it MAY wait and place 'error.execution'
> in the internal event queue at runtime when the expressions are evaluated. If
> the processor waits until it evaluates the expressions at runtime to raise
> errors, it MUST raise errors caused by expressions returning illegal values
> at the points at which the expressions are to be evaluated. Note that this
> requirement holds even if the implementation is optimizing expression
> evaluation.

Note the interaction with 5.9.2: `"foo` is *syntactically ill-formed*, which is
5.9.4's subject, and it is also a location expression that "cannot be evaluated
to yield a valid location", which is 5.9.2's subject. Under the deferral half
of 5.9.4's MAY the two clauses agree on `error.execution` at evaluation time;
under the load-time-rejection half, 5.9.4 licenses rejecting the document but
tests 553 and 554 then cannot pass.

## Code References

- [`lib/statifier/lowering/attributes.ex:39-48`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/lowering/attributes.ex#L39-L48) - `list/2` and the whitespace `split/1` that tokenizes `namelist`
- `lib/statifier/lowering/builders.ex:826,837` - `<invoke>` namelist location + tokens
- `lib/statifier/lowering/builders.ex:878,892` - `<send>` namelist location + tokens
- `lib/statifier/document/send.ex:51,69` / `lib/statifier/document/invoke.ex:49,65` - `namelist :: [String.t()]`
- [`lib/statifier/compiler.ex:143-157`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L143-L157) - moduledoc on `invoke_acc`/`invoke_errors` and why `<invoke>` cannot use the deferred merge
- [`lib/statifier/compiler.ex:193-198`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L193-L198) - `compile/1`'s `@doc` claiming `{:error, errors}` means "compiler defect"
- `lib/statifier/compiler.ex:263-270,304-306` - `compile/1`'s error merge, sort, and `{:error, errors}` return
- [`lib/statifier/compiler.ex:949-954`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L949-L954) - `<assign expr>` `{:invalid, error}`
- [`lib/statifier/compiler.ex:976-989`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L976-L989) - `<script>` `{:invalid, error}`
- [`lib/statifier/compiler.ex:1002-1037`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1002-L1037) - the `<send>` clause and its `with`
- [`lib/statifier/compiler.ex:1153-1164`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1153-L1164) - `build_send_namelist/3`
- [`lib/statifier/compiler.ex:1194-1202`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1194-L1202) - `build_global_scripts/1` `{:invalid, error}`
- [`lib/statifier/compiler.ex:1251-1253`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1251-L1253) - the comment contrasting `<if>` `cond` hard failure with `<assign expr>` deferral
- [`lib/statifier/compiler.ex:1431-1454`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1431-L1454) - `build_param/6`, the single `MParam` construction site
- [`lib/statifier/compiler.ex:1470-1522`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1470-L1522) - `build_invoke/3`
- [`lib/statifier/compiler.ex:1591-1618`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1591-L1618) - `build_invoke_namelist/4`
- [`lib/statifier/compiler.ex:1620-1627`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1620-L1627) - `collect_invoke_param/2`, the `invoke_errors` sink
- [`lib/statifier/compiler.ex:1744-1747`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1744-L1747) - `<data expr>` `{:invalid, error}`
- [`lib/statifier/compiler/expressions.ex:86-97`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler/expressions.ex#L86-L97) - `compile/3` into `Predicator.compile_with_spans/1`
- `lib/statifier/machine/param.ex:7-16,36-47` - `kind` as a descriptive tag; both kinds read through `expr`
- `lib/statifier/machine/content/send.ex:93-101,111-147,291-312` - `<send>` execution and its own `resolve_params/2`
- [`lib/statifier/machine/content/assign.ex:118`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/assign.ex#L118) / [`lib/statifier/machine/content/script.ex:68`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/machine/content/script.ex#L68) - `{:invalid, error}` consumers
- [`lib/statifier/interpreter.ex:378-383`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L378-L383) - global-script `{:invalid, _}` consumer
- `lib/statifier/interpreter.ex:735-759,784-799` - `auto_assign_finalize/5` and `write_finalize_target/6`
- `lib/statifier/interpreter.ex:1322-1334,1362-1418,1434-1449,1618-1631` - invoke fold, `invoke_one/6`, `resolve_params/2`, `abort_invocation/4`
- `lib/statifier/interpreter/content.ex:170-177,219-220,283-299` - the block runner's sole `error.execution` conversion site
- [`lib/statifier/interpreter/datamodel.ex:379-381`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/datamodel.ex#L379-L381) - `<data>` binding `{:invalid, _}` consumer
- `lib/statifier/validator.ex:85-86,113-125` - namelist checks in the error tier; warnings never gate
- [`lib/statifier/validator/checks/send.ex:217-222`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator/checks/send.ex#L217-L222) / [`lib/statifier/validator/checks/invoke.ex:100-105`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/validator/checks/invoke.ex#L100-L105) - the two co-occurrence checks
- [`test/support/case.ex:362-367`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/case.ex#L362-L367) - the `flunk("Document did not compile:...")` site
- `test/passing_tests.json` - three lists; neither test553 nor test554 present

## Architecture Documentation

- **ADR-0036** - a failed `<send>` argument (namelist included) discards the message
- **ADR-0031** - a failed `<invoke>` argument (namelist included) aborts the invocation
- **ADR-0026** - `<script>` as predicator statement programs; establishes deferral as a sanctioned 5.9.4 MAY
- **ADR-0021** - `<donedata>` `<content expr>` failure yields no data; its scope limit was amended by ADR-0036
- **ADR-0033** - validator warning tier; errors gate compilation, warnings ride on the Machine
- **ADR-0047** - static send target/type invalidity rejects in the core (a different `{:invalid, _}` usage)
- **ADR-0003** - pure core with effects; the block runner is the sole execution-failure conversion site
- **ADR-0004** - predicator as the datamodel
- **[`docs/datamodel.md:71-91`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/datamodel.md#L71-L91)** - the per-element-class load-time-versus-runtime policy, its 5.9.4 justification, and the stated leaning toward deferral if unified
- **`docs/architecture.md:31-41,45-64`** - errors-are-events, and the validator/compiler/interpreter layering

## Historical Context

- [`docs/plans/260814-st-af3.17-script-statement-bodies.md:163-178`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260814-st-af3.17-script-statement-bodies.md#L163-L178) - "Decision 1", the canonical statement of the deferral shape and its rationale
- `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md` - "Decision 2", the original `<data expr>` deferral
- `docs/plans/260813-st-af3.4-assign-deep-path-vivification.md` - "Decision 6", `<assign expr>` deferral
- `docs/research/260815-st-cmq.3-send-cancel-content-nodes-and-effects.md:330-345,677-684` - the `<send>` argument-failure research that ADR-0036 closed
- `docs/research/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md:224,594,833` - `<invoke>` namelist lowering
- `docs/research/260815-st-cmq.7-invoke-scxml-child-sessions.md:92,142,248` - namelist seeding the child datamodel
- [`docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md:1301-1310`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260816-st-cmq.9-corpus-flip-send-invoke-session-harness-ratchet.md#L1301-L1310) - the red-to-bead ledger naming st-vwdg for test553/test554
- [`docs/plans/260816-st-53ys-inline-content-markup-lowering.md:785-787`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/plans/260816-st-53ys-inline-content-markup-lowering.md#L785-L787) - independent prior observation of test554's compile failure

## Related Research

- `docs/research/260816-st-cmq.9-corpus-flip-send-invoke-ratchet.md`
- `docs/research/260817-st-yizi-send-target-validity-block-abort-and-order.md` - the other `{:invalid, _}` axis (target classification, ADR-0047)
- `docs/research/260814-st-af3.17-script-statement-bodies.md` - the deferral shape's own research

## Open Questions

1. **The bead's stated diagnosis does not survive the spec text.** The bead
   says a `namelist` token "should never reach the predicator compiler as an
   expression string at all". 6.2.2 and 6.4.1 both type `namelist` as a "List
   of location expressions" pointing at 5.9.2, so the entries are location
   expressions and compiling them is not the deviation. If the fix is scoped
   as "stop compiling namelist tokens", it would also need to answer what a
   non-trivial location expression (`foo.bar`, `foo[0]`) resolves against at
   send/invoke time, since `write_finalize_target/6`
   ([`lib/statifier/interpreter.ex:789-799`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter.ex#L789-L799)) currently depends on the compiled
   form being present. This is a plan-shaping question, recorded rather than
   answered.

2. **Whether deferral should be scoped to `namelist` or applied uniformly.**
   [`docs/datamodel.md:83-91`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/datamodel.md#L83-L91) says a unification would go toward deferral, and
   names a trigger it thought had not fired. These two tests arguably fire it
   for `namelist`. Whether that justifies deferring only namelist entries,
   deferring all `<send>`/`<invoke>` arguments, or revisiting the whole
   per-element-class split is a decision for the plan, and touching
   `docs/datamodel.md`'s recorded policy is a documentation change either way.

3. **The `<invoke>` half needs a shape choice the `<send>` half does not.**
   `<send>`'s `with` returns one error and stops; a `{:invalid, error}` on an
   `MParam` would slot in cleanly. `<invoke>` currently *drops* the failing
   entry from `namelist` ([`lib/statifier/compiler.ex:1617`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L1617)) while recording
   the error, so a deferred `<invoke>` namelist entry has to survive that
   `Enum.reject/2` to be evaluable later. Which of the two paths changes, and
   whether `MParam.expr` gains an `{:invalid, _}` arm in
   `lib/statifier/machine/param.ex`, is unresolved here.

4. **`compile/1`'s `@doc` contract is inaccurate today**
   ([`lib/statifier/compiler.ex:193-198`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/compiler.ex#L193-L198)): it says `{:error, errors}` signals a
   compiler defect rather than a malformed input document, but a malformed
   `namelist` token is exactly a malformed input document returning that
   tuple. Whether this is corrected as part of st-vwdg or noted separately is
   open.

5. **Ratcheting.** Both tests are untracked, so nothing enforces them today
   and nothing will unless `mix test.baseline add` is run for them once they
   pass. The [`docs/testing.md:220-236`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/docs/testing.md#L220-L236) protocol makes this a deliberate step,
   not an automatic one.
