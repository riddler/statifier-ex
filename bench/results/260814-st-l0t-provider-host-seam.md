# Provider/host seam for In/1: before/after, 2026-08-14

Evidence for `st-l0t` (mirrors `px-10u`), following the acceptance criterion
in `docs/plans/260814-st-l0t-provider-host-seam-for-in1.md`. Produced by
`mix run bench/macrostep.exs` and `mix run bench/context_build.exs`.

## Machine

- macOS, Apple M3, 8 cores, 24 GB
- Elixir 1.18.3, Erlang/OTP 27.3, JIT enabled
- benchee 1.5.1

The before and after rows in this file come from the same machine. The
Before rows below were captured on the merge-base tree, before any `lib/`
edit in this plan; `bench/results/260814-macrostep.md`'s own table is the
historical before-set from a prior session and is not reused here, so this
comparison is same-machine rather than same-machine-class.

Note per the plan: the script's derived `S_time`/`S_mem` figures are not
reported here. They are already declared dead in
`bench/results/260814-macrostep.md` (their derivation constants predate
ADR-0028's within-block threading), and Phase 3 of this plan repairs the
constants that make them meaningful again. Only `measured macrostep` and the
`context_build.exs` timing/memory figures are recorded in this Phase 1
capture.

## Before (baseline, this machine)

### `mix run bench/macrostep.exs` - measured macrostep

| Document family | Input | ips | average | median | Memory |
|---|---|---:|---:|---:|---:|
| realistic | (single) | 57.51 K | 17.39 μs | 17.33 μs | 74.19 KB |
| assign-heavy | n=1 | 96.99 K | 10.31 μs | 10.08 μs | 43.59 KB |
| assign-heavy | n=5 | 68.08 K | 14.69 μs | 14.54 μs | 56.83 KB |
| assign-heavy | n=25 | 27.27 K | 36.67 μs | 36.83 μs | 129.91 KB |
| assign-heavy | n=100 | 8.04 K | 124.41 μs | 121.38 μs | 455.93 KB |
| foreach | n=1 | 84.45 K | 11.84 μs | 11.08 μs | 43.66 KB |
| foreach | n=10 | 72.71 K | 13.75 μs | 13.58 μs | 50.23 KB |
| foreach | n=100 | 23.04 K | 43.40 μs | 43.00 μs | 116.55 KB |
| foreach | n=1000 | 2.87 K | 348.90 μs | 338.83 μs | 785.56 KB |
| cond-bearing selection (not corpus-reachable) | (single) | 116.25 K | 8.60 μs | 8.46 μs | 34.57 KB |

Per-build cost (`Evaluator.context/1` on each document's own live
`machine_state`):

| Document family | Input | average | Memory |
|---|---|---:|---:|
| realistic + assign-heavy (constant datamodel) | (single) | 1.91 μs | 9.26 KB |
| foreach | n=1 | 2.00 μs | 9.56 KB |
| foreach | n=10 | 2.30 μs | 9.56 KB |
| foreach | n=100 | 3.59 μs | 12.66 KB |
| foreach | n=1000 | 18.57 μs | 40.78 KB |
| cond | (single) | 1.95 μs | 8.98 KB |

### `mix run bench/context_build.exs` - `T_full`/`T_fixed`/`T_bind` at every size point

`T_new` (`Context.new/2, no nils`) is the script's own scenario and is
recorded too since Phase 2's equivalence claim references it.

| Size point | T_bind | T_fixed | T_new | T_full |
|---|---:|---:|---:|---:|
| corpus | 0.138 μs / 0.59 KB | 1.31 μs / 5.51 KB | 1.86 μs / 8.91 KB | 2.30 μs / 10.92 KB |
| stress_small | 0.111 μs / 0.63 KB | 1.31 μs / 5.77 KB | 6.10 μs / 32.42 KB | 9.53 μs / 48.56 KB |
| stress_medium | 0.161 μs / 0.72 KB | 1.31 μs / 5.77 KB | 170.74 μs / 843.14 KB | 302.15 μs / 1357.98 KB |
| stress_large | 0.00016 ms / 0.00075 MB | 0.00132 ms / 0.00564 MB | 1.22 ms / 5.81 MB | 2.33 ms / 9.43 MB |

Block-level A/B (`bind/3-threaded` vs `rebuild-per-write`) at each size
point, `n` in `[1, 5, 25, 100]` writes per block - unchanged by this plan
(ADR-0028's own mechanism, re-measured here only as a same-session
cross-check, not as a Phase 1 target):

| Size point | n | bind/3-threaded | rebuild-per-write |
|---|---:|---:|---:|
| corpus | 1 | 0.25 μs / 1.18 KB | 2.49 μs / 11.49 KB |
| corpus | 5 | 1.01 μs / 5.52 KB | 12.34 μs / 59.02 KB |
| corpus | 25 | 4.80 μs / 27.18 KB | 61.73 μs / 295.70 KB |
| corpus | 100 | 18.49 μs / 108.63 KB | 257.34 μs / 1183.77 KB |
| stress_small | 1 | 0.25 μs / 1.22 KB | 10.33 μs / 46.29 KB |
| stress_small | 5 | 1.00 μs / 5.72 KB | 48.21 μs / 231.54 KB |
| stress_small | 25 | 4.95 μs / 28.22 KB | 290.63 μs / 1156.21 KB |
| stress_small | 100 | 18.51 μs / 112.59 KB | 1209.55 μs / 4629.23 KB |
| stress_medium | 1 | 0.26 μs / 0.00128 MB | 364.69 μs / 1.30 MB |
| stress_medium | 5 | 1.12 μs / 0.00604 MB | 1806.92 μs / 6.51 MB |
| stress_medium | 25 | 5.20 μs / 0.0298 MB | 8939.33 μs / 32.54 MB |
| stress_medium | 100 | 20.15 μs / 0.119 MB | 35187.48 μs / 130.15 MB |
| stress_large | 1 | 0.00027 ms / 0.00133 MB | 2.41 ms / 9.38 MB |
| stress_large | 5 | 0.00112 ms / 0.00627 MB | 12.09 ms / 46.92 MB |
| stress_large | 25 | 0.00530 ms / 0.0310 MB | 60.74 ms / 234.62 MB |
| stress_large | 100 | 0.0201 ms / 0.123 MB | 238.80 ms / 938.48 MB |

Full raw benchee output for both runs is not reproduced here beyond the
tables above; both runs completed cleanly with no benchee errors, only the
routine "super fast function" warning on `T_bind` at `stress_small` (an
expected artifact of measuring a sub-microsecond operation, not a defect in
the run).

## After (Phase 2)

Not yet captured - Phase 3 of the plan appends the "After (Phase 2)" and
"Comparison" sections once the compile-time base context lands.
