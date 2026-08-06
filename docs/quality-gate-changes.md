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
