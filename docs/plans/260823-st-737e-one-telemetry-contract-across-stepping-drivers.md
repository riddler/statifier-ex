# One Telemetry Contract Across Stepping Drivers Implementation Plan

## Overview

Implements ADR-0067 in this repo: the emission half of the ADR-0040
telemetry contract moves out of the session boundary into a new
caller-agnostic `Statifier.Telemetry`, every emitter takes a leading
`driver` atom, every event's metadata gains one additive `driver` key, and
`Statifier.Session.Telemetry` stays as a thin facade pinning
`driver: :session` so nothing published in 2.0.0 breaks. Bead: st-737e.

ADR-0067 is accepted and authoritative. This plan implements it; it makes
no new design decisions beyond the one ADR-0067 explicitly delegated here
(its open question 3, resolved below).

## Current State Analysis

**The emitter is session-shaped by location, not by content.**
`lib/statifier/session/telemetry.ex` (752 lines) holds the authoritative
`@moduledoc` contract table, `events/0` (27 names), seven lifecycle
emitters, the `effect/3` dispatcher, and all private shape builders,
location resolution, and configuration translation. Nothing in the body
touches a pid, a GenServer, or session state: every function takes plain
values (`session_id`, `machine`, `machine_state`, payload structs). The
only thing binding it to `Statifier.Session` is the module name and the
call sites.

**The call sites are all in `session.ex`**, twelve of them
(`lib/statifier/session.ex:859`, `:860`, `:1207`, `:1350`, `:1483`,
`:1551`, `:1555`, `:1638`, `:1669`, `:1688`, `:1827`, `:1836`), aliased as
`Telemetry`.

**Public surface to preserve** (9 functions): `events/0`, `init/5`,
`halt/3`, `terminate/4`, `macrostep_start/4`, `macrostep_stop/7`,
`interpret/3`, `effect/3`, `unroutable/3`.

**A process-less driver gets nothing.** A host stepping through
`Statifier.Interpreter` directly (the `statifier_persistence` run
lifecycle) never constructs a `Statifier.Session`, so no event fires and
`opentelemetry_statifier` sees zero spans on the flagship durable path.
That is the gap st-737e was filed on and ADR-0067 closes.

**The guard blocks the move as it stands.** `Mix.Statifier.AdrGuard`'s
`@effect_call_pattern` (`lib/mix/statifier/adr_guard.ex:145-152`) includes
`:telemetry\.`, and `@effect_interpreter_paths`
(`lib/mix/statifier/adr_guard.ex:123-127`) exempts exactly three paths:
`session.ex`, `supervisor.ex`, `session/telemetry.ex`. A new
`lib/statifier/telemetry.ex` sits under `@core_prefix` (`lib/statifier/`),
so every `:telemetry.execute/3` in it is an `adr-0003-effects` finding
until the path joins that list.

**The tree is currently gate-red.** `docs/adr/0067-...md` is untracked and
`docs/adr/README.md` has no row for it, so `mix adr.check`'s
`adr-0058-readme-index` invariant (README table in bijection with the
directory) fails. Phase 1 clears that.

**Test coverage of the contract lives in one 1706-line file.**
`test/statifier/session/telemetry_test.exs` is `async: false` and attaches
`:telemetry_test.attach_event_handlers(self(), Telemetry.events())` in
`setup`. Two of its assertions are structurally coupled to the module
identity: the 27-name count (`:263-277`) and the moduledoc-bijection test
(`:279-295`), which does `Code.fetch_docs(Telemetry)` and compares every
`[:statifier, ...]` literal in the moduledoc against `events/0`. The second
one must follow the moduledoc to the new module.

### Key Discoveries:

- `lib/statifier/session/telemetry.ex:1-752` - the entire body is
  caller-agnostic already; the move is a rename plus one leading argument.
- `lib/statifier/session.ex:859-1836` - twelve call sites, all through the
  `Telemetry` alias, so the facade keeps them compiling unchanged.
- `lib/mix/statifier/adr_guard.ex:114-127` - the exemption list and the
  comment block that argues it; ADR-0027's "argued, not defaulted" bar.
- `lib/mix/statifier/gate_guard.ex:36` - `@guarded_paths` is
  `[".quality.exs", ".credo.exs", "coveralls.json", ".sobelow-conf",
  ".doctor.exs"]`. `lib/mix/statifier/adr_guard.ex` is **not** mechanically
  guarded, so the ledger entry for the exemption is policy (ADR-0027), not
  a gate requirement - exactly as the 2026-08-16 st-cmq.1 entry in
  `docs/quality-gate-changes.md:230-262` states in its own text.
- `.doctor.exs` - 100% module-doc, doc, and spec coverage, no ignores. Every
  facade wrapper needs its own `@doc` and `@spec`; a bare `defdelegate`
  cannot be used anyway because the `driver` argument goes *first*.
- `coveralls.json` - `minimum_coverage: 90`. A new module with no exercising
  test would move that number, which is one reason the module and its tests
  land in the same phase.
- `grep -rn "@deprecated" lib/` returns **zero hits**: this repo has no
  precedent for `@deprecated` on a kept facade. That resolves ADR-0067's
  open question 3 - see "Implementation Approach".
- `docs/adr/README.md:70` - the row format for the ADR index table.
- `docs/adr/0040-...md:1-15` - the status line and its five existing
  amendment clauses; ADR-0067's clause appends to that chain.
- `mix.exs:53-68` - `docs/adr/0*.md` is globbed, so ADR-0067 reaches
  hexdocs with no `mix.exs` edit.

