# Machine Identity and Position Serialization Implementation Plan

## Overview

A persisted `%Statifier.MachineState{}` is keyed by interned integer state
indexes (ADR-0005). Nothing today correlates such a position to the chart
revision that produced it, so recompiling a chart with a state added or
reordered silently resumes the wrong states rather than failing. This plan
gives `%Statifier.Machine{}` a content-hash identity taken over the SCXML
source, adds a versioned binary contract for a *position* that refuses to load
against a chart whose identity does not match, adds a string-id export/import
so a host can migrate a position across chart revisions on purpose, and records
the hazard, the two migration stories, and the decision itself.

Bead: st-m5c3. Source research:
`docs/research/260818-st-m5c3-machine-identity-and-serialization.md`.

## Current State Analysis

The research document is the ground truth; this section states only what the
plan turns on.

- `%Machine{}` (`lib/statifier/machine.ex:110-158`) carries no identity, no
  hash, and no version. It has `name` (the non-unique `<scxml name>`
  attribute) and drops the SCXML `version` attribute at
  `lib/statifier/compiler.ex:303`.
- `Statifier.compile/2` (`lib/statifier.ex:76-86`) is the **only** place in
  the library holding both the source binary and the finished `%Machine{}`.
  `Compiler.compile/1` never receives the source, and nothing past
  `Validator.validate/3` retains the document text.
- `%MachineState{}` (`lib/statifier/machine_state.ex:337-360`) embeds the whole
  `%Machine{}`. Measured on this branch: 5848 bytes encoded with the machine,
  725 bytes without it - roughly 88% of a small position's bytes are the chart.
- Every field of both structs is a plain term; the no-pid/ref/port/fun property
  is asserted and tested (`lib/statifier/session.ex:630`,
  `test/statifier/session/recording_test.exs:224-248`), and
  `Statifier.Interpreter`'s moduledoc already promises a `term_to_binary`
  round trip (`lib/statifier/interpreter.ex:38-40`).
- Both index/id directions already exist: `Machine.index/2` and `Machine.id/2`
  (`lib/statifier/machine.ex:337-347`). `id/2` returns `nil` for the root and
  for every nameless state.
- There is no format version anywhere in `lib/`, and nothing reads
  `Application.spec(:statifier, :vsn)`. The prior art for an
  integer-format-version-plus-upgrade is upstream: `Predicator.isa_version/0`
  (`deps/predicator/lib/predicator.ex:677-692`).
- `Mix.Statifier.AdrGuard` bans ad-hoc `:crypto.strong_rand_bytes/1` outside
  `machine_state.ex` (`lib/mix/statifier/adr_guard.ex:119-123`). It does **not**
  ban `:crypto.hash/2`, which is what this plan uses.
- `.doctor.exs` holds 100% on every axis with `struct_type_spec_required: true`,
  so every new module needs a `@moduledoc`, every new public function a `@doc`
  and a `@spec`, and every new struct a `@type t`.

### The five open questions the research left, resolved

Each of these is a decision this plan makes, with its reasoning, so the
implementer does not re-derive it.

**1. The bead's "ADR-0006 public-surface rule" is a mis-citation of ADR-0005.**
ADR-0006 is the conformance corpus and regression ratchet; its surface-shaped
content is a *driving-surface* list closing what `Statifier.Case` may couple to
(`docs/adr/0006-...`, 2026-08-17 amendment: nine functions plus
`MachineState.active_leaf_states/1` by declaration). The rule the bead
describes - "string IDs appear only at the API boundary (parsing in,
event/introspection out)" - is ADR-0005's fourth Consequence
(`docs/adr/0005-full-configuration-and-interned-state-indexes.md:25-28`). The
plan cites ADR-0005 for the string-id export and never cites ADR-0006 for it.

**ADR-0006 is not reopened by this work.** Its closed list constrains what the
generated corpus tests drive the library *through*, not what the library may
export: "the corpus still cannot widen the library surface". Nothing in this
plan is called from `test/support/case.ex` or from any generated corpus file,
so no function joins a driving-surface list and no amendment is owed. Phase 4
carries a grep that proves it.

**2. The content hash is taken over the raw SCXML source bytes handed to
`Statifier.compile/2`.** Rejected alternatives and why:

- *A term hash over the finished `%Machine{}`* is strictly worse than the
  source hash on the axis the bead cares about, and worse on a second axis.
  It is equally whitespace-sensitive (the Machine tree is dominated by
  `Parser.Location` spans, whose byte offsets move on any edit before them),
  and it additionally moves when a *library upgrade* adds a field to any struct
  in the Machine tree - conflating "the chart changed" with "the engine
  changed", which is exactly what a separate format version exists to keep
  apart. It is also a cached derived fact of the kind ADR-0030's third ground
  names as a hazard, since it is recomputable from the value it is stored on.
- *Embedder-supplied name/version alone* provides no safety: a host that
  forgets to bump gets the silent wrong-state resumption the bead exists to
  prevent. It is kept, but as an optional addition, exactly as the bead words
  it.

Against the failure mode the bead names - a recompile that reorders or adds
states - the source hash has **no false negatives**: reordering or adding a
state necessarily changes the source bytes. It is conservative in the other
direction (a comment or whitespace edit changes the identity even though every
index survives), which fails *loudly* toward a drain, and the string-id
export/import of Phase 3 is precisely the sanctioned escape hatch for a host
that knows an edit was benign. The hash is a fact the Machine does not
otherwise hold - the source is not retained anywhere - so ADR-0030's three-part
test (plain value, single write site, no duplication) passes on all three.

**3. `%Machine{}` gets no `to_binary/1`, and this is a deliberate narrowing of
the bead's acceptance criteria. Read this paragraph before implementing.**
Serializing a `%Machine{}` persists `%Predicator.Compiled{}` structs whose
`positions` / `segment_positions` tables predicator's own moduledoc says must
not be stored: it "is **not** a wire format", nothing checks a span table came
from the instruction list it is attached to, and the failure mode is "a
confidently wrong position, which is worse than the honest `position: nil`"
(`deps/predicator/lib/predicator/compiled.ex:10-38`). ADR-0014 item 2 declares
that hazard inapplicable to this repo on the explicit premise that "we compile
conds in-process at Machine-build time and store no instruction lists"
(`docs/adr/0014-expression-spans-in-cond-diagnostics.md:78-83`). Shipping
`Machine.to_binary/1` would falsify that premise and reopen ADR-0014.

