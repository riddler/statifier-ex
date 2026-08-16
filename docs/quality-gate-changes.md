# Quality gate change log

Every change to the quality gate's configuration gets an entry here, per
ADR-0011. `mix gate.check` fails the Gate guard stage when a guarded file
changes and no entry added in the same diff names it.

An entry needs a `## <date> - <issue>` heading, an `Approved-by:` line naming
the human who made the call, one `- <path>: <what changed>` bullet per guarded
path, and a reason. The check is mechanical about the path and the
`Approved-by:` line; the reason is for the reader.

Adding an entry is not permission to weaken a check. ADR-0011 says a genuinely
wrong check is a human call, and this file is where that call is recorded, not
where an agent grants itself one.

## 2026-08-16 - st-cmq.1

Approved-by: JohnnyT (in session)

- lib/mix/statifier/adr_guard.ex: adds `:telemetry\.` to
  `@effect_call_pattern`, so a `:telemetry` call added anywhere under
  `lib/statifier/` other than the ADR-0003 effect-interpreter paths is a
  named ADR-0003 finding
- lib/mix/statifier/adr_guard.ex: adds `lib/statifier/session/telemetry.ex`
  to `@effect_interpreter_paths`, the module that holds the
  `:telemetry.execute/3` call sites `session.ex` delegates to

Reason: st-cmq.1 makes `Statifier.Session` forward its effect and trace
stream as `:telemetry` events, and the bead's own acceptance criterion asks
for "no `:telemetry` call sites anywhere in the pure core (enforced by a test
or credo check if cheap)". The two halves go together: the pattern is what
makes the check exist, and the exempt path is where the check's one legitimate
exception lives. `Statifier.Session.Telemetry` is not a second effect
interpreter - it is the emission half of the one ADR-0003 names, split out of
`session.ex` only because `.doctor.exs`'s 100% bar puts the event contract in
a `@moduledoc`. It holds no state, drives no core function, and is called from
nowhere but `session.ex`. On net the check tightens: every other file under
`lib/statifier/` gains a new named finding. It loosens nothing, skips no test,
and lowers no threshold. `mix gate.check` does not guard
`lib/mix/statifier/adr_guard.ex`, so the gate would have gone green without
this entry - the block is policy, per ADR-0027, and this record is what keeps
the guard's own comment true rather than routed around.

This is the second new `@effect_interpreter_paths` entry since ADR-0027 called
a second one "a smell to be argued, not defaulted", so the argument is here
rather than assumed: `telemetry.ex` is not a new interpreter joining
`session.ex` and `supervisor.ex`, it is a file split out of `session.ex`
under documentation pressure. The check ADR-0027 wanted - that the exemption
list names design statements rather than accumulating convenience - is met by
that being true, not by the count staying at two.

## 2026-08-15 - st-cmq.5

Approved-by: JohnnyT (in session)

- lib/mix/statifier/adr_guard.ex: widens `@effect_interpreter_paths` from
  `["lib/statifier/session.ex"]` to the named session-runtime set, adding
  `lib/statifier/supervisor.ex`

Reason: ADR-0027 decided the session runtime's shape - an embedder-placed
`Statifier.Supervisor` holding `Statifier.Registry` and
`Statifier.SessionSupervisor` - and st-cmq.5 implements it. ADR-0003 names
`Statifier.Session` as the production effect interpreter; the supervisor that
places the registry and the DynamicSupervisor behind it is the same design
statement, and the exemption list is where that statement is written.
Registration, lookup and `start_child` calls stay inside `session.ex`, which
was already exempt, so this is the one new path ADR-0027 predicted - and that
record is explicit that a second new path is a smell to be argued, not
defaulted. It loosens no check, skips no test, and lowers no threshold: every
other file under `lib/statifier/` is still scanned by the same pattern, and the
guard's own comment ("Excluding it is the design, not a hole in the check") is
what this amendment keeps true rather than routing around.

