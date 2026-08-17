# ADR-0027: Embedder-placed session runtime with a named registry

Status: accepted (2026-08-14) - amended 2026-08-17 (st-hgyu: the test suite places one run-scoped runtime in test_helper.exs; start_supervised! could not be shared by async corpus files)

## Context

st-cmq.4 shipped `Statifier.Session` with `start_link/2` and a generated
`child_spec/1`, `restart: :transient` written explicitly, no application
callback, no supervision tree, and no registry. That was Decision 1 of its
plan (`docs/plans/260814-st-cmq.4-session-genserver-effect-interpreter.md`),
made deliberately for a bead whose only caller was its own test suite, with
this record's bead named as the revisit trigger. The trigger has fired: the
next two beads both need process infrastructure that does not exist, and
whichever was planned first would otherwise invent it as a side effect.

- st-cmq.5 must resolve `#_scxml_<sessionid>` send targets "through the
  registry, not raw pids". Spec 6.2 (The SCXML Event I/O Processor's target
  rules, restated in C.1) is precise about both the routing and the failure
  mode:

  > If the target is the special term '#_scxml_sessionid', where sessionid
  > is the id of an SCXML session that is accessible to the Processor, the
  > Processor MUST add the event to the external queue of that session.

  > If the sending SCXML session specifies a session that does not exist or
  > is inaccessible, the SCXML Processor MUST place the error
  > error.communication on the internal event queue of the sending session.

  So an id that names nothing live is an event on the sender, never a crash.
  C.1 also leaves this platform room to stand in:

  > The set of SCXML sessions that are accessible to a given SCXML Processor
  > is platform-dependent.

- st-cmq.7 must start child sessions "under the parent supervision umbrella"
  and, on cancellation, stop the child and discard its queued events. Spec
  6.4:

  > If the invoking session takes a transition out of the state containing
  > the <invoke> before it receives the 'done.invoke.id' event, the SCXML
  > Processor MUST automatically cancel the invoked component and stop its
  > processing. The cancel operation MUST act as if it were the final
  > <onexit> handler in the invoking state.

  > Once it cancels the invoked session, the Processor MUST ignore any
  > events it receives from that session. In particular it MUST NOT not
  > insert them into the external event queue of the invoking session.

  Appendix D reaches the same cancellation from `exitStates` and
  `exitInterpreter`, each of which runs `cancelInvoke(inv)` for the exiting
  state's invocations after its `<onexit>` handlers.

The constraint that shapes the cost: `Mix.Statifier.AdrGuard` exempts
exactly one path from the ADR-0003 side-effect ban -
`@effect_interpreter_paths ["lib/statifier/session.ex"]`, with the comment
"Excluding it is the design, not a hole in the check". Any new supervisor or
application module is a new exempt path, which amends the guard, which is a
gate-relevant change and therefore ADR-0011 ledger territory
(`docs/quality-gate-changes.md`).

## Decision

**The library ships no application callback. It ships one embedder-placed
supervisor, `Statifier.Supervisor`, holding a named `Registry` and a flat
`DynamicSupervisor` for sessions. Parent/child lifetime is an ownership
protocol in the session, not supervision-tree nesting. Sessions under the
supervisor are `restart: :temporary`.** Four numbered decisions:

1. **No `mod:` in `mix.exs`; the embedder places `Statifier.Supervisor`.**
   A library that starts processes on load taxes every host that only ever
   compiles a document, and ADR-0003's consequence that "Embedders can
   supply their own effect interpreter" already commits the lifecycle to the
   embedder's side of the line. `Statifier.Supervisor` is a module-based
   supervisor whose children are, in order,
   `{Registry, keys: :unique, name: Statifier.Registry}` and
   `{DynamicSupervisor, name: Statifier.SessionSupervisor}`, under
   `:rest_for_one` - a registry crash loses every registration it held, so
   the sessions behind it restart-fresh rather than continuing as
   unreachable orphans (and per decision 4 they do not come back as
   amnesiacs; the embedder observes the loss through monitors). One
   default-named instance; multiple named runtimes are mechanism with no
   caller and stay out, per the same standing rule that kept
   `states_to_invoke` off `MachineState` until st-cmq.6. The test suite is
   itself an embedder under this decision: it places one runtime for the
   whole run in `test/test_helper.exs`, before `ExUnit.start/1`. *(Amended
   2026-08-17, st-hgyu: this sentence originally read "Tests
   `start_supervised!` the same supervisor." st-cmq.9's corpus harness made
   that mechanism impossible to keep: `start_supervised!` binds the runtime's
   lifetime to one test process, the children are fixed module-qualified
   names so only one instance can exist per node, and the generated corpus is
   `async: true` unconditionally, so no two corpus files could share a
   runtime placed that way. The principle is untouched - the embedder places
   the runtime, the library never does, and nothing in `lib/` starts a
   process; only the stated test mechanism moved.)*