## Desired End State

`Statifier.Telemetry` is the public, caller-agnostic emitter for the 27
`[:statifier, :session, ...]` events. Every emitter takes `driver` first;
every event's metadata carries `driver`. `Statifier.Session` emits through
it with `driver: :session`, byte-for-byte identically to 2.0.0 except for
that one additive key. `Statifier.Session.Telemetry` still exists with the
same nine functions at the same arities, delegating with `:session` pinned,
and its `@moduledoc` points at the new module. `Mix.Statifier.AdrGuard`
exempts the new path with the ADR-0067 argument written into its comment
block, backed by a test. ADR-0040's status line names the amendment,
`docs/observability.md` and `docs/opentelemetry.md` name the new module and
the `driver` key, and `changelog.d/st-737e.md` tells a user what changed.

Verified by: `mix quality` green at every phase; a new
`test/statifier/telemetry_test.exs` proving `driver` flows through for a
non-`:session` atom; the existing session telemetry suite still green with
only the additive `driver: :session` assertions and the one moved
moduledoc test.

## What We're NOT Doing

- **No emit sites in `statifier_persistence`.** ADR-0067's consequences name
  that as a follow-up owned by that repo (its stepper seam, per decision 3's
  applicability table). Out of scope here, and the mirrored bead is filed
  there, not planned here.
- **No changes in `opentelemetry_statifier`.** Reading `driver` and mapping
  it to `statifier.driver` is that repo's follow-up.
- **No new event names, and no event shape changes.** `events/0` still
  returns the same 27 names. ADR-0067 decision 1 is explicit that a
  `[:statifier, :step, ...]` family was weighed and rejected.
- **No `:terminate` analog for process-less drivers.** ADR-0067 decision 3:
  it names a GenServer callback and gets no replacement; `:halt` is the
  "session finished" event on both paths.
- **No `@deprecated` attribute on the facade** - see the approach below.
- **No move of the 1706-line session telemetry suite.** It stays where it
  is and now doubles as the facade's proof: every assertion in it passes
  through `Statifier.Session.Telemetry` and therefore proves the delegation
  as well as the contract. Consolidating the two suites is a later cleanup
  and deliberately not this bead's work.
- **No change to clock behavior.** `System.system_time/0` and
  `System.monotonic_time/0` stay inside the emitter (ADR-0067 decision 2);
  `Statifier.Replay` still fires nothing (ADR-0034).
- **No `interpret` seam for process-less drivers.** ADR-0067 decision 3
  makes `:interpret` conditional on a driver having an ADR-0029-style
  injection seam; none exists outside `Statifier.Session`, so nothing to
  build.

## Implementation Approach

Three phases, ordered so each leaves the gate green on its own.

**Phase 1 is a records-only commit** that lands ADR-0067 itself, its
`docs/adr/README.md` row, and the ADR-0040 status-line amendment. It exists
as its own phase because the untracked ADR file currently fails
`adr-0058-readme-index`: until that row exists no other phase can show a
green gate, and mixing a decision record into a code commit makes both
harder to read.

**Phase 2 is the whole code change in one commit**, and it cannot be split
further. The new module, the facade, and the `AdrGuard` path addition are
mutually gating: a `lib/statifier/telemetry.ex` without the exemption is an
`adr-0003-effects` finding, an exemption without the module is an untested
list entry, and a facade without the module does not compile. The tests
land with it because a new module with no coverage moves
`coveralls.json`'s 90% floor.

**Phase 3 is prose**: the two user-facing docs pages ADR-0067's
consequences name.

**The mechanical shape of the move.** `lib/statifier/telemetry.ex` receives
the current body verbatim, with three systematic edits:

1. Each public emitter gains a leading `driver :: atom()` parameter and its
   `@spec` gains the matching first entry. Arities go `init/5 -> init/6`,
   `halt/3 -> halt/4`, `terminate/4 -> terminate/5`,
   `macrostep_start/4 -> macrostep_start/5`,
   `macrostep_stop/7 -> macrostep_stop/8`, `interpret/3 -> interpret/4`,
   `effect/3 -> effect/4`, `unroutable/3 -> unroutable/4`. `events/0` keeps
   its arity and shape.
2. Every `:telemetry.execute/3` metadata map gains `driver: driver`. For
   the two dispatchers that build metadata through `base_metadata/3`
   (`effect/4`), the key is threaded into that private builder rather than
   added at each of the 20 call paths - one site, uniform result.
3. The `@moduledoc` moves with the body and gains `driver` in every one of
   the 27 metadata cells, plus a short section stating that the second
   prefix segment names the logical session rather than the
   `Statifier.Session` process (ADR-0067 decision 1) and the applicability
   table from decision 3. The bijection regex the tests use
   (`~r/\[:statifier(?:, :[a-zA-Z_]+)+\]/`) is unaffected by the added
   column.