Worth stating plainly, because it is the reason this entry matters more than
its size suggests: **the gate would have gone green without it.**
`mix gate.check` does not guard `lib/mix/statifier/adr_guard.ex`, and a
module-based `use Supervisor` matches none of `@effect_call_pattern`'s
alternatives, so the supervisor could have shipped exempt-by-accident with no
amendment and no record. ADR-0027 forbids exactly that: "riding a pattern gap
instead of amending it would be the hole the guard's own comment disclaims."
The block on this phase was policy, not a red gate, which is the stronger of
the two and the easier one to quietly skip.

## 2026-08-15 - st-0ej

Approved-by: JohnnyT (in session)

- .sobelow-conf: adds lib/mix/statifier/adr_guard.ex to `ignore_files`, and
  extends the inline reason from two dev-only Mix support modules to three

Reason: closing the guard's heredoc blind spot means it can no longer work
from the diff alone - a body line added into a heredoc whose opening `"""` is
unchanged context is invisible to `--unified=0` - so `collect/1` now reads the
post-image text of the diffed files behind an `opts[:reader]` seam defaulting
to `File.read/1`. Sobelow's Traversal.FileModule flags that call because the
path is not a literal, and this project runs `exit: "low"` on purpose, so the
finding blocks. No code-level fix clears it: the check has no sanitization
detection and fires on any non-literal path outside a Phoenix controller.

adr_guard.ex is now the same shape as the two modules already excluded here -
a Mix task support module that runs under `mix` on a developer's machine,
reads paths derived from that developer's own repository, and never reaches
the released library. The exclusion is by path with its reason stated, which
is what .sobelow-conf's own comment asks for when a third such module
appears. No threshold moved: `exit: "low"` is unchanged, every other file
under lib/ is still scanned, and the change to the guard itself strengthens a
check rather than weakening one.

## 2026-08-14 - st-wjg

Approved-by: JohnnyT (in session)

- lib/mix/statifier/adr_guard.ex: adds the `adr-0018-bead-id` check, flagging
  a bead ID added in a comment, `@moduledoc`, `@doc`, `@typedoc` or test
  description under `lib/` or `test/`
- lib/mix/tasks/adr.check.ex: names ADR-0018 in the task's advice text and
  states that the new check clears only with `ADR-0018-exempt`

Reason: ADR-0018's Consequences ask for this check by name and say it does not
wait for the st-a89 cleanup sweep. The guard reads added diff lines only, so
the check holds the line on new code while 73 pre-existing files still carry
bead IDs in their comments. Both of the record's constraints are honored as
stated: the pattern matches bead IDs only, because a numbered phase or decision
reference is ordinary English before it is a process reference and point 2
deliberately keeps the unnumbered word "phase"; and the check carries its own
escape marker rather than the guard's shared `ADR-0\d{3}|deviation` hatch,
because here the violation and the escape sit on the same axis and ADR-0018
documents four real lines at `e2524fc` that would exempt themselves by
accident.

**This entry is voluntary**, in the same sense as st-6f7's. `mix gate.check`
does not guard `lib/mix/statifier/adr_guard.ex`, so the Gate guard stage was
green with or without it, and no agent was blocked waiting on it. It is
recorded because ADR-0018 says adding a gate check is gate-relevant and asks
for an ADR-0011 entry, and because what a check *catches* is as much a human's
call as what it stops catching. Adds a check; loosens nothing, skips no
existing check, and lowers no threshold. The new escape marker is not a
widening of the existing one - it is narrower, and deliberately does not accept
the citation the shared hatch does.

Two known limits, both documented in the moduledoc rather than left for a
reader to discover. The check is line-based rather than an AST pass, so a bead
ID added mid-body into a doc heredoc whose opening delimiter is unchanged
context is invisible to a `--unified=0` diff and is not caught; and the test
description shape it recognizes is the plain `test "..." do` form, so
`test "...", ctx do` falls through as ordinary code. Neither is a threshold
being lowered - they are the cost of the guard's existing shape, which
ADR-0018 chose knowingly.

