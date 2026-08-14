# Context build: the three-term decomposition, 2026-08-14

Produced by `mix run bench/context_build.exs`. Evidence for `docs/adr/0027-*`
(Phase 3) and for the pre-registered decision rule in
`docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`.

## Machine

- macOS, Apple M3, 8 cores, 24 GB
- Elixir 1.18.3, Erlang/OTP 27.3, JIT enabled
- benchee 1.5.1 (`{:benchee, "~> 1.3", only: :dev}`, added in this phase)

## Corpus scan behind the `:corpus` size point (D1/D2, §3 of the plan)

```
$ grep -rho '<data [^>]*>' test/scxml_tests/ test/scion_tests/ | wc -l
169

$ grep -rc '<data ' test/scxml_tests/ test/scion_tests/ | sort -t: -k2 -rn | head -15
test/scxml_tests/mandatory/selecting_transitions/test504_test.exs:5
test/scxml_tests/mandatory/foreach/test152_test.exs:5
test/scion_tests/foreach/test1_test.exs:5
test/scxml_tests/mandatory/system_variables/test329_test.exs:4
test/scxml_tests/mandatory/selecting_transitions/test533_test.exs:4
test/scxml_tests/mandatory/invoke/test241_test.exs:4
test/scxml_tests/mandatory/foreach/test153_test.exs:4
test/scxml_tests/mandatory/selecting_transitions/test506_test.exs:3
test/scxml_tests/mandatory/selecting_transitions/test505_test.exs:3
test/scxml_tests/mandatory/scxml_event_processor/test354_test.exs:3
test/scxml_tests/mandatory/invoke/test240_test.exs:3
test/scxml_tests/mandatory/foreach/test156_test.exs:3
test/scxml_tests/mandatory/foreach/test155_test.exs:3
test/scxml_tests/mandatory/foreach/test151_test.exs:3
test/scxml_tests/mandatory/foreach/test150_test.exs:3
```

