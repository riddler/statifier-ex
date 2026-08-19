# Source-Carrying Chart Binary Implementation Plan

## Overview

st-m5c3 gave `%Statifier.Machine{}` a content-hash identity and shipped
`Statifier.Position`, the versioned binary contract for a *position*. It
deliberately shipped no chart-level `to_binary`/`from_binary` pair, and
ADR-0052 decision 3 records that refusal. This plan supplies the missing half
in the shape the bead specifies: a **source-carrying** chart blob that stores
`{format_version, identity, scxml_source, compile_opts}` and no compiled term
at all, and a loader that recompiles the source through `Statifier.compile/2`
with the stored opts and verifies the recompiled chart's identity against the
stored one, failing loudly on mismatch.

Beads issue: st-i7y7. The bead's own description carries the design research (why
source-carrying rather than encoding the compiled `%Machine{}`), and this plan
does not re-derive it.

## Current State Analysis

- `Statifier.compile/2` (`lib/statifier.ex:88-97`) is the only place in the
  library holding both the source binary and the finished `%Machine{}`. It
  stamps `warnings` and `identity` onto the returned Machine and then
  **discards the source and the opts**. `Compiler.compile/1` never receives
  either.
- `%Machine{}` (`lib/statifier/machine.ex:121-135`) therefore carries the
  identity but not the two inputs needed to reproduce itself: no `source`
  field and no `compile_opts` field. A chart `to_binary/1` is not implementable
  against today's struct at all - this is the load-bearing gap, and it is why
  Phase 1 exists.
