# ADR-0072: Two compiled charts diff into four classes with their reasons on `Statifier.Chart`, and "compatible at the position" is a separate predicate on `Statifier.Position`

Status: proposed - adds two public functions, `Statifier.Chart.diff/3`
(`diff(from, to, opts \\ [])`) and `Statifier.Position.compatible_at?/3`;
changes no existing function, struct or record; reuses
`Statifier.Chart.events/1` (ADR-0071) for the event side and
`Statifier.Machine.Identity.matches?/2` (ADR-0052) for identity

## Context

A chart edited while executions are pinned to its old hash raises two
questions a host has to answer before it moves anything. What changed
between the two charts, and does the change matter to an execution that
is waiting somewhere in the old one? Today the library answers neither.
Every code cite in this record was read on `main` at `018ec64`; re-locate
each by its anchor.

**The four nouns.** A *document* is the host's stable name for a piece of
work. A *revision* is one saved edit of it. A *chart* is the SCXML a
revision emits, identified by its hash. An *execution* is pinned to one
chart hash, and only an explicit migration re-pins it. Nothing in this
record migrates an execution, and publishing a chart moves no execution
anywhere.

**What exists.** `Statifier.Chart` (`lib/statifier/chart.ex`) holds
`format_version/0`, `to_binary/1`, `from_binary/1`, `events/1` and
`check_accepts/2`, and no diff. `Statifier.Position`
(`lib/statifier/position.ex`) holds `format_version/0`, `to_binary/1`,
`from_binary/2`,
`export/1` and `import/2`, and no compatibility predicate.

**Identity.** `Statifier.Machine.Identity`
(`lib/statifier/machine/identity.ex`) is a SHA-256 hash of the source
bytes plus an optional `name` and `version` (`of_source/2`).
`matches?/2` compares the whole struct, and answers `false` when either
side is `nil`. ADR-0052 decision 1 makes `matches?/2` the only public
comparison. So the same bytes compiled under a different `chart_name` or
`chart_version` are not the same chart under it.

**The compiled surface carries positions, not only meaning.**
`%Statifier.Machine.Transition{}` (`lib/statifier/machine/transition.ex`,
its `defstruct`) carries `t_index`, integer `targets` and `source`, a
`content` list of `c_index`es, a compiled `cond`, `location`,
`cond_location` and `attribute_locations`. `%Statifier.Machine.Invoke{}`
(`lib/statifier/machine/invoke.ex`, its `defstruct`) carries `index`,
`location` and `attribute_locations`. An edit anywhere above an element
moves its offsets and its indexes, so struct equality between two charts
reports a change on elements the author never touched.

