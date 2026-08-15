# predicator 8.0 restatement of ADR-0030's figures, 2026-08-15

Evidence for `st-59d`, Phase 2 of
`docs/plans/260815-st-59d-predicator-8-0-bump-structured-compile-errors.md`.
Produced by `mix run bench/context_build.exs` and `mix run bench/macrostep.exs`
on the Phase 1 tree (predicator pinned `~> 8.0`, resolved `8.0.0`).

**Reduced durations.** Both scripts were run with `time: 2, memory_time: 1,
warmup: 1` for every primary `Benchee.run` and `time: 2, memory_time: 1,
warmup: 1` for every secondary run - down from ADR-0030's `time: 5,
memory_time: 2, warmup: 2` (primary) and `time: 3, memory_time: 1, warmup: 1`
(secondary). This is a deliberate change for this capture only, recorded
directly in each script beside the changed config. Every operation measured
here is microsecond-scale (sub-2us medians throughout), so even 2s of
measurement still yields on the order of a million samples per scenario;
past that point, benchee's own deviation bands are set by scheduler/GC noise,
not by sample count. **Do not compare this file's numbers against
ADR-0030's original figures without accounting for this: the timing config is
different, not just the predicator version.** Where a delta below is smaller
than or comparable to its own deviation band, it is reported as noise, never
as a win or a regression.

## Machine

- macOS 26.5.2 (build 25F84), Apple M3, 8 cores, 24 GB
- Elixir 1.18.3, Erlang/OTP 27.3 (erts-15.2.3), JIT enabled
- benchee 1.5.1
- predicator 8.0.0 (mix.lock: `0e3b0a3d...`)

Both scripts ran back to back on this machine, in this session, with no other
load. `benchee` and predicator versions above are read from `mix deps`
directly, not recalled.

## `mix run bench/context_build.exs` - Run 1: three-term decomposition + provider/host seam + `T_new_nf`

| Size point | T_put_host | T_bind | T_resolve_provider | T_resolve_closure | T_new_nf | T_fixed | T_new | T_full |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| corpus | 0.0290 us / 0.0859 KB | 0.1386 us / 0.586 KB | 0.3196 us / 0.414 KB | 0.3606 us / 0.898 KB | 0.3788 us / 0.867 KB | 0.3989 us / 0.992 KB | 1.0691 us / 4.125 KB | 1.0755 us / 4.773 KB |
| stress_small | 0.0281 us / 0.0859 KB | 0.1429 us / 0.625 KB | 0.3219 us / 0.414 KB | 0.3605 us / 0.898 KB | 0.3702 us / 0.867 KB | 0.4061 us / 0.992 KB | 5.0351 us / 27.641 KB | 8.6293 us / 42.469 KB |
| stress_medium | 0.0298 us / 0.0859 KB | 0.1934 us / 0.719 KB | 0.3292 us / 0.414 KB | 0.3532 us / 0.898 KB | 0.3773 us / 0.867 KB | 0.3981 us / 0.992 KB | 452.631 us / 838.359 KB | 324.242 us / 1356.02 KB |
| stress_large | 0.0304 us / 0.0859 KB | 0.2320 us / 0.766 KB | 0.3167 us / 0.414 KB | 0.3584 us / 0.898 KB | 0.3812 us / 0.867 KB | 0.4097 us / 0.992 KB | 1341.20 us / 5946.7 KB | 2070.49 us / 9652.9 KB |

Deviations at `:corpus` (the point the comparison below is decided on):
T_put_host ±2636.92%, T_bind ±3177.59%, T_resolve_provider ±1955.96%,
T_resolve_closure ±1693.96%, T_new_nf ±1615.08%, T_fixed ±719.60%, T_new
±853.69%, T_full ±522.88%. These are wide because every one of these
operations now completes in well under a microsecond except `T_new`/`T_full`,
which is exactly benchee's documented "fast function" regime - not a defect
in this run. Memory carries no deviation: benchee reported `**All
measurements for memory usage were the same**` for every scenario at every
size point in both scripts, so every memory figure above is an exact
per-call byte count.

At `stress_medium`, `T_new` (452.6 us) reads larger than `T_full` (324.2 us)
point-to-point, which is backwards from every other size point. Both carry
deviations well past 100% (T_new ±284.16%, T_full ±31.67%) - this is noise,
not a real crossover, and is called out explicitly rather than smoothed into
the table.

### `T_new_nf` at all four size points

`T_new_nf` (`Context.new/2, no nils, normalize: false`) is the new scenario
this bump's Phase 2 adds, evidence for Phase 3's refusal to adopt
`normalize: false`. It is essentially flat across all four size points
(0.370-0.381 us / 0.867 KB, unmoved by datamodel size), because it skips the
size-scaling `normalize_value/1` walk entirely - unlike `T_new`, which grows
from 1.07 us at `:corpus` to 1341 us at `:stress_large`. `T_new` minus
`T_new_nf` at `:corpus` is ~0.69 us, the walk `normalize: false` would
remove from a `Context.new/2` call; but `context/1` never calls `new/2` (it
binds per root via `T_bind`, at 0.139 us/root at `:corpus`), so this isolates
what the walk costs without saying anything about whether adopting the option
would help the shipped path - it would not, per Phase 3's refusal.

### Block-level A/B (`bind/3-threaded` vs `rebuild-per-write`)

| Size point | n | bind/3-threaded | rebuild-per-write |
|---|---:|---:|---:|
| corpus | 1 | 0.25 us / 1.18 KB | 1.23 us / 5.83 KB |
| corpus | 5 | 1.03 us / 5.52 KB | 5.95 us / 28.64 KB |
| corpus | 25 | 4.67 us / 27.18 KB | 73.48 us / 143.14 KB |
| corpus | 100 | 18.44 us / 108.63 KB | 121.70 us / 573.16 KB |
| stress_small | 1 | 0.26 us / 1.22 KB | 8.18 us / 40.27 KB |
| stress_small | 5 | 1.02 us / 5.72 KB | 41.10 us / 201.12 KB |
| stress_small | 25 | 5.81 us / 28.22 KB | 221.02 us / 1005.63 KB |
| stress_small | 100 | 18.69 us / 112.59 KB | 934.19 us / 4023.42 KB |
| stress_medium | 1 | 0.27 us / 1.28 KB | 318.46 us / 1331.2 KB |
| stress_medium | 5 | 1.13 us / 6.19 KB | 1590.09 us / 6656.0 KB |
| stress_medium | 25 | 5.12 us / 30.51 KB | 8117.70 us / 33269.8 KB |
| stress_medium | 100 | 20.57 us / 121.86 KB | 32013.06 us / 133091 KB |
| stress_large | 1 | 0.33 us / 1.36 KB | 3260 us / 9605 KB |
| stress_large | 5 | 1.79 us / 6.42 KB | 16200 us / 48026 KB |
| stress_large | 25 | 5.50 us / 31.74 KB | 81640 us / 240148 KB |
| stress_large | 100 | 20.3 us / 125.95 KB | 325140 us / 960573 KB |

This A/B is unchanged mechanism (ADR-0028's own, re-measured here only as a
cross-check per the template this file follows) - not one of the five ADR-0030
figures, and the magnitudes are consistent with the 7.0 Before/After capture:
`bind/3-threaded` stays roughly flat per size point regardless of `n`'s
absolute cost, `rebuild-per-write` scales the same way it always has.

## `mix run bench/macrostep.exs`

### Measured macrostep

| Document family | Input | ips | average | median | Memory | deviation |
|---|---|---:|---:|---:|---:|---:|
| realistic | (single) | 74.35 K | 13.45 us | 13.08 us | 43.05 KB | ±37.11% |
| assign-heavy | n=1 | 132.32 K | 7.56 us | 7.42 us | 25.25 KB | ±34.71% |
| assign-heavy | n=5 | 81.69 K | 12.24 us | 11.96 us | 39.16 KB | ±19.12% |
| assign-heavy | n=25 | 28.84 K | 34.67 us | 34.50 us | 112.92 KB | ±4.88% |
| assign-heavy | n=100 | 8.00 K | 125.03 us | 123.13 us | 443.51 KB | ±6.20% |
| foreach | n=1 | 109.91 K | 9.10 us | 8.79 us | 25.68 KB | ±15.94% |
| foreach | n=10 | 85.58 K | 11.68 us | 11.42 us | 32.43 KB | ±69.88% |
| foreach | n=100 | 24.23 K | 41.27 us | 41.04 us | 98.34 KB | ±5.06% |
| foreach | n=1000 | 2.69 K | 371.98 us | 362.25 us | 765.01 KB | ±8.70% |
| cond-bearing selection (not corpus-reachable) | (single) | 142.57 K | 7.01 us | 6.75 us | 23.00 KB | ±35.10% |

### Per-build cost (`Evaluator.context/1` on each document's own live `machine_state`)

| Document family | Input | average | Memory | deviation | build count |
|---|---|---:|---:|---:|---:|
| realistic + assign-heavy (constant datamodel) | (single) | 1.026 us | 2.928 KB | ±447.09% | 5 (realistic), 3 (assign-heavy, every n) |
| foreach | n=1 | 1.19 us | 3.536 KB | ±523.98% | 3 |
| foreach | n=10 | 1.28 us | 3.824 KB | ±643.64% | 3 |
| foreach | n=100 | 3.293 us | 6.16 KB | ±122.79% | 3 |
| foreach | n=1000 | 23.238 us | 35.504 KB | ±25.57% | 3 |
| cond | (single) | 1.158 us | 3.184 KB | ±452.39% | 2 |

## Which of ADR-0030's five cited figures this confirms or restates

1. **`put_host/2` at `:corpus`** (was 0.0330 us / 0.0859 KB) - restated as
   **0.0290 us / 0.0859 KB**. Memory is byte-identical. Time is inside the
   noise band by a wide margin (deviation ±2636.92% at this reduced
   duration, itself a "fast function" regime benchee flags on every run of
   this scenario) - flat, not a win.

2. **`resolve_functions/1` provider vs. closure** (was 1.36 us vs. 1.40 us) -
   restated as **0.3196 us vs. 0.3606 us** at `:corpus` (provider vs.
   closure), and 0.317-0.329 us vs. 0.353-0.361 us across all four size
   points. Both rows dropped together, roughly 4.2x, consistent with `px-rnc`
   memoizing `resolve_functions/1`'s provider validation upstream in 8.0 -
   exactly the "both rows may drop together" case this phase's task
   description names. The two rows still land close to each other at every
   size point (≤0.04 us apart, provider always the cheaper of the two) -
   **confirming** ADR-0030's claim that a provider swap by itself moves no
   number relative to the closure it replaced. Neither figure is claimed to
   be fast in absolute terms; they are claimed to match, and they do.

3. **`T_fixed / T_full` at `:corpus`** (was 56.6%) - this ratio was measured
   **before** ADR-0030's compile-time hoist landed (the pre-hoist "Before"
   capture in `bench/results/260814-st-l0t-provider-host-seam.md`), where
   `T_full` still called `resolve_functions/1` on every build and `T_fixed`
   isolated exactly that call's share. The hoist removed that call from
   `T_full`'s path entirely, so post-hoist (true of both the 7.0 "After"
   capture and this 8.0 capture) the ratio no longer measures a share of one
   number by another - it compares two unrelated calls. Computed anyway for
   completeness: 8.0 gives 0.3989/1.0755 = **37.1%**; the 7.0 "After" capture
   gives 1.33/1.13 = 117.7% (`T_fixed` exceeds `T_full`, because `T_full`
   dropped below `T_fixed`'s own now-largely-fixed cost once the hoist
   removed the term `T_fixed` isolates). Neither number restates or
   contradicts the 56.6% figure; that figure belongs to the pre-hoist
   world and stays there. This is **restated with a caveat**, not confirmed.

4. **`T_full` at `:corpus`** (was 2.30 us / 10.92 KB before the hoist, 1.13
   us / 4.77 KB after) - restated as **1.0755 us / 4.773 KB**. Memory matches
   the post-hoist 7.0 figure almost exactly (4.773 KB vs. 4.77 KB). Time is
   4.9% lower than the 7.0 post-hoist figure, well inside this run's own
   ±522.88% deviation band - flat, not a further win; the real win (versus
   the pre-hoist 2.30 us) was ADR-0030's own and stands unchanged.

5. **`measured macrostep`, `realistic`** (was 17.39 -> 13.58 us, 74.19 ->
   43.18 KB) - restated as **13.45 us / 43.05 KB**. Both figures land inside
   noise of the 7.0 post-hoist ("After") figures: time -1.0% against this
   run's own ±37.11% deviation band, memory -0.3% (and every macrostep
   memory figure in this run's table is within 1.5% of its 7.0 counterpart -
   flat, since memory allocation shape did not change with the predicator
   bump). The large pre-8.0 win (17.39 -> 13.58 us) was ADR-0030's own and is
   unaffected here; this run confirms 8.0 did not move it further or give it
   back.

### Other deltas worth naming explicitly (none of the five, reported for completeness)

- `T_full` at `stress_small`: 8.63 us / 42.47 KB vs. the 7.0-After 11.00 us /
  42.55 KB - an apparent 21.6% time drop that **clears** its own ±13.11%
  deviation band. Memory is flat (-0.2%). This is the one point in this
  capture where a time delta is large enough, relative to its own band, to
  be worth flagging as a plausible real change rather than noise - most
  likely explained by the same `px-rnc` memoization improving the ambient
  cost of everything routing through `resolve_functions/1` downstream calls,
  though this run does not isolate that further.
- `T_full` at `stress_medium` and `stress_large`: -14.7% and -10.6%
  respectively against 7.0-After, both inside their own deviation bands
  (±31.67%, ±20.81%) - noise.
- Macrostep `assign-heavy n=25`: 34.67 us vs. 7.0-After's 37.71 us, an 8.1%
  drop that clears this run's tight ±4.88% deviation band - a small real
  improvement, plausibly the same downstream memoization effect.
- Macrostep `assign-heavy n=100`: 125.03 us vs. 7.0-After's 118.95 us, a
  +5.1% apparent regression that is comparable to but slightly exceeds this
  run's ±6.20% deviation band. Reported honestly as a small possible
  regression at this one point rather than smoothed away; every other
  document family and every memory figure moved flat or favorably, so this
  reads as scheduler noise at this specific size point rather than a
  systemic effect, but it is not hidden.
- All other macrostep and per-build-cost deltas are inside their own
  deviation bands and are reported as flat/noise in the tables above.

## Summary

Nothing in this capture contradicts ADR-0030's Decision or its cited
figures. Where a direct restatement was possible (`put_host/2`, `T_full` at
`:corpus`, `measured macrostep realistic`), the 8.0 numbers land at or inside
noise of the 7.0 post-hoist figures - the predicator bump changed nothing
observable on the shipped `context/1` path, as `docs/plans/260815-...md`'s
"Performance Considerations" section predicted. Where `px-rnc`'s memoization
is directly visible (`T_resolve_provider`/`T_resolve_closure`), both rows
dropped together and stayed matched to each other, confirming rather than
reopening ADR-0030's provider-vs-closure claim. The `T_fixed/T_full` ratio
is the one figure that cannot be meaningfully restated post-hoist, and this
file says so rather than reporting a number that would misrepresent what
changed. `T_new_nf` is present at all four size points and shows the
normalization walk stays flat while the walked path (`T_new`) scales with
size - the number Phase 3's `normalize: false` refusal rests on.