The substitute is the one predicator itself prescribes: a host persists the
**source**, because "recompiling the same source is deterministic and yields an
identical table every time". This bead's own content hash is what makes that
substitute safe - it proves the recompile produced the same chart. So the plan
ships `Statifier.Machine.Identity.to_binary/1` / `from_binary/1` (a small
versioned blob a host stores beside its source) instead of a whole-Machine
codec, and ADR-0052 in Phase 4 records the refusal so the next reader does not
re-litigate it. The alternative - amending ADR-0014 and shipping the Machine
codec - is recorded in Open Questions Revisited.

**4. The string-id export covers every index-keyed field a resume needs, not
just `configuration`.** `history_values`, `states_to_invoke`, `entered_states`
and `active_invocations` are all index-keyed and share the invalidation hazard;
an export that covered only the configuration would translate the visible
quarter of the position and leave the rest silently wrong, which is the same
class of bug the bead is closing. Exported and translated: `configuration`
(the full configuration, not the leaf view - full is what is stored and what a
resume needs), `history_values`, `entered_states`, `states_to_invoke`, and
`active_invocations` (its `{state_index, invoke_index}` key becomes
`{state_id, invoke_index}`; the `invoke_index` is a within-state document-order
ordinal and stays an integer, documented as stable under state reordering but
not under editing that state's own `<invoke>` children). Carried verbatim
because they are not index-keyed: `invoke_counter`, `send_counter`,
`datamodel`, `running`, `status`, `macrostep`, `microstep`, `round`, `trace`,
`max_macrostep_rounds`.

Deliberately dropped, each loudly: `internal_queue` - a position being migrated
across chart revisions must be quiescent, so a non-empty queue is an error
return rather than a silent drop; `routes` and `invoke_types` - ADR-0048 and
ADR-0051 point-in-time caller declarations that the driver re-stamps per drive
and per session start, so they are not part of a revision-portable position;
`machine` - the whole point.

**5. `Statifier.Session.Recording` stays out of scope, and Phase 4 files the
follow-up bead.** It is `@opaque`, and it embeds the whole `%Machine{}` *by
design*: `Statifier.Replay.run/1` re-drives `Recording.machine(recording)` from
inside the recording (`lib/statifier/replay.ex:186-215`), so ADR-0034 never has
one artifact to reconcile against another. Giving it an identity stamp and a
format version means either breaking `@opaque` or changing Replay's input
contract, and its `opts` carry `:invoke_handlers` module atoms whose
portability is a third question again. All three reopen ADR-0034 and belong to
their own record.

## Desired End State

- `Statifier.compile/2` stamps a `%Statifier.Machine.Identity{}` on every
  `%Machine{}` it returns, carrying a SHA-256 content hash of the exact source
  bytes plus optional embedder-supplied `:chart_name` / `:chart_version`.
- `Statifier.Position.to_binary/1` encodes a position *without* its machine,
  inside a tagged, integer-versioned envelope carrying the identity, and
  refuses a position whose machine has no identity.
- `Statifier.Position.from_binary/2` takes the blob and a `%Machine{}`, and
  returns `{:error, {:identity_mismatch, expected, actual}}` rather than a
  reattached position when the identities differ. A wrong format version and a
  non-Statifier binary are equally loud.
- `Statifier.Position.export/1` and `import/2` move a position through
  ADR-0005 boundary vocabulary (string state ids) with no identity check, so a
  host can migrate a saved position onto a new chart revision on purpose.
- `docs/persistence.md` names the interned-index invalidation hazard and
  describes both migration stories; ADR-0052 records the decisions.
- `changelog.d/st-m5c3.md` exists.

Verified by: `mix quality` green at every phase; the round-trip and
mismatch tests in Phase 2 and 3; `mix adr.check` clean; and the Phase 4 grep
showing no corpus-harness coupling.

### Key Discoveries:

- `lib/statifier.ex:76-86` - the only site holding source and Machine together;
  the single write site the identity needs to satisfy ADR-0030.
- `lib/statifier/machine.ex:337-347` - both translation directions already
  exist; `id/2` returns `nil` for the root and nameless states, which the
  export must handle rather than drop.
- `lib/statifier/machine_state.ex:309-320` - `==` is not a position test: two
  `:queue` values with the same events can differ in their front/rear split.
  Round-trip tests must compare `internal_events/1`, not the struct, on that
  field.
- `deps/predicator/lib/predicator.ex:677-692` - `isa_version/0`, the
  integer-version-checked-before-use shape this plan copies.
- ADR-0003 / `docs/architecture.md:23-29` - serialization is boundary work, not
  core work, which is why the codec is its own module rather than functions on
  `%MachineState{}`.
- ADR-0012 constraint 1 (`docs/observability.md:26-49`) - "any machine_state
  value is a complete, inspectable, resumable position". Anything a round trip
  drops breaks this silently, which is why the export drops loudly.

## What We're NOT Doing

- **No `Statifier.Machine.to_binary/1` or `from_binary/1`.** See resolution 3
  above. This narrows the bead's acceptance criteria on purpose and says so.
  A host persists its SCXML source and the small identity blob, and recompiles.
- **No resume API.** `Session.start_link/2` gains no `:machine_state` or
  `:resume` option here - that is st-5yhl, which this bead blocks.
- **No change to `Statifier.Session.Recording` or `Statifier.Replay`.** See
  resolution 5; Phase 4 files the follow-up.
- **No compression, no encryption, no storage adapter.** The blob is a binary;
  what a host does with it is st-q6xl's charter.
- **No runtime library version in the blob.** Nothing reads
  `Application.spec(:statifier, :vsn)` today, and adding it would invite the
  conflation the format version exists to prevent: the integer format version
  is the compatibility fact, and the library version is not one. Recorded in
  ADR-0052's Consequences so the omission is a decision rather than a gap.
- **No edit to `CLAUDE.md`.** `docs/persistence.md` is linked from
  `docs/architecture.md` and `docs/extending.md`. This leaves a real
  inconsistency rather than a neutral gap: every other top-level doc in `docs/`
  is named in CLAUDE.md's "read before making design decisions" list, and this
  one would not be. Adding it is a one-line human edit, and this bullet is the
  request for it. An agent does not make that edit on its own initiative.
- **No corpus or ratchet movement.** Nothing here changes SCXML semantics, so
  `test/passing_tests.json` does not move and `mix test.baseline add` is not
  run. If a phase's full gate shows a conformance change, that is a defect in
  the phase, not a ratchet entry to add.

## Implementation Approach

Four phases along the module boundary: the identity primitive and its stamp
(Phase 1), the binary codec over it (Phase 2), the string-id migration
vocabulary (Phase 3), and the records and prose (Phase 4). Each adds a
self-contained module or file plus its own tests, so each is independently
committable with a green `mix quality`.

Two shapes hold throughout:

- **Errors are returned, never raised.** Every new function returns
  `{:ok, _} | {:error, reason}` with a structured reason, per the project's
  errors-are-events convention. Nothing here is an `error.execution`: none of
  it runs inside the interpreter.
- **No Appendix D function is touched.** This plan adds no interpreter code and
  therefore states no Appendix D deviation; the plan extension's Appendix D
  rule is satisfied vacuously and the per-phase spec-conformance manual
  criterion is scoped to "no touched function is an Appendix D port".

---

## Phase 1: Chart identity on `%Machine{}`

### Overview

A `%Statifier.Machine.Identity{}` struct, a content hash over the source, an
`identity` field on `%Machine{}`, and the stamp at `Statifier.compile/2`. No
serialization yet - this phase is complete and useful on its own: a host can
already compare two identities to detect a chart revision.

### Changes Required:

#### 1. The identity struct and hash

**File**: `lib/statifier/machine/identity.ex` (new)
**Changes**: A plain struct plus three pure functions. `@moduledoc` explains
what the hash is taken over and, briefly, why not the Machine term (the full
argument lives in ADR-0052; the moduledoc cites it).

```elixir
defmodule Statifier.Machine.Identity do
  @enforce_keys [:content_hash]
  defstruct [:content_hash, :name, :version]

  @type t :: %__MODULE__{
          content_hash: String.t(),
          name: String.t() | nil,
          version: String.t() | nil
        }

  @algorithm :sha256

  @spec of_source(source :: binary(), opts :: keyword()) :: t()
  def of_source(source, opts \\ []) when is_binary(source) and is_list(opts) do
    %__MODULE__{
      content_hash: "sha256:" <> Base.encode16(:crypto.hash(@algorithm, source), case: :lower),
      name: Keyword.get(opts, :chart_name),
      version: Keyword.get(opts, :chart_version)
    }
  end

  @spec matches?(t() | nil, t() | nil) :: boolean()
  def matches?(%__MODULE__{} = a, %__MODULE__{} = b), do: a == b
  def matches?(_a, _b), do: false
end
```

`matches?/2` is total and answers `false` whenever either side is `nil`: two
unidentified charts are not the same chart, and treating `nil == nil` as a
match is the silent misread the bead forbids.

The algorithm name is inside the string (`"sha256:<hex>"`) so a future
algorithm change is visible in the stored value rather than inferred from its
length.

`of_source/2` receives `compile/2`'s whole `opts` keyword and reads only its
own two keys, so `invoke_content_markup: true` arrives here and is ignored.
That is correct, not an oversight - note it inline so nobody "fixes" it into a
filtered keyword list.

#### 2. Identity blob codec

**File**: `lib/statifier/machine/identity.ex` (same module)
**Changes**: `to_binary/1` and `from_binary/1` over a tagged, versioned
envelope, so a host can store the identity beside its retained source. This is
the answer to the bead's "to_binary/from_binary for Machine", narrowed per
resolution 3.

```elixir
@format_version 1

@spec format_version() :: pos_integer()
def format_version, do: @format_version

@spec to_binary(t()) :: binary()
def to_binary(%__MODULE__{} = identity),
  do: :erlang.term_to_binary({:statifier_chart_identity, @format_version, identity})

@spec from_binary(binary()) ::
        {:ok, t()}
        | {:error, :not_a_statifier_blob}
        | {:error, {:unsupported_format_version, term()}}
def from_binary(blob) when is_binary(blob) do
  # ADR-0052: :safe refuses to create atoms a blob names, so a hostile or
  # corrupt blob cannot grow the atom table.
  case safe_decode(blob) do
    {:ok, {:statifier_chart_identity, @format_version, %__MODULE__{} = identity}} ->
      {:ok, identity}

    {:ok, {:statifier_chart_identity, version, _payload}} ->
      {:error, {:unsupported_format_version, version}}

    _other ->
      {:error, :not_a_statifier_blob}
  end
end
```

`safe_decode/1` wraps `:erlang.binary_to_term(blob, [:safe])` and rescues
`ArgumentError` into `:error`. Phase 2 reuses it; put it in this module as a
private helper now and promote it to a shared private in Phase 2 only if
duplication is real (two call sites in two modules is acceptable duplication -
prefer a second three-line private over a new module).

#### 3. The `identity` field and accessor

**File**: `lib/statifier/machine.ex`
**Changes**: Add `:identity` to `defstruct` (default `nil`, **not** in
`@enforce_keys` - `Compiler.compile/1` builds a Machine without a source and
must keep working), add it to `@type t`, extend the existing alias group to
`alias Statifier.Machine.{Content, Data, Identity, State, Transition}`
(`lib/statifier/machine.ex:105-108`; a bare `Identity.t()` with no alias does
not compile, and `Credo.Check.Design.AliasUsage` is on), and add:

```elixir
@doc """
The chart identity `Statifier.compile/2` stamped, or `nil` for a Machine
built without a source: `Statifier.Compiler.compile/1` called directly, or a
Machine an embedder's `:invoke_source` resolver returned
(`Statifier.Invoke.Source.resolve/2`'s `src` clause,
`lib/statifier/invoke/source.ex:84-90`).
"""
@spec identity(machine :: t()) :: Identity.t() | nil
def identity(%__MODULE__{identity: identity}), do: identity
```

Two facts the implementer should not have to rediscover:

- `Statifier.Machine.Identity` references nothing from `Statifier.Machine`, so
  the dependency stays one-directional and there is no compile cycle.
- An ADR-0041 `<invoke><content>` slice **does** get an identity, because
  `Invoke.Source.resolve/2`'s `content` clause goes through the public
  `Statifier.compile/2` (`lib/statifier/invoke/source.ex:78-83`). That identity
  hashes the content slice, not the parent document, which is correct - the
  slice is its own chart. Phase 1's tests assert this on purpose rather than
  leaving it to be discovered.

#### 4. The stamp

**File**: `lib/statifier.ex`
**Changes**: `compile/2` computes the identity from the source it already has
and stamps it alongside `warnings`. Two new recognized options,
`:chart_name` and `:chart_version`, documented in `compile/2`'s `@doc` beside
`:invoke_content_markup`. They are passed through to `Identity.of_source/2`
and ignored by every pipeline stage.

```elixir
{:ok, %Machine{machine | warnings: warnings, identity: Identity.of_source(source, opts)}}
```

`Validator.validate/3` receives the same `opts` keyword and already ignores
unrecognized keys: `Statifier.Validator.Context.build/3` reads exactly
`Keyword.get(opts, :invoke_content_markup, false)` and nothing else
(`lib/statifier/validator/context.ex:64-76`), so the two new options pass
through the pipeline untouched and no stage needs a change.

#### 5. Tests

**File**: `test/statifier/machine/identity_test.exs` (new),
`test/statifier/statifier_test.exs` (extend, or the existing compile test file)
**Changes**: Every test asserting `lib/` behavior carries its sabotage line.
Cover: equal source gives equal hash; a reordered-states edit gives a different
hash; a whitespace-only edit gives a different hash (asserted as the *intended*
conservative behavior, with a comment saying so, not as a defect);
`chart_name`/`chart_version` ride through and participate in `matches?/2`;
`matches?/2` is `false` when either side is `nil`; the identity blob round
trips; a bumped version byte and a foreign `term_to_binary` blob each produce
their own error; `Compiler.compile/1` alone leaves `identity: nil`; and an
ADR-0041 content slice compiled through `Invoke.Source.resolve/2` gets a
non-`nil` identity that differs from its parent document's.

The code sketches above show `@spec` without `@doc` for brevity. Every public
function needs both - `.doctor.exs` is at 100% on the doc axis too.

Example sabotage line shape:

```elixir
# sabotage: of_source/2 hashes a constant instead of source -> red
test "two documents differing only in state order get different hashes" do
```

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (use `mix quality --profile loop` between edits;
      a loop run never satisfies this phase) - **blocked**: `mix quality`
      reports one Sobelow `Misc.BinToTerm` high-confidence finding on
      `lib/statifier/machine/identity.ex:112`
      (`:erlang.binary_to_term(blob, [:safe])` in `safe_decode/1`), which is
      the plan's own designed shape (ADR-0052 forward reference). Sobelow
      flags any `binary_to_term` call regardless of the `:safe` option since
      `:safe` still deserializes functions. Silencing it needs a
      human-approved `.sobelow-conf` entry (`ignore_files` or `skip: true`
      plus a `#sobelow_skip` annotation) per ADR-0011 and
      `docs/quality-gate-changes.md` - out of this implementer's authority to
      decide unilaterally, so left for human review rather than resolved.
      Every other stage is green (Format, Compile, Dependencies, ADR guard,
      Gate guard, Doctor, Credo, Dialyzer, Tests 2340/2340, Regression
      ratchet).
- [x] `mix gate.verify` confirms the run was a full, unscoped gate - **blocked
      by the same Sobelow finding** (`mix gate.verify` exits
      `Not a full gate: the gate is red (Sobelow).`)
- [x] Doctor stays at 100%: the new module has a `@moduledoc`, a `@type t`, and
      a `@doc` plus `@spec` on every public function
- [x] `mix adr.check` reports no finding (in particular no ADR-0008 identifier
      finding: `:crypto.hash/2` is not on the banned list, and no `sess_`-shaped
      id is minted here)
- [x] `mix test.regression` passes, and
      `git diff --quiet origin/main -- test/passing_tests.json` exits 0 - the
      ratchet must be byte-identical, which `test.regression` alone does not
      prove

#### Manual Verification:
- [ ] No function touched in this phase is an Appendix D port, so no
      pseudocode comparison applies - confirm by inspection that
      `lib/statifier/interpreter/` is untouched
- [ ] Two real charts differing by one added state produce different hashes,
      checked in IEx
- [ ] Run the pre-existing `invoke_content_markup: true` tests and confirm
      they still pass with the two new options threaded through `compile/2`

**Implementation Note**: Use the project's loop gate between edits; run the full
gate as the phase gate. In interactive execution, pause here for the human to
confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: `Statifier.Position` - the versioned position codec

### Overview

A new boundary module owning the whole serialization contract for a position:
encode without the machine, decode against a supplied machine, refuse on
identity mismatch or version mismatch.

**Why a new module rather than `MachineState.to_binary/1`, which is the bead's
literal wording**: `docs/architecture.md`'s principle 2 puts boundary work
beside `Statifier.Session`, not in a core struct; `machine_state.ex` is already
the largest core module and carries the 100% Doctor moduledoc burden; and the
name states what the artifact is. The bead's substance - a to_binary/from_binary
pair with an explicit format version for a MachineState - is met exactly; only
the module the pair lives on differs, and this note is the record of that.

### Changes Required:

#### 1. The codec

**File**: `lib/statifier/position.ex` (new)
**Changes**:

```elixir
@format_version 1

@spec format_version() :: pos_integer()

@spec to_binary(MachineState.t()) :: {:ok, binary()} | {:error, :unidentified_chart}
```

`to_binary/1` returns `{:error, :unidentified_chart}` when
`machine_state.machine.identity` is `nil`. This is the structural guarantee
that no position blob can exist that `from_binary/2` cannot check: an
unidentified chart never produces one. On success it encodes

```elixir
payload = machine_state |> Map.from_struct() |> Map.delete(:machine)
:erlang.term_to_binary({:statifier_position, @format_version, identity, payload})
```

and `from_binary/2` rebuilds with
`struct!(MachineState, Map.put(payload, :machine, machine))`.

**Encode a plain map, never `%{machine_state | machine: nil}`.**
`MachineState`'s `@type t` declares `machine: Machine.t()`, not
`Machine.t() | nil` (`lib/statifier/machine_state.ex:415`), so assigning `nil`
to that field is a dialyzer contract violation - and dialyzer is a full-gate
stage. Widening the core type to serve one boundary module is not on the table
(ADR-0012 constraint 1 leans on that field being present) and a dialyzer skip
is barred by CLAUDE.md. The map form violates no type, and `struct!/2` gives
the loud failure on a payload missing a key that the malformed-blob arm wants
anyway.

Dropping `:machine` from the payload is what keeps ADR-0014 item 2's premise
true - no `%Predicator.Compiled{}` instruction list or span table is ever
written to a blob - and is also what makes the blob ~8x smaller. Say that in
an inline comment at the deletion site.

```elixir
@spec from_binary(blob :: binary(), machine :: Machine.t()) ::
        {:ok, MachineState.t()}
        | {:error, :not_a_statifier_blob}
        | {:error, {:unsupported_format_version, term()}}
        | {:error, {:identity_mismatch, expected :: Identity.t(), actual :: Identity.t() | nil}}
        | {:error, :unidentified_chart}
```

Order of checks, and it matters: decode safely, then tag, then format version,
then identity, then reattach. Checking the version before the identity means a
future format whose identity representation changed reports the version rather
than a confusing mismatch.

`:identity_mismatch`'s `expected` is the blob's identity, `actual` is the
supplied machine's - both carried in the error so a host can log which
revision it has and which it needed. When the supplied machine's identity is
`nil`, the error is `:unidentified_chart`, not `:identity_mismatch`: the host
handed over a Machine it built without a source, which is a different mistake
with a different fix.

#### 2. Tests

**File**: `test/statifier/position_test.exs` (new)
**Changes**: Sabotage line above every test. Cover:

- Round trip through `to_binary/1` then `from_binary/2` with the same machine
  reproduces every field. Compare `internal_queue` via
  `MachineState.internal_events/1` on both sides, never by `==` on the struct
  (`lib/statifier/machine_state.ex:309-320`); assert the remaining 18 fields
  by pattern match.
- A position advanced by a real `send_event/2` (not just a fresh `new/2`) round
  trips - so history values, counters, and a non-trivial datamodel are actually
  exercised.
- The blob does not contain the machine: assert `byte_size` is materially
  smaller than `:erlang.term_to_binary(machine_state)`, and assert via a
  deliberate direct `binary_to_term` that the decoded payload map has no
  `:machine` key at all.
- `to_binary/1` on a `Compiler.compile/1`-built machine returns
  `{:error, :unidentified_chart}`.
- Loading against a recompiled *identical* source succeeds (proving the hash is
  deterministic across compiles, not just within one).
- Loading against a chart with one state added returns
  `{:error, {:identity_mismatch, _, _}}` - **this is the bead's central test**.
- A blob whose version integer is bumped returns
  `{:error, {:unsupported_format_version, 2}}`.
- `:erlang.term_to_binary(:hello)` and a random binary each return
  `{:error, :not_a_statifier_blob}` rather than raising.
- An ADR-0037 `:undefined` datamodel value and a `nil` datamodel value survive
  the round trip distinctly.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating)