2. **The registry is `Statifier.Registry`: a named, library-owned `Registry`
   with unique keys, keyed by the session id string.** Registration happens
   inside `Session.init/1`, because that is the only place it can: the
   `sess_` UXID is generated by `MachineState.new/2` during init, so no
   `{:via, ...}` tuple can name the session before it starts. Sessions
   started through the runtime (`DynamicSupervisor.start_child` on
   `Statifier.SessionSupervisor`, wrapped by a public helper st-cmq.5
   names) register; a bare `Session.start_link/2` stays exactly as
   st-cmq.4 shipped it - legal, supervised by whoever placed it, and
   *unregistered*, which C.1's "accessible to a given SCXML Processor is
   platform-dependent" sanctions outright: an unregistered session is an
   inaccessible one. Resolution of `#_scxml_<sessionid>` is
   `Registry.lookup(Statifier.Registry, sessionid)`; an empty result -
   whether the id never existed, named a bare session, or named a session
   that died (Registry drops entries on death) - takes 6.2's mandated path:
   `error.communication` on the *sending* session's internal queue, never a
   crash and never a raise. The `:name`/`{:via, Registry, _}` seam Decision
   1 of the st-cmq.4 plan left open remains open for embedder-owned
   registries; the library's own routing consults only `Statifier.Registry`.

3. **Parents own their children through monitors and an invocation table,
   on the flat `Statifier.SessionSupervisor` - no links, no supervisor per
   parent.** A child session starts on the same DynamicSupervisor as its
   parent; the "umbrella" st-cmq.7 asks for is satisfied by ownership, not
   nesting. The parent session holds `invokeid -> {child_session_id, pid,
   monitor_ref}` and monitors each child; the child monitors its parent and
   stops on the parent's `:DOWN`, which is what makes a brutally-killed
   parent (where `terminate/2` never runs) still take its children down.
   Cancellation is an explicit act of the parent's own code - interpreting
   a cancel-invoke effect, or its own termination - because 6.4 puts it in
   the parent's execution order ("as if it were the final <onexit> handler
   in the invoking state"), an ordering a supervisor's shutdown sequence
   cannot express. Discarding queued events is inbox work, not process
   work: killing the child does nothing for events it already delivered, so
   the parent drops, at drain time, every queued entry originating from a
   cancelled invokeid, per 6.4's "MUST ignore any events it receives from
   that session. In particular it MUST NOT ... insert them into the
   external event queue of the invoking session." The candidates rejected:

   - **Links.** Symmetric by construction: a child crash would kill the
     parent, a coupling no clause of 6.4 asks for, and avoiding it means
     `trap_exit` and `handle_info({:EXIT, ...})` bookkeeping that monitors
     provide without the blast radius.
   - **A supervisor per parent.** One extra process per session whose only
     job is a shutdown ordering the parent must sequence itself anyway
     (finalize, then cancel, then discard), and which cannot touch the
     queued-events half of the requirement at all.