- `Statifier.Machine.Identity.of_source/2`
  (`lib/statifier/machine/identity.ex:55-62`) hashes the source bytes and
  carries `opts[:chart_name]` / `opts[:chart_version]`. It reads no other key.
  **`:invoke_content_markup` is therefore invisible to the identity**, while
  it does change what compiles (ADR-0042: it relaxes
  `Validator.Checks.Boilerplate`'s root-namespace check). An identity check
  alone cannot detect that a load dropped it - which is exactly why
  `compile_opts` has to be persisted rather than inferred.
- The three options `compile/2` recognizes today are `:invoke_content_markup`
  (ADR-0042), `:chart_name` and `:chart_version` (ADR-0052 decision 1), all
  documented at `lib/statifier.ex:52-86`. `Validator.Context.build/3` reads
  only `:invoke_content_markup`; every other stage ignores `opts` entirely.
- `Statifier.Position` (`lib/statifier/position.ex`) is the model to follow:
  a tagged four-tuple envelope, `@format_version` as a bare integer with a
  `format_version/0` reader, `safe_decode/1` with `:erlang.binary_to_term/2`
  `:safe` plus a per-function `@sobelow_skip ["Misc.BinToTerm"]` and the
  `Module.register_attribute(..., persist: true)` declaration that keeps
  `--warnings-as-errors` happy, and a strictly ordered check chain: decode ->
  tag -> format version -> identity.
- `Statifier.Position`'s moduledoc and ADR-0052 decision 5 argue the
  boundary-module placement for the position codec on two grounds: ADR-0003 /
  `docs/architecture.md` principle 2 keeps persistence concerns out of the core
  struct, and `machine_state.ex` already carries the whole Doctor moduledoc
  burden for the core struct.
- `docs/persistence.md`'s "What a host must persist" section currently tells a
  host it must persist three things and that the `%Machine{}` is explicitly not
  one of them. That section is the doc most directly changed by this work.
- `Statifier.Session.Recording` embeds a whole `%Machine{}`
  (`lib/statifier/session/recording.ex:92-93`), so Phase 1's new fields ride
  along inside every recording. ADR-0052 decision 8 keeps `Recording` itself
  out of scope (st-hz2a).
- No module named `Statifier.Chart` exists today; no test asserts the exact key
  set of `%Machine{}`, so adding defaulted fields is additive.

## Desired End State

`Statifier.Chart.to_binary/1` takes a `%Machine{}` that came from
`Statifier.compile/2` and returns a tagged, versioned binary carrying the
chart's identity, its SCXML source, and the closed set of compile options that
affect compilation. `Statifier.Chart.from_binary/1` decodes it, checks the
tag, checks the format version, recompiles the source through
`Statifier.compile/2` with the stored opts, and compares the recompiled
`Machine`'s identity against the blob's, returning
`{:ok, machine}` only when they match. No `%Predicator.Compiled{}` term - and
no compiled term of any kind - is ever written to the blob.

Verified by: a round trip whose decoded `%Machine{}` is `==` the original; a
blob whose bytes contain no compiled-instruction term; loud errors on hash
mismatch, unsupported format version, foreign blob, and a source that no
longer compiles; ADR-0052 amended in place; `docs/persistence.md` updated so a
host reads that it *can* now persist a chart and what that costs.

### Key Discoveries:

- `lib/statifier.ex:88-97` - `compile/2` is the single seam holding source,
  opts and Machine simultaneously; it already stamps two fields onto the
  returned Machine, so stamping two more is the established shape, not a new
  one.
- `lib/statifier/machine/identity.ex:55-62` - identity ignores
  `:invoke_content_markup`, so identity verification cannot substitute for
  round-tripping the opts.
- `lib/statifier/position.ex:96-140` - the envelope, the ordered check chain,
  and the loud-error arms this plan copies rather than reinventing.
- `lib/statifier/position.ex:1-25` and ADR-0052 decision 5 - the argument for a
  boundary module rather than a method on the core struct.
- ADR-0052 decision 3 - the decision this plan supersedes in part, and
  ADR-0014 item 2 - the premise decision 3 protects, which this shape keeps
  literally true.
- `docs/adr/0012-debuggability-designed-into-the-core.md:53-99` - this
  project's in-place ADR amendment convention: a `**Amendment (<bead>):**`
  block appended below the decision, the original sentence left standing
  unedited, and the Status line gaining an `- amended <date> (<bead>: ...)`
  clause.

## Decisions this plan settles

The bead names three judgment calls as costs to weigh. They are settled here so
no implementer has to re-open them.

### 1. The persisted `compile_opts` set is closed (an explicit allowlist)

`Statifier.Chart` persists exactly `[:invoke_content_markup, :chart_name,
:chart_version]`, filtered out of `compile/2`'s opts at compile time and stored
in that fixed key order. Three reasons, in decreasing order of force:

- **Decode safety.** `from_binary/1` decodes with `:safe`, which refuses to
  create atoms the blob names. An open set would let an embedder's own
  unrecognized option key (`my_app_tracing: true`) into the blob; on a load in
  a process where that atom does not yet exist, the decode raises and collapses
  into `{:error, :not_a_statifier_blob}` - a badly misleading error for a blob
  this library itself wrote. A closed allowlist of atoms this library defines
  makes the decode total for every blob `to_binary/1` can produce.
- **Only these keys can change what compiles.** `:invoke_content_markup`
  changes validation (ADR-0042); `:chart_name` / `:chart_version` change the
  identity the loader must reproduce. Every other key is ignored by every
  stage, so persisting it would store a fact nothing reads.
- **Adding a fourth recognized option becomes a deliberate act.** A new
  `compile/2` option that changes compilation and is *not* added to this list
  would break the round trip silently. A closed list turns that into a visible
  edit in one place, with a format-version decision attached to it. The list
  therefore ships with a comment saying so, and the moduledoc names the
  invariant: **every option `compile/2` recognizes is either in this list or
  provably inert.**

An open set was rejected on the decode-safety ground alone; "future-proof"
would here mean "persists terms nothing reads and may not decode".

### 2. The pair lives on `Statifier.Chart`, a boundary module - not on `Machine`

Position's moduledoc gives two reasons for a boundary module. Both transfer,
and a third applies only here:

- **Layering.** `from_binary/1` must call `Statifier.compile/2`. `Statifier`
  already aliases `Statifier.Machine`; putting `from_binary/1` on `Machine`
  would make the compiled-input struct depend on the public pipeline facade
  that produces it. That inversion is decisive on its own and has no analogue
  in the Position case.
- **ADR-0003 / architecture principle 2.** Encode/decode-with-verification is a
  concern of moving a chart across a process or machine boundary, not of being
  a compiled interpreter input. Neither function performs I/O, so ADR-0003 does
  not constrain the module's own contents - it constrains where the module
  sits relative to the core, exactly as ADR-0052 decision 5 puts it.
- **Doctor burden.** `machine.ex`'s moduledoc is already the longest in the
  tree and documents the compiled layout; a serialization contract in it would
  mix two subjects under one 100%-coverage obligation.

The module is named `Statifier.Chart` for symmetry with `Statifier.Position`:
the two boundary codecs are "a chart" and "a position", the same two nouns
`docs/persistence.md` already uses. The bead's acceptance criteria name
`Machine.to_binary/1`; this is the same substitution ADR-0052 decision 5 and
Position's moduledoc already made for `MachineState.to_binary/1` - the
substance asked for is delivered exactly, only the module the pair lives on
differs. Phase 3 records that in the ADR so the mismatch between bead wording
and shipped module is on the record rather than a surprise.

### 3. ADR-0052 is amended in place, per this project's convention

Phase 3 appends an `**Amendment (st-i7y7):**` block under the Decision section
and extends the Status line, leaving decisions 3 and 5 standing unedited -
the convention ADR-0012's three amendments demonstrate and ADR-0001 requires
("amended by a new ADR that supersedes it, not by rewriting history" applies to
the *decision*, not to the presentational block; this repo's practice, in
ADR-0012, ADR-0014 and ADR-0008, is an in-place amendment note that explains
rather than rewrites).

The amendment's substance: decision 3's literal rule - **a `%Machine{}` is
never serialized** - still stands, because this shape serializes no compiled
term either. What is superseded is decision 3's *implicit corollary*, that the
library therefore ships no chart-level binary contract at all and leaves
"persist the source and recompile" to every host. `Statifier.Chart` mechanizes
that advice inside the library. ADR-0014 item 2's premise ("we store no
instruction lists") is untouched and needs no amendment of its own, and
decision 5's boundary-module rule is extended, not contradicted.

## What We're NOT Doing

- **Not serializing a compiled `%Machine{}`, or any `%Predicator.Compiled{}`
  term.** That option was considered and rejected in the bead; ADR-0014 item 2
  stays untouched, and no predicator ISA check is needed on load because the
  loaded build always compiles the instructions it then evaluates.
- **Not touching `Statifier.Session.Recording`.** ADR-0052 decision 8 already
  filed the embedded-`Machine` and `:invoke_handlers` questions as st-hz2a.
  Recordings will simply carry the new `Machine` fields along, which is a size
  change and not a contract change.
- **Not adding an opt-out for source retention.** Every `Machine` from
  `compile/2` will hold its source binary for its lifetime. The retained bytes
  are the same bytes the caller just handed in, refcounted, and the Consequence
  is recorded in the ADR amendment rather than pre-emptively engineered around.
  A host that measures this as a real cost reopens it with a measurement.
- **Not adding a `Statifier.Chart` convenience that starts a session or
  initializes a position.** `from_binary/1` returns a `%Machine{}` and stops;
  composing it with `Position.from_binary/2` is the host's call, and
  `docs/persistence.md` shows the two-line composition rather than wrapping it.
- **Not canonicalizing SCXML source before hashing.** ADR-0052's accepted
  whitespace-sensitivity cost is unchanged by this plan.
- **Not changing `Statifier.Position` at all.** Its blob shape, its format
  version, and its error arms stay exactly as shipped; this plan only adds a
  sibling.

## Implementation Approach

Three phases, split at the seams that make each one independently
gate-verifiable:

1. Make a `%Machine{}` able to reproduce itself - retain `source` and the
   allowlisted `compile_opts` at the one seam that has both. Verifiable on its
   own by asserting `Statifier.compile/2` stamps them and filters correctly.
2. Add the `Statifier.Chart` codec on top of those fields. Verifiable on its
   own by round trip and by each error arm.
3. Record it - ADR-0052 amendment, `docs/persistence.md`, changelog fragment.
   No Elixir changes, so it commits on diff review, and it is the phase the
   `merge`-profile ADR judge reads.

Phases 1 and 2 cannot be merged into one smaller unit and cannot be split
further: Phase 1's fields are consumed only by Phase 2, but Phase 1 stands
alone because `compile/2`'s stamping is directly observable and directly
tested. Phase 3 depends on both but changes no code.

### The Appendix D rule

No Appendix D procedure is touched by any phase. `Statifier.compile/2` is the
pipeline facade, `%Machine{}` is compiler output, and `Statifier.Chart` is a
codec - none of them ports pseudocode, so this plan introduces no deviation to
justify (ADR-0002). Each phase's Manual Verification says so explicitly rather
than leaving the implementer to conclude it.

---

## Phase 1: A Machine retains its compilation inputs

### Overview

Add `source` and `compile_opts` to `%Machine{}`, stamped by `Statifier.compile/2`
alongside the `identity` it already stamps, with `compile_opts` filtered
through the closed allowlist decided above. Nothing consumes them yet; this
phase is what makes Phase 2 possible.

### Changes Required:

#### 1. The Machine struct

**File**: `lib/statifier/machine.ex`
**Changes**: two new defstruct fields with defaults (neither in
`@enforce_keys`, the same reasoning the moduledoc already gives for
`global_scripts`, `warnings` and `identity`: a Machine without them is exactly
as valid as one with them), two new `t()` members, two readers, and a moduledoc
section.

```elixir
defstruct [
  # ... existing keys unchanged ...
  :identity,
  :source,
  global_scripts: [],
  warnings: [],
  compile_opts: []
]

@type t :: %__MODULE__{
        # ... existing members unchanged ...
        identity: Identity.t() | nil,
        source: binary() | nil,
        compile_opts: keyword()
      }

@doc """
The SCXML source `Statifier.compile/2` compiled this Machine from, or `nil`
for a Machine built without going through that boundary.
"""
@spec source(machine :: t()) :: binary() | nil
def source(%__MODULE__{source: source}), do: source

@doc """
The persisted subset of the options `Statifier.compile/2` was called with ...
"""
@spec compile_opts(machine :: t()) :: keyword()
def compile_opts(%__MODULE__{compile_opts: compile_opts}), do: compile_opts
```

A moduledoc section, sibling to the existing "`identity`: the chart revision"
section, states the invariant Phase 2 depends on: `source`, `compile_opts` and
`identity` are stamped together by `compile/2` and only by `compile/2`, so
`source: nil` and `identity: nil` always co-occur; and that `compile_opts` is a
filtered subset, never the caller's whole keyword list.

#### 2. The stamping seam and the allowlist

**File**: `lib/statifier.ex`
**Changes**: `compile/2`'s success arm stamps the two new fields; a
module-level allowlist plus a private filter; `compile/2`'s `@doc` gains a
paragraph on retention.

```elixir
# The closed set of `compile/2` options persisted onto the Machine and, from
# there, into a `Statifier.Chart` blob. Closed rather than open: `:safe`
# decoding refuses to create atoms a blob names, so an embedder's own
# unrecognized option key could make a blob this library wrote undecodable.
# Every option this function recognizes is either listed here or provably
# inert for compilation - adding a fourth recognized option means deciding
# which it is. See ADR-0052's st-i7y7 amendment.
@persisted_compile_opts [:invoke_content_markup, :chart_name, :chart_version]

{:ok,
 %Machine{
   machine
   | warnings: warnings,
     identity: Identity.of_source(source, opts),
     source: source,
     compile_opts: persisted_opts(opts)
 }}

@spec persisted_opts(opts :: keyword()) :: keyword()
defp persisted_opts(opts),
  do: for(key <- @persisted_compile_opts, Keyword.has_key?(opts, key), do: {key, opts[key]})
```

The comprehension over `@persisted_compile_opts` (rather than
`Keyword.take/2`) fixes the key order to the allowlist's order regardless of
the caller's, so two callers passing the same options in different orders
produce `==` Machines and byte-identical blobs. Absent keys stay absent rather
than becoming explicit `nil`s, so a default-only compile stores `[]`.

#### 3. Tests

**File**: `test/statifier/machine_test.exs` (readers) and
`test/statifier_test.exs` (stamping and filtering)
**Changes**: `compile/2` stamps the exact source bytes; it stores only
allowlisted keys and drops an unrecognized one; key order is the allowlist's,
not the caller's; a default-opts compile stores `[]`; a Machine from
`Compiler.compile/1` directly carries `source: nil` and `compile_opts: []`;
the readers return those fields. Each test carries a sabotage line per
`docs/testing.md` (e.g. `# sabotage: persisted_opts/1 replaced with the raw
opts -> the unrecognized-key test reddens`).

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating (not the phase gate).
- [x] Full `mix quality` green, including dialyzer against the widened `t()`
      and Doctor's 100% moduledoc/doc thresholds for the two new readers.
- [x] `mix gate.verify` confirms the green run was a full, unscoped gate.
- [x] The new tests fail when the allowlist filter is replaced by the raw opts
      list (the sabotage each test records).

#### Manual Verification:
- [ ] No Appendix D procedure is touched by this phase; `compile/2` is the
      pipeline facade and `%Machine{}` is compiler output, so ADR-0002's
      deviation rule has nothing to bind here.
- [ ] The moduledoc's stated invariant (source, compile_opts and identity are
      stamped together, only by `compile/2`) is true of every site that builds
      a `%Machine{}` - checked by reading, not only by test.