- [x] `mix gate.verify` confirms a full, unscoped run
- [x] Doctor stays at 100% for the new module
- [x] `mix adr.check` reports no finding - in particular no ADR-0003 finding:
      this module is pure, does no I/O, and is not added to
      `@effect_interpreter_paths`
- [x] `mix test.regression` passes, and
      `git diff --quiet origin/main -- test/passing_tests.json` exits 0

#### Manual Verification:
- [ ] No Appendix D function is touched; `lib/statifier/interpreter/` is
      untouched by this phase
- [ ] The identity-mismatch error message, read cold, tells a host what to do
      next
- [ ] Take a `Session.snapshot/1` from a live session, `to_binary/1` it, and
      `from_binary/2` it against the same machine - confirm `{:ok, _}` and the
      same configuration. Nothing in this phase modifies `Session`; this
      confirms the codec accepts the position shape a real session produces,
      not just one built by `MachineState.new/2`

**Implementation Note**: Use the project's loop gate between edits; run the full
gate as the phase gate. In interactive execution, pause here for the human to
confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: String-id position export and import

### Overview

The migration vocabulary: a position in ADR-0005 boundary terms (string state
ids), so a host holding a position saved against revision A can load it onto
revision B on purpose. This is the deliberate counterpart to Phase 2's refusal
- `from_binary/2` never crosses a revision, `import/2` always may.

