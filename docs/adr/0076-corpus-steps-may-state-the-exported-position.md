# ADR-0076: A statifier corpus step may state the exported position it leaves, in a JSON rendering with the engine-local fields left out

Status: accepted (2026-10-02) - extends ADR-0070 decision 2 (what a case
asserts) with one optional step member on `statifier` cases; adds the
corpus schema's `expect_position` and the runner's check of it; changes
no public function, struct, effect or position field, and no answer an
existing function gives

## Context

A sibling implementation of this engine that exports and imports its
state in the string-id vocabulary of `Statifier.Position.export/1` can
prove only that its own export round-trips: it exports after a step,
imports into a fresh chart, continues, and compares configurations. No
corpus case states an exported position, so whether its export is the
one this engine produces at the same point has nowhere to be shown. Every
code cite below was read on `main` at `151d94f`; re-locate each by its
anchor.

**What the export holds.** `Statifier.Position.export/1` answers
`{:ok, exported}` or refuses: `{:error, :internal_queue_not_empty}` for a
position whose internal queue holds an event, and
`{:error, {:unnameable_states, indexes}}` when a state the position
refers to has no id. Its private `build_exported/2` writes seventeen
atom keys, counted off this list: `identity`, `configuration`,
`entered_states`, `states_to_invoke`, `history_values`,
`active_invocations`, `invoke_counter`, `send_counter`, `timer_counter`,
`datamodel`, `running`, `status`, `macrostep`, `microstep`, `round`,
`trace` and `max_macrostep_rounds`. The three state fields are
`MapSet`s of ids, `history_values` maps a history state's id to a
`MapSet`, `active_invocations` is keyed by `{state_id, invoke_index}`
tuples, and `identity` is a `Statifier.Machine.Identity` struct. The
export carries no queue: `Statifier.Position`'s moduledoc says
`internal_queue` is omitted because `export/1` refuses a non-empty one.
None of it is JSON as it stands, which is why `conformance/README.md`
said a case "states no position".

**What a case carries.** `conformance/schema/case.json` allows a step
exactly `event` and `configuration` (`additionalProperties: false`).
The one position surface, a host object's `expect_compatible_at`, is a
boolean asked after the last step (ADR-0072 decision 4), not a
position. `Mix.Statifier.Corpus.Runner.run_case/1` runs a case with no
`host` object through `Statifier.Testing.Case.test_scxml/4`, which reads
no position between steps, and a host case through
`Mix.Statifier.Corpus.HostCase.run/2`, whose `:after_steps` option is
offered once, after the last step.

**What the spec fixes and what it leaves.** Spec 5.10 binds
`_sessionid` "to the system-generated id for the current SCXML
session", binds `_name` "at load time to the value of the 'name'
attribute of the <scxml> element", and binds `_ioprocessors` to one
value per Event I/O Processor the platform supports. Spec 6.4 gives a
generated invoke id "the form stateid.platformid, where stateid is the
id of the state containing this element and platformid is automatically
generated". A session id, a platform id and a processor's location are
an implementation's own; the state a position holds and the values its
datamodel holds are not.

The bead that asked for this named "the queue" among the exported
fields; there is none to state, for the reason above.

## Decision

**1. A `statifier` case's step may carry `expect_position`.** It is an
optional member of a step item, beside `event` and `configuration`: the
position the chart holds once that step's configuration agrees, written
as the rendering decision 2 defines. A case may carry it on any of its
steps and on none of the others; a step without it states no position.
There is no position expectation for the initial configuration. The
schema validates the member's shape, and every member of it is required,
so an expectation never states part of a position by omission.

**2. The rendering.** `expect_position` is a JSON object with exactly
seven members. Each array of state ids is sorted ascending by its UTF-8
bytes; an id appears once. Keys are strings.