- [ ] Nothing else in `lib/` reads `opts` in a way the allowlist now misses.
- [ ] In `iex -S mix`: build a `Statifier.Session.Recording` over a compiled
      chart, `:erlang.term_to_binary/1` it and decode it back, and confirm the
      embedded Machine's new `source` and `compile_opts` survive unchanged -
      the one place Phase 1's fields cross a serialization boundary that this
      phase adds no test of its own for (ADR-0052 decision 8 keeps `Recording`
      out of scope, so this is a read-and-confirm, not a change).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: `Statifier.Chart`, the source-carrying codec

### Overview

The new boundary module: `format_version/0`, `to_binary/1`, `from_binary/1`,
modeled line for line on `Statifier.Position`'s envelope, check ordering, and
error arms.

### Changes Required:

#### 1. The codec

**File**: `lib/statifier/chart.ex` (new)
**Changes**:

```elixir
defmodule Statifier.Chart do
  @moduledoc """
  The versioned binary contract for a *chart* - a `Statifier.Machine.t()`
  reduced to the inputs that reproduce it: its SCXML source, the persisted
  subset of the options it was compiled with, and its
  `Statifier.Machine.Identity.t()`. No compiled term is written...
  """

  alias Statifier.Machine
  alias Statifier.Machine.Identity

  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @format_version 1

  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @spec to_binary(machine :: Machine.t()) :: {:ok, binary()} | {:error, :unidentified_chart}
  def to_binary(%Machine{identity: nil}), do: {:error, :unidentified_chart}
  def to_binary(%Machine{source: nil}), do: {:error, :unidentified_chart}

  def to_binary(%Machine{identity: identity, source: source, compile_opts: opts}) do
    {:ok,
     :erlang.term_to_binary({:statifier_chart, @format_version, identity, source, opts})}
  end

  @spec from_binary(blob :: binary()) ::
          {:ok, Machine.t()}
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
          | {:error, {:compile_failed, [Statifier.error()]}}
          | {:error, {:identity_mismatch, Identity.t(), Identity.t() | nil}}
  def from_binary(blob) when is_binary(blob) do
    case safe_decode(blob) do
      {:ok, {:statifier_chart, version, identity, source, opts}}
      when is_binary(source) and is_list(opts) ->
        with :ok <- check_version(version),
             {:ok, machine} <- recompile(source, opts) do
          check_identity(identity, machine)
        end

      _other ->
        {:error, :not_a_statifier_blob}
    end
  end
end
```

