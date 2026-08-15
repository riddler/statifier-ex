---
date: 2026-08-15T09:46:46-0600
researcher: Claude
git_commit: b52208e6f8d1aaa1be70427b803fa97d0a4f6824
branch: st-jzc-validator-warning-tier
repository: statifier-ex
beads_issue: st-jzc
topic: "Giving Statifier.Validator a warning tier, and reporting spec 6.5's send/raise ban inside <finalize>"
tags: [research, codebase, validator, invoke, finalize, observability]
status: complete
last_updated: 2026-08-15
last_updated_by: Claude
---

# Research: the validator's warning tier, and 6.5's send/raise ban in `<finalize>`

**Date**: 2026-08-15T09:46:46-0600
**Git Commit**: b52208e6f8d1aaa1be70427b803fa97d0a4f6824
**Branch**: st-jzc-validator-warning-tier
**Bead**: st-jzc

## Research Question

`Statifier.Validator` returns `{:ok, document} | {:error, [Error.t()]}` - every
check either passes or rejects. st-jzc needs a warning tier: a finding reported
without failing the document. On top of it, `Statifier.Validator.Checks.Invoke`
must report `<send>`/`<raise>` appearing under `<finalize>`, citing spec 6.5.

This document maps what exists today: the shape of a finding, the check
contract, every consumer of `validate/2`'s return, how the `<finalize>` block is
represented after st-cmq.6, what prior art the repo has for a non-fatal
diagnostic, which existing checks reject something the engine could execute
past, and what a return-shape change would touch in tests and the corpus
harness.

## The spec clause, quoted

From the local cache
(`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`),
section **6.5.2 Children**, verbatim:

> `<finalize>`'s children consist of 0 or more elements of executable content.
> In a conformant SCXML document, the executable content inside `<finalize>`
> MUST NOT raise events or invoke external actions. In particular, the `<send>`
> and `<raise>` elements MUST NOT occur. If one or more elements of executable
> content is specified, the SCXML Processor MUST execute them each time an
> event is received from the child process that was created by the parent
> `<invoke>` element. The Processor MUST execute them right before the event is
> pulled off the external event queue for processing. The Processor MUST NOT
> execute them at any other time or in response to any other events.

Two observations the bead's paraphrase does not carry:

1. The normative rule is broader than the two element names. The MUST NOT is on
   "raise events or invoke external actions"; `<send>` and `<raise>` are named
   as the particular case ("In particular"). A check that walks for exactly two
   element names implements the named instance, not the general rule.
2. The clause is stated as a constraint on a **conformant SCXML document** -
   phrasing addressed to the author, not to the processor. The processor-facing
   MUSTs in the same paragraph are about *when* finalize content runs, and
   this engine already satisfies those
   ([`lib/statifier/interpreter.ex:641-670`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L641-L670), `:426`, `:511-591`).

## Summary