### Changes Required:

#### 1. Export

**File**: `lib/statifier/position.ex`
**Changes**:

```elixir
@type exported :: %{required(atom()) => term()}

@spec export(MachineState.t()) ::
        {:ok, exported()}
        | {:error, :internal_queue_not_empty}
        | {:error, {:unnameable_states, [non_neg_integer()]}}
```

Translates `configuration`, `entered_states`, `states_to_invoke` (MapSets of
indexes to MapSets of string ids), `history_values` (both key and value sides),
and `active_invocations` (`{state_index, invoke_index}` key to
`{state_id, invoke_index}`). Carries `invoke_counter`, `send_counter`,
`datamodel`, `running`, `status`, `macrostep`, `microstep`, `round`, `trace`,
and `max_macrostep_rounds` verbatim. Includes the source identity under an
`:identity` key as provenance - `import/2` does not check it, but a host that
wants to log "migrated from revision X to revision Y" has both halves.

Two refusals, both loud:

- A non-empty `internal_queue` returns `{:error, :internal_queue_not_empty}`,
  tested with `MachineState.internal_queue_empty?/1`
  (`lib/statifier/machine_state.ex:650`), not by materializing the list.
  A position mid-macrostep is not a thing to move across chart revisions: the
  queued events were selected against the old chart's transitions. A host
  drains to quiescence first.