Points the implementer must not vary:

- **Check order is decode -> tag -> format version -> recompile -> identity**,
  which is Position's order with the recompile inserted at the only place it
  can go: the identity to compare against is the one the recompile produces.
  Version before identity for Position's own reason - a future format whose
  identity representation changed should report the version mismatch, not a
  confusing identity one.
- `{:error, {:compile_failed, errors}}` carries `Statifier.compile/2`'s own
  `[error()]` list unchanged. A blob whose source no longer compiles under this
  build (a validator check tightened across a library upgrade) is a real,
  distinct failure and must not be flattened into `:not_a_statifier_blob`.
- `{:error, {:identity_mismatch, expected, actual}}` uses Position's argument
  order: `expected` is the blob's identity, `actual` the recompiled Machine's.
  Compared with `Identity.matches?/2`, never `==/2` on the struct (ADR-0052
  decision 1).
- `safe_decode/1` is copied verbatim from `Statifier.Position`, including the
  `@sobelow_skip ["Misc.BinToTerm"]` annotation, the `rescue ArgumentError ->
  :error` arm, and the comment explaining both. The `Module.register_attribute`
  line is required for `--warnings-as-errors`.
- The `is_binary(source) and is_list(opts)` guard on the decoded tuple is this
  module's counterpart to Position's `is_map(payload)`: a well-formed envelope
  with a payload of the wrong shape is `:not_a_statifier_blob`, not an
  exception from `compile/2`.