Observed maximum: 5 `<data>` roots per document (three files tie), matching
D1's own citation of `test504_test.exs`, `test152_test.exs`, and scion
`foreach/test1_test.exs`. Declarations are overwhelmingly flat scalars, so
`Workload.size_points/0`'s `:corpus` point uses `roots: 5, depth: 1,
breadth: 2` - a couple of nested values per root, the corpus's worst case,
not the mean, per D1.

## Run 1: the three-term decomposition

Four scenarios (D2), swept over `:corpus` and three `:stress` points
(`roots/depth/breadth` = 10/2/3, 50/3/4, 200/3/5). `time: 5`, `memory_time: 2`,
`warmup: 2`.

### `:corpus` (the realistic point - decides the bead)

| Scenario | ips | average | median | deviation | memory |
|---|---:|---:|---:|---:|---:|
| T_bind  `Context.bind/3` one root | 7,225.53 K | 0.138 μs | 0.125 μs | ±3224.99% | 0.59 KB |
| T_fixed `Context.new/2`, empty data | 777.40 K | 1.29 μs | 1.25 μs | ±477.00% | 5.51 KB |
| T_new   `Context.new/2`, no nils | 536.92 K | 1.86 μs | 1.75 μs | ±343.89% | 8.91 KB |
| T_full  `Evaluator.context/1` | 438.98 K | 2.28 μs | 2.21 μs | ±257.56% | 10.92 KB |

**Derived terms (D2's subtraction), at `:corpus`:**

| Term | Time | Memory |
|---|---:|---:|
| Fixed cost (`resolve_functions/1`) = `T_fixed` | 1.29 μs | 5.51 KB |
| Predicator's `normalize_value/1` = `T_new - T_fixed` | 0.57 μs | 3.40 KB |
| Statifier's `undefine_nils/1` = `T_full - T_new` | 0.42 μs | 2.01 KB |
| **Total (= `T_full`)** | **2.28 μs** | **10.92 KB** |

Consistency check: `T_fixed <= T_new <= T_full` holds on both axes at
`:corpus` (1.29 <= 1.86 <= 2.28 μs; 5.51 <= 8.91 <= 10.92 KB) - the
decomposition is not inverted.

**Modifier C check:** `T_fixed / T_full` at `:corpus` = 1.29 / 2.28 = **56.6%**,
which is `>= 50%`. Modifier C fires: the fixed per-call `resolve_functions/1`
cost dominates `T_full` at realistic scale, not the datamodel-size-scaling
terms. Per the plan, this means Phase 3 also files a predicator-ex bead for
upstream memoization and cross-links it via `mirrors:` - Modifier C fires
independently of which of Branch A/B the pre-registered rule selects.

### `:stress_small` (roots=10, depth=2, breadth=3)

| Scenario | ips | average | median | memory |
|---|---:|---:|---:|---:|
| T_bind | 6,813.93 K | 0.147 μs | 0.125 μs | 0.63 KB |
| T_fixed | 755.52 K | 1.32 μs | 1.25 μs | 5.77 KB |
| T_new | 163.27 K | 6.12 μs | 5.92 μs | 32.42 KB |
| T_full | 106.67 K | 9.37 μs | 9.13 μs | 48.56 KB |

Derived: fixed = 1.32 μs / 5.77 KB; predicator normalize = 4.80 μs / 26.65 KB;
statifier `undefine_nils` = 3.25 μs / 16.14 KB. Consistency: 1.32 <= 6.12 <=
9.37 μs; 5.77 <= 32.42 <= 48.56 KB - holds.

### `:stress_medium` (roots=50, depth=3, breadth=4)

| Scenario | ips | average | median | memory |
|---|---:|---:|---:|---:|
| T_bind | 6,189.36 K | 0.162 μs | 0.125 μs | 0.72 KB |
| T_fixed | 773.89 K | 1.29 μs | 1.25 μs | 5.77 KB |
| T_new | 5.95 K | 168.11 μs | 164.17 μs | 843.14 KB |
| T_full | 3.31 K | 301.67 μs | 287.96 μs | 1357.98 KB |

Derived: fixed = 1.29 μs / 5.77 KB; predicator normalize = 166.82 μs /
837.37 KB; statifier `undefine_nils` = 133.56 μs / 514.84 KB. Consistency:
1.29 <= 168.11 <= 301.67 μs; 5.77 <= 843.14 <= 1357.98 KB - holds.

### `:stress_large` (roots=200, depth=3, breadth=5)

| Scenario | ips | average | median | memory |
|---|---:|---:|---:|---:|
| T_bind | 6,098,459.05 | 0.00016 ms | 0.00017 ms | 0.00075 MB |
| T_fixed | 737,808.20 | 0.00136 ms | 0.00125 ms | 0.00564 MB |
| T_new | 820.22 | 1.22 ms | 1.17 ms | 5.81 MB |
| T_full | 413.05 | 2.42 ms | 2.23 ms | 9.43 MB |

Derived: fixed = 1.36 μs / 5.64 KB; predicator normalize = 1.22 ms / 5.80 MB;
statifier `undefine_nils` = 1.20 ms / 3.62 MB. Consistency: 1.36 μs <= 1.22 ms
<= 2.42 ms; 5.64 KB <= 5.81 MB <= 9.43 MB - holds.

**Cross-scale reading:** `T_fixed` stays flat (~1.3 μs / ~5.5 KB) across all
four size points, exactly as D2 predicts - it does not scale with datamodel
size. `T_new` and `T_full` both grow with datamodel size, and the gap
between them (statifier's `undefine_nils/1`) grows proportionally too. At
`:corpus` the fixed term is the majority of `T_full`; at every larger stress
point the scaling terms dominate instead, which is the shape Modifier C's
own text anticipates ("at small datamodel sizes it can dominate").

## Run 2: block-level A/B (rebuild-per-write vs `bind/3`-threaded)

Script-local functions only (`bench/context_build.exs`'s `BlockAB` module) -
nothing in `lib/` changed for this measurement. `n` sequential single-root
writes, `n` in `[1, 5, 25, 100]`, over each size point. `time: 3`,
`memory_time: 1`, `warmup: 1`.

### `:corpus`

| n | rebuild-per-write | bind/3-threaded | time ratio | memory ratio |
|---:|---:|---:|---:|---:|
| 1 | 2.47 μs / 11.49 KB | 0.25 μs / 1.18 KB | 9.9x | 9.7x |
| 5 | 12.21 μs / 59.02 KB | 1.02 μs / 5.52 KB | 12.0x | 10.7x |
| 25 | 61.57 μs / 295.70 KB | 5.14 μs / 27.18 KB | 12.0x | 10.9x |
| 100 | 255.63 μs / 1183.77 KB | 18.38 μs / 108.63 KB | 13.9x | 10.9x |

### `:stress_small`

| n | rebuild-per-write | bind/3-threaded | time ratio | memory ratio |
|---:|---:|---:|---:|---:|
| 1 | 9.06 μs / 46.29 KB | 0.25 μs / 1.22 KB | 36.2x | 37.9x |
| 5 | 46.02 μs / 231.54 KB | 1.04 μs / 5.72 KB | 44.3x | 40.5x |
| 25 | 248.09 μs / 1156.21 KB | 4.97 μs / 28.22 KB | 49.9x | 41.0x |
| 100 | 1097.19 μs / 4629.23 KB | 18.42 μs / 112.59 KB | 59.6x | 41.1x |

### `:stress_medium`

| n | rebuild-per-write | bind/3-threaded | time ratio | memory ratio |
|---:|---:|---:|---:|---:|
| 1 | 378.14 μs / 1.30 MB | 0.27 μs / 0.00128 MB | 1400.5x | 1015.6x |
| 5 | 1854.89 μs / 6.51 MB | 1.12 μs / 0.00604 MB | 1656.1x | 1077.8x |
| 25 | 9124.64 μs / 32.54 MB | 5.19 μs / 0.0298 MB | 1758.1x | 1092.0x |
| 100 | 36530.12 μs / 130.15 MB | 20.10 μs / 0.119 MB | 1817.4x | 1093.7x |

### `:stress_large`

| n | rebuild-per-write | bind/3-threaded | time ratio | memory ratio |
|---:|---:|---:|---:|---:|
| 1 | 2.45 ms / 9.38 MB | 0.00027 ms / 0.00133 MB | 9074.1x | 7052.6x |
| 5 | 12.21 ms / 46.92 MB | 0.00113 ms / 0.00627 MB | 10805.3x | 7484.8x |
| 25 | 61.51 ms / 234.62 MB | 0.00528 ms / 0.0310 MB | 11650.4x | 7568.4x |
| 100 | 240.61 ms / 938.48 MB | 0.0200 ms / 0.123 MB | 12030.5x | 7638.8x |

The rebuild-per-write cost grows linearly in `n` at every size point (as
expected: each write pays the full `T_full` again). The bind/3-threaded cost
also grows in `n` (each bind normalizes the written value, `O(size of that
value)`, not the whole datamodel) but at a far smaller slope, and the gap
between the two arms widens both with `n` and with datamodel size - the
`<foreach>` shape (D1/D3), where this plan's block-level A/B matters most.

## Raw benchee output (verbatim)

```
Operating System: macOS
CPU Information: Apple M3
Number of Available Cores: 8
Available memory: 24 GB
Elixir 1.18.3
Erlang 27.3
JIT enabled: true