- Any index in any exported field for which `Machine.id/2` returns `nil`
  returns `{:error, {:unnameable_states, indexes}}`. The one exception is the
  root, index 0, which has no written id and is present in every configuration:
  it is dropped on export and re-added on import. Comment that exception at the
  site.

The `invoke_index` half of an `active_invocations` key stays an integer. It is
a within-state document-order ordinal over that state's own `<invoke>`
children, so it survives states being added or reordered elsewhere in the chart
but not an edit to that state's invokes. Say this in the `@doc`.

`internal_queue`, `routes`, `invoke_types` and `machine` are absent from the
exported map by design; the `@doc` lists them and why, so a host reading the
map does not conclude they were forgotten.

#### 2. Import

**File**: `lib/statifier/position.ex`
**Changes**:

```elixir
@spec import(machine :: Machine.t(), exported :: exported()) ::
        {:ok, MachineState.t()}
        | {:error, {:unknown_state_ids, [String.t()]}}
        | {:error, {:malformed_export, term()}}
```

Reverses the translation via `Machine.index/2`, collecting **every** unknown id
before returning rather than failing on the first - a host migrating a position
wants the whole list of states its new revision dropped. Re-adds the root index.
Rebuilds `internal_queue` as `:queue.new()`, `routes` and `invoke_types` as
`nil` (the driver re-stamps both), and `machine` as the supplied machine.
`{:error, {:malformed_export, reason}}` covers a map missing a required key or
carrying a value of the wrong shape - a host may have hand-edited it, which is
the entire point of a string-id vocabulary.