**The facade's shape.** Nine wrappers, not `defdelegate`: the `driver`
argument is leading, so the arities cannot line up. Each wrapper carries
its own `@doc` and `@spec` (`.doctor.exs`'s 100% bar) and is a single
expression forwarding to `Statifier.Telemetry` with `:session` pinned.
`events/0` is the one true `defdelegate`, since its arity is unchanged.

**ADR-0067 open question 3, resolved: doc-level supersession only, no
`@deprecated`.** `grep -rn "@deprecated" lib/` finds no occurrence anywhere
in this repo, so there is no precedent for the attribute on a kept facade,
and adding one would put a compiler warning in the path of every existing
2.0.0 consumer for a module that still works exactly as documented -
against ADR-0067's own stated 2.x deprecation-noise budget. The facade's
`@moduledoc` says it is superseded by `Statifier.Telemetry` and that removal
is a 3.0 question; nothing more.

**Terminology.** Every reference to the reporting embedder in code, tests,
docs and the changelog fragment is "a production CQRS/Oban host" or "the
first production embedder". No product or employer name appears anywhere.

---

## Phase 1: Land ADR-0067 in the record set

### Overview

Commits the accepted decision record, restores the ADR index bijection the
gate checks, and amends ADR-0040's status line to name the
supersession-in-part. Documentation only; no `lib/` change.

### Changes Required:

#### 1. The decision record

**File**: `docs/adr/0067-one-telemetry-contract-across-stepping-drivers.md`
**Changes**: Already written by the Direction stage and present in the
worktree as an untracked file. Land it unchanged - it is authoritative and
this plan implements it rather than revising it.

#### 2. The ADR index

**File**: `docs/adr/README.md`
**Changes**: Add one row after the ADR-0066 row (`:70`), matching the
established three-column format:

```
| [0067](0067-one-telemetry-contract-across-stepping-drivers.md) | One telemetry contract across stepping drivers: `[:statifier, :session, ...]` names the logical session, the emitters generalize into `Statifier.Telemetry`, `Statifier.Session.Telemetry` stays as a `driver: :session` facade, and a `driver` key joins every event's metadata | accepted (amends 0040 in part) |
```

#### 3. ADR-0040's status line

**File**: `docs/adr/0040-session-telemetry-event-contract.md`
**Changes**: Append one clause to the amendment chain in the `Status:` block
(`:2-15`), in the same voice as the five clauses already there:

```
- amended in part by ADR-0067 (2026-08-23, st-737e: the
`[:statifier, :session, ...]` prefix names the logical session rather than
the `Statifier.Session` process; the emission helpers generalize into
`Statifier.Telemetry` with a leading `driver` argument; a `driver` key
joins every event's metadata)
```

Its Consequences and event tables are untouched: ADR-0067 amends the
prefix's meaning, the emitter's location, and one metadata key, and states
that everything else in ADR-0040 stands.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` passes (full gate), with the ADR guard's
      `adr-0058-readme-index` and `adr-0058-duplicate-number` findings both
      clear - this is the check that was failing before the phase.
- [x] `mix quality --profile loop` is the command to use while iterating.
- [x] `mix format` has been run (Format runs in check mode).
- [x] `git status` shows `docs/adr/0067-...md` tracked, not untracked.
- [x] `grep -c "0067" docs/adr/README.md` returns at least 1.
- [x] `grep -n "ADR-0067" docs/adr/0040-session-telemetry-event-contract.md`
      shows the amendment clause inside the `Status:` block.

#### Manual Verification:
- [ ] The README row's summary reads as a decision, not a task description,
      and matches the voice of its neighbors.
- [ ] The ADR-0040 status clause names what was amended (prefix meaning,
      emitter location, `driver` key) and does not imply the event tables
      changed.
- [ ] No employer or product terminology appears in either edit.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

No changelog fragment: `changelog.d/README.md` excludes documentation and
ADRs.

---

## Phase 2: `Statifier.Telemetry`, the `Session.Telemetry` facade, and the guard exemption

### Overview

Moves the emission implementation to `Statifier.Telemetry` with a leading
`driver` argument and an additive `driver` metadata key on all 27 events;
reduces `Statifier.Session.Telemetry` to a `driver: :session` facade;
exempts the new path in `Mix.Statifier.AdrGuard` with the ADR-0067 argument
and a test; records the exemption in the guard ledger; and adds the
changelog fragment. One commit - the parts are mutually gating (see
"Implementation Approach").

### Changes Required:

#### 1. The caller-agnostic emitter

**File**: `lib/statifier/telemetry.ex` (new)
**Changes**: `defmodule Statifier.Telemetry`, receiving the entire current
body of `lib/statifier/session/telemetry.ex` - the `@moduledoc` contract
table, the `@type`s (`event_name`, `core_payload`, `trace_payload`), the
`@lifecycle_events`/`@effect_kinds`/`@trace_kinds` module attributes,
`events/0`, the seven lifecycle emitters, the `effect/_` dispatcher, and
every private helper (`base_metadata/_`, `core_shape/2`, `trace_shape/2`,
`counters/1`, `trace_kind/1`, `location/2`, `configuration_ids/1`,
`resolve_configuration/2`, `event_name/1`, `event_caller_context/1`) -
moved, not copied. The private helpers keep their clause ordering exactly,
including the load-bearing `d_index`-before-`c_index` rule in `location/2`
and its comment.

Systematic edits on top of the move:

```elixir
@typedoc """
The stepping driver that emitted an event. `:session` is reserved for this
library's own `Statifier.Session` process driver; an external driver names
itself with one stable atom of its own (ADR-0067 decision 4).
"""
@type driver :: atom()

@spec init(
        driver :: driver(),
        session_id :: String.t(),
        machine :: Machine.t(),
        machine_state :: MachineState.t(),
        invoked_by :: {pid(), String.t()} | nil,
        resumed :: boolean()
      ) :: :ok
def init(driver, session_id, machine, machine_state, invoked_by, resumed) do
  :telemetry.execute(
    [:statifier, :session, :init],
    %{system_time: System.system_time()},
    %{
      driver: driver,
      session_id: session_id,
      machine_name: machine.name,
      trace: machine_state.trace,
      invoked_by: invoked_by,
      resumed: resumed
    }
  )
end
```

and, so the 20 effect/trace paths get the key at one site rather than
twenty:

```elixir
@spec base_metadata(
        driver :: driver(),
        session_id :: String.t(),
        payload :: struct(),
        extra :: map()
      ) :: map()
defp base_metadata(driver, session_id, payload, extra) do
  Map.merge(%{driver: driver, session_id: session_id, effect: payload}, extra)
end
```

The remaining emitters follow the same pattern: `halt/4`, `terminate/5`,
`macrostep_start/5`, `macrostep_stop/8`, `interpret/4`, `effect/4`
(both clauses), `unroutable/4`. `events/0` is unchanged.

**Moduledoc changes**: `driver` joins the metadata column of all 27 rows
(7 lifecycle + 11 core effect + 9 trace). Two short sections are added
ahead of the tables:

- one stating ADR-0067 decision 1 - the second prefix segment names the
  logical SCXML session (`_sessionid`, the thing a position blob persists),
  not the `Statifier.Session` process, and the GenServer is one driver of a
  session rather than the definition of one;
- one carrying decision 3's applicability table (which events a
  process-less driver emits, why `:init` is per logical run and not per
  load, why `:terminate` is Session-only, why `:interpret` is conditional),
  and decision 5's constraint that a span's start and stop must be emitted
  within one driver invocation because a `make_ref/0` is node- and
  VM-local and can never cross a persist boundary.

The existing caveat about `Statifier.Session.init/1` calling the emitter
before the `:initialize` span's start is edited to name the facade
correctly but keeps its substance.

#### 2. The facade

**File**: `lib/statifier/session/telemetry.ex`
**Changes**: Reduced to a thin facade. `@moduledoc` shrinks to a pointer:
it says this module is the `Statifier.Session`-pinned view of
`Statifier.Telemetry` (ADR-0067 decision 2), that it exists so 2.0.0
consumers keep working, that the authoritative contract table now lives in
`Statifier.Telemetry`, and that it is superseded in documentation with
removal a 3.0 question - no `@deprecated` attribute (see "Implementation
Approach"). It carries no copy of the event tables and no
`[:statifier, ...]` event literals.

Nine members, each with its own `@doc` and `@spec` for `.doctor.exs`'s 100%
bar:

```elixir
alias Statifier.Telemetry

@doc """
Every event name `Statifier.Session` can emit - delegates to
`Statifier.Telemetry.events/0`, which is the same 27 names.
"""
@spec events() :: [Telemetry.event_name()]
defdelegate events(), to: Telemetry

@doc "Emits `[:statifier, :session, :init]` with `driver: :session`."
@spec init(
        session_id :: String.t(),
        machine :: Machine.t(),
        machine_state :: MachineState.t(),
        invoked_by :: {pid(), String.t()} | nil,
        resumed :: boolean()
      ) :: :ok
def init(session_id, machine, machine_state, invoked_by, resumed) do
  Telemetry.init(:session, session_id, machine, machine_state, invoked_by, resumed)
end
```

and the same shape for `halt/3`, `terminate/4`, `macrostep_start/4`,
`macrostep_stop/7`, `interpret/3`, `effect/3`, `unroutable/3`. Arities and
argument orders are unchanged from 2.0.0.

The `@type event_name`, `@type core_payload` and `@type trace_payload`
definitions move with the body to `Statifier.Telemetry`; the facade
references them qualified rather than re-declaring them, so there is one
definition site.

#### 3. `lib/statifier/session.ex`

**File**: `lib/statifier/session.ex`
**Changes**: **None.** All twelve call sites go through the `Telemetry`
alias to `Statifier.Session.Telemetry`, whose arities are unchanged. This
is deliberate and is what makes the "byte-for-byte identical except for
`driver: :session`" claim easy to verify: the session's emission code did
not move.

#### 4. The ADR guard exemption

**File**: `lib/mix/statifier/adr_guard.ex`
**Changes**: `"lib/statifier/telemetry.ex"` joins `@effect_interpreter_paths`
(`:123-127`), and the comment block above it (`:114-121`) gains the ADR-0067
argument - that this is the reopening trigger ADR-0040's own Consequences
named, fired on purpose, and that the exempt surface is unchanged in
substance: the ADR-0040 emission half moved to a path whose name no longer
claims the session owns it, and the old path stays only as a facade.

```elixir
  # ADR-0067 moves that emission half to `lib/statifier/telemetry.ex`, a
  # caller-agnostic module every stepping driver emits through, and leaves
  # `session/telemetry.ex` as a `driver: :session` facade. Both paths stay
  # on this list. This is precisely the reopening trigger ADR-0040's
  # Consequences named - "a second module outside session.ex and
  # session/telemetry.ex needing an exemption for telemetry-shaped
  # reasons" - and ADR-0067 fires it deliberately and argues it, rather
  # than riding the existing entry: the exempt surface did not grow a
  # second effect interpreter, it is the one emission half moving to a
  # name that no longer claims the session owns it, plus the facade left
  # behind for 2.0.0 consumers.
  @effect_interpreter_paths [
    "lib/statifier/session.ex",
    "lib/statifier/supervisor.ex",
    "lib/statifier/session/telemetry.ex",
    "lib/statifier/telemetry.ex"
  ]
```

#### 5. The guard-exemption ledger entry

**File**: `docs/quality-gate-changes.md`
**Changes**: A new dated entry at the top of the dated entries, in the
established format (`## 2026-08-23 - st-737e`, an `Approved-by:` line, one
`- <path>: <what changed>` bullet, a reason). The `Approved-by:` line names
no individual, because no individual has approved it yet - it reads
`Approved-by: pending operator confirmation (ADR-0067, st-737e, accepted
2026-08-23, which argues this exemption in full)`. It records the fourth
`@effect_interpreter_paths` entry and answers ADR-0027's "argued, not
defaulted" bar by citing ADR-0067's argument rather than restating it. The
entry notes, as the st-cmq.1 entry did, that `mix gate.check` does not
guard `lib/mix/statifier/adr_guard.ex` (`gate_guard.ex:36`) - the block is
policy, not a gate requirement, and the entry keeps the guard's own comment
true rather than routed around. It also states that the check does not
loosen: the new path is exempt, every other path under `lib/statifier/`
keeps its `:telemetry` finding.