Benchmark suite executing with the following configuration:
warmup: 2 s
time: 5 s
memory time: 2 s
reduction time: 0 ns
parallel: 1
inputs: corpus, stress_small, stress_medium, stress_large
Estimated total run time: 2 min 24 s
Excluding outliers: false

Benchmarking T_bind  Context.bind/3 one root with input corpus ...
Benchmarking T_bind  Context.bind/3 one root with input stress_small ...
Benchmarking T_bind  Context.bind/3 one root with input stress_medium ...
Benchmarking T_bind  Context.bind/3 one root with input stress_large ...
Benchmarking T_fixed Context.new/2, empty data with input corpus ...
Benchmarking T_fixed Context.new/2, empty data with input stress_small ...
Benchmarking T_fixed Context.new/2, empty data with input stress_medium ...
Benchmarking T_fixed Context.new/2, empty data with input stress_large ...
Benchmarking T_full  Evaluator.context/1 with input corpus ...
Benchmarking T_full  Evaluator.context/1 with input stress_small ...
Benchmarking T_full  Evaluator.context/1 with input stress_medium ...
Benchmarking T_full  Evaluator.context/1 with input stress_large ...
Benchmarking T_new   Context.new/2, no nils with input corpus ...
Benchmarking T_new   Context.new/2, no nils with input stress_small ...
Benchmarking T_new   Context.new/2, no nils with input stress_medium ...
Benchmarking T_new   Context.new/2, no nils with input stress_large ...
Calculating statistics...
Formatting results...

