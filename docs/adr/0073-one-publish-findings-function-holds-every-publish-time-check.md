# ADR-0073: One pure publish findings function, `Statifier.Publish.findings/2`, holds every publish-time check as a row of `docs/publish-time-checks.md`

Status: accepted (2026-09-25) - adds one public module, `Statifier.Publish`,
with one public function, `findings/2`; composes
`Statifier.Send.Types.unsupported_sends/2` (ADR-0069 decision 3) and
`Statifier.Chart.check_accepts/2` (ADR-0071 decision 3) without moving
either; changes no existing function, struct or record; leaves
`Statifier.Validator` and `Statifier.compile/2` untouched

## Context

`docs/publish-time-checks.md` lists every refusal this package raises at
run time next to the publish-time function that finds the same defect
first, or the word NONE. Its first sentence is the rule: a runtime
refusal for something a literal in the source could have told us is a
bug in the publish check. Every code cite in this record was read on
`main` at `c100724`; re-locate each by its anchor.

**What exists.** Two rows of the `statifier` table have a twin, and both
twins are pure functions a host calls before an execution starts:

- Row S1, an unregistered `<send type>`, is found by
  `Statifier.Send.Types.unsupported_sends/2`
  (`lib/statifier/send/types.ex`): every `<send>` whose literal `type`
  `classify/2` answers `:unsupported` for against the declared set, with
  the element's `Statifier.Parser.Location.t()`, in `c_index` order. It
  takes the set a host builds with `from_send_types/1` from its
  `:send_types` map, or `nil`, which is no declaration: the built-in set
  only, so every non-built-in type is unsupported.
- Row S15, an event the chart has no transition for, is not a refusal:
  the engine discards the event, as the SCXML algorithm does. Its twin,
  `Statifier.Chart.check_accepts/2` (`lib/statifier/chart.ex`), compares
  a declaration of accepted event names with the chart's vocabulary
  (`events/1`) and answers `%{unreachable: [name], undeclared:
  [descriptor]}`. With `nil` both lists are empty: the computed
  vocabulary is the contract.

