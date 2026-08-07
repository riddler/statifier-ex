# `.claude/scripts/` - the contract

Deterministic mechanics extracted out of `.claude/skills/*/SKILL.md`, so a
skill shrinks to: when to invoke, which script to run, and how to interpret
its output. See `docs/skill-automation.md` for the audit this extraction is
based on, and `docs/plans/260806-st-hzf-skill-mechanics-scripts.md` for the
phased plan that builds it out.

This file is the contract for anyone writing or calling a script here.

## Ruby version and syntax

**System Ruby 2.6.10 only** (`/usr/bin/ruby` on macOS - this repo's `mise.toml`
provisions Erlang, Elixir, and a JRE, no Ruby). Every script:

- starts with `#!/usr/bin/env ruby`,
- uses the standard library only - **no gems, no bundler**,
- is written to 2.6 syntax. Specifically avoid, because they need 2.7+:
  - `Data.define`
  - endless methods (`def foo = ...`)
  - hash-value omission (`{x:}`)
  - `Array#filter_map`
  - `Array#intersect?`
  - rightward assignment / pattern matching (`expr => pattern`)
  - numbered block parameters (`_1`, `_2`) are 2.7+ too - use named params

`minitest` ships with 2.6's stdlib, so `require "minitest/autorun"` works
with no install. When in doubt, write plain, boring, compatible Ruby and
verify:

```sh
find .claude/scripts -name '*.rb' -exec /usr/bin/ruby -c {} +
```

## The envelope

Every script prints **exactly one JSON object on stdout**:

```json
{
  "ok": true,
  "script": "worktree_create",
  "data": {},
  "warnings": [{"code": "plt_missing", "message": "..."}],
  "blocked": [{"code": "branch_exists", "message": "...", "needs": "human"}],
  "commands": ["git worktree add ...", "..."]
}
```

- `ok` - `true` only when `blocked` is empty and no wrapped command failed.
- `script` - the script's own name, so a caller reading several results in
  sequence never has to guess which is which.
- `data` - the script's payload. Shape is script-specific; see each script's
  own `--help` and its test file for the exact fields.
- `warnings` - informational. Never affects `ok` or the exit code; the model
  reads these but does not route on them.
- `blocked` - a condition the script refuses to resolve itself. Almost
  always `needs: "human"` - see "Step-scoping" below for why a script never
  works around one of these.
- `commands` **is mandatory and non-negotiable.** CLAUDE.md forbids
  truncating output, and a script that hides what it ran trades one opacity
  for another. Every command a script executes (or would execute, under
  `--dry-run`) is recorded here in order.

Diagnostics (progress messages, stack traces, debug output) go to **stderr**,
never stdout - stdout carries the one JSON object and nothing else.

Build a script's envelope with `Envelope` from `lib/envelope.rb`:

```ruby
require_relative "lib/envelope"

env = Envelope.new(script: "worktree_create")
env.data[:path] = path
env.block!(code: "branch_exists", message: "branch #{name} already exists")
exit env.emit
```

## Exit codes

- **0** - `ok` is `true`.
- **1** - `ok` is `false` (something is `blocked`, or a wrapped command
  failed). The envelope is still printed on stdout.
- **2** - a usage error (bad flags, missing required argument). A plain-text
  message on stderr, **no envelope** - the caller could not have gotten far
  enough to produce one.

## `--dry-run`

Every mutating script supports `--dry-run`: it populates `commands` with
what it would have run, executes nothing, and reports `ok: true` (absent an
unrelated `blocked` condition it can detect without running anything, such
as a pre-existing branch). This is both the audit path for a human reading
what a script intends to do, and how the test suite exercises scripts
without a real `git`, `gh`, or `tmux`.

## Step-scoping and the banned-operation list

CLAUDE.md's authority table draws a hard line between what this session may
do on its own and what needs a human ask. A script may never span that line,
and no script anywhere under `.claude/scripts/` may contain a code path
that:

- runs `git push`
- runs `gh pr create`
- runs `bd close`
- runs `bd edit` (blocks on `$EDITOR` - use `--notes`/`bd note` instead)
- writes `docs/quality-gate-changes.md` (the ADR-0011 ledger - a human's
  call, recorded, not automated)
- writes `.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf`, or
  a gate-relevant `mix.exs` line (the ADR-0011 guarded paths)

`test/contract_test.rb` asserts the first four mechanically against every
file under `.claude/scripts/` and is intended to survive unchanged as more
scripts land - see `docs/skill-automation.md`'s "What must never be
scripted" for the full list of judgment calls (sabotage protocol, phase
sizing, `bd close` triggers, and others) no script may absorb even when the
absorbing is technically possible.