**The source is sliceable.** An element's `location` spans its start tag
to its end tag (`Statifier.Parser.Handler`'s `span/2`, applied at the
element's end), and `Statifier.Parser.Location.slice/2` cuts those bytes
out of the source. `Statifier.Machine.source/1` returns the source, or
`nil` for a machine built without one.

**State ids can be absent.** `Statifier.Machine.State`'s `id` is `nil` on
the root and on any state the author gave no id. `Machine.id/2` returns
it and `Machine.index/2` resolves only non-nil ids. `Position.export/1`
refuses a position that references a nameless state other than the root
(`{:error, {:unnameable_states, indexes}}`, its `do_export/1`).

**"Can be active" is private.** ADR-0071 decision 2 states the static
rule, and `Statifier.Chart` implements it in its private
`entered_states/1` and `walk_entry/4`. `events/1` is its only caller.

**The datamodel surface.** `Machine.data_elements` holds every compiled
`<data>` element in the chart, top-level and per-state, each with a
string `id` (`Statifier.Machine.Data`). `Statifier.Machine.State`'s
`data` lists the `d_index`es a state's own `<datamodel>` declares.

**What a position holds.** `Position.export/1`'s map carries
`configuration`, `entered_states`, `states_to_invoke`,
`history_values`, `active_invocations`, the counters (`timer_counter`
among them) and the datamodel (its `build_exported/2`). It carries no
pending timer: a delayed send leaves the position as a
`%SendDelayed{}` effect (ADR-0054), which the session's timer table, a
durable host (self-routed sends only, ADR-0054 decision 2) or the
processor registered for its send type (ADR-0069) schedules; the
position keeps only the ordinal counter.
`configuration` is full: every active state's ancestors are in it
(ADR-0005), except the root, which `export/1` drops and `import/2`
re-adds. `states_to_invoke` is emptied at the end of every macrostep
by the invoke pass (`Statifier.Interpreter`'s `run_invoke_pass/1`), so a
position between macrosteps holds none.

**The migration case this record is designed against.** An execution
waits at a long wait state while its document is edited: the wait state
is renamed, and the step before it gains an outcome. In the library
world, a hold's execution waits in `awaiting_pickup` with its pickup
timer (send id `pickup`) pending, while the document is edited so that
`awaiting_pickup` becomes `ready_for_pickup` and the step that routes the
copy to the pickup branch gains a `transferred` outcome. The execution
must land in `ready_for_pickup` with its timer's deadline unchanged, or
be refused whole.

## Decision

**1. `Statifier.Chart.diff/3` classifies a pair of compiled charts into
one of four classes and returns the reasons.**
`diff(from, to, opts \\ [])` (`diff/2` is its defaulted head) takes two
`%Statifier.Machine{}` values and
returns `%{class: class, reasons: [reason]}`, where `class` is one of
`:identical`, `:compatible`, `:mapped` or `:breaking`.

- **Identical** means `Identity.matches?(Machine.identity(from),
  Machine.identity(to))`. That includes `name` and `version`, because
  ADR-0052 decision 1 makes `matches?/2` the only comparison of two
  identities. Nothing structural is compared, and `reasons` is `[]`. A
  machine with no identity is never Identical to anything. The same
  bytes compiled under a different name or version are not Identical;
  the structural comparison below then finds nothing, so the pair is
  Compatible with `reasons: []`.
- **Compatible** means the structural comparison found no breaking
  reason and no mapped state. Additions are allowed and reported.
- **Mapped** means no breaking reason, and at least one state of `from`
  that is absent from `to` is resolved by the caller's mapping
  (decision 2).
- **Breaking** means at least one breaking reason.

**The structural comparison.** Two states *correspond* when they carry
the same id, or when the mapping resolves a `from` state to a `to` state
(decision 2). The roots always correspond. A state of `from` is *held*
when an execution can hold it: it can be active under ADR-0071 decision
2's rule, or it is a history pseudo-state whose parent can be active
(a history's value is recorded when its parent exits, and stays in the
position). The comparison reports these reasons, and the
ones marked breaking make the pair Breaking:

- `{:state_nameless, index}` (breaking): a held state of `from`, other
  than the root, with no id. Nothing can be paired with it, and
  `Position.export/1` refuses a position that references it anyway. A
  nameless state that is not held is ignored. A nameless state in `to`
  is never reported, since no transition can target it by id.
- `{:state_unresolved, id}` (breaking): a held state of `from` with no
  corresponding state in `to`.
- `{:state_changed, id, fields}` (breaking): a held state of `from`
  whose corresponding state in `to` differs in any of `fields`, a list
  in this order: `:kind`; `:parent` (the parent's corresponding id
  differs); `:atomic` (one is atomic and the other is not); `:regions`
  (both parallel, and the corresponding ids of their children differ);
  `:history_type`. Each is a change after which a position that is legal
  in `from` can be illegal in `to` (spec 3.11, quoted in decision 4).
- `{:state_mapped, from_id, to_id}`: any state of `from` resolved by the
  mapping, held or not, with no `:state_changed` reason, so every
  resolved state that makes a pair Mapped is named.
- `{:state_removed, id}`: a state of `from` that is not held, has no
  corresponding state in `to`, and is not resolved by the mapping. Not breaking: no execution can be in it.
- `{:state_added, id}`: a state of `to` with an id that corresponds to no
  state of `from`.
- `{:transition_removed, source_id, t_index}` (breaking): a selectable
  transition of a held state of `from` (`t_index` in `from`) that
  matches no transition of the corresponding state in `to`. A
  transition of an unresolved or nameless state is not reported again;
  the state's own reason covers it.
- `{:transition_added, source_id, t_index}`: a selectable transition of
  a state of `to` that corresponds to a state of `from` (`t_index` in
  `to`) and matches no transition of that state. A transition of an
  added state is not reported; the state's own reason covers it.
- `{:event_removed, descriptor}` (breaking): a descriptor in
  `Statifier.Chart.events(from)` that is not in `events(to)`, compared
  as strings. A pattern replaced by a wider pattern still reports the
  removal: the comparison is structural and never reasons about which
  names a pattern stands for (ADR-0071 decision 1).
- `{:event_added, descriptor}`: a descriptor in `events(to)` that is not
  in `events(from)`.
- `{:data_removed, id}` (breaking): a `<data>` id anywhere in
  `from.data_elements` that no `<data>` element of `to` declares. The
  surface is every `<data>` element in the chart, not the top level
  only, because SCXML has one global datamodel and a state's own
  `<datamodel>` declares keys in it. An execution's datamodel crosses a
  migration as it is, so a key the new chart no longer declares is a
  value no part of that chart accounts for.
- `{:data_added, id}`: a `<data>` id of `to` that `from` does not
  declare. A `<data>` element's value is not compared: an execution
  that already bound it keeps its own value.
- `{:mapping_unused, from_id}`: a mapping entry that decision 2 does not
  read.

**The equality used for each compared element.** Never struct equality,
and never a source slice: a slice embeds ids a mapping has to translate,
reads a reformatted attribute as a change, and needs a source a machine
may not carry. Each element compares by the normalized fields named
here, and by nothing else.

- **A state** compares by its id (through correspondence), `kind`, its
  parent's corresponding id, whether it is atomic (`Machine.atomic?/2`),
  the corresponding ids of its children when it is parallel, and
  `history_type`. Its executable content, `initial`, `donedata` and
  `invoke` list are not compared.
- **A transition** matches another when these are all equal: the
  corresponding id of its source state; its `events`, each descriptor
  joined with `.` as `events/1` joins it, in the order written; the
  corresponding ids of its `targets`, in the order written; its `type`;
  and its `cond` as authored (`{:static, value}` compares the value,
  `{:compiled, _, source}` compares the expression's source text, `nil`
  matches only `nil`). Its `content`, `t_index` and every location are
  not compared. Transitions match as a multiset per source state: a
  reordering is not reported.
- **An event descriptor** compares as the string `events/1` returns.
- **A datamodel key** compares as the `<data>` element's `id` string.

**Order.** `reasons` is deterministic. It lists the `from`-side state
reasons (`:state_nameless`, `:state_unresolved`, `:state_changed`,
`:state_mapped`, `:state_removed`) in `from`'s document order, one per
state at most; then `:state_added` in `to`'s document order; then
`:transition_removed` in `from`'s `t_index` order; then
`:transition_added` in `to`'s `t_index` order; then `:event_removed` in
`events(from)`'s order; then `:event_added` in `events(to)`'s order; then
`:data_removed` in `from`'s `d_index` order; then `:data_added` in `to`'s
`d_index` order; then `:mapping_unused`, sorted by id.

**2. Mapped comes from a caller-supplied `mapping:` option.** The engine
has no block ids and no other identity a state keeps across an edit
that renames it, so it cannot infer that a removed state became an added
one. The caller says so: `opts[:mapping]` is a plain map from a `from`
state id to a `to` state id: plain data, so a mapping generated
elsewhere, from stable block ids for instance, is passed as it is.

- A mapping entry is read only for a state of `from` whose id is absent
  from `to`, and only when its value is a state id of `to`. Such a state
  corresponds to the state the entry names. Every other entry (a key
  that is still present in `to`, a key for which `from` has no state
  with that id, or a value for which `to` has no state with that id) is reported as `:mapping_unused` and changes no
  class. An entry whose value names no state of `to` leaves its key
  unresolved.
- Without a mapping, or with one that leaves a held state of `from`
  unresolved, the pair is Breaking, with that state named in a
  `{:state_unresolved, id}` reason.
- A mapped pair is still compared (decision 1): a mapping onto a state of
  another kind, or under another parent, is `:state_changed` and
  Breaking.
- `opts` accepts `mapping:` and nothing else. An unknown option, or a
  `mapping` that is not a map from strings to strings, raises
  `ArgumentError`: it is a caller's programming error, not data.
- A mapping that would make one state of `to` correspond to two states
  of `from` is refused the same way, with `ArgumentError`: two read
  entries whose values name the same state, or a read entry whose value
  is also the id of a state of `from`. No result is defined for
  it.

**3. `diff/3` answers what the charts are, never what an execution will
do.** The classes are structural. A Compatible pair can still behave
differently for an execution: a transition's content, a state's
`<onentry>`, a condition's meaning under a changed datamodel, or the
document order that decides which of two enabled transitions fires are
all outside the comparison. A Breaking pair can be harmless to every
execution a host actually holds, because "held" over-approximates the
states an execution can be in (ADR-0071 decision 2). A host that needs
to know about one execution asks decision 4's predicate as well.

**4. "Compatible at the position" is a separate predicate,
`Statifier.Position.compatible_at?/3`.**
`compatible_at?(from_machine, to_machine, exported)` takes the chart an
execution is pinned to, a candidate chart, and the execution's
`Position.export/1` map, and returns a boolean. It is `true` only when
every condition below holds, and `false` otherwise, including when
either machine has no source or `exported` is not a map `import/2` would
accept.

- **Every id the export names resolves in `to_machine`**, in every field
  `import/2` resolves (`configuration`, `entered_states`,
  `states_to_invoke`, `history_values`, `active_invocations`), so
  `import/2` onto `to_machine` would not refuse.
- **The configuration is legal in `to_machine`.** Each active state has
  the same `kind` in both machines and the same parent id, and the
  configuration resolved in `to_machine` meets spec 3.11: "The
  configuration contains exactly one child of the <scxml> element. The
  configuration contains one or more atomic states. When the
  configuration contains an atomic state, it contains all of its <state>
  and <parallel> ancestors. When the configuration contains a non-atomic
  <state>, it contains one and only one of the state's children. If the
  configuration contains a <parallel> state, it contains all of its
  children."
- **Each active state's own outgoing surface is byte-identical.** For
  every state in the configuration, these compare equal in both
  machines, element by element and in order: the source slices of its
  selectable transitions (`transitions`), of its `<onexit>` blocks, and
  of its `<invoke>` elements. "Byte-identical" means exactly that here:
  `Statifier.Parser.Location.slice/2` of each element's `location` over
  each machine's `source`. A slice covers the element and everything
  inside it, so a changed target, condition, event, executable content,
  parameter or child content is a changed slice. `<onexit>` is compared
  because every transition that leaves the state executes it; `<onentry>`
  is not, because it already executed.
- **A changed transition on an ancestor of an active state breaks it.**
  This follows from the rule above and is decided here so it is not
  argued later: `configuration` is full (ADR-0005), every ancestor of an
  active state except the root (which `export/1` drops and `import/2`
  re-adds, and which holds no transition, `<onexit>` or `<invoke>`) is
  in it, and a transition on an ancestor is selectable from the active
  configuration.
- **`history_values`.** Every recorded key resolves in `to_machine` to a
  history pseudo-state with the same `history_type` and the same parent
  id, and every recorded member resolves to a descendant of that parent.
  A recorded value is a configuration the execution will re-enter, so it
  has to be one `to_machine` can hold.
- **`states_to_invoke` is empty.** A non-empty set is a position inside a
  macrostep, before its invoke pass, and is not a position to move
  across charts, for the reason `export/1` refuses a non-empty internal
  queue.
- **`active_invocations`** needs nothing further: each key names a state
  in the configuration and an index into that state's `<invoke>` list,
  and that list is compared slice by slice above.

The predicate reads no datamodel and no timer. It compares no
`identity`, since `Position.import/2` performs none (ADR-0052 decision
6). It does not look past an active state's own surface: an unchanged
transition may target a state whose content changed, and that is the new
chart's behavior, not a change at the position. It takes no mapping: a
renamed active state is not byte-identical and answers `false`.

**5. The "can be active" rule stays private in `Statifier.Chart`.**
`diff/3` lives in the same module as `entered_states/1` and calls it
directly. `compatible_at?/3` does not need the rule: it reads the
execution's actual configuration, which is a fact, where the rule is a
static over-approximation for a chart with no execution in hand. So no
function is made public for it.

**6. `compatible_at?/3` is built and tested, and nothing in this
repository calls it outside its tests.** No function in `lib/` calls
`diff/3` either. Neither function changes a position, and neither is a
step in `Statifier.compile/2`, `Statifier.Chart.to_binary/1` or any
session path. Whether an execution moves, and onto which chart, is a
host's explicit decision, and a failed or refused move leaves the
execution exactly as it was.

**The worked example.** The library hold, hand-authored. The execution
is in `awaiting_pickup`:

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="routing">
    <datamodel>
        <data id="copy_id" expr="'c-1'"/>
    </datamodel>
    <state id="routing">
        <transition event="copy.routed" target="awaiting_pickup"/>
    </state>
    <state id="awaiting_pickup">
        <onentry>
            <send type="library:timer" target="hold" event="pickup.expired" id="pickup" delay="7d"/>
        </onentry>
        <onexit>
            <cancel sendid="pickup"/>
        </onexit>
        <transition event="copy.collected" target="collected"/>
        <transition event="pickup.expired" target="expired"/>
    </state>
    <final id="collected"/>
    <final id="expired"/>
</scxml>
```

The edited revision renames `awaiting_pickup` to `ready_for_pickup`
(its body unchanged), points `routing`'s `copy.routed` at it, adds
`<transition event="copy.transferred" target="in_transfer"/>` to
`routing` after its `copy.routed`, and adds a state `in_transfer`, after
`ready_for_pickup`, whose one transition is `copy.routed` to
`ready_for_pickup`.

- `diff(from, to)` is Breaking. Its reasons, in order:
  `{:state_unresolved, "awaiting_pickup"}`,
  `{:state_added, "ready_for_pickup"}`, `{:state_added, "in_transfer"}`,
  `{:transition_removed, "routing", 0}`,
  `{:transition_added, "routing", 0}`,
  `{:transition_added, "routing", 1}`,
  `{:event_added, "copy.transferred"}`. `routing`'s old transition
  matches nothing, because its target has no corresponding state; the
  new one to `ready_for_pickup` is an addition for the same reason.
- `diff(from, to, mapping: %{"awaiting_pickup" => "ready_for_pickup"})`
  is Mapped:
  `{:state_mapped, "awaiting_pickup", "ready_for_pickup"}`,
  `{:state_added, "in_transfer"}`,
  `{:transition_added, "routing", 1}`,
  `{:event_added, "copy.transferred"}`. `routing`'s `copy.routed` now
  matches through the mapping, and `awaiting_pickup`'s two transitions
  match `ready_for_pickup`'s.
- `compatible_at?(from, to, exported)` for the waiting execution is
  `false`: `awaiting_pickup` does not resolve in `to`. The predicate
  takes no mapping, and a renamed active state is not byte-identical.
- **The pending timer is not the engine's.** The `pickup` send's
  deadline is held by the processor registered for `library:timer`: it
  is a host-registered send type, so for its `%SendDelayed{}` the
  session schedules nothing and the processor owns the delay
  (`Statifier.Send.Processor`'s moduledoc, ADR-0069). It is not held by
  the position (its `timer_counter` is an ordinal, not a deadline). "Lands in `ready_for_pickup` with its timer's deadline
  unchanged" rests on the persistence layer's pin source, which is not
  an engine surface, and neither function here claims it. What the
  engine gives is the refusal half: `import/2` resolves every id before
  it builds anything and refuses the whole position when one does not
  resolve.
- **The same edit made in blocks renames nothing.** statifier_blocks
  derives state ids from block ids by a pure function (sb-ADR-0004
  decision 3), so a relabelled wait block keeps its state id and the new
  outcome adds a state: in block terms the edit is an identity mapping
  plus a new state. Nothing of `from` is absent from `to`, so the
  blocks-compiled pair diffs Compatible, not as a rename; an identity
  mapping passed with it changes nothing, since decision 2 reports each
  of its entries (a key still present in `to`) as `:mapping_unused`. Only a hand-authored SCXML edit that rewrites
  the id sees the rename above.

## What this record does not decide

- The migration plan's format, its validations, and the operation that
  applies one. Those are the persistence layer's.
- Any automatic migration. Nothing here moves an execution, and nothing
  moves one because a chart was published.
- Where a host shows the class or the reasons, and which class it
  refuses on.
- How a host rewrites an export through a mapping before `import/2`.
- Pending timers and their deadlines (the persistence layer's pin
  source).
- Behavioral equivalence of two charts, and a diff of `<invoke>` child
  charts.

## Consequences

- `Statifier.Chart` gains `diff/3` with an `@spec` and a `@doc` that
  states decision 1's classes, reasons, equalities and order, decision
  2's mapping rule, and decision 3's structural caveat. Its moduledoc's
  list of questions a host asks about a chart gains the diff.
- `Statifier.Position` gains `compatible_at?/3` with an `@spec` and a
  `@doc` that states decision 4's conditions, its ancestor, history and
  `states_to_invoke` cases, and that it reads no timer.
- The "can be active" rule gains a second caller in its own module and
  stays private.
- A host can tell, before it moves anything, whether a new chart keeps
  every state an execution can hold (diff), and whether one execution's
  position is untouched by the edit (predicate). Both answers are
  conservative: a Breaking diff or a `false` predicate can refuse a move
  that would have been safe, and neither can approve a move that drops a
  held state.
- The diff's transition comparison ignores content and order, so a
  Compatible pair may still differ in what a transition does; the
  predicate's slice comparison catches that at the position, and only
  there.

## Related

- [ADR-0071](0071-chart-event-vocabulary-and-accepts-check.md) (`events/1`, the event side of the diff, and decision 2's "can be active" rule)
- [ADR-0052](0052-chart-identity-and-position-serialization.md) (decision 1: identity and `matches?/2`; decision 6: `export/1` and `import/2`)
- [ADR-0005](0005-full-configuration-and-interned-state-indexes.md) (the full configuration the ancestor case rests on)
- [ADR-0054](0054-durable-timers-consume-the-effect-vocabulary.md) (a delayed send leaves the position as a `%SendDelayed{}` effect, scheduled by the session's timer table, a durable host for a self-routed send, or the processor registered for its send type under [ADR-0069](0069-host-registered-send-types.md))
- [ADR-0056](0056-renumbered-adr-citations-pointers-move-history-stands.md) (the `sb-ADR-0004` cross-repo cite form)