##### With input corpus #####
Name                                        ips        average  deviation         median         99th %
T_bind  Context.bind/3 one root       7225.53 K       0.138 μs  ±3224.99%       0.125 μs        0.25 μs
T_fixed Context.new/2, empty data      777.40 K        1.29 μs   ±477.00%        1.25 μs        1.79 μs
T_new   Context.new/2, no nils         536.92 K        1.86 μs   ±343.89%        1.75 μs           3 μs
T_full  Evaluator.context/1            438.98 K        2.28 μs   ±257.56%        2.21 μs        3.33 μs

Comparison:
T_bind  Context.bind/3 one root       7225.53 K
T_fixed Context.new/2, empty data      777.40 K - 9.29x slower +1.15 μs
T_new   Context.new/2, no nils         536.92 K - 13.46x slower +1.72 μs
T_full  Evaluator.context/1            438.98 K - 16.46x slower +2.14 μs

Memory usage statistics:

Name                                 Memory usage
T_bind  Context.bind/3 one root           0.59 KB
T_fixed Context.new/2, empty data         5.51 KB - 9.40x memory usage +4.92 KB
T_new   Context.new/2, no nils            8.91 KB - 15.20x memory usage +8.32 KB
T_full  Evaluator.context/1              10.92 KB - 18.64x memory usage +10.34 KB

**All measurements for memory usage were the same**

##### With input stress_small #####
Name                                        ips        average  deviation         median         99th %
T_bind  Context.bind/3 one root       6813.93 K       0.147 μs  ±4053.04%       0.125 μs        0.25 μs
T_fixed Context.new/2, empty data      755.52 K        1.32 μs   ±492.51%        1.25 μs           2 μs
T_new   Context.new/2, no nils         163.27 K        6.12 μs    ±98.20%        5.92 μs       13.92 μs
T_full  Evaluator.context/1            106.67 K        9.37 μs    ±37.91%        9.13 μs       12.71 μs

Comparison:
T_bind  Context.bind/3 one root       6813.93 K
T_fixed Context.new/2, empty data      755.52 K - 9.02x slower +1.18 μs
T_new   Context.new/2, no nils         163.27 K - 41.73x slower +5.98 μs
T_full  Evaluator.context/1            106.67 K - 63.88x slower +9.23 μs

Memory usage statistics:

Name                                 Memory usage
T_bind  Context.bind/3 one root           0.63 KB
T_fixed Context.new/2, empty data         5.77 KB - 9.24x memory usage +5.15 KB
T_new   Context.new/2, no nils           32.42 KB - 51.88x memory usage +31.80 KB
T_full  Evaluator.context/1              48.56 KB - 77.70x memory usage +47.94 KB