Both live outside `Statifier.Validator` for the same reason: `validate/3`
judges a document against the spec and takes no deployment state, while
each of these is a question about the deployment a chart will run in
(the moduledoc of `Statifier.Send.Types`; ADR-0071's Context).

**What does not exist.** Twelve rows of the table are NONE although a
literal in the source decides the defect, wholly or in part: S2, S3, S6,
S9, S11, S12, S13, S14, S16, S17, S18 and S19. Each was filed as its own
bead, and each bead met the same undecided question: where does the
check go? Three shapes were on the table. Twelve separate public
functions, one per row, which a host has to know the names of and keep
calling as rows are added. Checks inside `Statifier.Validator`, which
would make `Statifier.compile/2` refuse charts it accepts today, a
behaviour change for every host and for the conformance corpus. Or one
aggregate function a host calls at publish, into which each row lands as
one check. The operator ruled for the third, 2026-09-24, and this record
writes it down.

**A host's publish step is the gate.** The page's own words: the host's
publish step runs those functions over a chart before the chart can
start an execution, and it refuses the publish on what they report; an
editor runs the same functions at edit time. One function with one
finding shape is what makes that sentence cheap to keep true: a host
calls one thing, shows one list, and refuses on the rows it chooses.

**The declared claims.** A host already stamps three per-session claims
about its deployment onto `%Statifier.MachineState{}`
(`lib/statifier/machine_state.ex`, `new/2`): `send_types`
(`Statifier.Send.Types.t() | nil`), `invoke_types`
(`Statifier.Invoke.Types.t() | nil`, ADR-0051 decision 2) and `routes`
(`Statifier.Send.Routes.t() | nil`, the route snapshot of ADR-0048). Each
is a claim, not an observation, and `nil` on each means no declaration.
The route snapshot is stamped by the driver before each drive and names
the sessions, the parent and the invokes a send can reach; row S3's
literal half is a `#_<invokeid>` target that no `<invoke id>` in the
chart declares, which the chart alone decides, and its other half (a
session id or `#_parent`) depends on who started the execution and is
the table's "no".

**A naming precedent.** `statifier_blocks` names its aggregate
`StatifierBlocks.Publish.findings/3`, the findings a host's publish step
refuses a document on. This record takes the module and function names
from it and nothing else: the two packages judge different inputs and
share no shape.

## Decision

**1. One public function: `Statifier.Publish.findings/2`.**
`findings(machine, declaration \\ [])` (`lib/statifier/publish.ex`)
takes a compiled `%Statifier.Machine{}` and the host's declaration
(decision 3) and returns a list of findings (decision 2), one per defect
every check it holds found. It is pure and total: it reads the compiled
machine, runs nothing, performs no I/O, and the same chart and
declaration always give the same list. It reports and refuses nothing:
which rows a host refuses a publish on, if any, is the host's decision,
as it is for each twin the function composes.

`Statifier.Validator` and `Statifier.compile/2` are untouched, now and
by every check that lands later. A chart that compiles today compiles
after every twin has landed, whatever `findings/2` reports about it.

**2. The finding shape.** A finding is a plain map with exactly four
keys:

- `row` - the row's id in `docs/publish-time-checks.md`, a string
  (`"S1"`). Every finding names its row, and a host that reads the page
  reads the finding.
- `kind` - which finding of that row this is, an atom the row's check
  defines. One row can report more than one kind (S15 reports two).
- `location` - the `Statifier.Parser.Location.t()` of the element the
  finding is about, or `nil` when there is no element (a declared name
  the chart never selects on has none).
- `data` - the row's own detail, a map whose keys the row's check
  defines and documents on `findings/2`.

The list is ordered by row, in the function's row list's order, which is
the table's order; inside a row, in the check's own order (the composed
function's order for a composed check). A finding is data: no struct, no
severity, no message. A message is the host's or the editor's to render,
from the row and the kind, and a severity is the host's refusal policy,
which the page says is the host's.

**3. The declaration is a keyword list with three optional keys**, each
the publish-time form of one claim the host stamps on a session:

- `send_types:` - a `Statifier.Send.Types.t()` or `nil`, what row S1's
  composed check reads.
- `invoke_types:` - a `Statifier.Invoke.Types.t()` or `nil`, what row
  S6's check will read. Accepted and unread until that check lands.
- `accepts:` - a list of event-name strings or `nil`, what row S15's
  composed check reads.

An absent key is `nil`, and `nil` keeps the meaning each composed
function already gives it: no declaration. So `findings(machine)` with
no declaration reports every non-built-in `<send type>` under S1 and
nothing under S15, and a host that registers nothing and declares
nothing still gets every chart-only finding. A key outside the three, a
list that is not a keyword list, a non-list, or a value of the wrong
shape raises `ArgumentError`: a caller's programming error, not data,
the posture `Statifier.Chart.diff/3` takes for its `opts` (ADR-0072
decision 2).

The route snapshot is not a key. No check reads it: S3's literal half is
judged against the chart's own `<invoke id>`s, and its snapshot half is
not a literal's defect. If a later row needs a fourth key, that row's
record adds it here; the set does not grow in a patch.

**4. The rows the function holds, and how one lands.** Inside the
module, one list names the rows in the order their findings are
returned, and one private `check/3` clause per row produces that row's
findings. A twin lands by adding its row id to the list and one clause,
and by nothing else: no module, no public function, no new key on the
finding. Its bead ships a case that fails when the clause is removed,
and replaces the row's NONE cell in the table with the function's name.

Today the function holds two rows, both composed from a public function
that stays where it is and keeps its own contract:

- S1 composes `Statifier.Send.Types.unsupported_sends/2`: one finding of
  kind `:unsupported_send_type` per reported send, at the send's
  location, with `data: %{type: type}`.
- S15 composes `Statifier.Chart.check_accepts/2`: one finding of kind
  `:unreachable_name` per declared name in `unreachable`, with
  `data: %{name: name}`, then one of kind `:undeclared_descriptor` per
  descriptor in `undeclared`, with `data: %{descriptor: descriptor}`,
  each with no location.

The twelve rows the function will hold, each landing later as one check
inside it, are the table's literal-decided NONE rows: S2 (a built-in
send's literal `target` the engine cannot parse), S3 (a literal
`#_<invokeid>` target no `<invoke id>` declares), S6 (a literal `<invoke
type>` the declared `invoke_types:` does not register), S9 (an inline
`<content>` child that does not compile), S11 (a literal write location
whose root no `<data>` declares), S12 (a read of a root neither a
`<data>` nor a system variable declares), S13 (a compile failure the
compiler stored as `{:invalid, error}` on the node), S14 (a literal
`delay` that is not a duration), S16 (a cycle of eventless transitions
none of which carries a `cond`), S17 (an illegal `<foreach>` `item` or
`index` name), S18 (a `<script>` that writes a root beginning with `_`)
and S19 (a literal write location that is not assignable). Each row's
"part" cell says what its check judges and what it leaves to the
runtime; a value resolved at run time (a `typeexpr`, a `targetexpr`, an
`expr`) is never guessed at, as the page's rule for every twin says.

**5. The one row the function will not hold as a check of its own is
S15.** An event the chart has no transition for is discarded by design,
as the SCXML algorithm does; it is not a refusal, and there is nothing
in the chart alone to find. What the function composes under S15 is the
existing twin, which judges a host's declaration against the chart's
vocabulary and is silent with no declaration. No later bead adds an S15
check that reads the chart alone.

**The worked example.** The loan chart in `docs/publish-time-checks.md`
("An example: a library loan"), whose `<send>` names `library:notices`
and whose document declares `loan.renew`, `loan.due`, `copy.returned`
and `patron.blocked`:

```elixir
{:ok, machine} = Statifier.compile(loan_source)

Statifier.Publish.findings(machine)
#=> [%{row: "S1", kind: :unsupported_send_type,
#      location: %Statifier.Parser.Location{start_line: 6, ...},
#      data: %{type: "library:notices"}}]

types = Statifier.Send.Types.from_send_types(%{"library:notices" => NoticesProcessor})

Statifier.Publish.findings(machine,
  send_types: types,
  accepts: ["loan.renew", "loan.due", "copy.returned", "patron.blocked"]
)
#=> [%{row: "S15", kind: :unreachable_name, location: nil,
#      data: %{name: "patron.blocked"}}]
```

The page's own walk of that chart ends with row S2: drop the `type` and
the literal `target="overdue_notice"` raises `error.execution` the first
time a loan falls due, and its twin is NONE. When S2's check lands,
that call returns one more finding, `row: "S2"`, at the send's
location, and nothing else about the function changes.

## What this record does not decide

- Any of the twelve checks. Each lands in its own bead, with its kinds
  and its `data` keys documented on `findings/2` when it does.
- Which rows a host refuses a publish on, and how an editor renders a
  finding.
- The row ids themselves: they are the table's, and the table governs.
- A check for a refusal the table marks "no".
- Whether `statifier_router` or `statifier_blocks` compose this function
  into their own publish-time functions.

## Consequences

- `lib/statifier/publish.ex` is new: `Statifier.Publish` with
  `findings/2`, an `@spec`, the `finding` and `declaration` types, and a
  `@doc` that states decisions 2, 3 and 4 for the rows it holds. Its
  moduledoc states what a check is and how one lands.
- `Statifier.Send.Types.unsupported_sends/2` and
  `Statifier.Chart.check_accepts/2` are unchanged and gain a caller. A
  host that calls either today keeps its answer.
- `docs/publish-time-checks.md` names `Statifier.Publish.findings/2` in
  its header as the one function that reports the `statifier` rows. The
  NONE cells stay NONE until each check lands; the twin cells of S1 and
  S15 keep naming their own functions, which the new one composes.
- A host's publish step calls one function and reads one shape. Adding a
  check changes the list it gets, never the call it makes.
- A twin that ships as a public function of its own, or as a change to
  `Statifier.Validator`, contradicts decision 4 and is refused at
  review.
- The changelog gains a fragment: a public API addition.

## Related

- [ADR-0069](0069-host-registered-send-types.md) (decision 3: `unsupported_sends/2`, composed under S1)
- [ADR-0071](0071-chart-event-vocabulary-and-accepts-check.md) (decision 3: `check_accepts/2`, composed under S15; its Context on why the checks live outside `Statifier.Validator`)
- [ADR-0072](0072-chart-diff-classes-and-position-compatibility.md) (decision 2: `ArgumentError` for a caller's malformed option, the posture decision 3 takes)
- [ADR-0051](0051-invoke-handlers-are-registered-per-session.md) (decision 2: `Statifier.Invoke.Types`, the `invoke_types:` key)
- [ADR-0048](0048-send-reachability-judged-against-a-route-snapshot.md) (the route snapshot, which is not a key)
- [ADR-0056](0056-renumbered-adr-citations-pointers-move-history-stands.md) (the cross-repo cite form)

## Note (2026-09-25): the twelve rows have landed

This note decides nothing. It records that the twelve checks decision 4
names have landed, each as decision 4 directs, so its sentence "Today the
function holds two rows" describes the function as this record wrote it
and is superseded. No decision, consequence or Related entry changes.
Every anchor below was read on `main` at `ffc0b2b`, and nothing under
`lib/` or `test/` differs between that commit and the `v2.9.0` tag
(`f2365bb`).

The row list in `lib/statifier/publish.ex` (`@rows`) now names fourteen
rows in the table's order: S1, S2, S3, S6, S9, S11, S12, S13, S14, S15,
S16, S17, S18 and S19. Each has one private `check/3` clause and no module
or public function of its own; S1 and S15 still compose
`Statifier.Send.Types.unsupported_sends/2` and
`Statifier.Chart.check_accepts/2`. `test/statifier/publish_test.exs` has
one `describe` block per landed row, and removing a landed row's id and
its clause turns cases in that file red for every one of the twelve.
Decision 3's `invoke_types:` key is now read, by row S6's clause. The
worked example still returns the findings listed above, and with the
`type` dropped it returns the one `row: "S2"` finding at the send's
location that the paragraph after it predicts. In
`docs/publish-time-checks.md` the twelve rows' twin cells name
`Statifier.Publish.findings/2`.

## Note (2026-09-25): accepted

This record is accepted on 2026-09-25, under the operator's word. Its
Status line is the only line of it that changes; no decision,
consequence or Related entry changes here, and this note decides nothing.

Its code shipped in statifier 2.9.0: `Statifier.Publish.findings/2` came
with this record in `2efc6c6`, which is in the `v2.9.0` tag (`f2365bb`),
and statifier 2.9.0 is published. Every claim above was verified against
`main` at `ffc0b2b`, where nothing under `lib/` or `test/` differs from
that tag. Decision 4's "Today the function holds two rows" is read as the
Note above records: superseded by the twelve checks that have since
landed as decision 4 directs. The Context describes the package at
`c100724`, as it says, and was checked there: the twelve rows it names
were NONE in the table at that commit, and the two composed functions
and the three stamped claims were as it describes them; each of those
still holds on `main` except the NONE cells, which the Note above
records. The worked example was compiled from this record's text and
run on `main`: `findings/2` returns the listed findings with and without
the declaration, and a declaration with an unknown key, a non-list, or a
`send_types:` or `accepts:` value of the wrong shape raises
`ArgumentError`. `Statifier.Validator` and `Statifier.compile/2` are
unchanged since `2efc6c6`.