See "Open Questions" item 1 for why the line is written that way and what
the operator does with it.

#### 6. The guard exemption's test

**File**: `test/mix/statifier/adr_guard_test.exs`
**Changes**: One new test alongside the three existing exemption tests
(`:100-152`), following their shape exactly - including the sabotage note:

```elixir
    # ADR-0067's exemption: the :telemetry.execute/3 call sites moved to
    # lib/statifier/telemetry.ex, the caller-agnostic emitter every stepping
    # driver emits through. session/telemetry.ex stays as a driver: :session
    # facade and keeps its own entry (above).
    # sabotage: drop "lib/statifier/telemetry.ex" from
    #           @effect_interpreter_paths -> red
    test "a :telemetry call in telemetry.ex is exempt" do
      assert analyze("lib/statifier/telemetry.ex", [
               "    :telemetry.execute([:statifier, :session, :effect], measurements, metadata)"
             ]) == []
    end
```

#### 7. The new module's own test suite

**File**: `test/statifier/telemetry_test.exs` (new), `async: false`
**Changes**: Proves what the facade suite structurally cannot - that the
emitter is caller-agnostic and `driver` is a real parameter rather than a
constant. Handlers are VM-global, so `async: false` and an `on_exit/1`
detach, mirroring the existing suite's `setup`.

