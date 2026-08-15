# ADR-0032: The round budget spans the invoke pass's re-entry

Status: accepted (2026-08-15) - amends 0019 in part

## Context

Appendix D's `mainEventLoop` re-enters its own body with `continue` after
the invoke pass, when invoking left the internal queue non-empty:

```
macrostep(externalEvent)
if not running:
    break
for state in statesToInvoke.sort(entryOrder):
    for inv in state.invoke.sort(documentOrder):
        invoke(inv)
statesToInvoke.clear()
if not internalQueue.isEmpty():
    continue
```

In this port `main_event_loop/1` **is** that outer body - the fold ADR-0019
bounds lives inside it, called once per pass through the loop - so
Appendix D's `continue` becomes a self-call of `main_event_loop`, and each
self-call re-enters `macrostep/1`, which today starts a fresh
`max_macrostep_rounds` budget on every call.

That reopens exactly the hole ADR-0019 closed, one loop further out.
ADR-0019's Context describes a livelock where a deterministically erroring
`cond` on an eventless transition hands control back and forth between
rounds of one fold forever, with no external entity able to cancel it from
inside the pure core. The same shape now composes across invoke re-entries
instead of within one fold: two states whose `<invoke>` arguments
deterministically fail (ADR-0031's failure path) can hand each other
control forever. Each state's macrostep terminates within its own budget;
each state's invoke pass raises `error.execution` for the failing
argument; the post-invoke re-check sees a non-empty internal queue and
`continue`s; the next macrostep starts with a fresh budget and repeats.
The pure core still has no external entity to cancel it - ADR-0019's own
words, one loop further out:

> Inside `Statifier.Interpreter.macrostep/1`'s fold there is no external
> entity: a macrostep that never reaches quiescence never returns, and the
> calling process hangs with no recourse short of killing it.

ADR-0019's Decision scoped the budget to one fold: "each `microstep/1`
call within one fold consumes one round", with the rounds-spent count "a
fold-local accumulator, threaded through the private `macrostep/2`
(becoming `macrostep/3`)". Its Consequences state "a later `handle_event/2`
on the returned machine_state begins a new macrostep with a fresh
budget" - true of a single fold within one external call, and silent about
a second fold inside the same call reached by an invoke re-entry rather
than a new `handle_event/2`. Narrowing "per fold" to "per
`main_event_loop/1` call" is therefore an amendment to that Decision, not
an application of it, and the house record for a narrowing amendment is
the amends-in-part form ADR-0020 already used against this same record.

## Decision

**The round budget is spent across the whole `main_event_loop/1` call,
including every invoke re-entry, not reset per fold.** The budget is
threaded through a new private `main_event_loop/3` exactly as it is
already threaded through the private `macrostep/3`: the private
`macrostep/3`'s return grows a fourth element, `rounds_left`, and
`main_event_loop/3` passes the `rounds_left` one fold returned as the
budget for the next fold it starts on re-entry, rather than
`machine_state.max_macrostep_rounds` again.

**`terminal_effects/2` moves from `macrostep/1` to `main_event_loop/3`, so
exactly one terminal effect is emitted per `main_event_loop/1` call.**
Today `macrostep/1` appends `terminal_effects/2` once, at the end of its
one fold. With re-entries possible, appending it inside each fold would
emit one terminal-effect row per re-entry - `Trace.MacrostepStable`,
`Effect.Done`, or `Effect.BudgetExhausted` two or more times for what is,
from `handle_event/2`'s caller's perspective, one call. `main_event_loop/3`
instead calls the private `macrostep/3` directly with the budget it is
carrying and appends `terminal_effects/2` exactly once, when it stops
looping: from the last fold's `outcome` when the internal queue is empty,
or from `:budget_exhausted` when the loop wants to re-enter and
`rounds_left` was `0`. This is what keeps ADR-0019's three-outcome
exclusivity - "the three macrostep outcomes (stable, done,
budget-exhausted) stay mutually exclusive per macrostep" - true across a
re-entry: without the move, a fold that both reaches quiescence and leaves
the budget exhausted could emit both a stable row and a budget-exhausted
row for the same call.

**`Effect.BudgetExhausted`'s shape and its `budget` field's meaning are
unchanged.** The field still reports `machine_state.max_macrostep_rounds`,
the budget that was granted at the start of the `main_event_loop/1` call.
ADR-0032 does not edit what the field means - only its scope, from "spent
within one fold" to "spent within one call, across every fold that call's
re-entries produce" - which is the amendment itself.

**Public `macrostep/1` keeps its arity, signature, and behavior.** It
calls the private `macrostep/3` once with `ms.max_macrostep_rounds`,
discards the returned `rounds_left`, and appends `terminal_effects/2`
itself, exactly as `main_event_loop/3` does for its own last fold. Every
existing caller and every existing test of `macrostep/1` is untouched;
only `main_event_loop/1`'s internal delegation changes shape.

**The ADR-0002 mechanical-deviation comment for this narrowing sits
immediately above `defp main_event_loop/3` in `lib/statifier/interpreter.ex`**,
the private function that carries the budget across re-entries, joining
the existing hoisting comment ADR-0019 placed above `defp macrostep/3`
in the same module. Appendix D's `continue` has no notion of a budget at
all; the comment cites this record rather than re-deriving the argument
inline.

For a document with no `<invoke>`, the invoke pass produces no
invocations, `states_to_invoke` clears to empty, the internal queue is
whatever the fold already left it as, and the loop runs exactly one fold
and emits exactly one terminal effect - byte-identical to today's
behavior. The existing macrostep and budget test suites passing unchanged
is the proof of that equivalence.

## Consequences

- A chart whose invoke arguments deterministically and repeatedly fail
  terminates with a defined `{:budget_exhausted, _}` outcome within
  `max_macrostep_rounds` rounds of the whole `main_event_loop/1` call,
  rather than looping across re-entries indefinitely - the same guarantee
  ADR-0019 gives within one fold, now given across the outer loop ADR-0031
  and Appendix D's invoke pass add.
- `ADR-0019`'s Decision and Consequences stand for a single fold reached
  from one `handle_event/2` call with no invoke re-entry; this record
  narrows "per fold" to "per `main_event_loop/1` call" for the case a fold
  is reached via re-entry instead. A later, distinct `handle_event/2` call
  still begins with a fresh `machine_state.max_macrostep_rounds` budget,
  exactly as ADR-0019 states - this record does not touch that boundary.
- `terminal_effects/2`'s call site moves, but its own behavior - which
  effect it appends for which outcome - is unchanged. The move is what
  makes the site of the ADR-0002 deviation comment `main_event_loop/3`
  rather than `macrostep/3` for this particular narrowing, even though
  `macrostep/3` still carries ADR-0019's original comment for the
  within-fold budget itself.
- Public `macrostep/1`'s signature, arity, and observable behavior are
  unchanged; no existing caller or test needs to change because of this
  record.
- A future reader diffing `main_event_loop/1` against Appendix D's outer
  loop finds this record at the `continue` self-call, rather than
  re-deriving why a re-entry does not get a fresh budget from the code
  alone.
