# Phase 4 close-out audit: sessions, invoke, send/cancel

This is the close-out audit for the `st-cmq` epic ("Phase 4: Sessions, invoke,
send/cancel"), written under `st-xvps`. It is a record, not a design document:
it walks every scope item the epic's description and notes named, says where
that item landed, and names the bead for anything still open. Read it when you
want to know whether a piece of Phase 4 shipped, shipped differently than the
epic imagined, or is still owed.

The epic's eleven children (`st-cmq.1` through `st-cmq.11`) are all closed and
merged. This audit exists because "no open children" is not the same claim as
"the scope is covered", and the epic carried two hand-offs from `st-wju.2` that
never became children of their own.

## How the evidence was taken

Every "shipped" row was verified by reading the tree at `origin/main` commit
`0c3b392` (2026-09-02), not from bead text or memory. A row cites the module
and, where it is the load-bearing part, the function. Bead close reasons supply
the PR numbers; `git log --diff-filter=A` supplies the commit that first added
each module, and its `Refs` trailer supplies the owning bead.

One cross-check worth stating on its own: **no file under `lib/` mentions
`st-cmq` any more.** The four deliberately skipped interpreter sites that
`st-wju.6` left behind (the finalize and autoforward passes in `handle_event/2`,
the `statesToInvoke` pass and its `continue` guard in `main_event_loop/1`, the
external-queue divergence, and `cancelInvoke` in `exit_interpreter/1`) each
named `st-cmq` in a comment. All four are gone, replaced by real code cited
below.

## Shipped

| Scope item | Where it landed | Evidence |
|---|---|---|
| `Statifier.Session` GenServer effect interpreter | `lib/statifier/session.ex`, with `lib/statifier/session/{effects,inbox,invocations,recording,telemetry,timers}.ex` | ADR-0003 (pure core returns effects), ADR-0044, ADR-0046; `st-cmq.4`, PR #135, first commit `cf78428` |
| Session supervision and registry shape | decided and implemented: the embedder places `Statifier.Supervisor`, and `Session.init/1` registers the session under `Statifier.Registry` (`lib/statifier/session.ex:1223`, a private one-shot whose failure is never fatal - a bare `start_link/2` embedder stays legal and unregistered). Lookup is `Registry.lookup(Statifier.Registry, sid)` | ADR-0027 (embedder-placed session runtime), decision 2; `st-cmq.10`, PR #138 |
| `Session.interpret/2` public-API question | decided | `st-cmq.11`, PR #140 |
| `<send>` and `<cancel>` as content nodes | `lib/statifier/machine/content/send.ex` (`execute/2` -> `build_effect/6`), `lib/statifier/machine/content/cancel.ex` (`execute/2`) | ADR-0035 (send id is a `MachineState` counter), ADR-0036, ADR-0047; `st-cmq.3`, PR #150, commits `db60f81`, `908975b` |
| Delayed send and cancel | `Statifier.Session.Timers` plus the `{:schedule, ...}` instruction clause of `Session.perform_instruction/3`; `Session.cancel/1` | ADR-0055 (non-self delayed-send routes stay the library's), ADR-0059 (per-execution ordinal), `docs/durable-timers.md`; `st-cmq.4`/`st-cmq.3`, commit `7d348bc` |
| External send targets and the SCXML Event I/O processor | `lib/statifier/send/target.ex`: `parse/1` covers `#_internal`/`_internal`, `#_parent`/`_parent`, `#_scxml_<sessionid>`, and `#_<invokeid>`; `supported_type?/1` scopes the engine to the SCXML Event I/O Processor | ADR-0047, ADR-0048 (route snapshot), ADR-0039 (session-detected send failures re-enter the core); `st-cmq.5`, PR #152. The module was later renamed from `Statifier.Session.Target` to `Statifier.Send.Target` by `st-yizi` (PR #176, commit `cc39ed3`) |
| `<invoke>` lowering and the `statesToInvoke` passes | `Statifier.Interpreter.run_invoke_pass/1` (`lib/statifier/interpreter.ex:1387-1430`), fed by `Statifier.Interpreter.ExitEntry` (adds on entry at `:761`, subtracts the exit set at `:139`) | ADR-0031, ADR-0032 (round budget spans the invoke re-entry); `st-cmq.6`, PR #145, commits `5df8c27`, `a63f742` |
| Invoke `type="scxml"` child sessions, `#_parent`, autoforward, finalize | `lib/statifier/session/invocations.ex` starts children; `lib/statifier/effect/autoforward.ex` and `lib/statifier/effect/trace/finalize_autoforward.ex` carry the per-invocation selection; `#_parent` routes through `Send.Target.parse/1` | ADR-0038 (invoke `src` resolves at the session boundary), ADR-0050 (invoked children inherit observation by opt-in); `st-cmq.7`, PR #155, commit `2567982` |
| Handler-registry invoke as an extension | `lib/statifier/invoke/handler.ex` with the default `lib/statifier/invoke/handler/scxml.ex`; `Statifier.Invoke.Types`; completion door `Session.done_invocation/3` | ADR-0051 (invoke handlers are registered per session); `st-cmq.8`, PR #191, commit `2ba36e1`; `docs/extending.md` |
| Session telemetry for effect and trace streams | `lib/statifier/session/telemetry.ex`, `lib/statifier/telemetry.ex` | ADR-0040 (session telemetry event contract), ADR-0049 (late-subscriber catch-up via recording); `st-cmq.1`, PR #160 |
| OpenTelemetry bridge design over those events | designed here, shipped as a separate package | ADR-0062, `docs/opentelemetry.md`; `st-cmq.2`, PR #206 |
| Corpus: send and invoke features flipped, ratchet held | `Statifier.Testing.FeatureDetector.feature_registry/0` carries `send_elements: :supported` and `invoke_elements: :supported` (`lib/statifier/testing/feature_detector.ex:91,97`) | `st-cmq.9`, PR #164 |

## The two `st-wju.2` hand-offs

`st-wju.2` deliberately left two things for this epic rather than shipping them
dead. Both landed.

| Hand-off | Where it landed | Evidence |
|---|---|---|
| 1. `states_to_invoke` as a field on `Statifier.MachineState`, added only once a real caller exists | It is a field: `lib/statifier/machine_state.ex:404` (initialized), `:479` (`MapSet.t(non_neg_integer())` in the struct type), documented at `:33-35` as mirroring Appendix D's `statesToInvoke`. Its callers are the invoke pass (`interpreter.ex:1400`, cleared at `:1430`) and the entry/exit walks (`interpreter/exit_entry.ex:761`, `:139`) - so it arrived with the caller the hand-off asked for, not before it | `st-cmq.6`, PR #145. It also became part of the serialized position: `lib/statifier/position.ex:296,334,443,524` export, validate and resolve it (ADR-0052, ADR-0064) |
| 2. First producers for the four structurally-complete-but-unproduced effects (`{:send, ...}`, `{:send_delayed, ...}`, `{:cancel, ...}`, `{:invoke, ...}`) | `%Effect.Send{}` and `%Effect.SendDelayed{}` are both built in `Machine.Content.Send`'s `build_effect/6` (`lib/statifier/machine/content/send.ex:482` for a `nil` delay, `:499` for a resolved one). `%Effect.Cancel{}` is built in `Machine.Content.Cancel.execute/2` (`lib/statifier/machine/content/cancel.ex:63`). `%Effect.Invoke{}` is built in the interpreter's invoke pass (`lib/statifier/interpreter.ex:1511`) | `st-cmq.3` (PR #150) for the first three, `st-cmq.6` (PR #145) for the fourth. The `state_index` rename the note warned about held: `lib/statifier/effect/invoke.ex` carries `state_index`, and no `source` field was reintroduced |

## Shipped differently than the epic described

| Item | What changed | Where it is recorded |
|---|---|---|
| The effect vocabulary is wider than the six ADR-0003 core effects | `lib/statifier/effect/` also carries `autoforward.ex`, `cancel_invoke.ex`, `datamodel_change.ex`, `datamodel_init.ex` and `budget_exhausted.ex`. The epic's notes assumed the four unproduced effects were the whole Phase 4 addition | ADR-0031, ADR-0032, ADR-0046 (round on every core effect); `st-cmq.6` |
| Telemetry is no longer session-only | ADR-0040 shipped `[:statifier, :session, ...]` with `Statifier.Session` as its single emitter. A second stepping driver (a host that decodes a position and calls an advance entry, with no session process) made that too narrow, so the prefix was redefined to name the logical session and a `driver` key joined every event | ADR-0067, which amends ADR-0040 in part |
| Handler invoke gained a failure door as well as a completion door | ADR-0051 decision 5 gave a handler-backed invocation only `Session.done_invocation/3`. Permanent failure had nowhere to go, so `Session.failed_invocation/3` (`lib/statifier/session.ex:751`) now delivers a suffixed `error.communication` through the same invocation door | ADR-0068, which extends ADR-0051 decision 5 |
| A synchronous handler shape was added after the epic's children closed | `lib/statifier/invoke/sync_handler.ex` and `lib/statifier/invoke/sync_handler/adapter.ex`, wrapping into the ADR-0051 registry | `st-vrqu`, PR #248, commit `4274fc9` |
| Completed-invocation retention | An invoked child's `onexit` `<send>` to `#_parent` could race behind `done.invoke`; the fix retains the completed invocation so the late message still routes | `st-vfmb`, PR #270 (2026-09-02), recorded as a Note on ADR-0027 |

## Remaining, and the bead that holds each

Nothing in the epic's scope is open without a bead. Every item below already
has one; this audit filed none.

| Remaining item | Bead | Note |
|---|---|---|
| Invoke `src`/`content` equivalence race: a child that reaches its own final in the first microstep beats a sibling delayed timer (`test242`) | `st-vy97` (P3, open) | A conformance-corpus expectation question, not a missing feature |
| Corpus exclusion policy for `<invoke src/srcexpr>` with no resolver, and for unsupported `<send type>` (BasicHTTP) | `st-lz1c` (P3, open) | Both classes are documented non-goals (ADR-0038 for `src`; `Send.Target.supported_type?/1` for the processor scope), so this is a policy decision about the ratchet, not engine work. The bead's own text still cites the pre-rename `Statifier.Session.Target.supported_type?/1`; the module is `Statifier.Send.Target` since PR #176 |
| Whether an undecodable delayed-send row surfaces into the chart or cancels silently | `st-i7y8` (P3, open) | The timer half of `st-uumw`. Event vocabulary is this repo's to decide; `statifier_oban` consumes the answer |
| The `:internal` macrostep span passes `event: nil`, so a nested span cannot be correlated back to the causing effect | `st-aos7` (P3, open) | Telemetry metadata question against ADR-0040's contract |
| Extracting heartbeats into a reusable keep-alive library | `st-ewd7` (P4, open) | **Explicitly not a Phase 4 gap.** The charter stays wait-for-demand by standing decision; it is listed here so a future reader does not re-discover it as one |

## Conclusion

Every scope item named in the `st-cmq` description, and both hand-offs the
`st-wju.2` note left to it, is shipped and verifiable at `0c3b392`. The five
open items above are each held by an existing bead, and four of the five are
decisions or corpus policy rather than unbuilt Phase 4 engine scope; the fifth
(`st-ewd7`) is a charter deliberately parked.

No scope item remains open without a bead, so no new beads were filed by this
audit.