**All measurements for memory usage were the same**

##### With input stress_medium #####
Name                                        ips        average  deviation         median         99th %
T_bind  Context.bind/3 one root       6189.36 K       0.162 μs  ±3037.53%       0.125 μs        0.25 μs
T_fixed Context.new/2, empty data      773.89 K        1.29 μs   ±457.10%        1.25 μs        1.58 μs
T_new   Context.new/2, no nils           5.95 K      168.11 μs    ±18.09%      164.17 μs      375.35 μs
T_full  Evaluator.context/1              3.31 K      301.67 μs    ±19.19%      287.96 μs      573.34 μs

Comparison:
T_bind  Context.bind/3 one root       6189.36 K
T_fixed Context.new/2, empty data      773.89 K - 8.00x slower +1.13 μs
T_new   Context.new/2, no nils           5.95 K - 1040.52x slower +167.95 μs
T_full  Evaluator.context/1              3.31 K - 1867.17x slower +301.51 μs

Memory usage statistics:

Name                                 Memory usage
T_bind  Context.bind/3 one root           0.72 KB
T_fixed Context.new/2, empty data         5.77 KB - 8.03x memory usage +5.05 KB
T_new   Context.new/2, no nils          843.14 KB - 1173.07x memory usage +842.42 KB
T_full  Evaluator.context/1            1357.98 KB - 1889.37x memory usage +1357.27 KB

**All measurements for memory usage were the same**

##### With input stress_large #####
Name                                        ips        average  deviation         median         99th %
T_bind  Context.bind/3 one root      6098459.05     0.00016 ms  ±2465.20%     0.00017 ms     0.00025 ms
T_fixed Context.new/2, empty data     737808.20     0.00136 ms   ±754.30%     0.00125 ms     0.00167 ms
T_new   Context.new/2, no nils           820.22        1.22 ms    ±24.88%        1.17 ms        2.68 ms
T_full  Evaluator.context/1              413.05        2.42 ms    ±23.01%        2.23 ms        4.04 ms

Comparison:
T_bind  Context.bind/3 one root      6098459.05
T_fixed Context.new/2, empty data     737808.20 - 8.27x slower +0.00119 ms
T_new   Context.new/2, no nils           820.22 - 7435.14x slower +1.22 ms
T_full  Evaluator.context/1              413.05 - 14764.39x slower +2.42 ms

Memory usage statistics:

Name                                 Memory usage
T_bind  Context.bind/3 one root        0.00075 MB
T_fixed Context.new/2, empty data      0.00564 MB - 7.54x memory usage +0.00489 MB
T_new   Context.new/2, no nils            5.81 MB - 7772.12x memory usage +5.81 MB
T_full  Evaluator.context/1               9.43 MB - 12612.03x memory usage +9.43 MB

**All measurements for memory usage were the same**

=== block-level A/B at size point :corpus ===
[benchee header omitted - identical shape to above]

Name                                 ips        average  deviation         median         99th %
bind/3-threaded    (n=1)       3946.12 K        0.25 μs  ±2004.70%        0.21 μs        0.38 μs
bind/3-threaded    (n=5)        976.02 K        1.02 μs   ±661.89%        0.96 μs        1.33 μs
rebuild-per-write (n=1)         404.69 K        2.47 μs   ±281.08%        2.38 μs        3.54 μs
bind/3-threaded    (n=25)       194.65 K        5.14 μs  ±2572.62%        4.67 μs        6.46 μs
rebuild-per-write (n=5)          81.92 K       12.21 μs    ±16.75%       11.92 μs          15 μs
bind/3-threaded    (n=100)       54.40 K       18.38 μs     ±7.77%       18.25 μs       21.17 μs
rebuild-per-write (n=25)         16.24 K       61.57 μs     ±5.39%       60.63 μs       72.73 μs
rebuild-per-write (n=100)         3.91 K      255.63 μs     ±4.17%      250.59 μs      293.21 μs