4. **`restart: :temporary` replaces `restart: :transient`.** A supervisor
   restart re-runs `start_link(machine, opts)`: `MachineState.new/2`
   generates a fresh `sess_` UXID, and the configuration, datamodel,
   external queue, delayed-send timers, subscriber set, registry key, and
   every parent's invokeid mapping of the old process are all gone. What
   comes back is not the session that crashed but a new session wearing its
   supervisor slot - the registry cannot even re-associate it, since its
   id is new. Restarting is therefore actively wrong, not merely useless,
   and `:transient`'s one remaining behavior over `:temporary` (restart on
   abnormal exit) is exactly the wrong one. A crashed session is observed
   through monitors and the subscriber stream; recovery that preserves
   identity is replay - ADR-0003's "(machine, initial data, event log)"
   tuple - and belongs to the embedder or a later replay bead, not to a
   restart flag. The `use GenServer, restart: :transient` line in
   `session.ex` changes to `:temporary` in the first bead that implements
   this record; the st-cmq.4 plan's stated reason for writing the option
   explicitly (never `:permanent`) still stands.

**The guard amendment this costs, and the ledger entry it owes.** One new
exempt path is expected: `lib/statifier/supervisor.ex`. Registration,
lookup, monitor, and `start_child` calls are made from `session.ex`, which
is already exempt, so the supervisor module should stay the only addition;
a second new path is a smell to be argued, not defaulted. Whether or not
each new line happens to match `@effect_call_pattern`, the exemption list
is the design statement, and riding a pattern gap instead of amending it
would be the hole the guard's own comment disclaims. The amendment lands in
`Mix.Statifier.AdrGuard.@effect_interpreter_paths` on the implementing
branch, together with a `docs/quality-gate-changes.md` entry that needs: a
`## <date> - <issue>` heading, an `Approved-by:` line naming the human who
made the call, a `- lib/mix/statifier/adr_guard.ex: ...` bullet naming the
widened exemption, and a reason - that this record decided the session
runtime's shape, that the exemption widens from one path to the named
session-runtime set, and that it loosens no check, skips no test, and
lowers no threshold. **Writing that entry is the human's call at
implementation time, per ADR-0011; this record specifies its contents and
does not write it.**

## Consequences

- st-cmq.5 plans against a concrete shape: resolve `#_scxml_<sessionid>`
  via `Registry.lookup(Statifier.Registry, _)`, empty lookup =>
  `error.communication` on the sender's internal queue; `#_parent` reaches
  the parent through the invocation wiring of decision 3. The public
  start-through-the-runtime helper's name and signature are st-cmq.5's
  planning detail, not re-argument.
- st-cmq.7 plans against decision 3's protocol: children on the flat
  `Statifier.SessionSupervisor`, parent-held invocation table and monitors,
  child-side parent monitor, cancel sequenced by the parent, queued-event
  discard by invokeid at the parent's inbox. What error an `<invoke>`
  raises when the runtime supervisor is not running is st-cmq.7's detail to
  settle against spec 6.4's error clauses.
- Decision 1 of the st-cmq.4 plan is discharged on its own revisit trigger.
  `session.ex` changes two things when implementation lands: the
  `restart:` option and registration in `init/1`. Bare `start_link/2`
  embedders keep working unchanged, minus the restart-on-crash nobody
  should have wanted.
- Hosts that only compile documents keep paying nothing: no application
  callback exists, and nothing starts unless `Statifier.Supervisor` is
  placed.
- The implementing branch owes the AdrGuard amendment and the ADR-0011
  ledger entry described above, `Approved-by` a human.
- Open question, deferred with its trigger named: multiple named runtime
  instances (a `:name` option on `Statifier.Supervisor` fanning out to
  registry and DynamicSupervisor names) are excluded as mechanism without a
  caller. The first embedder who needs two isolated session populations in
  one VM is the trigger, and amending this record there is expected to be
  additive.
- `#_scxml_<sessionid>` resolution has one case that never reaches the
  registry: a session addressing *itself*. st-cmq.5 resolves `sid ==
  state.session_id` to the session's own inbox ahead of
  `Registry.lookup/2`, so a bare, unregistered `Session.start_link/2` session
  can still `<send>` to its own id. Decision 2's "an unregistered session is
  an inaccessible one" is about reachability *by other sessions*; the sending
  session is by construction neither nonexistent nor inaccessible to itself.