#### 2. Tests

**File**: `test/statifier/chart_test.exs` (new)
**Changes**: fixtures modeled on `test/statifier/position_test.exs` - a base
chart, and a one-state-added variant as the identity-mismatch fixture (a real
structural edit, not a whitespace one). Cases:

- Round trip: `from_binary(to_binary(machine))` returns a Machine `==` the
  original, asserted as whole-struct equality rather than field by field, since
  every field is a plain term.
- `:invoke_content_markup` round-trips: a source that compiles only under it
  (an `<invoke><content>` slice with no root namespace, per ADR-0042) survives
  the round trip, and a hand-built blob with that option stripped returns
  `{:error, {:compile_failed, _}}`. This is the case an identity check alone
  cannot catch, and it is the reason the opts are persisted at all.
- `:chart_name` / `:chart_version` round-trip and reach the reloaded identity.
- No compiled term in the blob: assert the blob's bytes contain no
  `Predicator.Compiled` module tag - `:binary.match(blob, "Predicator.Compiled")
  == :nomatch` - and, positively, that the decoded envelope is a five-tuple
  whose payload is a binary and a keyword list. Together these are the
  mechanical form of "no `%Predicator.Compiled{}` term is written".
- Every error arm: `:unidentified_chart` for a `Compiler.compile/1`-built
  Machine; `{:unsupported_format_version, 99}` for a hand-built envelope;
  `:not_a_statifier_blob` for a foreign `term_to_binary` term, for garbage
  bytes, and for a well-formed envelope whose source slot is not a binary;
  `{:compile_failed, _}` for a blob carrying source that does not compile;
  `{:identity_mismatch, expected, actual}` for a blob whose stored identity was
  swapped for the one-state-added chart's.