## 2026-08-12 - st-1xz

Approved-by: JohnnyT (in session)

- mix.exs: adds `{:doctor, "~> 0.23", only: :dev, runtime: false}`, so the
  Doctor stage runs instead of reporting itself skipped
- .doctor.exs: adds the file, setting every coverage threshold to 1.0 (module
  doc, overall doc, struct type specs, overall spec) with `raise: true`

Reason: `mix quality` has reported `○ Doctor: skipped (:doctor not installed)`
on every run since the gate existed, and `.claude/wurk.json` classified it as a
project-level gap - warned about forever, decided never. st-1xz is the bead
that decides it, and it decides in favor of running the stage. Doc coverage is
a discipline this project already follows by review: CLAUDE.md requires `@spec`
on public functions, ADR-0002 requires interpreter functions to keep their
Appendix D names with moduledocs explaining the port, and several moduledocs do
real explanatory work. This makes that mechanical, in the same spirit as the
ADR guard and the regression ratchet.

The thresholds are set above doctor's own defaults on three axes, not below:
module doc 0.4 -> 1.0, overall doc 0.5 -> 1.0, overall spec 0.0 -> 1.0. Nothing
was bent to fit. Measured before the threshold was written, the codebase was
already at 100% moduledoc coverage, 100% spec coverage and 100% struct type
specs; the only shortfall was fifteen public functions with no `@doc`, and
those were backfilled in commit e10d663 - a separate, attribute-only commit
that landed under the old thresholds - rather than accommodated by a lower
number. `mix doctor` now reports 89 modules, 0 failed. The stage costs ~1.7s.

Adds a stage; loosens nothing, skips no existing check, and lowers no
threshold.

The same branch first made doctor's config surface guarded, in commit 5931088:
`lib/mix/statifier/gate_guard.ex` gained `.doctor.exs` in `@guarded_paths` and
`:doctor` in `@mix_exs_pattern`, mirrored into `.claude/wurk.json`'s
`gate.moving_files` and CLAUDE.md. That file is not itself a guarded path, and
it is named here because it is the reason this entry is required at all: before
it, both changes above would have landed silently. A doc-coverage threshold
file nobody watches is lowerable without a record, which is the exact shape
ADR-0011 exists to prevent - so the guard was extended ahead of introducing the
file it guards, rather than after.

Retiring the `^:doctor not installed$` pattern from
`.claude/wurk.json`'s `gate.project_level_skips`, and the CLAUDE.md prose that
named Doctor as an open decision owned by st-1xz, follows in the next commit -
it has to, since a stage that is neither skipped nor classified is a hard red
until it actually runs.

## 2026-08-09 - st-6yb

Approved-by: JohnnyT (in session)

- .quality.exs: removes the script_tests custom stage (`ruby
  .claude/scripts/test/run.rb`) and its explanatory comment block

Reason: st-6yb deletes the whole `.claude/scripts/` tree - the kit it tested
now lives at `~/.claude/skills/wurk:kit/scripts/` and every skill already
calls it there. st-cex left the tree in place specifically so this bead could
move the deletion and the gate config together. The stage ran a directory
that no longer exists and carried no `skip_exit_code`, so leaving it
registered would make every future `mix quality` hard red rather than
reporting a meaningful failure. Retargeting is not available - the suite it
ran now lives in another repo, with its own gate - so removal is the only
shape. This removes a stage measuring code that is gone; it loosens no
remaining check, skips no test that still runs, and lowers no threshold.

## 2026-08-08 - st-6f7

Approved-by: JohnnyT (in session)

- test/test_helper.exs: adds `:adr_judge_corpus` to `ExUnit.start`'s
  `exclude:` list, alongside `:scion` and `:scxml_w3`

