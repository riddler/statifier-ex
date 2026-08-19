# ADR-0012: Debuggability is designed into the core

Status: accepted (2026-08-04) - amended 2026-08-17 (st-1xwh: `d_index` named a
third identity under item 3) - amended 2026-08-18 (st-9i5r: item 3's retention
reaches attribute-level spans, not only element-level) - amended 2026-08-18
(st-xsb1: item 4's step counters are stamped against the state at the phase
boundary, not against whatever the state became afterwards)

## Context

We eventually want tooling that steps through a running state chart at macrostep
and microstep granularity - an interactive debugger, live visualization, time
travel. That tooling is explicitly not being built now. The risk is that the
interpreter, written without these consumers in mind, fuses away the seams they
need: microstep state living only on the call stack, source locations dropped at
compilation, trace points that would have to be retrofitted into a finished
Appendix D port. Each seam is cheap while the code is being written and
expensive to recover afterwards.

The architecture already does most of the work. A pure
`(machine_state, event) -> {machine_state, [effect]}` core (ADR-0003) is
inherently steppable and replayable, and the function-per-pseudocode-block port
(ADR-0002) naturally exposes `select_transitions`, `compute_exit_set`, and
friends as callable queries. What remains is a short list of constraints on how
that code is shaped.

## Decision

The interpreter is built to the constraints in `docs/observability.md`, which
this ADR makes binding. In summary:

1. **Microsteps are resumable values.** The machine_state struct fully reifies
   the between-microsteps position (configuration, internal queue, datamodel,
   running flag, history, step counters). A macrostep is a fold over a
   `microstep` step function; mid-macrostep state never lives only in loop
   variables or on the call stack.
2. **Trace is part of the effect vocabulary.** Structured trace effects are
   emitted at the phase boundaries Appendix D itself names (event dequeued,
   transitions selected, exit set, executable content, entry set, macrostep
   stable, done), gated by an option so the untraced hot path pays nothing.
   Debuggers and visualizers are effect interpreters, not core hooks.
3. **The Machine retains source locations and stable identities.** Compilation
   keeps locations on states, transitions, and executable content, and assigns
   document-order indexes to transitions and executable-content nodes so trace
   effects can name them and tooling can map them back to source.
4. **Steps are counted and causes are stamped.** machine_state carries monotonic
   macrostep/microstep counters; trace effects and internally raised events
   (e.g. `error.execution`) carry the step and the identity of what raised them.

No stepper API, debug protocol, or UI is built now. Items 1-4 are constraints
on code being written anyway.

**Amendment (st-1xwh):** item 3's document-order-index sentence named two
indexes, `t_index` and `c_index`. A third has existed on the compiler and on
`Statifier.Machine.Data` since before this sentence was written
(`lib/statifier/machine/data.ex:4-5` already cited this ADR's item 3 for it),
and neither this item nor `docs/observability.md` constraint 3 enumerated it.
`d_index` is that third index: a `<data>` element's own stable, dense-from-0,
document-order identity, assigned by the compiler the same way `t_index` and
`c_index` are and resolved back to its `%Statifier.Machine.Data{}` -
`location` and `value_location` included - through `Statifier.Machine.data/2`.
This amendment completes the enumeration item 3 had already fallen behind; it
mints no new identity kind and the original sentence is left standing above,
unedited, for the same reason ADR-0040's amendments explain rather than
rewrite the rule they amend.

**Amendment (st-9i5r):** item 3 says compilation "keeps locations on states,
transitions, and executable content", and `docs/observability.md` constraint
3 illustrates that with a visualizer highlighting a `<transition>` line.
Both are element-granular. `Statifier.Machine.Invoke` had already gone one
step finer - carrying `Statifier.Document.Invoke`'s `attribute_locations`
map verbatim rather than distilling a `*_location` field per attribute - and
`Statifier.Machine.State` and `Statifier.Machine.Transition` now do the
same. The retained data is the value span of each attribute the author
actually wrote, so the Machine can answer both "where is this attribute" and
"was it written or defaulted" without a second parse. This widens what item
3 retains; it mints no new identity and adds no runtime cost beyond the
memory the Consequences section already accepts, which is why it is an
amendment rather than a new record. The original sentence stands above,
unedited, for the same reason the st-1xwh amendment explains rather than
rewrites.

**Amendment (st-xsb1):** item 4 commits trace effects to carrying "the step
and the identity of what raised them" but does not say which state those
counters are read from. A trace effect names a phase boundary, and the step
counters it carries are the ones that stood at that boundary - stamped
against the state as it was when the boundary was crossed, not against
whatever the state became afterwards.

The converse is equally part of the rule: a payload field whose meaning is
defined only by the mutation - "the configuration after this exit set was
applied" - is correctly read from the post-mutation state. Reading such a
field after the mutation is not a violation of this item; stamping the
counters after it is. A trace effect can therefore mix a pre-mutation
stamp with a post-mutation field in the same payload without breaking item
4, so long as each is read from the state its own meaning depends on.
`exit_states/2` (`lib/statifier/interpreter/exit_entry.ex:134-167`) is a
worked example of exactly this split.

This is an amendment rather than a new record: it mints no new identity,
adds no runtime cost, and constrains no code that was not already
constrained by item 4. It completes a sentence item 4 left half-stated,
the same way st-1xwh completed the index enumeration. The original
sentence stands above, unedited, for the same reason the st-1xwh and
st-9i5r amendments explain rather than rewrite the rule they amend.

## Consequences

- Future step tooling attaches to existing seams: the public microstep
  boundary, the trace effect stream, and the pure Appendix D queries. No core
  rework, no instrumentation pass.
- Deterministic replay stays a property of the session boundary: (machine,
  initial data, external event log) reproduces a run, and step counters give
  every trace an ordering key.
- The core carries modest permanent weight: locations and indexes on Machine,
  counters on machine_state, and a trace-gate check per phase boundary.
- Interpreter code review gains a checklist item: a change that moves microstep
  state off the struct, drops locations in the compiler, or raises an internal
  event without cause metadata violates this ADR.