- A blob is smaller than `term_to_binary(machine)` for the same chart, asserted
  as an inequality (not a fixed byte count), which is the honest form of the
  size claim `docs/persistence.md` will make.

Every test carries a sabotage line. Two the implementer should expect to write:
`# sabotage: from_binary/1's check_identity/2 arm returns :ok unconditionally
-> the identity-mismatch test reddens`, and `# sabotage: check_version/1
accepts any integer -> the unsupported-format-version test reddens`.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green while iterating (not the phase gate).
- [ ] Full `mix quality` green, including Sobelow (the `@sobelow_skip` is
      per-function and named, so the rest of the module stays scanned), Credo,
      dialyzer against the new `@spec`s, and Doctor's thresholds for the new
      module.
- [ ] `mix gate.verify` confirms the green run was a full, unscoped gate.
- [ ] The no-compiled-term assertion passes: the blob's bytes contain no
      `Predicator.Compiled` tag.
- [ ] Each error-arm test reddens under the sabotage its comment names.

#### Manual Verification:
- [ ] No Appendix D procedure is touched by this phase; `Statifier.Chart` is a
      codec and ports no pseudocode, so ADR-0002 introduces no deviation to
      justify here.
- [ ] The check chain reads in the ADR-0052 order (tag, version, recompile,
      identity) and each arm's error term is the one `docs/persistence.md` will
      tell a host to expect.
- [ ] `Statifier.Position`'s behavior is unchanged - its blob shape, format
      version, and errors are untouched by this phase's diff.
- [ ] The moduledoc argues the boundary-module placement in its own words
      (layering, ADR-0003, Doctor burden) rather than only pointing at
      `Statifier.Position`.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: Record it - ADR-0052 amendment, persistence doc, changelog

### Overview

The written half of the bead's acceptance criteria. No Elixir changes, so this
phase commits on review of the diff; it is also the phase the merge-profile ADR
judge reads.

### Changes Required:

#### 1. ADR-0052 amended in place

**File**: `docs/adr/0052-chart-identity-and-position-serialization.md`
**Changes**: the Status line gains `- amended 2026-08-19 (st-i7y7: decision 3's
corollary superseded; a chart blob carries source and compile opts, still no
compiled term)`. An `**Amendment (st-i7y7):**` block goes under the Decision
section, below decision 8, leaving decisions 3 and 5 standing unedited. It
records, in this order:

- What still stands: no compiled term of any kind is serialized, so decision
  3's literal rule and ADR-0014 item 2's premise are both untouched and neither
  needs its own amendment.
- What is superseded: decision 3's implicit corollary that the library
  therefore ships no chart-level binary contract and leaves "persist the source
  and recompile" to every host. `Statifier.Chart` mechanizes that advice.
- Why not encoding the compiled Machine: predicator's `compiled.ex:32-38`
  hazard is a *re-pairing* hazard (instructions and span table stored
  separately and re-paired wrong), which a whole-struct round trip cannot
  trigger - recorded here so the next reader does not re-derive it - and
  recompiling sidesteps predicator ISA skew entirely, since the loaded build
  always evaluates instructions it compiled itself.