Reason: st-6f7 added a fixture corpus that runs the ADR judge's propose and
refute passes against the real `claude` CLI, so the ordinary suite must not
reach it - st-c8c is the incident where a test that forgot to inject
`opts[:caller]` made real CLI calls and real spend, and the corpus is eight
fixtures whose measured runs take 90-360 seconds and cost money every time.
Excluding it by tag is the same treatment the two conformance suites already
get, and `mix test --only adr_judge_corpus` is how it runs.

**This entry is voluntary.** `mix gate.check` does not guard
`test/test_helper.exs`, so the Gate guard stage was green with or without it,
and no agent was blocked waiting on it. It is recorded because the spirit of
ADR-0011 is that narrowing what the suite runs is a human's call, and a tag
exclusion is exactly that shape even though the mechanical check does not
reach it. Nothing that ran before this change stops running: the corpus is new
in the same diff, so the exclusion removes no existing coverage. Its
cheap, caller-free companion (`adr_judge_corpus_shape_test.exs`) does stay in
the ordinary suite, so the corpus cannot rot unnoticed between hand-runs.

Worth a maintainer's eye at some point: whether `test/test_helper.exs` should
become a guarded path. Any future tag exclusion added there narrows the
default suite silently, and this entry only exists because someone chose to
write it.

## 2026-08-06 - st-hzf

Approved-by: JohnnyT (in session)

- .quality.exs: registers the script_tests custom stage, which runs
  `ruby .claude/scripts/test/run.rb` (the minitest suite covering
  `.claude/scripts/`)

Reason: st-hzf extracted the deterministic mechanics of all 13 skills into
Ruby under `.claude/scripts/` - roughly 8k lines that drive commit, push, PR,
worktree and bead mechanics. That code had a test suite from Phase 1, but the
suite ran only by hand: the branch touches no `lib/`, `test/`, `config/` or
`mix.exs`, so a bare `mix quality` carved out of it entirely and reported a
green gate that had measured nothing that changed. Nothing mechanical stood
between a red Ruby suite and a push.

The gap is not hypothetical. st-hzf's own Phase 12 left `plan_state_test.rb`
red, filed it as discovered work (st-trm) rather than fixing it, and reported
the phase complete; only a hand-run caught it before the commit. That is
precisely the failure mode the gate exists to make impossible.

Adds a stage; loosens nothing, skips no existing check, and lowers no
threshold. It is a reader, absent from the loop profile's `stages:`
allow-list, and carries no `skip_exit_code` - a missing Ruby makes it red
rather than skipped, since a stage that can quietly report itself skipped
would reintroduce the same gap in a different shape.

Registering it also required widening the gate's carve-out predicate
(`.claude/scripts/lib/touches_elixir.rb`): `touches_elixir` still means what
its name says, and a new `gate_applicable?` adds `.claude/scripts/` on top,
because the gate now measures something that is not the Elixir build. That
file is not a guarded path; it is named here because the carve-out is what
decides whether this stage runs at all, and an entry that omitted it would
describe half the change.

## 2026-08-06 - st-4hk

Approved-by: JohnnyT (in session)

- .quality.exs: header comment says "Statifier-ex" instead of "Statifier v2"
- .credo.exs: two comment references to the bead that generated it are now
  `st-vbu` instead of `st2-vbu`
- .sobelow-conf: header comment says "Statifier-ex (st-21b)" instead of
  "Statifier v2 (st2-21b)"

Reason: the project renamed statifier_2 -> statifier-ex and the bd issue
prefix migrated st2 -> st, so these three lines name a project and two beads
that no longer exist. All four edits are inside comments: no check is added,
removed, reordered, or reconfigured, no threshold moves, and the three files
parse to exactly the configuration they did before. The entry exists because
the guard is mechanical about the path, not because the change is a judgment
call about a check - but it is recorded here rather than exempted, since the
guard's value comes from having no path around it. The rest of the rename
landed in PR #55 and in this branch's first commit; these were held back
because ADR-0011 makes editing a guarded file a human's call even when the
edit is a comment.

