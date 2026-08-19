---
date: 2026-08-18T22:45:39-0600
researcher: Claude
git_commit: bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9
branch: st-m5c3-machine-identity-serialization
repository: statifier-ex
beads_issue: st-m5c3
topic: "How Machine and MachineState are shaped today, what a chart identity could hash, and what a binary serialization contract would have to round-trip"
tags: [research, codebase, machine, machine-state, serialization, identity, persistence]
status: complete
last_updated: 2026-08-18
last_updated_by: Claude
---

# Research: Machine identity and a serialization contract (st-m5c3)

**Date**: 2026-08-18T22:45:39-0600
**Git Commit**: bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9
**Branch**: st-m5c3-machine-identity-serialization
**Bead**: st-m5c3

## Research Question

What exists today, in this repository, that a chart identity and a
serialization contract would have to be built on and would have to respect?
Specifically: the shape and serializability of `%Statifier.Machine{}` and
`%Statifier.MachineState{}`; whether anything retains a canonical SCXML source
a content hash could be taken over; where the string-id / interned-index
boundary already is; what version and serialization precedents exist; and what
the accepted ADRs and design docs constrain.

This document records today's reality. It proposes no design.

## Summary

Ten findings, in the order a design would have to confront them.

1. **Both structs are already plain terms.** Nothing reachable from
   `%Machine{}` or `%MachineState{}` is a fun, pid, reference, or port. This
   is not incidental - it is an asserted, tested property ([`lib/statifier/session.ex:630`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session.ex#L630),
   [`test/statifier/session/recording_test.exs:224-248`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/test/statifier/session/recording_test.exs#L224-L248)), and `Statifier.Interpreter`'s
   own moduledoc already tells callers they may "round-trip one through
   `:erlang.term_to_binary/1` to resume in another process"
   ([`lib/statifier/interpreter.ex:38-40`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/interpreter.ex#L38-L40)). Measured on this branch (OTP 27), a
   4-state chart encodes to 5129 bytes as a `%Machine{}` and 5848 bytes as a
   `%MachineState{}`; the same `%MachineState{}` with `machine: nil` is 725
   bytes. Round-tripping both compared `==` to the originals.

2. **`%MachineState{}` embeds the whole compiled `%Machine{}`**
   ([`lib/statifier/machine_state.ex:339`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L339), `:414`). Roughly 88% of a small
   position's encoded bytes are the chart, not the position. `Session.status/1`
   exists specifically because `snapshot/1` "copies the entire compiled
   `machine` on every call" ([`lib/statifier/session.ex:636-644`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session.ex#L636-L644)). Any identity
   check at load has this reference available for free; any per-position blob
   pays for the chart again unless the two are split.

3. **There is no canonical SCXML source to hash.** `Statifier.compile/2`
   threads `source` through `Parser.parse/1`, `Lowering.lower/2`, and
   `Validator.validate/3`, but `Compiler.compile/1` never receives it
   ([`lib/statifier.ex:76-86`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier.ex#L76-L86), [`lib/statifier/compiler.ex:209`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/compiler.ex#L209)). Nothing past
   the validator holds the document text. `Parser.Location` keeps byte offsets
   into a string it does not own ([`lib/statifier/parser/location.ex:17-41`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/location.ex#L17-L41),
   `:72-76`). Two partial exceptions retain substrings: `expr()`'s
   `{:compiled, %Predicator.Compiled{}, source}` third element
   ([`lib/statifier/machine.ex:132`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L132)) and ADR-0041's `<content>` markup slice on
   `Document.Content` ([`lib/statifier/document/content.ex:47-63`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/document/content.ex#L47-L63)) - neither is
   whole-document. `Statifier.compile/2` is the only place in the library that
   holds both the source string and the finished `%Machine{}` at the same time.

4. **`%Machine{}` carries no identity and no version today.** It has `name`
   (the optional, non-unique `<scxml name>` attribute, [`lib/statifier/machine.ex:117`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L117),
   consumed only by `_name` and by telemetry) and it *drops* the SCXML
   `version` attribute the `%Document{}` carried
   ([`lib/statifier/compiler.ex:303`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/compiler.ex#L303)). No hash, no digest, no fingerprint
   exists anywhere in `lib/` - the only `:crypto` call in the library is
   `strong_rand_bytes/1` for session-id entropy
   ([`lib/statifier/machine_state.ex:522`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L522)), and `Mix.Statifier.AdrGuard` bans
   that call outside that one site ([`lib/mix/statifier/adr_guard.ex:119-123`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/mix/statifier/adr_guard.ex#L119-L123)).

5. **There is no format version anywhere, and no runtime library version.**
   [`mix.exs:4`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/mix.exs#L4) declares `@version "2.0.0-dev"` and uses it only at [`mix.exs:10`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/mix.exs#L10);
   nothing in `lib/` reads `Application.spec/2` or `:vsn`. The one repo-written
   JSON artifact, `test/passing_tests.json`, has `description` and
   `last_updated` keys and no version key
   ([`lib/mix/statifier/regression_registry.ex:5-16`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/mix/statifier/regression_registry.ex#L5-L16), `:110-142`). Telemetry
   payloads carry none (ADR-0040, [`lib/statifier/session/telemetry.ex:282-293`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session/telemetry.ex#L282-L293)).

6. **The closest existing persistable artifact is `Statifier.Session.Recording`,
   and it has the same gap.** It is `@opaque`, embeds the whole `%Machine{}` by
   value, normalizes and sorts its `opts` "so two recordings of the same run
   compare equal", and carries no version and no chart identity
   ([`lib/statifier/session/recording.ex:87-163`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session/recording.ex#L87-L163)). `Statifier.Replay.run/1`
   re-drives `Recording.machine(recording)` from inside the recording
   ([`lib/statifier/replay.ex:186-215`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/replay.ex#L186-L215)) - the recording *is* the machine, so
   ADR-0034 never has to reconcile one against another. Its single loud error,
   `{:error, {:unscheduled_timer_firing, send_id}}` ([`lib/statifier/replay.ex:264`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/replay.ex#L264)),
   is about internal inconsistency, not about the chart having changed. The
   recording's `opts` also carry `:invoke_handlers`, a `%{String.t() => module()}`
   map ([`lib/statifier/session/recording.ex:111-118`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session/recording.ex#L111-L118)) - atoms, so they encode,
   but they name code rather than data.

7. **The string-id boundary is ADR-0005's, not ADR-0006's.** ADR-0005's
   Consequences say it in one sentence: "Configurations are `MapSet`s of
   integers; string IDs appear only at the API boundary (parsing in,
   event/introspection out)" ([`docs/adr/0005-full-configuration-and-interned-state-indexes.md:25-28`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/adr/0005-full-configuration-and-interned-state-indexes.md#L25-L28)).
   ADR-0006 is about the conformance corpus and the regression ratchet and
   contains no such rule - see Open Questions.

8. **Both translation directions already exist.** Index to id is
   `Statifier.Machine.id/2` ([`lib/statifier/machine.ex:341-347`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L341-L347)), total,
   returning `nil` for the root and for nameless states; id to index is
   `Statifier.Machine.index/2` ([`lib/statifier/machine.ex:337-339`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L337-L339)), a bare
   `Map.fetch/2` over the partial `id_to_index` map, returning `:error` on an
   unknown id. Two call sites already do the map/reject/`MapSet.new` pipeline:
   `Statifier.active_leaf_states/1` ([`lib/statifier.ex:152-158`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier.ex#L152-L158), leaf view) and
   `Statifier.Session`'s private `translate_configuration/2`
   ([`lib/statifier/session.ex:2044-2051`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session.ex#L2044-L2051), full configuration, used by `status/1`).

9. **Serializing a `%Machine{}` reopens a hazard ADR-0014 declared inapplicable.**
   ADR-0014 item 2 says predicator's storage advice "does not apply here: we
   compile conds in-process at Machine-build time and store no instruction
   lists ... so the round trip that hazard describes does not exist for us"
   ([`docs/adr/0014-expression-spans-in-cond-diagnostics.md:78-83`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/adr/0014-expression-spans-in-cond-diagnostics.md#L78-L83)). That
   premise holds only because nothing is persisted today. `Predicator.Compiled`'s
   own moduledoc is explicit: the struct "is **not** a wire format"; `positions`
   and `segment_positions` "hold offsets into the source string the program was
   compiled from"; "Nothing checks that a `positions` table actually came from
   the `instructions` list it is attached to ... just a confidently wrong
   position, which is worse than the honest `position: nil`"; and a consumer
   that wants positions back "should persist the *source* ... recompiling the
   same source is deterministic and yields an identical table every time"
   ([`deps/predicator/lib/predicator/compiled.ex:10-38`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/deps/predicator/lib/predicator/compiled.ex#L10-L38)).

10. **The versioned-artifact prior art is upstream, in predicator.**
    `Predicator.isa_version/0` returns an integer "independent of this library's
    semantic version", to be compared against
    `Predicator.Instructions.required_isa/1` "before running a stored
    instruction list, so a version mismatch is caught up front instead of
    failing partway through evaluation" ([`deps/predicator/lib/predicator.ex:677-692`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/deps/predicator/lib/predicator.ex#L677-L692)),
    with `Predicator.Instructions.upgrade/1` as the documented migration path
    for a stored artifact holding a retired opcode
    ([`deps/predicator/lib/predicator/instructions.ex:32-37`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/deps/predicator/lib/predicator/instructions.ex#L32-L37)). That is the
    integer-format-version-plus-upgrade shape the bead's "explicit format
    version" asks for, already in a dependency this repo pins at `~> 9.0`.

## Detailed Findings

### `%Statifier.MachineState{}` - 19 fields, every one a plain term

Struct at [`lib/statifier/machine_state.ex:337-360`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L337-L360), types at `:413-433`.

| Field | Shape | Round-trips |
|---|---|---|
| `machine` | `Machine.t()` - the whole compiled chart | yes |
| `configuration` | `MapSet` of integer indexes (ADR-0005) | yes |
| `internal_queue` | `:queue.queue(Event.t())` | yes; see note below |
| `history_values` | `%{index => MapSet of indexes}` | yes |
| `entered_states` | `MapSet` of indexes | yes |
| `states_to_invoke` | `MapSet` of indexes | yes |
| `active_invocations` | `%{{state_index, invoke_index} => invokeid string}` | yes |
| `invoke_counter`, `send_counter` | integers (ADR-0008 as amended, ADR-0035) | yes |
| `datamodel` | map, string/boolean keys at every level | yes, as this library writes it |
| `running`, `status`, `trace` | `boolean`, `:running \| :done`, `boolean` | yes |
| `macrostep`, `microstep`, `round` | integers (ADR-0020) | yes |
| `max_macrostep_rounds` | `pos_integer() \| :infinity` (ADR-0019) | yes |
| `routes` | `%Statifier.Send.Routes{}` or `nil` (ADR-0048) | yes |
| `invoke_types` | `%Statifier.Invoke.Types{}` or `nil` (ADR-0051) | yes |

The three fields the bead flagged as risks are all clean:

- **`routes`** is `%Routes{sessions: MapSet.t(String.t()), parent?: boolean(),
  invokes: MapSet.t(String.t())}` ([`lib/statifier/send/routes.ex:26-32`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/send/routes.ex#L26-L32)) -
  sets of id strings, "a point-in-time claim, not a subscription"
  ([`lib/statifier/machine_state.ex:391-400`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L391-L400)). No pids.
- **`invoke_types`** is `%Types{types: MapSet.t(String.t())}`
  ([`lib/statifier/invoke/types.ex:27-29`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/invoke/types.ex#L27-L29)) - type URIs, not handler modules.
  The handler map `%{String.t() => module()}` lives in the ephemeral plan
  context threaded by `Statifier.Session.Effects.plan/2`
  ([`lib/statifier/invoke/handler.ex:60-64`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/invoke/handler.ex#L60-L64)), never on the struct.
- **`active_invocations`** holds only the `invokeid` string. Its moduledoc is
  explicit that no pid, monitor ref, or child session id lives here
  ([`lib/statifier/machine_state.ex:82-87`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L82-L87) region) - that identity is in an
  ADR-0027 parent-held table off the struct.

Two shape notes that bear on a contract rather than on encodability:

- **`internal_queue` breaks `==` as a position test.** The moduledoc says so
  itself ([`lib/statifier/machine_state.ex:309-320`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L309-L320)): two `:queue` values holding
  the same events in the same order can differ in their front/rear split.
  `internal_events/1` ([`lib/statifier/machine_state.ex:644-645`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L644-L645),
  `:queue.to_list/1`) is the normalized view. A `term_to_binary` round trip of
  one value reproduces that value, so this is a comparison hazard, not an
  encoding one.
- **`datamodel` value types are unchecked.** `new/2` runs `checked_datamodel!/1`
  ([`lib/statifier/machine_state.ex:535-560`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L535-L560)), which inspects *keys* only, and
  only at construction - later writes (`<assign>`, `put_event/2`) are not
  re-checked. Every value this library itself writes is plain predicator data,
  but nothing statically stops an embedder from placing an arbitrary term in
  the map at `new/2`. ADR-0037's `nil`-vs-`:undefined` distinction
  ([`docs/datamodel.md:198-210`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/datamodel.md#L198-L210)) must survive any round trip.

The session id has no field of its own: it is `datamodel["_sessionid"]`,
written once by `SystemVariables.initial/2`
([`lib/statifier/evaluator/system_variables.ex:74-84`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/evaluator/system_variables.ex#L74-L84)) and never rewritten. It
is also embedded in `datamodel["_ioprocessors"]` as `"#_scxml_" <> session_id`.

### `%Statifier.Machine{}` - the transitive tree

Struct and types at [`lib/statifier/machine.ex:110-158`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L110-L158): `states`,
`id_to_index`, `transitions`, `contents`, `data_elements` (four dense tuples
plus one map), `name`, `datamodel`, `binding`, `location`, `global_scripts`,
`warnings`.

Reachable structs, all plain-field: `Machine.State`
([`lib/statifier/machine/state.ex:73-116`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine/state.ex#L73-L116)), `Machine.Transition`
([`lib/statifier/machine/transition.ex:73-98`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine/transition.ex#L73-L98)), `Machine.Block`, `Machine.Data`,
`Machine.Donedata`, `Machine.Invoke`, `Machine.Param`, the eight
`Machine.Content.*` variants (`Assign`, `Cancel`, `Foreach`, `If` plus
`If.Branch`, `Log`, `Raise`, `Script`, `Send`), `Parser.Location` (six plain
integers, [`lib/statifier/parser/location.ex:17-41`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/location.ex#L17-L41)), `Validator.Warning`
([`lib/statifier/validator/warning.ex:31-38`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/validator/warning.ex#L31-L38)), `Compiler.Error`
([`lib/statifier/compiler/error.ex:34-41`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/compiler/error.ex#L34-L41)), and `Predicator.Compiled`
([`deps/predicator/lib/predicator/compiled.ex:84-90`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/deps/predicator/lib/predicator/compiled.ex#L84-L90)).

`Predicator.Compiled` is bytecode-as-data: `instructions` is a list of
`[opcode_binary, operand]` entries and `positions` / `segment_positions` are
maps of integer to line/column tuples
(`deps/predicator/lib/predicator/types.ex:114,121,136,162,176-178`). No
closures - predicator interprets the instruction list rather than emitting
funs.

No `MapSet` appears anywhere in the Machine tree; the maps present
(`id_to_index`, every `attribute_locations`, the position tables) are read by
key, never by iteration order. `Location` instances outnumber the nodes they
annotate, several nodes carrying two or three, which is what makes a Machine's
encoded size dominated by diagnostics rather than by structure.

### Measured sizes (this branch, OTP 27)

Compiled from a 4-state chart with one `<log expr>`, one `cond`, and one
`<final>`:

```
machine bytes:                    5129
machine bytes (compressed: 9):    1055
machinestate bytes:               5848
machinestate w/o machine:          725
roundtrip machine equal?:         true
roundtrip machinestate equal?:    true
```

A second chart of comparable size (286 bytes of XML, 4 states) encoded to 4287
bytes / 820 compressed. Map encoding was stable across two encodes of equal
maps built in different insertion orders, both with and without the
`:deterministic` option.

### The compile pipeline, and where a hash would have to be taken

```
Statifier.compile(source, opts)          lib/statifier.ex:76-86
  |- Parser.parse(source)                lib/statifier/parser.ex:104-114
  |- Lowering.lower(root, source)        lib/statifier/lowering.ex:104-106
  |- Validator.validate(document, source, opts)   lib/statifier/validator.ex:115-117
  `- Compiler.compile(document)          lib/statifier/compiler.ex:209   <- no source
```

`%Statifier.Document{}` ([`lib/statifier/document.ex:112-147`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/document.ex#L112-L147)) has `location`
and `attribute_locations` but no `source` field. The DOM nodes hold normalized
values and spans, not text: `DOM.Element`
([`lib/statifier/parser/dom/element.ex:30-31`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/dom/element.ex#L30-L31)), `DOM.Text`
([`lib/statifier/parser/dom/text.ex:24-25`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/dom/text.ex#L24-L25)), `DOM.Attribute`
([`lib/statifier/parser/dom/attribute.ex:31-32`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/dom/attribute.ex#L31-L32), whose comment says outright
"nothing needs to be stored here").

Two normalizations run at parse time and are one-way with respect to the
original bytes: ADR-0043 attribute-value normalization
([`lib/statifier/parser/location.ex:168-176`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/location.ex#L168-L176)) and ADR-0045 character-data
line-break folding ([`lib/statifier/parser/location.ex:217-225`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/location.ex#L217-L225)). The raw span
is still recoverable through `Location.slice/2` while `source` is in hand;
after `Validator.validate/3` returns, it is not.

`%Statifier.Document{}` is not a substitute normalized form: its own moduledoc
calls it "walkable and unambiguous, not fast" and the "pre-validation type"
that can "hold the malformed shapes the validator exists to report"
([`lib/statifier/document.ex:1-12`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/document.ex#L1-L12)). Whitespace-only text runs and comments are
filtered out by `Statifier.Parser.DOM.elements/1`
([`lib/statifier/parser/dom.ex:26-29`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/dom.ex#L26-L29)).

### The public boundary

`lib/statifier.ex` is the whole top-level surface: `compile/2` (`:75-86`),
`initialize/2` (`:112-115`), `send_event/2` (`:132-138`),
`active_leaf_states/1` (`:151-158`), `start_session/2` (`:183-203`). Only
`active_leaf_states/1` speaks string ids; `initialize/2` and `send_event/2`
hand back the raw integer-indexed `%MachineState{}`.

`Statifier.Session` exposes both shapes and documents the split at
[`lib/statifier/session.ex:292-301`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session.ex#L292-L301): `snapshot/1` (`:627-634`) returns the whole
`%MachineState{}` - "a complete, resumable position ... A term copy and nothing
more: `MachineState` carries no pid, ref, port, or fun" - integer-indexed;
`status/1` (`:636-645`) returns a projection whose `configuration` is
`MapSet.t(String.t())` (`:408-421`), translated by `translate_configuration/2`
(`:2044-2051`), and read from the retained `%Effect.Done{}` for a halted
session (`:2029-2042`).

Full configuration versus leaf view is orthogonal to string versus index. Full
configuration is what is stored (`MachineState.configuration`) and what every
effect carries (`Effect.Done`, `Effect.BudgetExhausted`, `Effect.Trace.EntrySet`,
`Effect.Trace.ExitSet`); the leaf view is derived on demand by
`MachineState.active_leaf_states/1` ([`lib/statifier/machine_state.ex:597-613`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L597-L613)),
whose own doc says the string translation "belongs to a future API boundary,
not this module's". So today: `Statifier.active_leaf_states/1` is leaf+string,
`Session.snapshot/1` is full+index, `Session.status/1` is full+string.

### `Statifier.Session.Recording` and `Statifier.Replay`

`recording.ex:87-103`: `@enforce_keys [:machine, :opts, :entries]`, `@opaque t`
over `machine: Machine.t()`, `opts: keyword()`, `entries: [entry()]`. Entry
variants at `:90-104` cover events, invoked events, cancels, timer firings,
`interpret/2` batches, and internal/platform events, each carrying the ADR-0048
`Routes.t() | nil` snapshot in force for the drive it triggered.

`new/2` (`:144-163`) takes exactly `@normalized_opts` - `:session_id`, `:trace`,
`:datamodel`, `:max_macrostep_rounds`, `:routes`, `:invoke_types`,
`:invoke_handlers` - defaults each and `Enum.sort()`s them "so two recordings
of the same run compare equal regardless of the order their options were
supplied in". That is the repo's only existing canonicalization-for-equality
precedent. `opts[:session_id]` "should be the id the session actually resolved
to (`machine_state.datamodel["_sessionid"]`)".

The recording is deliberately clock-free ("Nothing here reads a clock",
moduledoc) and the timer `make_ref/0` is dropped because it "has no
reproducible value across runs". [`test/statifier/session/recording_test.exs:224-248`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/test/statifier/session/recording_test.exs#L224-L248)
asserts the term round trip, with a comment stating the test exists only to
check that the struct carries no pid/ref/port/fun.

`Statifier.Replay.run/1` ([`lib/statifier/replay.ex:186-215`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/replay.ex#L186-L215)) calls
`Interpreter.initialize(Recording.machine(recording), Recording.opts(recording))`
and folds `apply_entry/2` over the entries. It never recompiles source and
never consults a registry (`:96-105`). One tolerance for older artifacts is
already documented at `:222-233`: an `{:invoked_event, ...}` from a dead
invocation "captured by an older build" is skipped rather than failing.

### What the ADRs constrain

- **ADR-0003 (pure core).** The core is `(machine_state, event) -> {machine_state, [effect]}`.
  A load-time identity check is pure validation and fine; the act of reading a
  blob is boundary work, like parsing.
- **ADR-0005.** Quoted above. Indexes inside, string ids at the boundary; "the
  Machine keeps both directions".
- **ADR-0008 as amended (2026-08-15).** Ids minted outside the core are UXIDs;
  ids minted inside are deterministic values derived from `%MachineState{}`
  alone, because "the pure core's contract does not admit" a clock or CSPRNG. A
  content hash is derived, not minted, but the no-entropy-in-pure-computation
  line applies to where it is computed. ADR-0008's own amendment notes the
  UXID-dependency drop "breaks no compatibility: no persisted run, external
  identifier store ... exists" ([`docs/adr/0008-uxid-for-identifiers.md:228`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/adr/0008-uxid-for-identifiers.md#L228)).
- **ADR-0012 (`docs/observability.md`).** Constraint 1: "Any machine_state value
  is a complete, inspectable, resumable position" ([`docs/observability.md:26-49`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/observability.md#L26-L49)).
  Constraint 3: the Machine retains locations and stable document-order
  identities `t_index` / `c_index` / `d_index`, "compile-time-immutable Machine
  data - no runtime cost beyond memory, no invalidation story"
  ([`docs/observability.md:118-158`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/observability.md#L118-L158)). Constraint 4: the three step counters live
  on `machine_state` and are load-bearing for trace ordering. Anything a
  round trip drops breaks one of these silently.
- **ADR-0014 item 2.** The predicator span-table hazard, declared inapplicable
  on the premise that nothing is stored. See Summary point 9.
- **ADR-0027.** `restart: :temporary`, because a supervisor restart cannot
  restore identity - "recovery that preserves identity is replay ... and
  belongs to the embedder or a later replay bead, not to a restart flag."
- **ADR-0030.** Three grounds for keeping a built `%Predicator.Context{}` off
  `%MachineState{}`: (1) a closure "could not survive a node boundary, a code
  reload, or a round-trip through storage, so a struct carrying one could not
  be a resumable position under ADR-0012 constraint 1"; (2) staleness across
  multiple write sites; (3) duplication of a fact another field already states.
  ADR-0048 distinguishes itself against grounds 2 and 3 explicitly for
  `routes`, and ADR-0051 follows for `invoke_types`. The working test a new
  field on either struct has to pass is therefore: plain value, single write
  site, no duplication.
- **ADR-0029 / ADR-0034.** Replay's four inputs are the machine, the initial
  data, the external event log, and the `interpret/2` batches. ADR-0034 does
  **not** address a chart changing underneath a saved artifact - replay assumes
  it re-drives the same machine, because the recording carries it.
- **ADR-0040.** Establishes the "public contract, frozen at a named point,
  changing it afterwards is a breaking change" pattern for the telemetry event
  names, without a version field.
- **ADR-0041.** An entire record about *not* building an XML re-serializer,
  preferring a source slice. House precedent that declining to build
  round-trip machinery is a citable decision, and that round-trip integrity is
  the axis such a decision is argued on.
- **ADR-0006.** The corpus and ratchet, plus the driving-surface function set,
  widened by its 2026-08-17 amendment to nine named functions plus
  `MachineState.active_leaf_states/1` as a declared exception. Adding a
  function to that list "reopens this record."

### Docs: what a contract would sit inside, and where prose would live

[`docs/architecture.md:8-41`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/architecture.md#L8-L41) holds the four numbered principles. Principle 2
(pure core, effects at the edge, `:23-29`) puts serialization at the boundary
layer, beside `Statifier.Session`, not in the core. Principle 4 ("make invalid
states unrepresentable", `:36-41`) is the one a deserialized `%Machine{}`
tests: today a `%Machine{}` exists only because the validator passed. The
layer diagram is at `:45-64`, the Machine description at `:75-89`, the
MachineState description at `:92-106`, and the deterministic invoke-id counter
at `:184-194`.

`docs/datamodel.md` supplies the round-trip constraints on the datamodel map:
string keys at every level checked at `MachineState.new/2` (`:111-114`), the
`nil` / `:undefined` distinction (`:198-210`), and the separate fact that the
datamodel is already reconstructible from the effect stream alone via one
`{:datamodel_init, ...}` plus one `{:datamodel_change, ...}` per bound `<data>`
(`:36-44`).

[`docs/observability.md:257-263`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/observability.md#L257-L263) states the standing non-goal: "No trace
persistence/rotation story" - scoped to trace effects, not to `MachineState`.

[`docs/extending.md:154-159`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/extending.md#L154-L159) is the only place in any top-level doc that already
speaks of a persist/reload cycle as a real thing: "`invoke_id` stays stable
across a persist/reload cycle because it is not a freshly generated value - it
is a deterministic counter carried on `%Statifier.MachineState{}` (ADR-0008, as
amended)." Its handler idempotency section (`:177-189`) describes a host that
"crashes between starting an instruction and durably recording that it ran".

The docs tree is `docs/{architecture,datamodel,extending,observability,testing,workflow,quality-gate-changes}.md`
plus `docs/adr/`, `docs/plans/`, `docs/research/`. [`docs/adr/README.md:1-57`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/adr/README.md#L1-L57)
sets the ADR conventions: numbered table, next number, three sections
(Context, Decision, Consequences). There is no "public seams index" doc; a
concern-scoped doc per cross-cutting constraint is the established shape
(`observability.md`, `datamodel.md`, `extending.md`).

### Related beads

- **st-5yhl** - "Boots a session from a persisted MachineState (resume API)",
  open, P1, blocked by st-m5c3. Adds a `machine_state:` / `resume:` option to
  `Session.start_link/2`, defines what resume does not restore (in-flight
  delayed-send timers, live invoked children) and how it composes with
  `record: true` and ADR-0049/0050 catch-up.
- **st-q6xl** - "Charter: statifier_persistence - durable stepper and storage
  adapters", open, P2, blocked by both st-m5c3 and st-5yhl. Its acceptance
  criteria require the save/load of MachineState snapshots to be "guarded by
  the Machine identity/content-hash ... so a position can never be loaded
  against the wrong chart revision", enforced on every load.
- **st-rsyx** - "Charter: statifier_oban", open, P2. Owns the durable-timer
  half st-5yhl excludes.
- **st-ewd7** - keep-alive library charter, open, P4, blocked by st-5yhl.
- **st-jdvr** - pinnable pre-release and CI, open, P2; names statifier_persistence
  and statifier_oban as satellites that can only pin a moving `2.0.0-dev` by git
  SHA today.

No bead other than st-m5c3 holds the hashing, versioning, or position-migration
concept.

### v1 prior art (`../statifier`, read-only)

Nothing to port. v1 had a persistence *hook* and no mechanism: the
`handle_snapshot/2` callback (`../statifier/lib/statifier/state_machine_behaviour.ex:172-183`)
hands the host a live `%StateChart{}` on a `Process.send_after/3` timer
(`../statifier/lib/statifier/state_machine.ex:475-486`, `:373-376`) and the
return value is ignored. Nothing ever reads a snapshot back, there is no
encoding, no chart identity, and no hashing anywhere in its `lib/`.
`docs/roadmap.md:50` there lists persistence as a future item.

The `%StateChart{}` could not have been serialized anyway: it embeds a
`state_machine_pid` and a map of anonymous invoke-handler closures
(`../statifier/lib/statifier/state_chart.ex:11-48`), which is presumably why
the callback hands the struct out rather than encoding it. Its configuration
was `MapSet.t(String.t())` of leaf ids
(`../statifier/lib/statifier/configuration.ex:13-17`), with ancestors expanded
on demand - so v1's in-memory position was incidentally already in the
boundary vocabulary the bead wants exported, with no interning layer to
invalidate.

## Code References

- [`lib/statifier.ex:75-86`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier.ex#L75-L86) - `compile/2`, the only place holding both `source` and the finished `%Machine{}`
- [`lib/statifier.ex:151-158`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier.ex#L151-L158) - `active_leaf_states/1`, the leaf+string boundary translation
- [`lib/statifier/machine.ex:110-158`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L110-L158) - the `%Machine{}` struct and its types
- [`lib/statifier/machine.ex:132`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L132) - `expr()`, whose `{:compiled, ...}` arm carries `%Predicator.Compiled{}` plus source
- [`lib/statifier/machine.ex:337-347`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine.ex#L337-L347) - `index/2` and `id/2`, both translation directions
- [`lib/statifier/machine_state.ex:337-360`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L337-L360) - the 19-field struct
- [`lib/statifier/machine_state.ex:309-320`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L309-L320) - why `==` is not a position test (`:queue` front/rear split)
- [`lib/statifier/machine_state.ex:511-524`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L511-L524) - `generate_session_id/0`, the only `sess_` mint
- [`lib/statifier/machine_state.ex:535-560`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L535-L560) - `checked_datamodel!/1`, keys only, construction only
- [`lib/statifier/machine_state.ex:597-613`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/machine_state.ex#L597-L613) - `active_leaf_states/1`, the derived leaf view in indexes
- [`lib/statifier/compiler.ex:209`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/compiler.ex#L209) - `compile/1`, the point past which `source` is gone
- [`lib/statifier/compiler.ex:303`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/compiler.ex#L303) - copies `name`, `datamodel`, `binding`; drops the SCXML `version`
- [`lib/statifier/parser/location.ex:17-41`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/parser/location.ex#L17-L41), `:72-76` - the six-integer span and `slice/2`
- [`lib/statifier/interpreter.ex:38-40`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/interpreter.ex#L38-L40) - the moduledoc that already promises a `term_to_binary` round trip
- [`lib/statifier/session.ex:292-301`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session.ex#L292-L301), `:627-645` - the two snapshot shapes
- [`lib/statifier/session.ex:2044-2051`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session.ex#L2044-L2051) - `translate_configuration/2`, the full+string translation
- [`lib/statifier/session/recording.ex:87-163`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/session/recording.ex#L87-L163) - the recording struct, entry variants, and `new/2` normalization
- [`lib/statifier/replay.ex:186-215`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/replay.ex#L186-L215), `:264` - `run/1` and its one loud error
- [`lib/statifier/send/routes.ex:26-32`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/send/routes.ex#L26-L32), [`lib/statifier/invoke/types.ex:27-29`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/invoke/types.ex#L27-L29) - the two ADR-0048/0051 snapshot structs
- [`lib/statifier/invoke/handler.ex:60-64`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/statifier/invoke/handler.ex#L60-L64) - the handler-module map, in the ephemeral plan context
- [`lib/mix/statifier/adr_guard.ex:119-123`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/mix/statifier/adr_guard.ex#L119-L123) - the ban on ad-hoc `strong_rand_bytes/1`
- [`lib/mix/statifier/regression_registry.ex:110-142`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/lib/mix/statifier/regression_registry.ex#L110-L142) - the repo's one hand-rolled canonical JSON encoder
- [`mix.exs:4`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/mix.exs#L4), [`mix.exs:10`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/mix.exs#L10) - `@version "2.0.0-dev"`, build-time only
- [`deps/predicator/lib/predicator/compiled.ex:10-38`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/deps/predicator/lib/predicator/compiled.ex#L10-L38) - "not a wire format", and why
- [`deps/predicator/lib/predicator.ex:677-692`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/deps/predicator/lib/predicator.ex#L677-L692) - `isa_version/0`
- [`deps/predicator/lib/predicator/instructions.ex:32-37`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/deps/predicator/lib/predicator/instructions.ex#L32-L37) - `upgrade/1`, the migration path
- [`test/statifier/interpreter/interpreter_acceptance_test.exs:143-178`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/test/statifier/interpreter/interpreter_acceptance_test.exs#L143-L178) - round-trips `%MachineState{}` between microsteps
- [`test/statifier/session/recording_test.exs:224-248`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/test/statifier/session/recording_test.exs#L224-L248) - round-trips a populated recording

## Architecture Documentation

The design already leans toward serializability without naming it. ADR-0012
constraint 1 makes `%MachineState{}` a complete resumable position; ADR-0008 as
amended makes every core-minted id a deterministic counter precisely so it
"replays identically"; ADR-0034's recording is clock-free and ordinal-ordered;
`Session.snapshot/1`'s doc asserts the no-pid-ref-port-fun property outright.
Three prior research documents state the same property in the same words
(`docs/research/260814-st-cmq.4-...:108`, `:317`;
`docs/research/260815-st-dtm-...:66`;
`docs/plans/260814-st-cmq.4-...:50`).

What the design has never had is a *name* for a chart revision. The stable
identities ADR-0012 constraint 3 names - `t_index`, `c_index`, `d_index`, and
by extension the state index itself - are stable *within* one Machine build and
say nothing across two. That is exactly the gap the bead's motivating sentence
describes, and nothing in the repo currently detects it: `Statifier.Replay`
sidesteps it by carrying the Machine inside the recording, and no other
artifact outlives a process.

ADR-0030's three grounds, as narrowed by ADR-0048 and ADR-0051, are the
standing test any new field on either struct is argued against - plain value,
single write site, no duplication of a fact another field already states.

## Historical Context

- [`docs/research/260815-st-dtm-replay-recorder-session-boundary.md:140-143`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/research/260815-st-dtm-replay-recorder-session-boundary.md#L140-L143) -
  scoped persistence out explicitly: "No persistence, no wire format, no
  serialization layer ... choosing a format is that bead's job." Line 486
  leaves the format and owning module as an open question. Line 66 records the
  no-pid-ref-port-fun property with permalinks.
- [`docs/research/260818-st-cmq.8-handler-registry-invoke.md:200`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/research/260818-st-cmq.8-handler-registry-invoke.md#L200) - a section
  titled "Invoke ids and persist/reload stability"; lines 676-678 describe
  st-q6xl's charter as "load a persisted position, step it, execute the
  effects, persist", with no Session process.
- [`docs/research/260809-st-wju.1-compile-document-to-interned-machine.md:395-397`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/research/260809-st-wju.1-compile-document-to-interned-machine.md#L395-L397),
  `:471-476` - the first place predicator's "never persist the struct" advice
  was weighed against the interned-Machine design.
- [`docs/research/260814-st-l0t-provider-host-seam-for-in1.md:302-311`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/research/260814-st-l0t-provider-host-seam-for-in1.md#L302-L311), `:505` -
  notes that ADR-0012 constraint 1 "never mentions serialization, node
  boundaries, or code reload"; ADR-0030 is where that reasoning landed.
- [`docs/adr/0008-uxid-for-identifiers.md:228`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/adr/0008-uxid-for-identifiers.md#L228) - "no persisted run, external
  identifier store ... exists", the amendment's own compatibility argument.
- [`docs/adr/0049-late-subscriber-catch-up-via-recording.md:58`](https://github.com/riddler/statifier-ex/blob/bfa2a3b3015faa4a21d9c4b26254ab8da4a092a9/docs/adr/0049-late-subscriber-catch-up-via-recording.md#L58), `:191` - defers
  to `docs/observability.md`'s persistence non-goal.

## Related Research

- `docs/research/260815-st-dtm-replay-recorder-session-boundary.md` - the
  recorder at the session boundary; the nearest prior art and the document that
  deliberately left this bead's job undone
- `docs/research/260818-st-cmq.8-handler-registry-invoke.md` - invoke-id
  persist/reload stability, and the st-q6xl charter
- `docs/research/260814-st-cmq.4-session-genserver-effect-interpreter.md` - the
  `snapshot/1` / `status/1` split and the plain-serializable-value claim
- `docs/research/260809-st-wju.1-compile-document-to-interned-machine.md` - the
  interned Machine and predicator's storage advice
- `docs/research/260814-st-l0t-provider-host-seam-for-in1.md` - the
  resumable-position contract as it was read before ADR-0030
- `docs/research/260818-st-uqo4-late-subscriber-trace-and-session-header.md` -
  probing the trace-persistence non-goal

## Open Questions

These are recorded, not answered. No human was available during this research.

1. **The bead cites an "ADR-0006 public-surface rule" that does not resolve.**
   ADR-0006 is the conformance corpus and regression ratchet; its only
   surface-shaped content is the driving-surface function list (four functions,
   widened to nine by its 2026-08-17 amendment, plus
   `MachineState.active_leaf_states/1` as a declared exception). The rule the
   bead describes is ADR-0005's Consequences sentence
   (`docs/adr/0005-...:25-28`). Two readings are possible and they lead
   different places: the citation is simply a typo for ADR-0005, or it is a
   deliberate pointer at ADR-0006's driving-surface list, in which case adding
   `to_binary` / `from_binary` / a position export to the public API reopens
   ADR-0006 by its own terms. Worth settling before the bead's description is
   quoted into a plan.
2. **What the identity is taken over is unresolved by the codebase.** There is
   no canonical source past the validator, and `%Statifier.Document{}` is
   documented as a pre-validation, lossy-relative-to-bytes projection. The
   candidates the code makes available are: the raw `source` binary at
   `Statifier.compile/2` (available, but never retained today), a term hash
   over the finished `%Machine{}` (available, but includes `Location` spans, so
   a whitespace edit changes the identity), or an embedder-supplied name and
   version (the bead already calls this optional). Nothing in the repo picks.
3. **Whether the identity is stamped on `%Machine{}` or computed on demand.**
   ADR-0030's grounds-3 test (no duplication of a fact another field states) is
   the relevant precedent and does not obviously resolve either way: a hash of
   the Machine's own content stored on the Machine is a cached derived fact of
   exactly the kind ADR-0030 and predicator's ADR-0009 both name as a hazard,
   while a hash of the *source* is a fact the Machine does not otherwise hold.
4. **Whether a serialized `%Machine{}` is in scope at all, given ADR-0014.**
   Serializing the Machine carries `%Predicator.Compiled{}` structs whose
   position tables predicator explicitly says not to persist, on grounds
   ADR-0014 item 2 currently rules inapplicable "because we store no instruction
   lists". Persisting only `%MachineState{}` against a Machine recompiled from
   source would keep that premise true - and predicator states that recompiling
   the same source "is deterministic and yields an identical table every time" -
   but the bead's acceptance criteria name `to_binary` / `from_binary` for both.
   Either scope is defensible; the record does not choose.
5. **What "the position" is, for export.** The full configuration and the leaf
   view are both defensible boundary vocabularies and both already exist. Beyond
   the configuration, a resumable position also carries `history_values` (keyed
   by history-pseudostate index, valued by index sets),
   `states_to_invoke`, `entered_states`, and `active_invocations` (keyed by
   `{state_index, invoke_index}`) - all index-keyed, all subject to the same
   invalidation hazard. Whether a string-id export covers only the
   configuration or all five is not implied by anything in the codebase.
6. **`Statifier.Session.Recording` is `@opaque` and carries a whole Machine.**
   Whether it is in scope for the identity stamp and format version, or whether
   it stays out until a later bead, is unstated. It is the only existing
   artifact anyone might already be holding across a chart change.
7. **The library version is not reachable at runtime.** Nothing reads
   `Application.spec(:statifier, :vsn)`. If a blob is to record which build
   wrote it, that reader does not exist yet.
8. **`:invoke_handlers` in a recording's `opts` names modules, not data.** A
   module atom encodes fine and means nothing on a node where that module is
   absent or has changed. Whether a format version or an identity covers that
   is unaddressed.