- The closed allowlist and its decode-safety reason, naming the three keys and
  the obligation a fourth recognized `compile/2` option incurs.
- The placement: decision 5's boundary-module rule extended to the chart codec,
  with the layering argument (`from_binary/1` calls `Statifier.compile/2`) that
  applies here and not to Position, and the note that the bead said
  `Machine.to_binary/1` while the shipped pair is `Statifier.Chart.to_binary/1`
  - the same substitution decision 5 already made for `MachineState`.
- Consequences: compile time on load, in exchange for never needing an ISA
  check or a compiled-format compatibility story; and every `Machine` now
  retaining its source binary for its lifetime, which also enlarges every
  `Session.Recording` (still out of scope per decision 8 / st-hz2a).
- What would reopen it: recompilation cost on load becoming a measured
  operational problem for some host, which is the case for storing a compiled
  form and therefore for the ISA and format-compatibility story this shape
  avoids.

#### 2. The persistence guide

**File**: `docs/persistence.md`
**Changes**:

- "What a host must persist" is rewritten around the new option. Its current
  three-item list stands for a host that manages its own source; a new
  paragraph says a host that cannot retain its own SCXML source can persist a
  single `Statifier.Chart.to_binary/1` blob instead, and shows the two-line
  composition of `Chart.from_binary/1` with `Position.from_binary/2`.
- Its "Explicitly **not** the `%Statifier.Machine{}` struct" paragraph is
  corrected rather than deleted: what is still never persisted is the
  *compiled* chart, and the chart blob's source-carrying shape is why that
  remains true. It cites the ADR-0052 amendment beside the existing decision-3
  link.
- A short "What it costs" list: recompilation on every load; a source that must
  still compile under the loading build (`{:error, {:compile_failed, _}}` is
  the arm that says it does not); and the closed compile-opts set, so an
  embedder passing an option outside it must recompile with that option itself
  rather than expect the blob to carry it.
- The blob-size sentence stays honest: the chart blob is roughly the size of
  the SCXML source, not of the compiled `Machine`, stated as a relation rather
  than a measured byte count.

#### 3. Changelog fragment

**File**: `changelog.d/st-i7y7.md` (new)
**Changes**: an `### Added` section - the `Statifier.Chart` pair, and
`Statifier.Machine.source/1` / `compile_opts/1`. A capability v1 never had, so
it qualifies under `changelog.d/README.md`'s narrower v2 rule. One line per
change, present tense, no nested bullets.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` green (no Elixir changed, so this is a no-regression
      check on the docs-only diff).
- [ ] `mix quality --profile merge` green, which is the profile that actually
      runs the ADR judge stage (`.quality.exs:23` disables it in the bare gate
      by design; `.claude/wurk/mr.md` runs the merge profile before every
      push).
- [ ] `mix gate.check` passes: no guarded gate file is touched by this branch,
      so no `docs/quality-gate-changes.md` ledger entry is owed.
- [ ] `changelog.d/st-i7y7.md` exists and uses only standard Keep a Changelog
      headings.

#### Manual Verification:
- [ ] The amendment explains rather than rewrites: decisions 3 and 5 are
      byte-identical to their pre-amendment text, and the Status line names the
      bead and the date.
- [ ] A host author reading `docs/persistence.md` end to end can tell which of
      the two persistence shapes applies to them and what each costs, without
      opening the ADR.
- [ ] No `lib/` or `test/` file is modified by this phase's diff.

**Implementation Note**: This phase changes no Elixir code, so per this repo's
`CLAUDE.md` authority table it may commit on review of the diff alone; the full
gate is still run to confirm no regression. In interactive execution, pause here
for the human to confirm the manual testing. In looped (`--loop`) execution,
this phase's Automated Verification gates advancement automatically, and Manual
Verification items are deferred to the end.

---

## Testing Strategy

### Unit Tests:

- `test/statifier_test.exs` - `compile/2` stamps `source` and the filtered
  `compile_opts`; an unrecognized option is dropped; caller key order does not
  affect the stored order; default opts store `[]`.
- `test/statifier/machine_test.exs` - `source/1` and `compile_opts/1` readers,
  including the `nil` / `[]` case for a `Compiler.compile/1`-built Machine.
- `test/statifier/chart_test.exs` - the round trip (whole-struct equality), the
  `:invoke_content_markup` case that identity alone cannot catch, the
  no-compiled-term byte assertion, the size relation, and every error arm:
  `:unidentified_chart`, `{:unsupported_format_version, _}`,
  `:not_a_statifier_blob` (foreign blob, garbage, wrong payload shape),
  `{:compile_failed, _}`, `{:identity_mismatch, _, _}`.
- Every one of the above carries a sabotage line naming the mutation that
  reddens it (`docs/testing.md`). No harness plumbing is added, so no
  `# sabotage: n/a` exemptions are expected.