Tests, each with its own one-line sabotage note per CLAUDE.md:

- `events/0` returns exactly 27 unique names, all `[:statifier, :session | _]`.
- The `@moduledoc`'s tables name exactly the same events - **the bijection
  test moved from `test/statifier/session/telemetry_test.exs:279-295`**,
  retargeted at `Statifier.Telemetry` because the moduledoc moved with the
  body. Unchanged in substance.
- **`driver` on all 27 events.** One test that walks every name
  `Statifier.Telemetry.events/0` returns, drives that name's emitter with a
  driver atom that is not `:session` (`:test_driver`), and asserts
  `metadata.driver == :test_driver`. It is modelled on the existing suite's
  "measurements are numbers, for every event this module can emit" describe
  (`test/statifier/session/telemetry_test.exs:1285-1332`), which drives
  every emitter once - the seven lifecycle calls, then
  `for {kind, payload} <- @core_fixtures` and
  `for {_kind, effect} <- @trace_fixtures`, then `unroutable` - drains the
  mailbox and asserts a property over every message received. The new file
  needs its own `@core_fixtures`/`@trace_fixtures` (module attributes do not
  cross files); copy them from the existing suite so the two stay
  recognizably the same list. Assert `messages != []` and then
  `metadata.driver == :test_driver` on every drained message, which covers
  the 11 core-effect and 9 trace events through `base_metadata/4` as well as
  the 7 lifecycle emitters directly.
- `unroutable/4` with `:test_driver` carries `driver` *and* still resolves
  `location` - it is the one lifecycle emitter that does both.
- **The equivalence test**: for a representative event from each family,
  calling `Statifier.Telemetry.<f>(:session, ...)` and
  `Statifier.Session.Telemetry.<f>(...)` with the same arguments produces
  identical measurements and identical metadata. This is the mechanical
  proof of "byte-for-byte identical for Session consumers except the
  additive key".

#### 8. Additive assertions in the existing suite

**File**: `test/statifier/session/telemetry_test.exs`
**Changes**: Two edits, both minimal:

- **Remove** the moduledoc-bijection test (`:279-295`); it moved to the new
  file in change 7. `Statifier.Session.Telemetry`'s moduledoc is now a
  pointer and names no events, so the assertion has nothing to bind to
  here. The 27-name `events/0` test at `:263-277` stays put - `events/0` is
  still part of the facade's surface and the delegation is worth asserting.
- **Add** one test to the existing "measurements are numbers, for every
  event this module can emit" area (`:1285-1335`), reusing that describe's
  enumeration to assert every emitted event carries `metadata.driver ==
  :session`. One test, one sabotage note; nothing else in the file changes.

#### 9. The changelog fragment

**File**: `changelog.d/st-737e.md` (new)
**Changes**: User-facing per `changelog.d/README.md` - a new public module
and a new metadata key on a published contract. Two standard headings, one
line each, present tense, no nested bullets:

```markdown
### Added

- `Statifier.Telemetry` emits the `[:statifier, :session, ...]` events for any
  stepping driver, taking the driver as a leading atom, so a host stepping the
  pure interpreter without a `Statifier.Session` process can emit the same
  contract (ADR-0067).

### Changed

- Every `[:statifier, :session, ...]` event's metadata carries `driver`;
  `Statifier.Session` emits `driver: :session`. `Statifier.Session.Telemetry`
  keeps its functions and arities as a facade over `Statifier.Telemetry`.
```

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` passes (full gate) - format check, `warnings_as_errors`
      compile, Credo strict, Dialyzer, Doctor at 100% on all five axes,
      coverage at or above 90%, and the ADR guard clean.
- [x] `mix quality --profile loop` is the command to use while iterating.
- [x] `mix format` has been run (Format runs in check mode).
- [x] `mix test test/statifier/telemetry_test.exs
      test/statifier/session/telemetry_test.exs
      test/statifier/session_test.exs test/mix/statifier/adr_guard_test.exs`
      passes - the four suites this phase can move.
- [x] `mix adr.check` reports no `adr-0003-effects` finding for
      `lib/statifier/telemetry.ex`.
- [x] `git diff --stat lib/statifier/session.ex` is empty - the session's
      call sites did not move.
- [x] Every one of the 27 events carries `driver`, decided by test rather
      than by inspection: `test/statifier/telemetry_test.exs` enumerates
      `Statifier.Telemetry.events/0`, drives each name's emitter with
      `:test_driver`, drains the mailbox, and asserts
      `metadata.driver == :test_driver` on every message (with
      `messages != []`) - the same enumeration shape the existing suite's
      "measurements are numbers, for every event this module can emit"
      describe already uses.
- [x] `Statifier.Session.Telemetry.events() |> length()` is 27 and equals
      `Statifier.Telemetry.events() |> length()`, asserted by tests in both
      files.
- [x] Every sabotage note required by CLAUDE.md is present: each new test in
      `test/statifier/telemetry_test.exs`,
      `test/statifier/session/telemetry_test.exs` and
      `test/mix/statifier/adr_guard_test.exs` carries a one-line
      `# sabotage: ... -> red` note above it, and each mutation was actually
      run and reverted.
- [x] `changelog.d/st-737e.md` exists and uses only standard Keep a
      Changelog headings.
- [x] `docs/quality-gate-changes.md` has a `## 2026-08-23 - st-737e` entry
      naming `lib/mix/statifier/adr_guard.ex`.
- [x] That entry's `Approved-by:` line names no individual:
      `sed -n '/## 2026-08-23 - st-737e/,/^## /p' docs/quality-gate-changes.md
      | grep '^Approved-by:'` matches `pending operator confirmation` and
      contains no personal name (Open Questions item 1).

#### Manual Verification:
- [ ] **Spec conformance**: this phase touches `lib/statifier/`, so the
      touched functions are read against the W3C Appendix D pseudocode -
      here the check is that *nothing* in the interpreter path changed. No
      Appendix D function is touched, no core behavior moves, and the ADR-0002
      rule has nothing to bite on: the change is emission-side only. Confirm
      by reading the diff for any edit outside `telemetry.ex`,
      `session/telemetry.ex`, the guard, and the tests.
- [ ] The moved body is a move, not a rewrite: read
      `git diff -M --find-copies-harder` (or diff the two files side by
      side) and confirm every private helper's clause ordering survived
      intact, especially `location/2`'s `d_index`-before-`c_index` rule and
      its comment.
- [ ] Attach a handler to `Statifier.Telemetry.events/0` in `iex -S mix`,
      run a small chart through `Statifier.Session` with `trace: true`, and
      confirm every event carries `driver: :session` and is otherwise
      identical to what 2.0.0 emitted.
- [ ] Call a lifecycle emitter directly with a driver atom of your own from
      `iex` - no `Statifier.Session` process anywhere - and confirm the
      event fires with that atom.
- [ ] The facade's `@moduledoc` reads as a pointer, carries no copy of the
      event tables, and states the doc-level supersession without promising
      a removal date other than "3.0".
- [ ] The guard-ledger entry's reason argues the exemption rather than
      asserting it, and cites ADR-0067.
- [ ] No employer or product terminology appears in the module docs, the
      guard comment, the ledger entry, the tests, or the changelog fragment.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Name the new module and the `driver` key in the user-facing docs

### Overview

The two guides ADR-0067's consequences name. Prose only; no `lib/` or
`test/` change.

### Changes Required:

#### 1. `docs/observability.md` constraint 6

**File**: `docs/observability.md`
**Changes**: The Observation bullet (`:198-210`) currently says the
`:telemetry` bridge attaches at the session boundary and names
`Statifier.Session.Telemetry` as the authoritative reference. Amend it to
say that the authoritative reference is now `Statifier.Telemetry`
(ADR-0067), that `Statifier.Session.Telemetry` is the `driver: :session`
facade over it, and that a driver stepping the pure interpreter without a
session process emits the same contract by calling the same module at its
own step seam - with a pointer to `docs/persistence.md` for what that loop
looks like. Constraint 6's framing widens accordingly: `Statifier.Session`
is *a* session boundary, and the observation property belongs to the
logical session rather than to the process.

#### 2. `docs/opentelemetry.md`

**File**: `docs/opentelemetry.md`
**Changes**: Four edits:

- The opening paragraph (`:1-8`) names `Statifier.Telemetry` alongside
  ADR-0040/ADR-0067 as where the contract lives.
- The attribute-mapping list (`:145-163`) gains one bullet: `driver` becomes
  the `statifier.driver` attribute on every span and span event, uniform
  across drivers, and a consumer that ignores it sees exactly the
  pre-amendment contract.