| Export key | In the expectation | Why |
|---|---|---|
| `configuration` | asserted, as a sorted array of every active state's id, ancestors included and the `<scxml>` root left out | the state a conforming implementation is in after the step |
| `entered_states` | asserted, sorted array, root left out | Appendix D's `isFirstEntry`, held per state: which states have ever been entered is fixed by the document and the steps |
| `states_to_invoke` | asserted, sorted array | Appendix D's `statesToInvoke`; the invoke pass that ends a macrostep empties it, so after a step that leaves the chart running it is empty, and an implementation that does not clear it differs. After the step that ends the chart it holds the states entered since the last invoke pass and not exited by a transition since: no invoke pass runs once the chart has stopped, and exiting the chart removes none of them. Appendix D adds a state on entry, deletes it in `exitStates`, and clears the set in the invoke pass, which `mainEventLoop` skips once `running` is false; `exitInterpreter` never touches it (`Statifier.Interpreter`'s `main_event_loop/3`, `Statifier.Interpreter.ExitEntry`'s `exit_states/2`) |
| `history_values` | asserted, an object from each history state's id to its recorded ids as a sorted array; a history that recorded nothing has no member | the value spec 3.10 says a history state records is fixed by the document and the steps |
| `active_invocations` | asserted as `{"state", "index"}` objects sorted by state then index; the invocation's id is left out | which `<invoke>` elements are running is the document's, but a generated id's `platformid` half is the implementation's (spec 6.4) |
| `running` | asserted, the boolean | Appendix D's `running`: whether the chart has reached a top-level final state |
| `datamodel` | normalized, decision 3 | the variables are the document's; four system variables are not |
| `identity` | left out | provenance only: `import/2` reads nobody's `:identity` (`Statifier.Position`'s moduledoc), and its hash is this engine's own |
| `invoke_counter`, `send_counter`, `timer_counter` | left out | this engine's sequences behind its generated ids and timer ordinals (ADR-0008, ADR-0035, ADR-0059); the spec requires only that a generated id be unique |
| `status` | left out | after a step it says what `running` says (the two differ only while `exit_interpreter` runs, inside a macrostep), in this engine's atoms |
| `macrostep`, `microstep`, `round` | left out | this engine's stamps for its trace and cause metadata (`Statifier.MachineState`'s counter contract); Appendix D counts none of them |
| `trace`, `max_macrostep_rounds` | left out | options the host started the chart with, not position |

The test for each row is whether a conforming implementation
necessarily produces the same value after the same step. A row that
fails it is left out rather than normalized, because a normalized value
the spec does not fix would still be this engine's.

**3. The datamodel.** The expectation's `datamodel` is the export's
datamodel with `_event`, `_ioprocessors`, `_name` and `_sessionid`
removed: `_sessionid` and the `_ioprocessors` locations embed this
engine's session id; `_event` is the step's own event, which the case
already names, with unset fields an implementation spells as it
chooses; and `_name` is a constant the document fixes at load time,
which says nothing about the position. Every other variable is written
by its name with its value as JSON: a string, a number, a boolean and
`null` as they are, an unset value (`:undefined`) as `null`, a list as
an array and a map with string keys as an object, member by member. A
value with no JSON form (a date, a tuple, an atom other than those
named) makes the step disagree, naming the variable, rather than being
dropped. The expectation therefore does not tell an unset variable
from a null one.

**4. Every state carries an id.** A case that carries `expect_position`
on any step names every state of its document, the root excepted.
`export/1` refuses only a position that refers to an unnamed state, so
an unnamed state that is never entered would pass unnoticed; the runner
refuses the whole case instead, before it starts the chart, naming how
many states have no id.

**5. Statifier suite only.** The schema refuses `expect_position` on a
`scion` or `w3c` case's step. Those cases are emitted from upstream
documents and assert what upstream asserts; a position stated beside
them would be this repository's claim written into another suite's
case. A `statifier` case may carry it with or without a `host` object.

**6. Where it is checked.** `Mix.Statifier.Corpus.Runner.run_case/1`
runs a case whose step carries `expect_position` through
`Mix.Statifier.Corpus.HostCase.run/2`, as a host that registers nothing
when the case has no `host` object. Once a step's configuration agrees,
the runner exports the session's state, read with
`Statifier.Session.snapshot/1` between macrosteps, so the internal queue
is empty and the export answers. It renders the export
(`Mix.Statifier.Corpus.PositionExpectation.render/1`) and the case
agrees only when the rendering equals the step's `expect_position`,
member by member, arrays in order. A disagreement names the step, its
event and each member that differs, with both values.
`Statifier.Testing.Case.test_scxml/4` is not changed: ADR-0006's closed
list of library calls the harness makes stays as it is.

**7. The corpus hash moves.** New `statifier` cases that carry the
member are emitted into `conformance/corpus/statifier.json`, so
`corpus_hash` in `conformance/manifest.json` and `registry.json` moves.
A sibling that vendors the corpus from `v2.10.0` keeps that tag's hash
and re-vendors from the next tag; it then meets the new cases, and a
sibling that does not export positions claims them like any case it
cannot pass, by leaving them out of its registry. Adding an optional
schema member adds to the corpus contract and removes nothing, so the
release that carries it is a minor under the SemVer ADR-0066 adopts.
The shape of a position expectation was ruled by the
operator, 2026-10-01.