**The validator has no severity axis anywhere.** `Statifier.Validator.Error`
([`lib/statifier/validator/error.ex:75-82`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/error.ex#L75-L82)) is exactly three enforced fields -
`reason`, `message`, `location` - and nothing else in `lib/statifier/`
distinguishes one finding from another by seriousness. All 18 wired checks share
one return type, `[Error.t()]`, and `validate/2`
([`lib/statifier/validator.ex:87-99`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator.ex#L87-L99)) flat-maps them, sorts by
`location.start_offset`, and returns `{:ok, document}` only when the list is
empty. There is no branch anywhere by which a constructed `Error` produces
anything but `{:error, errors}`.

**The absence is a recorded decision, not an oversight.** Decision 4 of the
original validator plan
([`docs/plans/260808-st-l5k.5-document-validator.md:296-314`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260808-st-l5k.5-document-validator.md#L296-L314)) settled "errors
only, no warnings" on the grounds that every check was a spec MUST and a warning
channel would have zero producers - "an empty channel now costs a public API
shape we would have to keep". The same decision explicitly names the escape
hatch this bead would use: "Decision 3's struct shape makes adding a channel
later purely additive - a `{:ok, document, warnings}` arm or a second list needs
no change to any existing reason." st-t8w later reaffirmed the decision rather
than opening the tier
(`docs/plans/260812-st-t8w-idless-compound-final-validator.md`). st-cmq.6
recorded the 6.5 gap as deferred for precisely this reason
([`docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md:187-191`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md#L187-L191)).

**The blast radius of a return-shape change is narrow in `lib/` and wide in
`test/`.** Exactly one production call site pattern-matches `validate/2`:
[`lib/statifier.ex:62`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier.ex#L62), inside `Statifier.compile/1`'s `with` chain. 71 test call
sites across 25 files match it, most as fixture setup. Nothing renders a
validator error to a user anywhere in `lib/`; the sole formatter in the repo is
`format_errors/1` in the test harness ([`test/support/case.ex:184`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/support/case.ex#L184)).

**The 6.5 check has only one reachable half today.** `<raise>` is a first-class
`Document.content_node()` and lowers fine inside `<finalize>`. `<send>` has no
`Statifier.Document.Send` module and no dispatch entry, so a `<send>` anywhere -
inside `<finalize>` included - is rejected by *lowering* as
`{:unsupported_element, "send"}` ([`lib/statifier/lowering.ex:154-155`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/lowering.ex#L154-L155),
[`lib/statifier/lowering/error.ex:44-50`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/lowering/error.ex#L44-L50)) before the validator ever runs. A
Document-layer check for 6.5 can therefore observe the `<raise>` half only, and
the `<send>` half becomes reachable only when `<send>` lands.

**Warnings would need a new surfacing seam; ADR-0012's existing ones do not
reach the validator.** Every seam ADR-0012 and `docs/observability.md` name
lives on the Machine or in the interpreter's effect stream
([`docs/observability.md:177-186`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/observability.md#L177-L186)). The validator runs before a Machine exists,
returns a value rather than emitting effects, and is not mentioned in ADR-0012
or `docs/observability.md` at all. The closest prior art is structural, not
reusable: the trace-effect tag-and-gate mechanism (`lib/statifier/effect.ex`),
and the `severity: String.t()` field in the repo's own gate mix tasks, which is
hardcoded to `"error"` at all seven of its construction sites.

## Detailed Findings

### The validator's shape today

`Statifier.Validator` (`lib/statifier/validator.ex`) is 100 lines. Its moduledoc
states four contracts ([`lib/statifier/validator.ex:10-28`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator.ex#L10-L28)): collect-all never
fail-fast, document-order sort, never a partial result, and `source` must be the
document's own binary. `validate/2`:

```elixir
def validate(%Document{} = document, source) when is_binary(source) do
  context = Context.build(document, source)

  errors =
    @checks
    |> Enum.flat_map(fn check -> check.(document, context) end)
    |> Enum.sort_by(fn error -> error.location.start_offset end)

  case errors do
    [] -> {:ok, document}
    errors -> {:error, errors}
  end
end
```

`@checks` ([`lib/statifier/validator.ex:53-72`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator.ex#L53-L72)) is a fixed list of 18 captured
`check/2` closures. `Statifier.Validator.Context`
(`lib/statifier/validator/context.ex`) is a throwaway per-call index (`source`,
`states`, `ancestors`, `parents`, `transitions`) shared read-only by every
check; it is never returned, cached, or handed to the compiler
(`context.ex:2-7`).

`Statifier.Validator.Error` (`lib/statifier/validator/error.ex`) is 781 lines,
almost all of it doc comments and constructors:

- `@enforce_keys [:reason, :message, :location]`, `defstruct` the same three
  (`error.ex:75-76`). No `severity`, no `category`, no `code` field.
- `@type reason` is a closed tagged-tuple union of 41 variants
  (`error.ex:33-73`), declared in one place and extended one constructor at a
  time - "Later additions add a constructor per reason rather than reopening
  the type" (`error.ex:12-15`).
- One public constructor per reason, each carrying its own `@doc` citing the
  spec clause and explaining where the location points.
- `code/1` (`error.ex:87-88`) returns the reason tuple's tag atom. It is the
  only classifier on the struct, and it identifies *which check fired*, not how
  serious the finding is. Nothing in `lib/` calls it.
- The moduledoc names the one place a severity axis is gestured at in prose:
  the struct "Mirrors `Statifier.Lowering.Error`'s shape (`reason`, `message`,
  `location`) with character-identical field names, so a future common
  diagnostic protocol can adopt both" (`error.ex:4-10`). No such protocol
  exists.

`test/statifier/validator/layer_test.exs` is a structural test that AST-walks
`error.ex` and every `checks/*.ex` to assert every `@type reason` tag has
exactly one constructor and one producing check. A new reason arriving through a
different mechanism has to satisfy it.

### The check contract, and which checks reject what the engine could run past

All 18 wired checks declare the identical `@spec check(Document.t(),
Context.t()) :: [Error.t()]`. None returns a tuple, a map, or a nested
structure, and none reads another check's result - `validate/2`'s bare
`Enum.flat_map` with no per-check unwrapping depends on that uniformity
([`lib/statifier/validator.ex:92`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator.ex#L92)).

`lib/statifier/validator/checks/default_transition.ex` exists on disk but is
**not** in `@checks`. It is a shared helper with a `check/3` (not `/2`)
consumed by `Checks.InitialElement` (`initial_element.ex:49-53`) and
`Checks.History` (`history.ex:65`), and its own moduledoc says so
(`default_transition.ex:16-19`). It is the only check-level code shared between
two checks; the per-file `flatten/1`, `blank?/1`, and `descend/1` helpers are
duplicated in each file rather than shared.

The bead asks which existing checks reject a document the engine could execute
past. Reported, not decided:

**Reject something the engine could physically run past** - the document is
nonconformant but the interpreter has a defined behavior either way:

| Check | Reason(s) | Why the engine could run past it |
|---|---|---|
| `Checks.Enums` | `{:transition_bad_type, raw}`, `{:scxml_bad_binding, raw}`, `{:scxml_bad_datamodel, raw}`, `{:invoke_bad_autoforward, raw}` | `Lowering.Attributes.atom/4` already mapped the out-of-range value onto the attribute's default, so the struct the interpreter sees is a valid one. The check exists only because `Location.slice/2` can recover the source text (`checks/enums.ex:1-12`). The `datamodel` case documents its own weakness: spec 3.2.1 permits "other platform-defined values", so the check catches typos, not nonconformance (`error.ex:529-543`) |
| `Checks.History` | `{:history_bad_type, raw}` | Same shape - out-of-range `type` already lowered to `:shallow` (`error.ex:268-273`) |
| `Checks.Boilerplate` | `{:bad_namespace, uri}`, `{:bad_version, version}` | Nothing downstream reads namespace or version to run; lowering accepts a boilerplate-free `<scxml>` unconditionally (`checks/boilerplate.ex:5-7`) |
| `Checks.Assign` | `{:assign_expr_and_text, expr}` | Both are representable and the interpreter would execute one of them |
| `Checks.Content` | `{:content_expr_and_text, expr}` | Same |
| `Checks.Donedata` | `{:donedata_not_on_final, id}`, `{:donedata_content_and_params, id}` | Both are shapes lowering leaves representable on purpose (`checks/donedata.ex:6-7,15-16`) |
| `Checks.Invoke` | all five 6.4.1 mutual-exclusion reasons | Every pair is simultaneously representable precisely so the check can report the shape (`checks/invoke.ex:17-22`) |
| `Checks.Param` | `{:param_expr_and_location, name}` | Leaf shape; the interpreter would use one |
| `Checks.If` | `{:if_elseif_after_else}`, `{:if_duplicate_else}` | `Document.If.Branch` partitions branches by shape regardless of order, so the interpreter still evaluates them |
| `Checks.Script` | `{:script_no_src_or_text}` | An empty script is a no-op at execution |
| `Checks.Data` | `{:data_expr_and_src, id}`, `{:data_value_and_children, id}`, `{:data_reserved_id, id}`, `{:datamodel_bad_parent, kind}` | The first three are leaf shapes; `datamodel_bad_parent` is representational-only, since all four state kinds share one `%Document.State{}` struct (`checks/data.ex:26-28`) |
| `Checks.Final` | `{:final_has_transitions, id}` | A `<final>` never fires its own outgoing transitions in Appendix D, so the transition is dead code rather than a crash |

**Reject something that would break compilation or interpretation** - not
candidates on the same footing:

`Checks.Ids` (`{:duplicate_id}`, `{:empty_id}` - the Machine interns by id,
ADR-0005), `Checks.Targets` (`{:unresolved_target}` - a dangling reference
`select_transitions` cannot resolve), `Checks.InitialTargets`
(`{:unresolved_initial}`, `{:initial_not_descendant}`,
`{:initial_on_atomic_state}` - nothing for `enterStates` to descend into),
`Checks.FinalParent` (`{:final_parent_missing_id}` - `done.state.<nil>`),
`Checks.DefaultEntry` (`{:default_entry_not_enterable}`), and the
count/missing-target arms of `Checks.DefaultTransition`. `Checks.Final`'s
`{:final_has_states}` and `Checks.History`'s `{:history_bad_parent}` are
structural in the same way.

`Checks.DefaultTransition`'s third arm is mixed: `event`/`cond` on a default
transition is ignorable at runtime, while a missing or miscounted target is not.
The same split runs through `Checks.InitialElement` (the
attribute-and-element exclusivity arm is semantic, the transition arms are
structural) and `Checks.History`.

The classification above is evidence, not a recommendation. Note also that
several "semantic-only" reasons exist *only* because lowering deliberately
declines to refuse the shape - `Document.Invoke`'s moduledoc
([`lib/statifier/document/invoke.ex:5-12`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/document/invoke.ex#L5-L12)), `Checks.Enums`'s
(`checks/enums.ex:1-12`), and `Checks.Donedata`'s all state the division of
labour explicitly. Reclassifying any of them as a warning changes which layer
holds the line, not just the severity label.

### Callers of `validate/2` and everything downstream

**One production caller.** `Statifier.compile/1` ([`lib/statifier.ex:59-65`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier.ex#L59-L65)):

```elixir
@spec compile(source :: binary()) :: {:ok, Machine.t()} | {:error, [error()]}
def compile(source) when is_binary(source) do
  with {:ok, root} <- parse(source),
       {:ok, document} <- Lowering.lower(root),
       {:ok, document} <- Validator.validate(document, source) do
    Compiler.compile(document)
  end
end
```

The `{:error, errors}` half is never explicitly matched: `with` falls through
and returns the clause's value verbatim, so a validator error list becomes
`compile/1`'s return untouched - no wrapping, no exception, no mapping.
`Statifier.error()` ([`lib/statifier.ex:42-46`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier.ex#L42-L46)) is the four-member union that
makes this work.

Consequences of a shape change at this one site:

- `{:ok, document, warnings}` breaks the `with` clause on arity, not semantics -
  the match at line 62 fails outright and the three-tuple becomes `compile/1`'s
  return value, uncovered by its `@spec`.
- A third arm such as `{:warning, document, warnings}` falls through the `with`
  the same way an error does, and would silently become `compile/1`'s return.
- Either way `compile/1`'s `@spec` needs a third arm, and `compile/1` is the
  only place in `lib/` where the decision "does a warning still produce a
  Machine" can be expressed.

**`Compiler` and `Machine` never call it.** [`lib/statifier/compiler.ex:1-8`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/compiler.ex#L1-L8)
states its contract as "a validated `%Statifier.Document{}` in"; it cites
specific `Checks.*` modules as the reason a code path is unreachable at
`compiler.ex:429, 665, 927, 1175, 1186, 1442`. [`lib/statifier/machine.ex:30`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine.ex#L30)
references `Checks.Ids` in prose only.

**Nothing in `lib/` renders a validator error.** There is no `Statifier.Error`
module, no `Inspect` implementation for any pipeline error struct, no exception
module, and no formatter. The only formatter in the repo is
[`test/support/case.ex:184`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/support/case.ex#L184):

```elixir
defp format_errors(errors), do: Enum.map_join(errors, "\n", & &1.message)
```

reached from `parse_document/1` ([`test/support/case.ex:160-165`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/support/case.ex#L160-L165)), which
`flunk/1`s on `{:error, errors}` from `Statifier.compile/1`. It works across all
four stages' error types only because all four carry a `message` field with the
same name - the mirroring `error.ex:4-10` describes.

### How `<finalize>` is represented, after st-cmq.6

`<finalize>` lowers into an ordinary `%Statifier.Document.Block{}` - the same
struct `<onentry>`/`<onexit>` use - stored on `Document.Invoke.finalize`:

- `Statifier.Document.Block` ([`lib/statifier/document/block.ex:33-38`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/document/block.ex#L33-L38)):
  `@enforce_keys [:location]`, `defstruct [:location, content: []]`,
  `content: [Document.content_node()]`.
- `Document.Invoke.finalize` (`lib/statifier/document/invoke.ex:55, 71`) is
  `Block.t() | nil`. `nil` means no `<finalize>` child at all;
  `%Block{content: []}` means a written but childless one. The moduledoc calls
  this out as a 6.5 requirement (`invoke.ex:28-33`).
- `Builders.build_finalize/2` ([`lib/statifier/lowering/builders.ex:826-834`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/lowering/builders.ex#L826-L834))
  walks children into a bare `%Block{}` and tags the result `{:finalize,
  block}`; `place/3` (`builders.ex:950-951`) sets it on the parent `Invoke`.
  Dispatch entries: `"invoke"` at [`lib/statifier/lowering.ex:76`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/lowering.ex#L76), `"finalize"`
  at `:77`.

**The content-node union** ([`lib/statifier/document.ex:99-100`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/document.ex#L99-L100)):

```elixir
@type content_node :: Raise.t() | Log.t() | Assign.t() | If.t() | Foreach.t() | Script.t()
```

Six members. `Statifier.Document.Send` does not exist; neither does
`Document.Cancel`. `lib/statifier/effect/send.ex` and
`lib/statifier/effect/send_delayed.ex` are runtime `Effect` structs, not
document nodes, and lowering never builds them.

**Nesting a 6.5 walk must descend into:**

- `%Document.If{}` carries no content directly, only `branches: [Branch.t()]`
  ([`lib/statifier/document/if.ex:26-31`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/document/if.ex#L26-L31)); each `%If.Branch{}` carries
  `content: [Document.content_node()]` (`if.ex:59-66`).
- `%Document.Foreach{}` carries `content: [Document.content_node()]` flat
  (`lib/statifier/document/foreach.ex:50, 57`).
- Everything else (`Raise`, `Log`, `Assign`, `Script`) is a leaf.

**The walk to model on** is `Checks.Script`'s `descend/1`
([`lib/statifier/validator/checks/script.ex:82-92`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/checks/script.ex#L82-L92)), the most fully commented of
three identical copies (the others are `Checks.Assign`'s at `assign.ex:97-103`
and `Checks.If`'s `collect_ifs/1` at `if.ex:95-102`):

```elixir
defp descend(%DIf{branches: branches}) do
  branches |> Enum.flat_map(& &1.content) |> Enum.flat_map(&descend/1)
end

defp descend(%DForeach{content: content}), do: Enum.flat_map(content, &descend/1)

defp descend(other), do: [other]
```

applied at `script.ex:68-73` over a list of blocks. None of the three currently
reaches `Invoke.finalize` - they walk `state.onentry`, `state.onexit`,
`state.transitions`, `state.initial_element`'s transitions, and
`document.scripts`. `Checks.Invoke` reaches `invoke` (`checks/invoke.ex:36-41`)
but does not descend into `finalize.content`; `Checks.Param` reaches
`invoke.params` only (`checks/param.ex:49`).

**Compiler and interpreter both already handle it.** `build_invoke_finalize/2`
([`lib/statifier/compiler.ex:1420-1427`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/compiler.ex#L1420-L1427)) routes a populated block through
`assign_blocks/2` - the same `c_index`-assigning helper `onentry`/`onexit` use -
inline during `walk_siblings/4` while `acc.c_next` is live
(`compiler.ex:1260-1272`). `Machine.Content.owner/0`
([`lib/statifier/machine/content.ex:61-65`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine/content.ex#L61-L65)) names the case `{:finalize,
state_index, invoke_index}`. `Interpreter.apply_finalize/5`
([`lib/statifier/interpreter.ex:641-670`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L641-L670)) has three arms: `nil` is a no-op,
`%Block{content: []}` runs 6.5's auto-assign-by-namelist
(`interpreter.ex:680-704`), and a populated block runs through
`Interpreter.Content.execute_block/3`. So a `<raise>` inside `<finalize>`
executes today, exactly as st-jzc's description says.

### Prior art for a non-fatal diagnostic

**Absent entirely from `lib/`:**

- Any `{:ok, value, warnings}` return, or any struct carrying a warnings or
  diagnostics list.
- `Logger.warning`, `Logger.warn`, `IO.warn`, `:telemetry` - zero matches
  anywhere under `lib/`.
- Any `severity` or `level` field inside `lib/statifier/` with more than one
  live value.
- Any check or lowering builder that reports a finding without it being fatal.

**Present, and closest in kind:**

1. **The trace-effect tag-and-gate mechanism.** `Statifier.Effect`
   ([`lib/statifier/effect.ex:137-173`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L137-L173)) holds one closed `@type t :: core() |
   trace()` union, a `trace?/1` that splits the two by tag alone
   (`effect.ex:146-148`), and a `trace/3` macro that reads a single boolean
   `machine_state.trace` and builds the payload only when true
   (`effect.ex:161-173`). Trace effects are ordinary members of the same effect
   list, "never a side channel" (`effect.ex:63-67`). Nine payload modules live
   under `lib/statifier/effect/trace/`, each with a `new/2` that stamps
   `macrostep`/`microstep`/`round` from `MachineState`. Notably,
   `MachineState`'s `trace` field is documented as "a plain boolean, not a
   level... a later level would arrive as a separate field so this one never
   turns into a comparison" ([`lib/statifier/machine_state.ex:325-330`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L325-L330)) - the
   repo's one explicit statement about how a severity axis would arrive if it
   did.

2. **The `severity` field in the repo's own gate machinery.**
   [`lib/mix/statifier/gate_guard.ex:22-28`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/statifier/gate_guard.ex#L22-L28) types a finding with `severity:
   String.t()`, and `finding/4` (`:247-255`) sets `severity: "error"` as a
   literal. The same field/constant pair recurs in `adr_guard.ex:57, 486`,
   `adr_judge.ex:129, 643`, and the tool-crash fallbacks in
   `adr.check.ex:130`, `adr.judge.ex:133`, `gate.check.ex:120`. Seven
   construction sites, one value. The `String.t()` typing rather than a closed
   atom set is the only trace of a warning tier ever being anticipated here.

3. **Lowering's map-to-default division of labour.** `Checks.Enums`
   (`checks/enums.ex:1-12`, `:87-114`) is the worked example:
   `Lowering.Attributes.atom/4` maps an unrecognised enum value onto the
   default, and only `Location.slice/2` against `context.source` can tell
   `type="sideways"` from `type="external"`. `Document.Invoke`'s moduledoc
   (`invoke.ex:5-12, 22-26`) states the same division for the 6.4.1 pairs.
   Everything this division produces is fatal today.

**v1's answer, for contrast.** `../statifier`'s
`Statifier.Validator.validate/1` returned `{:ok, optimized_document, warnings}`
or `{:error, errors, warnings}`, both lists of bare `String.t()`, threading a
`%Validator{errors: [], warnings: []}` accumulator, with classification a
per-call-site choice between `Utils.add_error/2` and `Utils.add_warning/2`
([`docs/research/260808-st-l5k.5-document-validator.md:294-310`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/research/260808-st-l5k.5-document-validator.md#L294-L310)). Its four
warning-classified rules were unreachable states, a non-top-level document
`initial`, unreachable history, and uncompilable expressions
(`:322, :324, :331-333`). Three of the four are stated non-goals for v2, and the
fourth is an error here.

### Does a warning need a surfacing seam, and which one would carry it

ADR-0012 (`docs/adr/0012-debuggability-designed-into-the-core.md`) is about the
interpreter: its four constraints are microsteps-as-resumable-values, trace as
part of the effect vocabulary, locations and identities retained on the
**Machine**, and step counters plus cause stamps. `docs/observability.md`'s
seam table (`:177-186`) names `MachineState`, `Interpreter`, `Effect` and
`Effect.Trace.*`, `Compiler` and `Machine.State`/`Transition`/`Content`,
`Event.Cause`, and the `Interpreter.*` query modules. **The validator appears in
neither document.**

Mechanically, none of those seams is reachable from `validate/2`: it runs before
a Machine exists, has no `MachineState` to gate on, returns a value rather than
emitting effects, and there is no session boundary yet for constraint 6's
subscriber forwarding to attach to. The one thing a validator warning shares
with the ADR-0012 world is constraint 3's substrate - `Error.location` is
already a `Parser.Location`, and `Location.slice/2` against `Context.source` is
already how `Checks.Enums` recovers what the author wrote.

The nearest structural precedent for "surfaced through the same channel,
distinguishable by tag" is `Effect.trace?/1`. The nearest structural precedent
for "a second list alongside the first" is v1's own two-accumulator validator.
Decision 4 named both options ([`docs/plans/260808-st-l5k.5-document-validator.md:310-314`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260808-st-l5k.5-document-validator.md#L310-L314))
and chose neither at the time.

There is one relevant precedent for declining a seam on the observability side:
st-cmq.6 decided against a `Trace.InvokeSet` row on the grounds that
"`Effect.Invoke` is a *core* effect and is therefore already visible with
`trace: false`; a trace row would be additive observability with no caller"
([`docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md:196-199`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md#L196-L199)).

### Tests and the corpus harness

**Assertion idioms.** Three shapes, none shared through a helper module:

1. `assert {:ok, ^document} = Validator.validate(document, @valid_document)` -
   pins that the input document is returned unchanged
   (`test/statifier/validator_test.exs:141, 152`;
   [`test/statifier/validator/checks/ids_test.exs:250`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/validator/checks/ids_test.exs#L250)).
2. Collect-all assertions in [`test/statifier/validator_test.exs:185-203`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/validator_test.exs#L185-L203):
   `{:error, errors}`, then `length(errors) == 6`, then per-reason matches
   through a local `find/2` (`:15-17`, comparing `Error.code(error.reason)`),
   then `offsets == Enum.sort(offsets)` for the document-order contract.
3. Per-check files (18 under `test/statifier/validator/checks/`) each define
   their own `lower!/1` and often a local `validate!/1` wrapper, then assert
   `{:error, [%Error{reason: {...}}]}` plus a `location.start_line`, or
   `{:ok, %Document{}}` for the negative case.

`test/statifier/validator/layer_test.exs` is structural rather than behavioral -
it AST-walks `error.ex` and the checks directory to assert the one-reason,
one-constructor, one-producer invariant. It carries `# sabotage: n/a` markers at
`:108-110, 119-124, 137-142`.

**Call-site count.** 1 in `lib/` ([`lib/statifier.ex:62`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier.ex#L62)) and 71 across 25 files
in `test/`. Roughly 55 of the test sites are `{:ok, document} =
Validator.validate(document, xml)` fixture setup in tests that are not about
validation at all - compiler, interpreter, evaluator, machine, and session
tests. The remaining ~16 are validator-specific.

**The harness.** `Statifier.Case.test_scxml/4` ([`test/support/case.ex:82-97`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/support/case.ex#L82-L97),
`@spec ... :: :ok` at `:76-81`) never calls `Validator` directly. It calls
`Statifier.compile/1` inside `parse_document/1` (`:160-165`), which returns the
bare `machine` on success and `flunk/1`s on error. There is **no channel** from
`validate/2`'s success arm to a corpus test today: `{:ok, document}` is
destructured inside `compile/1`'s `with`, and only `document` proceeds. A
warnings payload would need new plumbing through `compile/1`'s `with`, a
decision about where it rides (a third tuple element, a field on `Machine`), and
new arms in `parse_document/1` and `test_scxml/4`'s `@spec`. Note also that
`validate_features!/2` (`case.ex:99-117`) runs *before* `parse_document/1`, so
an unsupported-feature document never reaches the validator stage at all.

**Corpus tests.** Every generated file under `test/scion_tests/` and
`test/scxml_tests/` is `use Statifier.Case` + a `@moduletag` + a heredoc + one
`test_scxml/4` call (e.g. [`test/scion_tests/basic/basic0_test.exs:1-42`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/scion_tests/basic/basic0_test.exs#L1-L42)). A grep
for `Validator|validate(` matches none of them. All corpus assertion goes
through `assert_configuration/3` (`case.ex:121-130`), comparing active-leaf-state
sets. A return-shape change touches the corpus only through `test_scxml/4`.

**The ratchet.** `test/passing_tests.json` is a registry of file globs with a
`last_updated` field - no per-test expected-error or expected-warning data.
`Mix.Tasks.Test.Regression` ([`lib/mix/tasks/test.regression.ex:42-141`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/tasks/test.regression.ex#L42-L141)) resolves
the registry to a file list and shells out to `mix test`, reading only the exit
status (`:90, :96-100`). A warning-producing-but-passing document is invisible
to it unless some test starts asserting on the warning in a way that changes
exit status. The registry format and the task need no change.

**The corpus generator.** `tools/corpus/` has exactly one match for
`Validator|validate`, and it is spec prose in an exclusion reason
([`tools/corpus/scxml_w3/exclusions.exs:17`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/tools/corpus/scxml_w3/exclusions.exs#L17)). The generator fetches upstream
sources, transforms them with Saxon/XSLT, and emits `.exs` files at `mise run
corpus` time. It never calls `Statifier.compile/1` or `Validator.validate/2`. A
return-shape change does not touch this directory.

**Corpus state for `<invoke>`.** Per st-cmq.6's plan (`:120-127`), 35 emitted
W3C mandatory files carry `required_features: [:invoke_elements]` and `flunk`
through the feature gate; `FeatureDetector` classifies both `invoke_elements`
and `finalize_elements` as `:unsupported`
([`test/support/feature_detector.ex:112-113`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/support/feature_detector.ex#L112-L113)), and none of the 35 is in
`test/passing_tests.json`.

## Code References

- [`lib/statifier/validator.ex:53-72`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator.ex#L53-L72) - the `@checks` list, 18 captured `check/2` closures
- [`lib/statifier/validator.ex:87-99`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator.ex#L87-L99) - `validate/2`: flat-map, sort by offset, `{:ok, document} | {:error, errors}`
- [`lib/statifier/validator/error.ex:33-73`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/error.ex#L33-L73) - the closed 41-variant `reason` union
- [`lib/statifier/validator/error.ex:75-82`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/error.ex#L75-L82) - the three-field struct, no severity
- [`lib/statifier/validator/error.ex:87-88`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/error.ex#L87-L88) - `code/1`, the tag-atom extractor nothing in `lib/` calls
- [`lib/statifier/validator/checks/invoke.ex:36-53`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/checks/invoke.ex#L36-L53) - the walk a 6.5 check would extend
- [`lib/statifier/validator/checks/script.ex:68-92`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/checks/script.ex#L68-L92) - the recursive `descend/1` through `<if>` branches and `<foreach>` bodies
- [`lib/statifier/validator/checks/enums.ex:87-114`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/checks/enums.ex#L87-L114) - `out_of_range/5`, the slice-back-from-source shape
- [`lib/statifier/validator/context.ex:33-63`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator/context.ex#L33-L63) - the per-call index, including `source`
- [`lib/statifier.ex:42-46`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier.ex#L42-L46) - the four-stage `error()` union
- [`lib/statifier.ex:59-65`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier.ex#L59-L65) - the sole production caller, a `with` chain
- [`lib/statifier/document.ex:99-100`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/document.ex#L99-L100) - `content_node()`, six members, no `Send`
- [`lib/statifier/document/block.ex:33-38`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/document/block.ex#L33-L38) - the `Block` struct `<finalize>` reuses
- `lib/statifier/document/invoke.ex:28-33, 55, 71` - `finalize`, absent versus empty
- [`lib/statifier/lowering.ex:53-78`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/lowering.ex#L53-L78) - the 24-entry dispatch map; no `"send"` key
- [`lib/statifier/lowering.ex:149-155`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/lowering.ex#L149-L155) - the `:error` branch that makes `<send>` a lowering error
- [`lib/statifier/lowering/error.ex:44-50`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/lowering/error.ex#L44-L50) - `unsupported/2`, `{:unsupported_element, name}`
- `lib/statifier/lowering/builders.ex:826-834, 950-951` - `build_finalize/2` and its `place/3`
- [`lib/statifier/compiler.ex:1420-1427`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/compiler.ex#L1420-L1427) - `build_invoke_finalize/2`
- [`lib/statifier/interpreter.ex:641-670`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/interpreter.ex#L641-L670) - `apply_finalize/5`'s three arms
- [`lib/statifier/effect.ex:137-173`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/effect.ex#L137-L173) - the effect union, `trace?/1`, and the `trace/3` gate
- [`lib/statifier/machine_state.ex:325-330`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/machine_state.ex#L325-L330) - "a plain boolean, not a level"
- `lib/mix/statifier/gate_guard.ex:22-28, 247-255` - `severity: String.t()`, always `"error"`
- `test/support/case.ex:160-165, 184` - `parse_document/1` and the repo's only error formatter
- [`test/statifier/validator_test.exs:185-203`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/test/statifier/validator_test.exs#L185-L203) - the collect-all and document-order assertions
- `test/statifier/validator/layer_test.exs` - the structural one-reason-one-constructor test
- [`lib/mix/tasks/test.regression.ex:42-141`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/mix/tasks/test.regression.ex#L42-L141) - the ratchet, which reads exit status only

## Architecture Documentation

- **[`docs/architecture.md:36-39`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/architecture.md#L36-L39), principle 4** - "Make invalid states
  unrepresentable. Parsing produces a `Document`; validation produces a distinct
  `Machine` type... The interpreter only accepts a `Machine`, so 'validate if
  not already validated' fallback branches do not exist." `Statifier.Validator`'s
  own moduledoc calls itself "the only gate in front of the Machine compiler"
  ([`lib/statifier/validator.ex:3-8`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier/validator.ex#L3-L8)). A finding that does not gate is, by
  construction, outside what principle 4 describes; it does not contradict the
  principle, which is about the Machine type, but the validator's moduledoc
  wording would need revisiting.
- **ADR-0012 and `docs/observability.md`** - all six constraints and every row
  of the seam table (`:177-186`) name interpreter- or Machine-side homes. The
  validator is absent from both.
- **ADR-0002** (literal Appendix D port) - unaffected; 6.5's children rule is a
  document-conformance clause, not pseudocode.
- **ADR-0003** (pure core with effects) - the validator is already pure and
  already returns data rather than emitting; a warnings list stays inside that.
- **ADR-0026** - already narrowed `Checks.Script`'s remaining job by moving the
  `src`-and-content half of 5.8.2 into a lowering refusal
  (`error.ex:664-673`). The same move is what makes `<send>` inside
  `<finalize>` a lowering error today, and is the closest precedent for "the
  layer that holds the line is a decision, not a given".
- **ADR-0018** - no process jargon in code comments; a new reason's `@doc`
  should read like the 41 already there, citing the clause rather than the bead.

## Historical Context

- **[`docs/plans/260808-st-l5k.5-document-validator.md:296-314`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260808-st-l5k.5-document-validator.md#L296-L314), Decision 4** -
  the decision this bead reopens. "`{:ok, document} | {:error, [Error.t()]}`,
  exactly as the bead states. No warning list, no `:strict` option." Rationale:
  every check is a spec MUST; v1's four warnings are each a stated non-goal or
  an error here; "that leaves a warning channel with zero producers, which is
  speculative API." And the forward-compatibility note: "Decision 3's struct
  shape makes adding a channel later purely additive - a `{:ok, document,
  warnings}` arm or a second list needs no change to any existing reason.
  Deferring costs nothing."
- **[`docs/plans/260808-st-700-relaxed-parsing-options.md:29`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260808-st-700-relaxed-parsing-options.md#L29)** - assigns
  `:strict` (warnings-as-errors) to st-l5k.5, which declined it on the grounds
  that "a warnings-as-errors switch is meaningless while nothing warns." If a
  warning tier lands, `:strict` becomes meaningful and is currently homeless.
- **`docs/plans/260812-st-t8w-idless-compound-final-validator.md`** - reaffirmed
  Decision 4 rather than opening the tier, making the id-less-compound-`<final>`
  case a hard error. A prior instance of exactly this question, answered the
  other way.
- **[`docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md:187-191`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md#L187-L191)** -
  the deferral that created this bead: "**No 6.5 `<send>` and `<raise>` MUST NOT
  occur inside `<finalize>` check.** The validator has no warning tier, so
  expressing this would mean rejecting documents - a conformance constraint on
  *authors* turned into an engine refusal. Recorded here rather than silently
  skipped; revisit if a warning tier ever lands."
- **`docs/plans/260815-st-cmq.6-...:357-375`, Decision 6** - finalize runs in
  the pure core, and the reasoning leans on 6.5: "6.5 bans `<send>` and
  `<raise>` inside it, so nothing impure can appear there in a conformant
  document". The unchecked ban is load-bearing for that decision.
- **[`docs/research/260808-st-l5k.5-document-validator.md:294-334`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/research/260808-st-l5k.5-document-validator.md#L294-L334)** - the v1
  validator audit: its `{:ok, document, warnings}` shape, its two-accumulator
  `Utils.add_error/2` / `Utils.add_warning/2` split, and the four rules it
  classified as warnings.

## Related Research

- `docs/research/260808-st-l5k.5-document-validator.md` - the validator's
  founding research, including Open Question 4 on warnings
- `docs/research/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md` - the
  `<invoke>`/`<finalize>` lowering research this bead descends from
- `docs/plans/260808-st-l5k.5-document-validator.md` - Decision 4
- `docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md` -
  Decisions 4 and 6, and the deferral note
- `docs/adr/0014-expression-spans-in-cond-diagnostics.md` - the adjacent
  diagnostics ADR, amended 2026-08-15 to stop at the predicator seam
- `docs/adr/0026-script-as-predicator-statement-programs.md` - the precedent for
  moving a MUST's enforcement from the validator into lowering

## Open Questions

Recorded here rather than asked, since no human was available during this
research. None of these is decided by this document.

1. **Which half of 6.5 is actually checkable today.** `<send>` cannot appear in
   a lowered `Document` at all - it is an `{:unsupported_element, "send"}`
   lowering error before the validator runs. A 6.5 check written now can only
   observe `<raise>`. Options visible in the codebase: write the check for
   `<raise>` only and let the `<send>` arm arrive with `<send>`; write both arms
   with the `<send>` one dead until then; or note that when `<send>` lands, its
   builder could carry the finalize rule itself the way ADR-0026 moved 5.8.2's
   `src` half into lowering. The bead's acceptance criteria say "reports
   `<send>`/`<raise>` under `<finalize>`", which the first option satisfies only
   partially.
2. **Whether the rule is the two element names or the general clause.** 6.5.2's
   MUST NOT is on "raise events or invoke external actions", with `<send>` and
   `<raise>` as the named instance. A nested `<invoke>` is not currently
   representable inside a `Block` (`content_node()` has no `Invoke` member), so
   the general reading has no additional producers today - but the reason tag
   and its `@doc` will encode one reading or the other.
3. **Where a warning rides, and whether a warned document still compiles.**
   `Statifier.compile/1` ([`lib/statifier.ex:59-65`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/lib/statifier.ex#L59-L65)) is the only place that can
   express it. A third tuple element from `validate/2` forces a decision about
   what `compile/1` returns, since its own `{:ok, Machine.t()}` has no room for
   a warnings list without either a third element of its own or a field on
   `Machine`. Nothing in the repo currently carries diagnostics past the
   compiler boundary.
4. **Whether `Error` gains a `severity` field or warnings get a separate
   struct.** The existing struct has three enforced fields and 41 reasons, and
   `test/statifier/validator/layer_test.exs` asserts a one-reason-one-constructor
   invariant over the whole file. A `severity` field is the smaller diff; a
   separate `Warning` struct keeps the `reason` unions disjoint the way
   `Validator.Error` and `Lowering.Error` are kept disjoint today
   (`error.ex:4-10`). `MachineState`'s `trace` field carries the repo's one
   stated preference on this shape - "a later level would arrive as a separate
   field so this one never turns into a comparison"
   (`machine_state.ex:325-330`) - but that is about a boolean, not about an
   error struct.
5. **Whether any existing check moves.** The table under "which checks reject
   what the engine could run past" lists roughly 20 reasons across 11 checks
   whose documents the interpreter could execute. The bead says to consider it;
   this document reports the candidates and does not choose. Two constraints on
   whoever does: several of those reasons exist only because lowering
   deliberately declined to refuse the shape, so reclassifying them re-opens
   which layer holds the line; and the bead's own acceptance criteria say
   "existing checks' pass/reject behavior is unchanged".
6. **Whether `:strict` lands with the tier.**
   [`docs/plans/260808-st-700-relaxed-parsing-options.md:29`](https://github.com/riddler/statifier-ex/blob/b52208e6f8d1aaa1be70427b803fa97d0a4f6824/docs/plans/260808-st-700-relaxed-parsing-options.md#L29) assigns
   warnings-as-errors to the validator bead, and Decision 4 declined it only
   because nothing warned. The moment something warns, the option has a meaning
   and no home.
7. **Whether a warning needs a surfacing seam at all right now.** ADR-0012's
   seams are all interpreter- and Machine-side, and none is reachable from
   `validate/2`. The return value is itself a surfacing channel for the one
   production caller. st-cmq.6's "additive observability with no caller"
   reasoning (`:196-199`) is the nearest precedent for declining a seam; nothing
   in `lib/` renders a validator finding today, so a warning would reach a user
   only through whatever `Statifier.compile/1` hands back.