## 2026-08-06 - st-l42

Approved-by: JohnnyT (in session)

- test/passing_tests.json: removes the literal `test/statifier_test.exs`
  entry from `internal_tests`

Reason: `test/statifier_test.exs` was the `mix new` scaffold ("greets the
world" against `Statifier.hello/0`), deleted as part of backfilling sabotage
notes (st-l42's acceptance criterion: give the scaffold test a real
assertion or remove it - it had neither real behavior nor a doctest
distinct from the one already covering the same function). `hello/0` was
removed from `lib/statifier.ex` alongside it, so nothing this entry drops was
verifying real behavior; the ratchet's own regression stage (`mix
test.regression`) fails outright with a dead entry left in place, since it
matches no file on disk. Removes a dead reference; loosens no check, skips no
test, and lowers no threshold.

## 2026-08-06 - st-00p.10

Approved-by: JohnnyT (in session)

- .quality.exs: registers the regression custom stage, which runs `mix
  test.regression` against `test/passing_tests.json`

Reason: makes a regression ratchet failure a named stage (`Regression
ratchet`) instead of a count buried in the Tests stage's own output
(docs/testing.md). It is a reader - like the Tests stage, it reads the build
Compile already produced rather than writing to it - and is absent from the
loop profile's `stages:` allow-list, so `mix quality --profile loop` does not
run it. Adds a stage; loosens nothing, skips no existing check, and lowers no
threshold.

## 2026-08-05 - st-qcc

Approved-by: JohnnyT (in session)

- .quality.exs: registers the adr_judge custom stage, disabled by default,
  with a :merge profile that re-enables it

Reason: adds an LLM-backed judge for ADR-0012 (debuggability), the one
in-scope ADR whose rule is a judgment call rather than a name or call-site
pattern. A candidate only reaches gate-failure status after surviving an
independent adversarial refute pass. It shells out to the developer's own
`claude` CLI (`System.cmd/3`, no tool access, no MCP servers) rather than
calling the Anthropic API directly, so it rides the developer's existing
Claude Code auth instead of needing its own API key. It is a reader, absent
from a bare `mix quality`, from `--profile loop`, and from CI; it runs only
under `--profile merge`, which `/merge-request` invokes before pushing. It
skips cleanly (claude CLI not on PATH, no lib/statifier/ changes, no base
ref) rather than failing when it cannot run. Adds a stage; loosens nothing,
skips no existing check, and lowers no threshold.

## 2026-08-04 - st-meo

Approved-by: JohnnyT (in session)

- .quality.exs: registers the adr_guard custom stage

Reason: adds the ADR guard to the run, so a likely violation of ADR-0002,
0003, 0004 or 0008 is a named failure. Adds a stage; loosens nothing, skips
nothing, and lowers no threshold.

## 2026-08-04 - st-h6p

Approved-by: JohnnyT (in session)

- .quality.exs: registers the gate_guard custom stage

Reason: bootstraps the check itself. Adds a stage to the run; loosens nothing,
skips nothing, and lowers no threshold.

## 2026-08-05 - st-21b

Approved-by: JohnnyT (in session)

- .sobelow-conf: adds the file, setting exit: "low" and excluding two dev-only
  Mix support modules by path
- mix.exs: adds :sobelow as a dev dep, so the Sobelow stage runs instead of
  reporting itself skipped

Reason: the gate did no security scanning at all before this. The threshold is
set stricter than ExQuality's default, not looser: Sobelow downgrades Traversal,
RCE and SQL findings to low confidence outside a Phoenix controller, so "medium"
would leave those checks unable to block anything in a library. The two excluded
files are Mix task support that reads developer-configured paths and never ship;
the exclusion is by path with its reason in .sobelow-conf, and no threshold was
lowered.