Memory usage statistics:

Name                          Memory usage
bind/3-threaded    (n=1)           1.18 KB
bind/3-threaded    (n=5)           5.52 KB - 4.68x memory usage +4.34 KB
rebuild-per-write (n=1)           11.49 KB - 9.74x memory usage +10.31 KB
bind/3-threaded    (n=25)         27.18 KB - 23.04x memory usage +26 KB
rebuild-per-write (n=5)           59.02 KB - 50.03x memory usage +57.84 KB
bind/3-threaded    (n=100)       108.63 KB - 92.08x memory usage +107.45 KB
rebuild-per-write (n=25)         295.70 KB - 250.66x memory usage +294.52 KB
rebuild-per-write (n=100)       1183.77 KB - 1003.46x memory usage +1182.59 KB

=== block-level A/B at size point :stress_small ===
Name                                 ips        average  deviation         median         99th %
bind/3-threaded    (n=1)       3940.31 K        0.25 μs  ±2733.42%        0.21 μs        0.38 μs
bind/3-threaded    (n=5)        962.65 K        1.04 μs   ±795.80%        0.96 μs        1.42 μs
bind/3-threaded    (n=25)       201.09 K        4.97 μs   ±209.64%        4.83 μs       10.04 μs
rebuild-per-write (n=1)         110.37 K        9.06 μs    ±24.20%        8.75 μs       11.96 μs
bind/3-threaded    (n=100)       54.28 K       18.42 μs    ±14.54%       18.25 μs       22.04 μs
rebuild-per-write (n=5)          21.73 K       46.02 μs     ±5.94%       45.04 μs       55.58 μs
rebuild-per-write (n=25)          4.03 K      248.09 μs     ±8.46%      246.13 μs      297.96 μs
rebuild-per-write (n=100)         0.91 K     1097.19 μs     ±4.06%     1110.87 μs     1165.96 μs

Memory usage statistics:

Name                          Memory usage
bind/3-threaded    (n=1)           1.22 KB
bind/3-threaded    (n=5)           5.72 KB - 4.69x memory usage +4.50 KB
bind/3-threaded    (n=25)         28.22 KB - 23.15x memory usage +27 KB
rebuild-per-write (n=1)           46.29 KB - 37.98x memory usage +45.07 KB
bind/3-threaded    (n=100)       112.59 KB - 92.38x memory usage +111.38 KB
rebuild-per-write (n=5)          231.54 KB - 189.98x memory usage +230.32 KB
rebuild-per-write (n=25)        1156.21 KB - 948.69x memory usage +1154.99 KB
rebuild-per-write (n=100)       4629.23 KB - 3798.35x memory usage +4628.02 KB

=== block-level A/B at size point :stress_medium ===
Name                                 ips        average  deviation         median         99th %
bind/3-threaded    (n=1)       3757.03 K        0.27 μs  ±2515.65%        0.25 μs        0.38 μs
bind/3-threaded    (n=5)        889.77 K        1.12 μs   ±548.10%        1.04 μs        1.46 μs
bind/3-threaded    (n=25)       192.84 K        5.19 μs    ±66.98%           5 μs        8.17 μs
bind/3-threaded    (n=100)       49.75 K       20.10 μs    ±34.72%       19.96 μs       23.46 μs
rebuild-per-write (n=1)           2.64 K      378.14 μs    ±17.66%      356.25 μs      574.86 μs
rebuild-per-write (n=5)           0.54 K     1854.89 μs     ±6.52%     1878.07 μs     2120.87 μs
rebuild-per-write (n=25)         0.110 K     9124.64 μs     ±2.10%     9088.45 μs     9639.92 μs
rebuild-per-write (n=100)       0.0274 K    36530.12 μs     ±2.20%    36135.32 μs    37995.05 μs

