# ADR-0071: A chart's event vocabulary and its accepts check are pure functions on `Statifier.Chart`, outside `Statifier.Validator`

Status: proposed - adds two public functions, `Statifier.Chart.events/1`
and `Statifier.Chart.check_accepts/2`, and two optional keys to a
statifier case's `host` object; widens `Statifier.Chart`'s stated scope
from the binary contract alone to questions a host asks about a chart
without running it; amends no record

## Context

A host that publishes a chart for other parties to send events to wants
to know, before the chart is live, which event names the chart will
listen for. Two questions follow. What is the chart's event vocabulary,
computed from the chart itself? And when the author (or the host)
declares the names the chart accepts, where does the declaration and the
chart disagree? Today neither question has a function in this library.
Every code, schema and corpus cite in this record was read at `555f15a`;
re-locate each by its anchor.

**No function computes the vocabulary.** `Statifier.Chart`
(`lib/statifier/chart.ex`) holds `format_version/0`, `to_binary/1` and
`from_binary/1` and nothing else, and nothing in `lib/` defines an
`events` function. The raw material is in the compiled chart:
`Statifier.Machine.Transition`'s `events` field is `[[String.t()]]`, one
dot-split token list per whitespace-separated descriptor in the
transition's `event` attribute, split once at compile time (that
module's moduledoc). `Statifier.Machine.State`'s `transitions` field
lists a state's own selectable transitions; an `<initial>` element's
transition and a history's default live in `initial_transition` and
`history_default` instead (the same moduledoc), and spec 3.3 and 3.6 give
neither an `event` attribute.

**Descriptor matching exists once.** `Statifier.Interpreter.NameMatch`
is Appendix D's `nameMatch` under ADR-0002's naming amendment:
`name_match?/2` answers whether any of a list of descriptors matches an
event name's tokens, on token boundaries, with a trailing `*` or a
trailing `.` dropped before the prefix test, and `tokenize/1` splits an
event name into those tokens. `Statifier.Interpreter.Selection` calls
`name_match?/2` when it selects transitions for an event.

**The runtime has no refusal for an event name.** Appendix D's
`mainEventLoop` dequeues an external event, selects transitions for it,
and runs a microstep only `if not enabledTransitions.isEmpty()`. An event
that no transition matches changes no configuration and raises nothing.
A chart that never listens for a name a sender relies on fails quietly,
which is the case for checking it before the chart is published.

**The precedent for a deployment check outside the Validator.**
[ADR-0069](0069-host-registered-send-types.md) decision 3 puts its
pre-start check of a chart's `<send type>` values outside
`Statifier.Validator`: "It lives outside `Statifier.Validator`, whose
`validate/3` judges a document against the spec and takes no deployment
state". The check it describes is `Statifier.Send.Types.unsupported_sends/2`
(`lib/statifier/send/types.ex`), whose `@doc` calls it "Pure and total. A
host calls it with a compiled chart and the set it will start the chart
with". `Statifier.Validator.validate/3` (`lib/statifier/validator.ex`)
still takes a document, its source and one keyword list.

**`Statifier.Chart`'s own contract.** Its moduledoc opens "The versioned
binary contract for a *chart*", argues that the pair could not live on
`Statifier.Machine` because it calls back into `Statifier.compile/2`, and
keeps the dependency pointing one way: `Statifier.Chart` depends on
`Statifier` and `Statifier.Machine`, never the reverse. It performs no
I/O.

**The corpus.** `conformance/schema/case.json` has no top-level
expectation object: a case's top-level keys are fixed and
`additionalProperties` is `false`. Every host-side expectation already
lives inside the optional `host` object, which today holds `send_types`
and `expect_sends` and is itself `additionalProperties: false`; the
schema's `allOf` refuses `host` on scion and w3c cases.
`Mix.Statifier.Corpus.Json`'s `@key_order` (`lib/mix/statifier/corpus/json.ex`)
fixes the written key order, and `Mix.Statifier.Corpus.HostCase.run/1`
(`lib/mix/statifier/corpus/host_case.ex`) runs a case that carries a
`host` object.

## Decision

**1. `Statifier.Chart.events/1` computes a chart's event vocabulary from
the compiled chart: every event descriptor on a transition whose source
state can be active.** It takes a `%Statifier.Machine{}` and returns
`[String.t()]`. It reads no source text, needs no `identity` or `source`
on the machine, and runs nothing.

- **Each descriptor is returned as authored.** The token list is joined
  back with `.`, which reconstructs the descriptor exactly because the
  compile-time split is by `.` alone: `loan.renew` returns `loan.renew`,
  and a descriptor written `loan.` returns `loan.`.
- **A pattern is reported as a pattern, never expanded.** `*` and
  `loan.*` are returned as written. The function never guesses which
  names a pattern stands for.
