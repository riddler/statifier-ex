# Benchmarks

Measures the cost of `Statifier.Evaluator.context/1` (the rebuild path) and
compares it against `Predicator.Context.bind/3` (the alternative), per
`st-sdh` and `docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`.

## Running

Each script is a standalone entry point, run with `mix run`:

```bash
mix run bench/context_build.exs
mix run bench/macrostep.exs
```

There is no `mix bench` alias. An `aliases:` entry in `mix.exs` would match
the gate guard's pattern outright (`lib/mix/statifier/gate_guard.ex:40-43`),
and adding a `mix bench` alias is explicitly out of scope for this bead (D4
in the plan above) - it is not needed to run these scripts, and adding one
would be a decision for a future maintainer to make deliberately, not a
side effect of landing a benchmark.

## What each script measures

- `context_build.exs` - the three-term decomposition of one context build
  (`T_full`, `T_new`, `T_fixed`, `T_bind`), plus a block-level A/B of
  rebuild-per-write against `bind/3`-threaded writes, over named datamodel
  size points including the corpus-derived `:corpus` point. See
  `bench/support/workload.exs` for how the size points and machine states
  are built, and `bench/results/260814-context-build.md` for the recorded
  output.
- `macrostep.exs` - the end-to-end share of a real macrostep's time and
  memory that context construction accounts for, at realistic and stress
  scale (Phase 2 of the plan above).

## `bench/` is outside every gate stage, on purpose

This directory is invisible to `mix quality` by construction, not by
oversight:

- Outside `.formatter.exs`'s `inputs:` - the formatter never touches it.
- Outside `.credo.exs`'s `included:` - Credo never lints it.
- Outside `elixirc_paths` in `mix.exs` - Compile, Dialyzer, Doctor, and
  coverage never see it, because it is never compiled as part of the
  project.
- Outside the gate guard's file-interest scan
  (`lib/mix/statifier/gate_guard.ex`) - editing this directory never
  triggers a ledger-entry demand.

The reason is what this code is: benchmark scripts, not test code and not
shipped code. They assert nothing, no `lib/` behavior depends on them, and
they are run by a human reading numbers, not by CI. Bringing `bench/` under
the formatter or Credo would mean editing `.formatter.exs` or `.credo.exs` -
both guarded paths under ADR-0011, both needing a human-written ledger entry
in `docs/quality-gate-changes.md` - to lint a directory that cannot break
anything. That trade is not worth making, so `bench/` stays ungated, and
this file records that decision so the next reader does not mistake it for
something that was simply forgotten.

Because nothing here is compiled by `mix compile`, each script starts with
`Mix.install/2`-free plain `Code.require_file/2` calls against
`bench/support/workload.exs`, and depends on `benchee` (`only: :dev` in
`mix.exs`) being present in the dev environment `mix run` uses by default.
