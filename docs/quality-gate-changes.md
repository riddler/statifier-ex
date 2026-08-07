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
