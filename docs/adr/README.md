# Architecture Decision Records

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | accepted |
| [0002](0002-literal-w3c-appendix-d-port.md) | Port the W3C SCXML algorithm literally (Appendix D) | accepted (amended 2026-08-09: predicate naming) |
| [0003](0003-pure-core-with-effects.md) | Pure functional core returning effects | accepted |
| [0004](0004-predicator-as-the-datamodel.md) | Predicator is the datamodel; no ECMAScript, no Elixir eval | accepted (amended in part by 0026: `<script>`) |
| [0005](0005-full-configuration-and-interned-state-indexes.md) | Full configuration; interned state indexes | accepted |
| [0006](0006-reuse-conformance-corpus-and-regression-ratchet.md) | Reuse conformance corpus and ratchet; commit a generator | accepted |
| [0007](0007-beads-for-issue-tracking.md) | Beads for issue tracking | accepted |
| [0008](0008-uxid-for-identifiers.md) | UXID for generated identifiers | accepted (amended 2026-08-15: invoke id format; invoke platformid is a session counter, not a UXID; amended 2026-08-15: the uxid dependency is dropped, the format decisions stand) |
| [0009](0009-ex-quality-as-quality-gate.md) | ex_quality is the quality gate | accepted |
| [0010](0010-worktree-parallel-development.md) | Worktree parallel development via beads | accepted |
| [0011](0011-quality-gate-config-not-agent-editable.md) | Quality gate config is not agent-editable | accepted |
| [0012](0012-debuggability-designed-into-the-core.md) | Debuggability is designed into the core | accepted |
| [0013](0013-archive-v1-statifier-repo-in-place.md) | Archive the v1 statifier repo in place | accepted |
| [0014](0014-expression-spans-in-cond-diagnostics.md) | Expression-level spans are part of the retained-location constraint | accepted (amended 2026-08-15: item 4 stops at the predicator seam; engine policy checks are not expression failures; amended 2026-08-18: item 4's protected-root refusal is a policy check, not a predicator error) |
| [0015](0015-skill-mechanics-in-scripts.md) | Skill mechanics live in scripts, judgment lives in prose | superseded by 0017 (amended in part by 0016) |
| [0016](0016-wurk-skills-out-of-repo-extensions-gated.md) | The wurk skills live in their own repo; this repo gates its extensions | accepted (amends 0015 in part; amended by 0017) |
| [0017](0017-judgment-not-scriptable-in-wurk-extensions.md) | Judgment is not scriptable, scoped to the wurk extension surface | accepted (supersedes 0015; amends 0016 in part) |
| [0018](0018-no-process-jargon-in-code-comments.md) | Process artifacts are not code comments | accepted |
| [0019](0019-macrostep-round-budget.md) | A round budget bounds the macrostep fold | accepted (amended in part by 0020: round ordinal; amended in part by 0032: invoke re-entry) |
| [0020](0020-round-ordinal-joins-the-step-counters.md) | A round ordinal joins the step counters | accepted (amends 0019 in part; amended in part by 0046: the core-effect exemption is withdrawn) |
| [0021](0021-donedata-content-expr-failure-yields-no-data.md) | A failed donedata content expr yields no data | accepted |
| [0022](0022-parallel-is-never-the-lcca.md) | A parallel is never the LCCA; SCION's contrary tests leave the corpus | accepted |
| [0023](0023-numeric-type-fixes-upstream-not-boundary-coercion.md) | Numeric-type gaps are fixed in predicator, never coerced at the boundary | accepted |
| [0024](0024-data-src-is-never-fetched.md) | `<data src>` is never fetched | accepted |
| [0025](0025-cross-repo-tracker-authority-and-mirrors.md) | Tracker authority follows the artifact; mirrors pull (adopts predicator ADR-0010) | accepted |
| [0026](0026-script-as-predicator-statement-programs.md) | `<script>` bodies are predicator statement programs | accepted (amends 0004 in part) |
| [0027](0027-embedder-placed-session-runtime.md) | Embedder-placed session runtime with a named registry | accepted |
| [0028](0028-executable-content-blocks-thread-one-context.md) | Executable-content blocks thread one context and `bind/3` each write | accepted |
| [0029](0029-session-interpret-stays-public.md) | `Session.interpret/2` stays public; replay records four inputs | accepted |
| [0030](0030-in1-becomes-a-provider-context-stays-off-machinestate.md) | `In/1` becomes a provider; the built context still is not a `MachineState` field | accepted (amended 2026-08-15: predicator 8.0 memoization; hoist kept) |
| [0031](0031-invoke-argument-failure-aborts-the-invocation.md) | A failed invoke argument evaluation aborts the invocation | accepted |
| [0032](0032-round-budget-spans-the-invoke-re-entry.md) | The round budget spans the invoke pass's re-entry | accepted (amends 0019 in part) |
| [0033](0033-validator-warning-tier.md) | The validator has a warning tier; warnings ride on the Machine | accepted |
| [0034](0034-replay-re-drives-the-core-not-a-live-session.md) | Replay re-drives the core, not a live session; recording carries ordinal order, no clock | accepted |
| [0035](0035-send-id-is-a-machinestate-counter.md) | The send id is `send_<n>` off a new `machine_state.send_counter` | accepted (amended 2026-08-15: cross-session sendid collision recorded harmless) |
| [0036](0036-send-argument-failure-discards-the-message.md) | A failed `<send>` argument discards the message (amends 0021 in part) | accepted |
| [0037](0037-unbound-spelled-undefined-at-the-writer.md) | Unbound is spelled `:undefined` at the writer; `nil` means null | accepted |
| [0038](0038-invoke-source-resolves-at-the-session-boundary.md) | `<invoke>`'s source resolves at the session boundary, never inside the library | accepted |
| [0039](0039-session-detected-send-failures-re-enter-the-core.md) | Session-detected send failures re-enter the core through `deliver_internal/5` | accepted (amended in part by 0047: the rejected alternative is scoped to liveness; amended in part by 0048: the core may judge reachability against a caller-declared route snapshot) |
| [0040](0040-session-telemetry-event-contract.md) | Session telemetry event contract: the `[:statifier, :session, ...]` bridge, measurements-vs-metadata split, and trace-off policy | accepted (amended 2026-08-16: singleton location carve-out withdrawn; no trace event carries a location; amended 2026-08-16: `:datamodel_change` joins the core effect events; amended in part by 0046: `round` joins every core-effect event's measurements; amended in part by 0059: `ordinal` joins the `:send_delayed` and `:cancel` events' measurements; amended in part by 0063: `caller_context` joins the macrostep and durable-timer events' metadata) |
| [0041](0041-content-markup-lowers-to-a-source-slice.md) | `<content>` markup lowers to a source slice, compiled at invoke time | accepted (amended 2026-08-16: namespace limitation corrected - the corpus child documents do not compile standalone; amended in part by 0042) |
| [0042](0042-invoke-content-compiles-under-the-relaxed-namespace-rule.md) | Invoke content markup compiles under the relaxed namespace rule | accepted (amends 0041 in part) |
| [0043](0043-attribute-values-normalize-per-xml-3-3-3.md) | Attribute values normalize per XML 1.0 3.3.3, guided by the raw source | accepted |
| [0044](0044-re-entry-effects-defer-to-the-outer-batch.md) | Re-entry effects defer to the outer batch; subscriber delivery is monotone in `(macrostep, round)` and `{:halted, _}` is end-of-stream | accepted |
| [0045](0045-character-data-folds-line-breaks-per-xml-2-11.md) | Character data folds line breaks per XML 1.0 2.11, guided by the raw source (resolves 0043's open question) | accepted |
| [0046](0046-round-on-every-core-effect.md) | Every core effect carries `round`; the ADR-0020 exemption is withdrawn and `round` joins the core-effect event measurements | accepted (amends 0020 in part; amends 0040 in part) |
| [0047](0047-send-static-target-type-invalidity-rejects-in-the-core.md) | Static send target/type invalidity rejects in the core; reachability stays session-side, test496 deferred to its own record | accepted (amends 0039 in part) |
| [0048](0048-send-reachability-judged-against-a-route-snapshot.md) | Send reachability is judged in the core against a caller-declared route snapshot; core-detected unreachability aborts the block (discharges 0047 decision 6's deferral) | accepted (amends 0039 in part) |
| [0049](0049-late-subscriber-catch-up-via-recording.md) | Late subscribers catch up by replaying the recording; no header effect joins the stream | accepted |
| [0050](0050-invoked-children-inherit-observation-by-opt-in.md) | Invoked children inherit the parent's observers by opt-in; the invocation table gets a public accessor | accepted |
| [0051](0051-invoke-handlers-are-registered-per-session.md) | Invoke handlers are registered per session; the registered invoke-type set becomes core-visible deployment state | accepted |
| [0052](0052-chart-identity-and-position-serialization.md) | Chart identity is a content hash of the SCXML source; a position blob carries identity and a format version, checked before use | accepted |
| [0053](0053-chart-test-helpers-ship-in-lib-under-statifier-testing.md) | The chart-author test helpers ship in `lib/` under `Statifier.Testing` | accepted (amends 0006 in part) |
| [0054](0054-durable-timers-consume-the-effect-vocabulary.md) | Durable timers consume the effect vocabulary; the host owns keying and the 6.2 discard | accepted (amended 2026-08-19: decisions 2, 3, and 4 corrected; decision 2's recorded gap decided by 0055; decision 3's residual foreach collision decided by 0059) |
| [0055](0055-non-self-delayed-send-routes-stay-the-librarys.md) | Non-self delayed-send routes stay the library's: `#_parent`/`#_invokeid`/`#_internal` permanently, the external-session route deferred with a named trigger; no route field joins `%SendDelayed{}` | accepted (decides 0054's recorded gap) |
| [0056](0056-renumbered-adr-citations-pointers-move-history-stands.md) | After a renumbering, pointer citations move (path fix plus an at-the-time note) and historical statements stand; cross-repo ADR citations must name the repo | accepted |
| [0057](0057-recording-identity-and-serialization.md) | A recording blob nests the chart blob in the compiled `%Machine{}`'s place; the codec lives on the `@opaque` owner; `:invoke_handlers` cross the boundary as strings, never as atoms or code | accepted (answers 0052 decision 8's follow-up) |
| [0058](0058-adr-number-collisions-fail-the-gate-tree-locally.md) | ADR number collisions fail the gate via a tree-local numbering invariant; the README table becomes machine-read | accepted (amended 2026-08-19: decision 2's bite point corrected - the base-ref half fires after the rebase, not merely after a fetch; its addition is the rename/renumber shape; renumbered from 0056 before merge) |
| [0059](0059-per-execution-ordinal-on-durable-timer-effects.md) | `%SendDelayed{}` and `%Cancel{}` carry a per-execution `ordinal` off a new `timer_counter`; the durable dedup key gains it as its eighth component and the foreach author guidance retires | accepted (amends 0054 in part; amends 0040 in part) |
| [0060](0060-resuming-a-session-from-a-persisted-position.md) | `Session.start_link/2` gains a `:resume` option for a position blob or `%MachineState{}`; resume requires an identified chart, keeps the position's `_sessionid`, refuses a non-quiescent or terminated position, carries `active_invocations` verbatim, and anchors a resumed session's recording at the resumed position | accepted (amends 0057 in part; amends 0049 in part) |
| [0061](0061-sha-pinning-contract-until-2-0-0.md) | Consumers pin `main` SHAs under a documented contract until 2.0.0: no pre-release is published, `2.0.0-dev` stands on updated grounds, the fragment rule widens to cover breaks between pins, `package/0` metadata lands without publishing, and the no-publish rule defers to a named trigger | accepted (contract ended with the 2.0.0 release per its own decision 5; re-decided by 0066) |
| [0062](0062-opentelemetry-bridge-is-a-separate-package.md) | The OpenTelemetry bridge is a separate package, `opentelemetry_statifier`: family-scoped, public-events-only, git-pinned and unpublished until statifier is on Hex; span topology and propagation in `docs/opentelemetry.md` | accepted |
| [0063](0063-caller-context-on-external-events-and-durable-timer-effects.md) | An opaque `caller_context :: term()` (default `nil`, never read by the library) rides `%Event{}` via `external/2`, is stamped by the core onto `%SendDelayed{}`/`%Cancel{}`, surfaces in four telemetry events' metadata, and recordings carry it (format 2 -> 3); ADR-0054's keys untouched | accepted (amends 0040 in part) |
| [0064](0064-position-blob-drops-the-per-drive-snapshot-fields.md) | The position blob drops `routes` and `invoke_types`: `to_binary/1` omits both alongside `:machine`, `from_binary/2` blanks both on decode regardless of blob vintage, and the format version stays 2 | accepted (amends 0052 in part) |
| [0065](0065-handler-conformance-case-in-statifier-testing.md) | `Statifier.Testing.HandlerCase`: a `use`-injected conformance case any `Statifier.Invoke.Handler` implementation runs against itself - planning purity, `perform/2` idempotency against a declared observation point (fail-not-skip), and the library-half pins via probe handlers | accepted |
| [0066](0066-publishes-2-0-0-ending-the-sha-pinning-contract.md) | Publishes 2.0.0 to Hex, ending the SHA-pinning contract - ADR-0061's satellite trigger fired; known issues recorded; SemVer and the changelog take over | accepted |
| [0067](0067-one-telemetry-contract-across-stepping-drivers.md) | One telemetry contract across stepping drivers: `[:statifier, :session, ...]` names the logical session, the emitters generalize into `Statifier.Telemetry`, `Statifier.Session.Telemetry` stays as a `driver: :session` facade, and a `driver` key joins every event's metadata | accepted (amends 0040 in part) |
| [0068](0068-permanent-invoke-failure-is-a-suffixed-error-communication.md) | Permanent invoke failure is `error.communication.invoke.<invokeid>`, reported by the host through `Statifier.Session.failed_invocation/3` and delivered on the same invocation-tagged entry as `done.invoke` | proposed |

New ADRs: next number, same three-section format (Context, Decision, Consequences),
drafted or reviewed at the direction level per `docs/workflow.md`. Pick the number
against a freshly fetched remote - `git fetch origin && git ls-tree origin/main
--name-only docs/adr/` - so a branch does not start behind a record that has
already landed; `mix quality`'s ADR guard catches a collision that materializes
later, but only once the colliding file is in your tree.