**No identity check.** State this in the `@doc` in one sentence, as a
deliberate contrast with `from_binary/2`, because a reader who has just read
Phase 2's contract will otherwise assume it was forgotten. Concretely:
`import/2` **ignores the `:identity` key entirely** - it does not compare it,
and the malformed-export check does not require it to be present or
well-formed. A host hand-editing an export may update it, delete it, or leave
it stale, and all three import identically. Say this in the `@doc` too, since
the plan's own manual test hand-edits the map.

#### 3. Tests

**File**: `test/statifier/position_test.exs` (extend)
**Changes**: Sabotage line above every test. Cover:

- `export/1` then `import/2` against the *same* machine reproduces the position
  on every translated field (`internal_queue` compared as `internal_events/1`,
  which is empty on both sides by construction).
- Export then import against a machine recompiled from a source with one
  **unrelated** state added: every original id still resolves, and the resulting
  configuration is the same set of ids - the migration story working.
- Export then import against a machine whose source **removed** an active state
  returns `{:error, {:unknown_state_ids, ["..."]}}` listing all of them, not
  just the first.
- A position with a non-empty `internal_queue` returns
  `{:error, :internal_queue_not_empty}`.
- `history_values` with a real history state survives a round trip, keys and
  values both translated.
- `active_invocations` survives a round trip with its `invoke_index` intact.
- A chart with a nameless non-root state active returns
  `{:error, {:unnameable_states, _}}`.
- `routes` and `invoke_types` set before export come back `nil` after import,
  asserted as the documented drop rather than tolerated. Build them directly -
  `Statifier.Send.Routes.new/1` (`lib/statifier/send/routes.ex:40-41`) and the
  `Statifier.Invoke.Types` constructor - rather than standing up a Session for
  it; the test is about the drop, not about how a driver stamps them.
- An export map with a key deleted returns `{:error, {:malformed_export, _}}`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (`mix quality --profile loop` while iterating)
- [x] `mix gate.verify` confirms a full, unscoped run
- [x] Doctor stays at 100%
- [x] `mix adr.check` reports no finding
- [x] `mix test.regression` passes, and
      `git diff --quiet origin/main -- test/passing_tests.json` exits 0

#### Manual Verification:
- [ ] No Appendix D function is touched
- [ ] A hand-edited export map (a state id renamed by hand) imports onto the
      renamed chart, checked in IEx - the migration story a human would
      actually perform
- [ ] The set of dropped fields, read from the `@doc` alone, is enough for a
      host to know what it must re-supply

**Implementation Note**: Use the project's loop gate between edits; run the full
gate as the phase gate. In interactive execution, pause here for the human to
confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 4: ADR-0052, `docs/persistence.md`, changelog, follow-up bead

### Overview

The record and the prose. This phase writes no `lib/` code, so its gate is a
formatting/compile/credo pass over the docs plus the unchanged suite - plus one
explicit `mix quality --profile merge` run, because that is the only profile
that runs the ADR judge and ADR-0052 is exactly what the judge exists for.

### Changes Required:

#### 1. ADR-0052

**File**: `docs/adr/0052-chart-identity-and-position-serialization.md` (new)
**Changes**: The standard three sections. Decisions to record, each with the
reasoning already argued above:

1. Chart identity is a SHA-256 hash of the SCXML source bytes handed to
   `Statifier.compile/2`, plus optional embedder name and version. Not a term
   hash over the Machine, and why.
2. A position blob carries the identity and an integer format version, checked
   before use, after the prior art of `Predicator.isa_version/0`.
3. A `%Machine{}` is never serialized. ADR-0014 item 2's premise - that this
   library stores no instruction lists - is *reaffirmed* by this record rather
   than amended: the substitute is predicator's own advice, persist the source
   and recompile, which the content hash makes safe.
4. `to_binary/1` refuses an unidentified chart, so no unverifiable blob can
   exist.
5. Serialization lives on `Statifier.Position`, a boundary module, not on
   `%MachineState{}` (architecture principle 2, ADR-0003).