- **Order and duplicates.** Descriptors appear in `t_index` order (states
  in document order, each state's own transitions in the order it wrote
  them, before its children's), and within one `event`
  attribute in the order written. A descriptor equal, as a string, to one
  already returned is dropped.
- **An eventless transition contributes nothing.** A chart with no
  transition carrying an `event` returns `[]`.
- **A child chart is its own chart.** A document given inline to
  `<invoke>` has its own vocabulary; `events/1` reads only the machine it
  is given.
- **Platform and internal descriptors are included.** A `done.state.`
  or `error.` descriptor, or a name the chart raises itself, is a
  descriptor the chart listens for, and `events/1` reports
  it. Telling a name a host sends from one the engine or the chart
  produces would mean reading `<raise>`, `<send>` and `eventexpr` values
  and guessing at the last; the function does not.

**2. "Can be active" is a static rule over the chart's structure: a
state some path enters, its ancestors included.** A state is *entered*
when it is in the least set closed under these rules, which follow
Appendix D's `addDescendantStatesToEnter` and
`addAncestorStatesToEnter`:

- The root is entered by its default.
- Entering a state by its default enters it and then: for a compound
  state (or the root), its `initial` states as targets
  (`Statifier.Machine.State`'s `initial`, which the compiler has already
  resolved from the `initial` attribute, the `<initial>` element, or the
  first child); for a parallel state, every child that is not a history
  by its default; for a history pseudo-state, the targets of its
  `history_default` transition as targets.
- Entering a state as a target enters it by its default, enters each of
  its proper ancestors, and, for each parallel ancestor, enters by its
  default every child region that holds none of the transition's targets.
- For every entered state, every transition in its `transitions` enters
  its targets as targets. A transition's `cond` and `event` are not
  read: a condition is an expression, and the rule never guesses at one,
  so a transition whose condition is never true in practice still counts.

A state's descriptors join the vocabulary when the state is entered and
is not a history pseudo-state (a history is never in a configuration).
The answers this gives, each to be decided by a test on the code that
implements it:

- **A transition on an ancestor of an active state is reachable.** Every
  proper ancestor of an entered state is entered.
- **A descriptor on a state no path enters is not in the vocabulary.** A
  state that no default entry and no transition target reaches is never
  entered, and its transitions contribute nothing.
- **A history pseudo-state's default target counts as entered.** A
  restored history configuration adds no state, because it re-enters
  only states that were active before, which some other path entered.
- **Every region of a reachable parallel state is reachable.**

The rule over-approximates the executions a chart can have and never
under-approximates them: a descriptor missing from `events/1` is one the
chart can never select on.

**3. `Statifier.Chart.check_accepts/2` compares a declaration with the
vocabulary.** It takes the machine and `declared`, a list of event names
or `nil`, and returns
`%{unreachable: [String.t()], undeclared: [String.t()]}`.

- **Matching is descriptor semantics, one relation both ways.** A
  descriptor *matches* a declared name when
  `Statifier.Interpreter.NameMatch.name_match?/2` answers `true` for the
  descriptor's tokens and the name's `tokenize/1` tokens: the same test
  selection runs at runtime. A declared `loan.renew` is matched by the
  descriptor `loan.renew`, by `loan.*`, by `loan`, and by `*`.
- **`unreachable`** lists each declared name that no descriptor in
  `events/1` matches, in the declaration's order, without duplicates: a
  name the declaration promises and the chart can never select on.
- **`undeclared`** lists each descriptor in `events/1` that matches no
  declared name, in `events/1`'s order: a name the chart listens for that
  the declaration does not state.
- **A declared entry is a name, not a descriptor.** The declaration is
  name-only in this record (no payload shape), and a `*` in a declared
  entry is read as an ordinary token, never as a pattern.
- **An empty list is a declaration.** `check_accepts(machine, [])`
  declares that the chart accepts nothing: `unreachable` is `[]` and
  `undeclared` is all of `events/1`.

The function reports and refuses nothing. Which list a host refuses a
publish on, if either, is the host's decision.

**4. A `nil` declaration makes the computed vocabulary the contract, and
membership is asked through the same function.**

- `check_accepts(machine, nil)` answers `%{unreachable: [], undeclared: []}`:
  with no declaration, `events/1` is the contract, and a contract cannot
  disagree with itself.
- **Membership for a receiver that declares nothing.** A host asking "is
  the name `n` in this chart's computed vocabulary" calls
  `check_accepts(machine, [n])` and reads `unreachable`: `[]` means some
  reachable descriptor matches `n`, and `[n]` means none does. This is
  the same relation as decision 3 applied to a one-name declaration, so
  no third public function is needed, and a caller never re-implements
  pattern matching over the strings `events/1` returns.

**5. Both functions live in `Statifier.Chart`, outside
`Statifier.Validator`, for the reason ADR-0069 decision 3 gives
(`docs/adr/0069-host-registered-send-types.md`).** A
declaration of accepted names is deployment state: it is a claim a host
or an author makes beside a chart, not a property the spec defines for a
document. `Statifier.Validator.validate/3` judges a document against the
spec and takes no deployment state, so a check that compares a chart
with a declaration does not go there, exactly as
`Statifier.Send.Types.unsupported_sends/2` does not. Both functions take
the same posture as that check: pure and total over their typed
arguments, called by a host with a compiled chart, before any execution
starts.

The module is `Statifier.Chart` rather than `Statifier.Send.Types` or
`Statifier.Machine`:

- `Statifier.Send.Types` is the registered send-type set and its
  classifier; an event vocabulary is not a question about a send type.
- `Statifier.Machine` is the compiled struct and the structural queries
  the interpreter walks. `check_accepts/2` calls
  `Statifier.Interpreter.NameMatch`, and putting it on `Statifier.Machine`
  would point the compiled struct's module at the interpreter.
- `Statifier.Chart` already sits outside the core, depends on
  `Statifier.Machine` and never the reverse, and performs no I/O. Both
  functions keep all three properties. What they change is the
  moduledoc's scope: it widens from "the versioned binary contract for a
  chart" to the questions a host asks about a chart without running it,
  of which the binary contract is one. Nothing in the module's existing
  contract conflicts: `to_binary/1`'s refusal of an unidentified chart
  does not apply, since neither function writes or reads a binary.

**6. The runtime stays the backstop and is unchanged.** Nothing here
adds a runtime check, a finding to `Statifier.Validator`, or a field to
any struct. An event that reaches a running chart and matches no enabled
transition does what it does today: no transition fires and the
configuration is unchanged.

**7. The corpus carries the check inside a statifier case's `host`
object.** `conformance/schema/case.json`'s `host` gains two optional
keys, present together or not at all:

- `declared_events`: an array of event-name strings, unique, possibly
  empty, the `declared` argument.
- `expect_accepts`: an object with exactly two array-of-string keys,
  `unreachable` and `undeclared`, the expected result in decision 3's
  order.

The expectation goes inside `host`, beside `expect_sends`, not in a new
top-level object: the top level carries no expectation object today and
is closed, every host-side expectation already lives in `host`, and the
schema's existing `allOf` already keeps `host` off scion and w3c cases,
so the new keys are statifier-only with no new conditional. The writer's
`@key_order` and the runner that executes host cases move with the
schema: a case carrying `declared_events` is run as any host case is,
and the runner also calls `check_accepts/2` with it and compares both
lists exactly, order included. Such a case sits under
`conformance/cases/accepts/`.

**The example is the library loan chart** (the chart
`conformance/cases/library/loan_renew_within_limit.scxml` carries). Its
states are all entered, and `events/1` answers

```
["copy.returned", "copy.disputed", "loan.renew", "loan.due_soon",
 "loan.due", "loan.lost", "dispute.resolved"]
```

(`active`'s own two transitions precede its children's in `t_index`
order, and `due_soon`'s `loan.due` is a duplicate of `on_loan`'s). A
declaration of `loan.renew`, `copy.returned` and `loan.archived` answers

```
%{unreachable: ["loan.archived"],
  undeclared: ["copy.disputed", "loan.due_soon", "loan.due",
               "loan.lost", "dispute.resolved"]}
```

`loan.archived` is unreachable because no transition in the chart
listens for it.

## What this record does not decide

- Where a host stores a declaration, or whether it travels with a chart's
  binary form. `to_binary/1`'s payload is unchanged.
- Which of the two lists a host refuses a publish on.
- A receiver-side check at delivery time, for a host that routes events
  between executions. That belongs to the router's own record; decision 4
  gives it the engine's membership answer for a receiver that declares
  nothing.
- Payload shapes. A declaration names events and nothing about their data.
- A vocabulary for `<invoke>` children, `done.invoke` events, or any
  name a chart sends rather than listens for.

## Consequences

- Two public functions join `Statifier.Chart`, each with an `@spec` and
  a `@doc` that states decision 2's rule and decision 1's never-expand
  rule. `events/1` lands first; `check_accepts/2` builds on it.
- `Statifier.Chart`'s moduledoc gains a section for the widened scope of
  decision 5.
- A host's publish step can refuse a chart whose declaration promises a
  name the chart never selects on, before any execution exists; an
  editor can show the same two lists at edit time from the same function.
- The case schema, the writer's key order, the host-case runner and the
  generated corpus change together when the corpus half lands, and a
  sibling implementation proves the same check from the same case.
- The vocabulary over-approximates: a descriptor behind a condition that
  is never true still appears. A tighter answer would have to evaluate
  expressions, which this library does not do before a chart runs.

## Related

- [ADR-0069](0069-host-registered-send-types.md) (decision 3: the pre-start check outside `Statifier.Validator`, the posture both functions take)
- [ADR-0002](0002-literal-w3c-appendix-d-port.md) (Appendix D's `nameMatch` and the entry procedures decision 2 follows)
- [ADR-0003](0003-pure-core-with-effects.md) (the layering decision 5 keeps)
- [ADR-0070](0070-statifier-emits-a-language-neutral-conformance-corpus.md) (the corpus, the `host` object and the statifier suite decision 7 extends)