### Manual Testing Steps:

1. In `iex -S mix`: compile a chart with `chart_name: "demo", chart_version:
   "1"`, `Statifier.Chart.to_binary/1` it, `from_binary/1` it back, and confirm
   the reloaded Machine is `==` the original and that its identity carries the
   name and version.
2. Initialize a position on the original Machine, `Position.to_binary/1` it,
   then reload *both* blobs in a fresh session and confirm
   `Position.from_binary/2` accepts the position against the
   `Chart.from_binary/1` Machine - the composition `docs/persistence.md`
   documents.
3. Edit the SCXML source by one state, recompile, and confirm the old chart
   blob still loads to the old chart (it carries its own source) while a
   position saved against the new chart is refused against it.
4. Hand-edit a decoded envelope to drop `invoke_content_markup: true` from a
   chart that needs it, re-encode, and confirm the load fails with
   `{:error, {:compile_failed, _}}` rather than succeeding with a differently
   compiled chart.

## Performance Considerations

- `from_binary/1` pays a full parse/lower/validate/compile pass on every load.
  That is the deliberate trade named in the bead and recorded in the ADR
  amendment: it buys freedom from a compiled-format compatibility story and
  from predicator ISA skew. A host loading the same chart repeatedly should
  cache the resulting `%Machine{}` itself; the library adds no cache, and
  `docs/persistence.md` says so rather than implying a cheap load.
- Every `%Machine{}` now retains its source binary. For large sources this is
  the source's own bytes, refcounted from the binary the caller already held,
  and it rides along inside every `Session.Recording`. Recorded as a
  Consequence, not engineered around (see "What We're NOT Doing").

## References

- Bead: `st-i7y7` (its description carries the design research this plan does
  not repeat).
- Related ADRs: `docs/adr/0052-chart-identity-and-position-serialization.md`
  (decisions 1, 3, 5 and 8; amended by Phase 3),
  `docs/adr/0014-expression-spans-in-cond-diagnostics.md` (item 2's premise,
  kept true), `docs/adr/0042-invoke-content-compiles-under-the-relaxed-namespace-rule.md`
  (why `:invoke_content_markup` must round-trip),
  `docs/adr/0005-full-configuration-and-interned-state-indexes.md` (the hazard
  identity exists to detect), `docs/adr/0003-*` /
  `docs/architecture.md` principle 2 (the boundary-module placement),
  `docs/adr/0002-literal-w3c-appendix-d-port.md` (no procedure touched here).
- Similar implementation: `lib/statifier/position.ex:96-140` (envelope, check
  ordering, error arms, `safe_decode/1`),
  `lib/statifier/machine/identity.ex:75-115` (the same envelope at its
  simplest), `test/statifier/position_test.exs` (fixture and sabotage style).
- Docs: `docs/persistence.md`, `docs/testing.md`, `changelog.d/README.md`.
- Prior plan: `docs/plans/260818-st-m5c3-machine-identity-and-position-serialization.md`.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] No Appendix D procedure is touched by this phase; `compile/2` is the
      pipeline facade and `%Machine{}` is compiler output, so ADR-0002's
      deviation rule has nothing to bind here.
- [ ] The moduledoc's stated invariant (source, compile_opts and identity are
      stamped together, only by `compile/2`) is true of every site that builds
      a `%Machine{}` - checked by reading, not only by test.
- [ ] Nothing else in `lib/` reads `opts` in a way the allowlist now misses.
- [ ] In `iex -S mix`: build a `Statifier.Session.Recording` over a compiled
      chart, `:erlang.term_to_binary/1` it and decode it back, and confirm the
      embedded Machine's new `source` and `compile_opts` survive unchanged -
      the one place Phase 1's fields cross a serialization boundary that this
      phase adds no test of its own for (ADR-0052 decision 8 keeps `Recording`
      out of scope, so this is a read-and-confirm, not a change).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---