**Shelling out goes through one runner.** `Sh.run` (`lib/sh.rb`) always uses
`Open3.capture3`/`popen3` with an argv array - never a shell string - so a
developer's `-i` alias on `cp`/`rm`/`mv` cannot apply and no argument's shell
metacharacters are ever interpreted. `system(...)` and backticks are banned
outside `lib/sh.rb` itself, checked by `test/contract_test.rb`. Every
`cp`/`rm`/`mv` argv still carries its explicit non-interactive flag
(`cp -Rf`, `rm -rf`, ...), per CLAUDE.md - the argv discipline removes the
aliasing hazard, it does not remove the need to ask non-interactively.

## Running the tests

```sh
ruby .claude/scripts/test/run.rb
ruby .claude/scripts/test/run.rb -n /pattern/   # run a subset by name
```

**`mix quality` runs this suite** as the `Script tests` stage, registered in
`.quality.exs` with an ADR-0011 ledger entry (`docs/quality-gate-changes.md`,
st-hzf). Running `test/run.rb` directly is still the fast inner loop - half a
second against the gate's minutes - but a green `mix quality` now does mean
the Ruby suite passed.

It was hand-run only at first, on the reasoning that registering a stage
needs a human's ledger call. That was the wrong trade: `.claude/**` is not a
gate-guarded path, and this branch touches no `lib/`, `test/`, `config/` or
`mix.exs`, so the gate carved out of ~8k lines of new Ruby entirely and
reported green having measured none of it. st-hzf's own Phase 12 left a test
red and reported the phase done; only a hand-run caught it.

Registering the stage also widened the carve-out predicate - see
`lib/touches_elixir.rb`, where `any?` still means "touches the Elixir build"
and `gate_applicable?` adds `.claude/scripts/` on top. A gate stage that
measures something outside the Elixir build has to be reflected in the
predicate that decides whether the gate runs at all, or it never fires on the
branches it exists for.

## `gate.rb`: the quality-gate wrapper

Wraps `mix gate.verify` and `mix quality --format json --report -`. The most
constrained script here - see
`docs/plans/260806-st-hzf-skill-mechanics-scripts.md` Phase 7.

- `data.skipped_stages` always stays in the payload, for every skip. Whether
  a skip *blocks* follows CLAUDE.md's own distinction - "the reason says
  whether the gap is in this run or in what the project checks at all":
  - a gap **in this run** (Dialyzer skipped for a missing PLT, Tests skipped
    because compilation failed) sets `ok` false;
  - a gap in **what the project checks at all** (`:doctor not installed`,
    `disabled in .quality.exs`) is reported with `project_level: true` and a
    `stage_skipped_project_level` warning, and does not block.

  The second case is not a softening. It is true on every run including the
  green ones, so blocking on it would make `ok` false on every full gate run
  forever - which deletes the signal rather than enforcing it. Either way a
  skipped stage is never a passing one, and both kinds must appear in what
  you report. `PROJECT_LEVEL_SKIP_RE` is narrow by design: an unrecognized
  skip reason blocks, and widening it is a review decision.
- Only one profile argument is accepted: `--profile loop`. It always sets
  `data.attested` to `false`. No `--skip`, `--quick`, or other `--profile`
  value is defined by this script's parser, so passing one is a usage error
  (exit 2), not a narrower run.
- **`data.sabotage.missing` is a report, not a gate.** It never blocks and
  never flips `ok`. A present `# sabotage:` note (either a real mutation or
  a stated `n/a` exemption) is not evidence the mutation described was
  actually run against broken code - only reading the diff by hand and
  confirming the test failed for the right reason is. `/commit`'s own
  Step 0 carries that judgment call; this script only reports absence.
- **`data.gate_guard` reports; it never writes.** There is no code path in
  `gate.rb` that writes `docs/quality-gate-changes.md` - `test/contract_test.rb`
  asserts that mechanically over every file under `.claude/scripts/`.

## Writing a new script

1. Require `lib/envelope`, `lib/sh`, and `lib/cli`.
2. Build the option parser with `Cli.build`, add script-specific flags in the
   block, parse with `Cli.parse!`.
3. Build an `Envelope.new(script: "<name>")`, do the work, route conditions
   the script cannot resolve itself into `env.block!`, informational notes
   into `env.warn`, and exit with `env.emit`.
4. Every `Sh.run` call that mutates anything must be skippable under
   `--dry-run` - populate `commands` regardless, but only actually invoke
   `Sh.run` when `options[:dry_run]` is false.
5. Add `test/<name>_test.rb` using `test/support/fake_sh.rb` to fake every
   shelled-out command; a script that shells out to something the test did
   not register a fixture for fails loudly (`FakeSh::UnexpectedCommand`),
   not silently.
6. `chmod +x` the script (top-level scripts are the ones directly invoked;
   files under `lib/` and `test/` are not and do not need the executable
   bit). `test/contract_test.rb` checks every direct child of
   `.claude/scripts/*.rb` for the shebang and the executable bit.