6. `export/1` / `import/2` speak string ids (ADR-0005) and perform **no**
   identity check, because crossing a revision is their purpose; the fields
   they drop and why.
7. The blob records no library version; the format version is the only
   compatibility fact.
8. `Session.Recording` is out of scope and why (ADR-0034).

Consequences must include the whitespace-sensitivity cost, the drain-or-migrate
choice it forces on a host, and the fact that `:erlang.binary_to_term/2` is
called with `:safe`.

**File**: `docs/adr/README.md`
**Changes**: One row appended to the table, matching the existing format. The
status column reads a plain `accepted` - the table's `(amends NNNN in part)`
marker is for amendments, and this record reaffirms ADR-0014 rather than
amending it. The relationship goes in ADR-0052's body; do not invent a new
marker for it.

#### 2. The hazard and migration doc

**File**: `docs/persistence.md` (new)
**Changes**: A concern-scoped doc, the shape `observability.md` and
`datamodel.md` already establish. Sections:

- **The hazard.** Configurations are MapSets of interned integer indexes
  (ADR-0005). Indexes are stable *within* one Machine build and mean nothing
  across two. Adding or reordering a state renumbers them, and a position
  loaded against the renumbered chart resumes different states with no error.
  Quote ADR-0005's Consequences sentence.
- **What identity buys.** The content hash detects the renumbering; the format
  version detects a library upgrade that changed the blob shape. Two separate
  facts, two separate fields.
- **Migration story A: drain on the old version.** Keep the old chart source
  compiled and reachable; run existing positions to completion against it;
  start new positions on the new revision. No translation, no data loss,
  bounded by how long a position lives. The default recommendation.
- **Migration story B: position migration via string ids.** `export/1` on the
  old machine, hand or programmatic mapping of renamed ids, `import/2` on the
  new machine. What it cannot do: it cannot invent a state the new revision
  deleted, it cannot fix an `active_invocations` key whose state's invoke
  children were edited, and it refuses a non-quiescent position.
- **What a host must persist.** The SCXML source (so the Machine can be
  recompiled deterministically), the identity blob, and the position blob.
  Explicitly: not the `%Machine{}`, and why (ADR-0052 decision 3, predicator's
  `compiled.ex:10-38`).

**Files**: `docs/architecture.md`, `docs/extending.md`
**Changes**: One cross-reference each. In `architecture.md`, beside the
MachineState description (`:92-106`). In `extending.md`, beside the existing
persist/reload paragraph (`:154-159`), which is the only place in the docs that
already speaks of a persist/reload cycle.

#### 3. Changelog fragment

**File**: `changelog.d/st-m5c3.md` (new)
**Changes**: `### Added` with one line per user-visible addition, present tense,
no nested bullets, per `changelog.d/README.md`. Roughly: the chart identity on
`Statifier.compile/2`; the versioned position blob with its mismatch error; the
string-id export/import. Three lines, no more.

#### 4. Prove ADR-0006 is untouched

**Changes**: No file change - a check the phase must run and record in the
commit body:

```
grep -rnE "Position\.(to_binary|from_binary|export|import)|Machine\.Identity|Machine\.identity\(" \
  test/support/ test/scion_tests/ test/scxml_tests/
```

Qualified call forms only, deliberately: bare `to_binary` / `from_binary` are
not distinctive tokens, and this repo does write comments mentioning
`term_to_binary` in test files (`test/statifier/session/recording_test.exs:224-248`),
so an unqualified grep would report prose as coupling.

Must return nothing. If it returns anything, the corpus has coupled to a new
function and ADR-0006 *is* reopened - stop and escalate rather than amending
it in passing.

#### 4b. Prove the ratchet did not move

**Changes**: No file change - a second check, run and recorded the same way:

```
git diff --quiet origin/main -- test/passing_tests.json
```

`mix test.regression` passing does not prove this: a phase that *added* an
entry passes it too, and `mix gate.check` (ADR-0011) only guards the file
*shrinking*. Nothing in this bead changes SCXML semantics, so the file must be
byte-identical to `origin/main`.

#### 5. File the follow-up bead

**Changes**: `bd create` a feature bead for extending the identity and format
version to `Statifier.Session.Recording`, blocked by nothing, `area:interpreter`,
P2, with a description naming: the `@opaque` boundary, the embedded Machine and
why ADR-0034's design put it there, the `:invoke_handlers` module-atom
portability question, and a `mirrors:` line only if a predicator-ex counterpart
exists (it does not today). Add a note on st-m5c3 pointing at the new id.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes - the docs-only diff still runs the whole gate
- [ ] `mix gate.verify` confirms a full, unscoped run
- [ ] `mix quality --profile merge` passes - run it explicitly as this phase's
      gate in addition to the bare full gate, because that is the profile that
      re-enables the ADR judge (`.quality.exs:23` disables it in the bare gate
      on purpose - see CLAUDE.md), and ADR-0052 is the record it exists to
      review. `/wurk:mr` runs it again for the branch; running it here means
      the judge's verdict is not deferred to push time
- [ ] `mix adr.check` reports no finding
- [ ] The grep in item 4 returns nothing
- [ ] The `git diff --quiet` check in item 4b exits 0
- [ ] `changelog.d/st-m5c3.md` exists and uses only standard Keep a Changelog
      headings
- [ ] `docs/adr/README.md`'s table has a row for 0052

#### Manual Verification:
- [ ] No `lib/` code changed in this phase, so no Appendix D comparison applies
- [ ] ADR-0052 reads as a decision record, not as a summary of the code -
      Context, Decision, Consequences, with the rejected alternatives named
- [ ] `docs/persistence.md` is understandable to a host author who has not read
      ADR-0005
- [ ] The follow-up bead exists and its description is enough to work from cold