### A worked example in the library world

Patron `p-1`'s chart is the parallel `patron` state with the regions
`standing`, `fines` and `desk`, and one variable, `patron_id`. After
`fine.assessed`, the case
`conformance/cases/library/patron_position_in_every_region` states:

```json
{
  "configuration": ["desk", "fines", "good", "owed", "patron", "standing", "waiting"],
  "entered_states": ["desk", "fines", "good", "none", "owed", "patron", "standing", "waiting"],
  "states_to_invoke": [],
  "history_values": {},
  "active_invocations": [],
  "running": true,
  "datamodel": { "patron_id": "p-1" }
}
```

`none` has left the configuration and stays in `entered_states`; the
regions and their parallel parent are in the configuration beside the
leaves the step's `configuration` lists. A loan whose dispute takes it
out of `active` from `due_soon` states `"history_values": {"h":
["due_soon"]}` after `copy.disputed` (`loan_position_records_history`),
and a loan renewed twice states `"renewals": 2` in its datamodel
(`loan_position_counts_renewals`), which no configuration can show.

## Consequences

- A sibling can prove position parity from the corpus alone, for the
  members decision 2 asserts, after every step a case names.
- An existing case is unchanged and runs as before; a case without
  `expect_position` takes the same path it took.
- The expectation states nothing this engine is free to choose: no
  counters, no ids it generates, no session id. A sibling that matches
  every asserted member matches this engine's position up to those
  fields, and the record says which they are.
- An implementation whose datamodel distinguishes an unset value from
  `null` writes both as `null` here (decision 3).
- A case that sends, invokes or delays runs through a session either
  way; a case whose document needs none of them now also runs through a
  session when it states a position. `Statifier.Testing.Case`'s routing
  comment says such a document reaches the same configuration on either
  path, and the case's configurations are still compared at every step.
- Reopen when a case needs a position before its first step, or a
  generated invoke id's `stateid` half, or a datamodel value with no JSON
  form; each is a new member or a new rendering, decided by its own
  record.

## Related

- ADR-0070 (decision 2: what a case asserts; decision 5: the `statifier`
  suite and the `host` object)
- ADR-0072 (decision 4: `expect_compatible_at`, which stays a boolean
  after the last step)
- ADR-0006 (the harness's closed list of library calls, unchanged)
- ADR-0005 (string ids at the boundary, the vocabulary `export/1` uses)
- ADR-0008, ADR-0035, ADR-0059 (the three counters left out)
- ADR-0066 (SemVer from 2.0.0 on)

## Note (2026-10-02): accepted

This record is accepted on 2026-10-02. Its Status line and its row's
status cell in the ADR index are the only lines that change; no decision,
consequence or Related entry changes here, and this Note decides nothing.

Its code shipped in statifier 2.11.0: the tag `v2.11.0` names
`bbc4c0ee`, and statifier 2.11.0 is published. Every claim was verified
against `main` at `bbc4c0ee`:

- decisions 1 and 5: `conformance/schema/case.json` gives a step an
  optional `expect_position` with the seven members required and no
  other allowed, and refuses it on a `scion` or `w3c` case's step;
- decisions 2 and 3: `Mix.Statifier.Corpus.PositionExpectation.render/1`
  writes exactly the seven members, the state ids sorted, the datamodel
  without `_event`, `_ioprocessors`, `_name` and `_sessionid`, and refuses
  a datamodel value with no JSON form, naming its variable;
- decision 4: `Mix.Statifier.Corpus.PositionExpectation.named/1` counts the
  states without an id, and `Mix.Statifier.Corpus.HostCase.run/2` asks it
  before it starts the chart;
- decision 6: `Mix.Statifier.Corpus.Runner.run_case/1` runs a case whose
  step carries `expect_position` through `HostCase.run/2`, as a host that
  registers nothing when the case has no `host` object, and
  `Mix.Statifier.Corpus.PositionExpectation.compare/3` names the step, its
  event and each member that differs; `Statifier.Testing.Case` is the same
  at `v2.10.0` and `v2.11.0`;
- decision 7 and the worked example: the cases
  `patron_position_in_every_region`, `loan_position_records_history` and
  `loan_position_counts_renewals` (under `conformance/cases/library/`) are
  in `conformance/corpus/statifier.json`, in `test/passing_tests.json` and
  in `conformance/registry.json`, and state the values the example quotes;
  `corpus_hash` in `conformance/manifest.json` differs from its value at
  `v2.10.0`.

The Context describes the package at `151d94f`, as it says, before the
schema key, the renderer and the cases existed.