Memory usage statistics:

Name                          Memory usage
bind/3-threaded    (n=1)        0.00128 MB
bind/3-threaded    (n=5)        0.00604 MB - 4.71x memory usage +0.00476 MB
bind/3-threaded    (n=25)        0.0298 MB - 23.29x memory usage +0.0286 MB
bind/3-threaded    (n=100)        0.119 MB - 92.88x memory usage +0.118 MB
rebuild-per-write (n=1)            1.30 MB - 1015.55x memory usage +1.30 MB
rebuild-per-write (n=5)            6.51 MB - 5077.31x memory usage +6.51 MB
rebuild-per-write (n=25)          32.54 MB - 25386.65x memory usage +32.54 MB
rebuild-per-write (n=100)        130.15 MB - 101540.14x memory usage +130.15 MB

=== block-level A/B at size point :stress_large ===
Name                                 ips        average  deviation         median         99th %
bind/3-threaded    (n=1)      3689653.24     0.00027 ms  ±2316.58%     0.00025 ms     0.00038 ms
bind/3-threaded    (n=5)       881164.62     0.00113 ms   ±584.98%     0.00108 ms     0.00142 ms
bind/3-threaded    (n=25)      189476.43     0.00528 ms   ±106.56%     0.00508 ms     0.00942 ms
bind/3-threaded    (n=100)      49960.16      0.0200 ms     ±7.08%      0.0198 ms      0.0233 ms
rebuild-per-write (n=1)           407.66        2.45 ms    ±21.81%        2.29 ms        3.49 ms
rebuild-per-write (n=5)            81.87       12.21 ms     ±4.20%       12.28 ms       13.39 ms
rebuild-per-write (n=25)           16.26       61.51 ms     ±4.11%       61.14 ms       77.93 ms
rebuild-per-write (n=100)           4.16      240.61 ms     ±0.71%      240.21 ms      245.22 ms

Memory usage statistics:

Name                               average  deviation         median         99th %
bind/3-threaded    (n=1)        0.00133 MB     ±0.00%     0.00133 MB     0.00133 MB
bind/3-threaded    (n=5)        0.00627 MB     ±0.00%     0.00627 MB     0.00627 MB
bind/3-threaded    (n=25)        0.0310 MB     ±0.00%      0.0310 MB      0.0310 MB
bind/3-threaded    (n=100)        0.123 MB     ±0.00%       0.123 MB       0.123 MB
rebuild-per-write (n=1)            9.38 MB     ±0.00%        9.38 MB        9.38 MB
rebuild-per-write (n=5)           46.92 MB     ±0.00%       46.92 MB       46.92 MB
rebuild-per-write (n=25)         234.62 MB     ±0.00%      234.62 MB      234.62 MB
rebuild-per-write (n=100)        938.48 MB     ±0.00%      938.47 MB      938.48 MB

EXIT: 0
```

## Noise check

At `:corpus`, per-scenario deviation runs 257%-3225% - large in relative
terms, but the absolute values involved are sub-microsecond to
low-microsecond, where benchee's own timer resolution and scheduler noise
dominate any real signal at that scale (this is exactly the T_bind row: its
average is smaller than one scheduler tick). The comparisons this file
draws conclusions from are all order-of-magnitude (9x-18x at `:corpus`
alone, growing to 1000x+ at stress scale), which is far outside what this
noise band could produce by chance. At `:stress_medium` and `:stress_large`,
where the interesting terms (`T_new`, `T_full`) run into the hundreds of
microseconds to milliseconds, deviation drops to 18%-25% - a 5% signal
would not be trustworthy there without a longer run, but nothing in this
file's derived terms rests on a difference that small; Phase 2's macrostep
benchmark is what has to clear the pre-registered rule's actual 5%
threshold, and it should raise `time:`/`memory_time:` if its own deviation
does not comfortably clear that bar.