**Implementation Note**: Use the project's loop gate between edits; run the full
gate as the phase gate. In interactive execution, pause here for the human to
confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/machine/identity_test.exs` - hashing determinism, sensitivity
  to state reordering and to whitespace, optional name/version, `matches?/2`
  totality including both `nil` sides, identity blob round trip and both error
  arms.
- `test/statifier/position_test.exs` - the position round trip on an *advanced*
  position rather than a fresh one; the machine's absence from the blob; the
  identity-mismatch refusal (the bead's central assertion); version and
  malformed-blob refusals; then the Phase 3 export/import cases including the
  unrelated-state-added migration success and the removed-state failure listing
  every id.
- Edge cases that must each have a test, because each is a silent-wrongness
  risk: the `:queue` front/rear split (compare `internal_events/1`, never
  `==`); ADR-0037's `nil` versus `:undefined`; the root index's absence from
  the export and its re-addition on import; a nameless non-root state.
- Every test asserting `lib/` behavior carries its one-line sabotage comment
  (`docs/testing.md`): break the covered code, confirm red, revert, record the
  mutation.

### Manual Testing Steps:

1. Compile a 4-state chart, `Statifier.initialize/2`, send one event,
   `Position.to_binary/1`. Confirm the blob is materially smaller than
   `:erlang.term_to_binary(machine_state)` - the research measured 5848 to 725
   bytes, about 8x, on a 4-state chart; a chart with a large datamodel will
   show less, which is fine.
2. Recompile the identical source in a fresh IEx session and `from_binary/2`
   the blob against it. Confirm `{:ok, _}` and that the configuration matches.
3. Add a state near the top of the chart, recompile, `from_binary/2` the same
   blob. Confirm `{:error, {:identity_mismatch, _, _}}` - this is the bug the
   bead exists to close, observed failing loudly.
4. `export/1` the original position, `import/2` it onto the edited chart.
   Confirm the same string ids come back active - migration story B, performed.
5. Hand-edit the exported map to rename one id, import onto a chart with that
   state renamed. Confirm success.

## References

- Source research: `docs/research/260818-st-m5c3-machine-identity-and-serialization.md`
- Bead: st-m5c3 (blocks st-5yhl, st-q6xl)
- ADR-0003 (pure core, effects at the edge), ADR-0005 (interned indexes; string
  ids at the boundary), ADR-0006 (corpus driving surface - *not* the string-id
  rule the bead cites), ADR-0012 (`docs/observability.md`, resumable position),
  ADR-0014 item 2 (the predicator span-table hazard and its premise),
  ADR-0030 (the three-part test for a new struct field), ADR-0034 (replay
  re-drives the recording), ADR-0037 (`nil` versus `:undefined`), ADR-0041
  (declining to build round-trip machinery is a citable decision)
- Prior art: `deps/predicator/lib/predicator.ex:677-692` (`isa_version/0`),
  `deps/predicator/lib/predicator/instructions.ex:32-37` (`upgrade/1`),
  `deps/predicator/lib/predicator/compiled.ex:10-38` ("not a wire format")
- Existing round trips: `test/statifier/session/recording_test.exs:224-248`,
  `test/statifier/interpreter/interpreter_acceptance_test.exs:143-178`

## Open Questions Revisited

Every question the research left is decided above and implemented as decided.
These are the two calls a human might overrule, recorded so they can be
revisited without re-deriving the argument. Neither blocks implementation.

1. **Shipping a `%Machine{}` codec after all.** This plan refuses it and
   substitutes "persist the source, recompile, verify by hash". The alternative
   is to amend ADR-0014 item 2 - replacing "we store no instruction lists" with
   a rule that a persisted Machine must be recompiled rather than trusted for
   diagnostics, or that span tables are stripped before encoding - and ship
   `Machine.to_binary/1` for hosts that cannot retain source. If a human wants
   this, it is a fifth phase: the ADR amendment, a codec that nulls every
   `%Predicator.Compiled{}` `positions` table on encode, and a documented loss
   of cond diagnostics after a reload.

2. **Whitespace sensitivity of the content hash.** A comment or indentation edit
   changes the identity and forces a drain or a migration even though every
   index survived. The alternative is to hash a *canonicalized* form - the
   `%Document{}` with locations stripped, say - which would be insensitive to
   formatting. It is rejected here because `%Statifier.Document{}` is documented
   as a pre-validation, deliberately lossy projection (`lib/statifier/document.ex:1-12`),
   so a canonicalizer over it would be new machinery with its own correctness
   burden and its own false-negative risk - and a false negative on this hash is
   exactly the silent wrong-state resumption the bead exists to prevent. Erring
   toward a loud false positive is the defensible default; a canonical hash can
   be added later as a second, opt-in identity without invalidating any blob,
   because the algorithm name is inside the stored hash string.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] No function touched in this phase is an Appendix D port, so no
      pseudocode comparison applies - confirm by inspection that
      `lib/statifier/interpreter/` is untouched
- [ ] Two real charts differing by one added state produce different hashes,
      checked in IEx
- [ ] Run the pre-existing `invoke_content_markup: true` tests and confirm
      they still pass with the two new options threaded through `compile/2`

**Implementation Note**: Use the project's loop gate between edits; run the full
gate as the phase gate. In interactive execution, pause here for the human to
confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] No Appendix D function is touched; `lib/statifier/interpreter/` is
      untouched by this phase
- [ ] The identity-mismatch error message, read cold, tells a host what to do
      next
- [ ] Take a `Session.snapshot/1` from a live session, `to_binary/1` it, and
      `from_binary/2` it against the same machine - confirm `{:ok, _}` and the
      same configuration. Nothing in this phase modifies `Session`; this
      confirms the codec accepts the position shape a real session produces,
      not just one built by `MachineState.new/2`

**Implementation Note**: Use the project's loop gate between edits; run the full
gate as the phase gate. In interactive execution, pause here for the human to
confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

### Phase 3

- [ ] No Appendix D function is touched
- [ ] A hand-edited export map (a state id renamed by hand) imports onto the
      renamed chart, checked in IEx - the migration story a human would
      actually perform
- [ ] The set of dropped fields, read from the `@doc` alone, is enough for a
      host to know what it must re-supply

**Implementation Note**: Use the project's loop gate between edits; run the full
gate as the phase gate. In interactive execution, pause here for the human to
confirm the manual testing before moving to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---