- The "Failure tolerance" section's `:terminate` cleanup bullet (`:187-193`)
  gains ADR-0067 decision 3's judgment: `:terminate` is Session-only, and
  for a process-less driver both span halves arrive inside one synchronous
  driver call, so there is no open-span entry to leak; the existing liveness
  sweep still covers the last-span-context entry.
- The "One trace per macrostep, stitched with links" section (`:103-115`)
  gains ADR-0067 decision 5: a macrostep span never crosses a persist
  boundary (a `make_ref/0` is node- and VM-local), so a durable timeline is
  stitched exactly as a session's is - per-macrostep traces linked through
  the bridge's last-span-context table, and to the scheduling trace through
  `caller_context` (ADR-0063). A durable macrostep span nests inside
  whatever step or job span the persistence and Oban layers opened around
  it, by ordinary OTel ambient context, since both are in the same process.
  The "What lands where" table (`:216-222`) gains a row for the durable
  emit sites, owned by `statifier_persistence`.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` passes (full gate).
- [ ] `mix quality --profile loop` is the command to use while iterating.
- [ ] `mix format` has been run (Format runs in check mode).
- [ ] `grep -c "Statifier.Telemetry" docs/observability.md
      docs/opentelemetry.md` returns at least 1 for each.
- [ ] `grep -c "statifier.driver" docs/opentelemetry.md` returns at least 1.
- [ ] `mix docs` builds without a broken-reference warning for either page.

#### Manual Verification:
- [ ] Both pages read as documents that always described a driver-agnostic
      contract, not as a page with an amendment bolted on.
- [ ] Neither page copies the event table - ADR-0040's consequence that
      `docs/observability.md` "carries no second copy of the table" still
      holds, now pointing at `Statifier.Telemetry`.
- [ ] The durable path is described only in terms this repo owns; storage
      phases (load, decode, persist, lock) stay named as
      `statifier_persistence`'s own vocabulary per ADR-0067 decision 6.
- [ ] No employer or product terminology appears; the motivating embedder,
      if mentioned at all, is "a production CQRS/Oban host".
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

No changelog fragment: documentation only, and Phase 2's fragment already
covers the user-visible change.

---

## Testing Strategy

### Unit Tests:

- **`test/statifier/telemetry_test.exs` (new)** - the caller-agnostic
  proof. Its job is everything the facade suite cannot show: that `driver`
  is a parameter and not a constant, that a non-`:session` atom reaches
  every one of the 27 events, that the moduledoc's tables stay in bijection
  with `events/0`, and that pinning `:session` through the facade produces
  metadata identical to calling the new module directly.
- **`test/statifier/session/telemetry_test.exs` (existing, 1706 lines)** -
  now doubles as the facade's regression proof. It is the reason the "at
  most additive assertion updates" constraint is checkable: every one of its
  assertions runs through `Statifier.Session.Telemetry`, so if the
  delegation changed any measurement or metadata value it goes red. Only
  two edits: the moduledoc-bijection test moves out, one `driver: :session`
  test comes in.
- **`test/mix/statifier/adr_guard_test.exs`** - the exemption is
  load-bearing rather than an unverified list entry, matching the pattern
  the three existing exemption tests set.
- **Edge cases**: `effect/4` on a trace payload (the metadata builder path
  with an extras map), `unroutable/4` (the one lifecycle emitter that sets
  `driver` inline *and* resolves a location), and `macrostep_start/5` /
  `macrostep_stop/8` (`span_ref` must survive the added leading argument
  unchanged).
- **Sabotage**: every new test asserting `lib/` behavior gets its mutation
  run, confirmed red, reverted, and noted in one line above the test
  (CLAUDE.md, `docs/testing.md`). The guard test's note names the list entry
  to drop; the driver tests' notes name hardcoding `driver: :session` in the
  emitter.

### Manual Testing Steps:

1. `iex -S mix`, then
   `:telemetry.attach_many("m", Statifier.Telemetry.events(), fn n, m, md, _ -> IO.inspect({n, m, md}) end, nil)`.
2. Start a small chart through `Statifier.Session.start_link/2` with
   `trace: true`, send it an event, let it reach a final state. Confirm the
   `:init`, both `:macrostep` halves, the effect and trace events, and
   `:halt` all carry `driver: :session`, and that measurements and every
   other metadata key are what 2.0.0 emitted.
3. Without any session: compile a chart, call
   `Statifier.Interpreter.initialize/2`, and call
   `Statifier.Telemetry.init(:my_driver, session_id, machine, machine_state, nil, false)`
   plus a `macrostep_start/5` / `macrostep_stop/8` pair around a
   `handle_event/2`. Confirm the same event names fire with
   `driver: :my_driver` - this is the gap st-737e was filed on, closing.
4. Confirm `Statifier.Replay.run/1` over a recording still emits nothing
   (ADR-0034 clock-freedom is untouched).
5. Read `h Statifier.Session.Telemetry` in `iex` and confirm it points a
   reader at `Statifier.Telemetry` without duplicating the contract, and
   produces no deprecation warning on use.

## Open Questions

Every question below has a chosen default, so the plan is actionable
unattended; each is recorded because a human would otherwise have been
asked. They are surfaced to the operator rather than blocking.

1. **The guard-ledger `Approved-by:` line.**
   `docs/quality-gate-changes.md`'s own preamble says the entry "is where
   that call is recorded, not where an agent grants itself one", and every
   existing entry names JohnnyT. No operator is available during this bead's
   unattended run, and `mix gate.check` only checks that the substring
   `Approved-by:` is present - it cannot tell a real approval from an
   invented one, so the honesty of this line is entirely on whoever writes
   it. **Default taken:** write the line with no individual's name on it -
   `Approved-by: pending operator confirmation (ADR-0067, st-737e, accepted
   2026-08-23, which argues this exemption in full)` - and surface it in the
   MR description as the one item needing an explicit operator nod before
   merge. Writing `Approved-by: JohnnyT` with a hedge in parentheses was
   considered and rejected: the committed line would still read as an
   approval by a named human who never gave one, and a later reader
   grepping the ledger sees the name, not the hedge. The operator replaces
   the placeholder with their own name when they make the call; until then
   the record says plainly that no call has been made. Nothing mechanical
   is blocked either way - `mix gate.check` does not guard
   `lib/mix/statifier/adr_guard.ex` (`gate_guard.ex:36`), so the gate is
   green with the placeholder in place.
2. **ADR-0067's own open question 3 (`@deprecated` on the facade).**
   ADR-0067 explicitly delegates this to the implementing stage.
   **Resolved here: doc-level supersession only.** `grep -rn "@deprecated"
   lib/` returns zero hits, so there is no repo precedent for the attribute
   on a kept facade, and adding one would emit a compiler warning into every
   existing 2.0.0 consumer's build for a module that still behaves exactly
   as documented. Recorded in "What We're NOT Doing" so the decision
   survives.
3. **Whether the 1706-line session telemetry suite should eventually move
   wholesale to `test/statifier/telemetry_test.exs`.** **Default taken:
   no, not in this bead.** Leaving it in place is what makes "byte-for-byte
   identical for Session consumers" mechanically checkable, and moving 1706
   lines of assertions in the same commit that moves 752 lines of
   implementation would make the diff unreviewable. If the facade is ever
   removed at 3.0, that is the moment to consolidate.
4. **The durable driver's atom.** ADR-0067 open question 1 leaves
   `:persistence` to `statifier_persistence`'s own follow-up. Nothing in
   this plan depends on the value: `driver` is an open enumeration here, and
   the new suite uses a deliberately non-production atom (`:test_driver`) so
   no test pins a value that repo has not chosen.

## References

- Source decision: `docs/adr/0067-one-telemetry-contract-across-stepping-drivers.md`
  (accepted 2026-08-23, authoritative - this plan implements it)
- Amended record: `docs/adr/0040-session-telemetry-event-contract.md`
- Related ADRs: `docs/adr/0003-*` (pure core, effects out),
  `docs/adr/0027-*` (the exemption-list bar), `docs/adr/0029-*`
  (`interpret/2` seam), `docs/adr/0034-*` (clock freedom),
  `docs/adr/0039-*` (re-entry, nested spans), `docs/adr/0052-*` /
  `docs/adr/0060-*` (chart identity, resume, `_sessionid`),
  `docs/adr/0062-*` (the bridge package), `docs/adr/0063-*`
  (`caller_context`), `docs/adr/0066-*` (2.0.0 published; the freeze)
- Guides to update: `docs/observability.md` (constraint 6),
  `docs/opentelemetry.md`
- Implementation to move: `lib/statifier/session/telemetry.ex:1-752`
- Call sites (unchanged): `lib/statifier/session.ex:859-1836`
- Guard: `lib/mix/statifier/adr_guard.ex:114-127`; ledger precedent:
  `docs/quality-gate-changes.md:230-262`
- Similar prior work: `docs/plans/260816-st-cmq.1-session-telemetry-effect-trace-streams.md`
  (the plan that created the module, its guard exemption, and its ledger entry)
- Bead: `st-737e`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The README row's summary reads as a decision, not a task description,
      and matches the voice of its neighbors.
- [ ] The ADR-0040 status clause names what was amended (prefix meaning,
      emitter location, `driver` key) and does not imply the event tables
      changed.
- [ ] No employer or product terminology appears in either edit.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

No changelog fragment: `changelog.d/README.md` excludes documentation and
ADRs.

---

### Phase 2

- [ ] **Spec conformance**: this phase touches `lib/statifier/`, so the
      touched functions are read against the W3C Appendix D pseudocode -
      here the check is that *nothing* in the interpreter path changed. No
      Appendix D function is touched, no core behavior moves, and the ADR-0002
      rule has nothing to bite on: the change is emission-side only. Confirm
      by reading the diff for any edit outside `telemetry.ex`,
      `session/telemetry.ex`, the guard, and the tests.
- [ ] The moved body is a move, not a rewrite: read
      `git diff -M --find-copies-harder` (or diff the two files side by
      side) and confirm every private helper's clause ordering survived
      intact, especially `location/2`'s `d_index`-before-`c_index` rule and
      its comment.
- [ ] Attach a handler to `Statifier.Telemetry.events/0` in `iex -S mix`,
      run a small chart through `Statifier.Session` with `trace: true`, and
      confirm every event carries `driver: :session` and is otherwise
      identical to what 2.0.0 emitted.
- [ ] Call a lifecycle emitter directly with a driver atom of your own from
      `iex` - no `Statifier.Session` process anywhere - and confirm the
      event fires with that atom.
- [ ] The facade's `@moduledoc` reads as a pointer, carries no copy of the
      event tables, and states the doc-level supersession without promising
      a removal date other than "3.0".
- [ ] The guard-ledger entry's reason argues the exemption rather than
      asserting it, and cites ADR-0067.
- [ ] No employer or product terminology appears in the module docs, the
      guard comment, the ledger entry, the tests, or the changelog fragment.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---
