---
date: 2026-08-19
issue: st-hz2a
status: draft
---

# Recording Identity and Serialization Implementation Plan

## Overview

Give `Statifier.Session.Recording` the versioned binary contract ADR-0052
decision 8 filed and ADR-0056 specifies: a `to_binary/1` / `from_binary/1` /
`format_version/0` trio on the `@opaque` owner itself, whose blob nests a
`Statifier.Chart.to_binary/1` blob in the compiled `%Machine{}`'s place and
carries `:invoke_handlers` as module-name strings. Beads issue: `st-hz2a`.

ADR-0056 is the accepted specification this plan implements. Every decision
below is that record's; this plan decides only mechanics the record left to
the implementer, and records the two it could not settle without a human.

## Current State Analysis

**What exists.**

- `Statifier.Session.Recording` (`lib/statifier/session/recording.ex:1-274`)
  is `@opaque` (`:105-109`) with four readers - `machine/1` (`:261`),
  `opts/1` (`:265`), `entries/1` (`:269`), `size/1` (`:273`) - and
  construction only through `new/2` (`:145`) and six `put_*` appenders
  (`:167`, `:184`, `:201`, `:217`, `:229`, `:254`). The `entries` field is
  stored **reversed** as a prepend-list optimization; `entries/1` is the only
  thing that reverses it back into append order.
- `new/2` normalizes `opts` to exactly seven keys (`:111-119`), including
  `:invoke_handlers`, defaulted to `%{}` (`:155`) and sorted (`:156`).
  `:invoke_handlers` is a `%{String.t() => module()}` map
  (`lib/statifier/session.ex:379`, `lib/statifier/replay.ex:166`) - the
  values are module **atoms**.
- Two codecs already ship under ADR-0052 and are the template for this one:
  `lib/statifier/position.ex` and `lib/statifier/chart.ex`.
  `Chart.to_binary/1` (`lib/statifier/chart.ex:80-85`) writes
  `{:statifier_chart, @format_version, identity, source, opts}` and refuses
  an unidentified or source-less `Machine` with
  `{:error, :unidentified_chart}`. `Chart.from_binary/1` (`:124-136`) decodes
  `:safe`, matches one literal five-tuple shape, checks version, recompiles
  through `Statifier.compile/2`, then compares identity with
  `Identity.matches?/2`.
- Both codecs carry the Sobelow pattern this plan must follow: a
  `Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)`
  declaration near the top (`lib/statifier/chart.ex:49`,
  `lib/statifier/machine/identity.ex:35`) and a per-function
  `@sobelow_skip ["Misc.BinToTerm"]` immediately above `safe_decode/1`
  (`lib/statifier/chart.ex:176-181`), with the justification comment above
  it. `.sobelow-conf` already sets `skip: true`, so **no edit to
  `.sobelow-conf` is needed and no ADR-0011 ledger entry is owed.**
- `Statifier.Replay.run/1` (`lib/statifier/replay.ex:203-231`) reads the
  recording exclusively through `Recording.machine/1`, `Recording.opts/1`,
  and `Recording.entries/1`, and pulls `:invoke_handlers` off the recorded
  opts (`:207`). It needs no change.
- A raw `term_to_binary`/`binary_to_term` round trip of a populated recording
  is already pinned green (`test/statifier/session/recording_test.exs:224-248`),
  so the mechanics of encoding were never the open question - only the
  *supported contract* is missing.
- `test/statifier/session/recording_test.exs`'s `compile!/0` (`:9-24`) builds
  a `Machine` through the raw `Parser`/`Lowering`/`Validator`/`Compiler`
  pipeline, so it carries **no `identity` and no `source`**. Every new codec
  test that must succeed needs a second helper built on `Statifier.compile/2`.
- `Session.start_link(machine, record: true)` plus `Session.recording/1`
  (`lib/statifier/session.ex:519-520`) is how a live run produces a
  recording; `test/statifier/replay_test.exs:461-464` is the working example.

**What is missing.** No `format_version/0`, no `to_binary/1`, no
`from_binary/1` on `Recording`; no recording section in
`docs/persistence.md`; ADR-0052's status line has no pointer to ADR-0056; and
ADR-0056 itself plus its `docs/adr/README.md` index row are **uncommitted in
the working tree** (`git status`: `?? docs/adr/0056-...md`, `M
docs/adr/README.md`).

## Desired End State

`Statifier.Session.Recording` exposes three new public functions and nothing
else new; `Statifier.Replay` is byte-for-byte unchanged; a recording made
over an identified chart survives an encode/decode round trip and replays to
the same stream and terminal position as the live run that produced it; a
recording made over an unidentified chart is refused at encode; and
`docs/persistence.md` documents the artifact.

Verified by: `mix quality` green with the new tests in
`test/statifier/session/recording_test.exs`; `git diff --stat` showing no
change to `lib/statifier/replay.ex`; and the ADR-0052 status line naming
ADR-0056.

### Key Discoveries:

- The `@opaque` boundary is what places the codec (ADR-0056 decision 1):
  dialyzer forbids a foreign module matching or building `%Recording{...}`,
  and rebuilding via `new/2` + the `put_*` heads would re-normalize `opts` at
  decode time - which decision 1 explicitly rejects. `from_binary/1`
  therefore constructs `%__MODULE__{}` directly, and is the *only* function
  outside `new/2`/`put_*` that may.
- `entries` storage order is an implementation detail the blob must not bake
  in (ADR-0056 decision 4): `to_binary/1` writes `entries(recording)` (append
  order) and `from_binary/1` restores the reversed internal field itself.
- The blob nests `Chart.to_binary/1`'s output rather than inlining
  source/opts/identity, so a chart-format bump is not forced to be a
  recording-format bump; nested failures come back wrapped as
  `{:error, {:chart, reason}}`, unflattened (ADR-0056 decision 4).
- `:safe` decoding refuses to create atoms a blob names, and a module atom
  exists on a node only once that module is loaded - hence
  `Atom.to_string/1` at encode and `String.to_existing_atom/1` at decode,
  with every failure collected into
  `{:error, {:unknown_handler_modules, names}}` sorted (ADR-0056 decision 5).
- ADR-0018 forbids process artifacts (bead ids) in code comments; the new
  comments cite ADR numbers only.
- ADR-0002/Appendix D: **no Appendix D procedure is touched by this work.**
  A serialization codec on a session-boundary artifact has no pseudocode
  counterpart, so there is no deviation to justify. That is the plan's answer
  to the project's Appendix D rule, not an omission.

## What We're NOT Doing

- **Not adding `Recording.identity/1`.** ADR-0056 decision 2:
  `Recording.machine/1` composed with `Statifier.Machine.identity/1` already
  exposes it, and a second reader of one fact is the redundancy
  `lib/statifier/machine.ex` rules out for the `Machine` itself. The
  accessor surface is unchanged.
- **Not touching `Statifier.Replay`.** Its input is a `Recording.t()` however
  obtained, so decode-then-run composes with no replay change.
- **Not reopening ADR-0034's whole-`%Machine{}` embedding.** Rehydration
  happens entirely at decode; no caller ever sees a machine-less recording
  and `t()` gains no `nil` arm.
- **Not writing any compiled term** (ADR-0014 item 2, ADR-0052 decision 3).
- **Not calling `Code.ensure_loaded?/1`** or verifying handler-callback
  behavior (ADR-0056 decision 5). Handlers are code; code does not travel in
  a blob.
- **Not adding a migration counterpart** to `Position.export/1`/`import/2`.
  ADR-0056's "what would reopen" bullet names replaying against a different
  chart revision as deliberately out of scope - replay's determinism claim is
  per-revision by construction.
- **Not resolving ADR-0056's two recorded open questions** (identity without
  recompile; a handler planning-callback fingerprint). Both are re-listed
  under Open Questions below as deferred, and neither is implemented here.
- **Not editing `.sobelow-conf`, `.quality.exs`, `coveralls.json`,
  `.credo.exs`, `.doctor.exs`, or `test/passing_tests.json`**, so no
  `docs/quality-gate-changes.md` entry is owed on this branch. If the gate
  guard fires anyway, that is a signal something outside this plan's scope
  was touched - stop rather than write a ledger entry, which is a human's
  call on the record.

## Implementation Approach

Three phases, ordered so the tree is clean before any Elixir change lands.

Phase 1 commits the accepted record already sitting untracked in the tree and
discharges ADR-0052's reopen bullet with a status-line pointer - docs only,
no gate-relevant build path touched. Phase 2 is the whole codec plus its
tests in one commit: an encoder without a decoder leaves untestable, uncovered
branches, and splitting handler translation out of the envelope would mean
shipping one blob format and then changing it mid-branch, so the smallest
independently gate-verifiable unit is the pair. Phase 3 documents the artifact
for hosts.

Model every line of Phase 2 on `lib/statifier/chart.ex` and
`test/statifier/chart_test.exs` - same envelope shape discipline, same
check-ordering discipline, same `safe_decode/1` + `@sobelow_skip` shape, same
one-describe-block-per-error-arm test layout with a sabotage line above every
test.

---

## Phase 1: Land ADR-0056 and point ADR-0052 at it

### Overview

Commit the accepted record and its index row, and give ADR-0052's status line
the pointer ADR-0056's Consequences direct to the implementing branch. Docs
only; no `lib/` or `test/` change.

### Changes Required:

#### 1. The record and its index row (already written, uncommitted)
**Files**: `docs/adr/0056-recording-identity-and-serialization.md` (new,
untracked), `docs/adr/README.md` (modified - row 60 already added)
**Changes**: none needed to content; these are staged and committed as-is.
Re-read both before committing to confirm nothing else drifted into
`README.md`.

#### 2. ADR-0052's status line gains a pointer
**File**: `docs/adr/0052-chart-identity-and-position-serialization.md`
**Changes**: extend the status line (currently lines 3-6) with a pointer to
ADR-0056, following the ADR-0054 -> ADR-0055 precedent
(`docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md:3`, which
reads `- decision 2's recorded gap decided by ADR-0055 (2026-08-19: ...)`).

```
Status: accepted (2026-08-19) - reaffirms ADR-0014 item 2's premise rather
than amending it (decision 3 below) - amended 2026-08-19 (st-i7y7: decision
3's corollary superseded; a chart blob carries source and compile opts,
still no compiled term) - decision 8's named follow-up answered by ADR-0056
(2026-08-19: a recording blob nests the chart blob, the codec lives on the
`@opaque` owner, `:invoke_handlers` cross as strings)
```

Match the file's existing typography (hyphens, no em dashes) and its ~72
column wrapping. Do **not** edit any of ADR-0052's decisions or Consequences
prose - ADR-0056 supersedes nothing there, and the "what would reopen"
bullet at `:302-303` stays as written; the status line is the whole edit.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix quality --profile loop` while
      iterating; a loop-profile green does not satisfy this phase).
- [x] `mix gate.verify` confirms the run was a full, unscoped gate.
- [x] `git status --porcelain` is empty after the commit - no leftover
      untracked ADR file.
- [x] `grep -c "0056" docs/adr/README.md` is 1 and
      `grep -c "ADR-0056" docs/adr/0052-chart-identity-and-position-serialization.md`
      is 1.

#### Manual Verification:
- [ ] The ADR-0052 status line reads as one sentence a reviewer can follow,
      and its clause ordering matches ADR-0054's precedent.
- [ ] No Appendix D-named function was touched (this phase changes no
      `lib/` file at all, so the project's spec-conformance criterion is
      satisfied vacuously - confirm by `git diff --stat` showing only
      `docs/`).
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. This phase touches no Elixir
code, so per CLAUDE.md's authority table it may commit on review of the diff
alone - but run the full gate anyway, since ADR guard and doc stages read
`docs/`. In interactive execution, pause here for the human to confirm the
manual testing before moving to the next phase. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: The recording codec and its tests

### Overview

Add `format_version/0`, `to_binary/1`, and `from_binary/1` to
`Statifier.Session.Recording`, plus the moduledoc section explaining the
blob, plus every test ADR-0056's Consequences owe - each with its sabotage
line - plus the changelog fragment for the new public API.

### Changes Required:

#### 1. The codec
**File**: `lib/statifier/session/recording.ex`
**Changes**: add the Sobelow attribute declaration and `@format_version`
beside the existing `@normalized_opts`, then the three public functions after
`size/1` (`:273`), then the private helpers. Add `Statifier.Chart` to the
existing `alias Statifier.{Effect, Event, Machine}` line (`:88`).

Envelope, exactly as ADR-0056 decision 4 fixes it:

```elixir
@format_version 1

# `@sobelow_skip` is read out of this file's AST by Sobelow, never at
# runtime, so the compiler sees an attribute that is set and never used and
# rejects the build under `--warnings-as-errors`. Registering it as
# persisted is what makes it a declaration rather than dead code; see its
# one use site below, and .sobelow-conf for the mechanism (the same one
# `lib/statifier/chart.ex` already uses).
Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)
```

```elixir
@spec format_version() :: pos_integer()
def format_version, do: @format_version

@spec to_binary(recording :: t()) :: {:ok, binary()} | {:error, :unidentified_chart}
def to_binary(%__MODULE__{machine: machine, opts: opts} = recording) do
  with {:ok, chart_blob} <- Chart.to_binary(machine) do
    {:ok,
     :erlang.term_to_binary(
       {:statifier_recording, @format_version, chart_blob, encode_opts(opts),
        entries(recording)}
     )}
  end
end
```

`entries(recording)` - the public accessor, i.e. **append order**, not the
reversed field (ADR-0056 decision 4). `to_binary/1` refuses exactly when
`Chart.to_binary/1` refuses, so the `with` passes
`{:error, :unidentified_chart}` straight through.

```elixir
@spec from_binary(blob :: binary()) ::
        {:ok, t()}
        | {:error, :not_a_statifier_blob}
        | {:error, {:unsupported_format_version, term()}}
        | {:error, {:chart, term()}}
        | {:error, {:unknown_handler_modules, [String.t()]}}
def from_binary(blob) when is_binary(blob) do
  case safe_decode(blob) do
    {:ok, {:statifier_recording, version, chart_blob, opts, entries}}
    when is_binary(chart_blob) and is_list(opts) and is_list(entries) ->
      with :ok <- check_version(version),
           {:ok, machine} <- decode_chart(chart_blob),
           {:ok, opts} <- decode_opts(opts) do
        {:ok, %__MODULE__{machine: machine, opts: opts, entries: Enum.reverse(entries)}}
      end

    _other ->
      {:error, :not_a_statifier_blob}
  end
end
```

Check order: **version, then nested chart, then handler resolution.** Version
first is ADR-0056 decision 4's own words ("checked before the nested chart is
touched"). Chart before handlers is this plan's call - see Open Question
OQ-1 below for the tradeoff and why this is the default.

`Enum.reverse(entries)` restores the internal reversed representation - legal
only because the codec lives on the owning module (decision 1).

Helpers. Follow `lib/statifier/chart.ex`'s own practice rather than a blanket
rule: the helpers carrying a non-obvious return contract get an `@spec`
(`check_version/1`, `decode_chart/1`, `decode_opts/1`, `resolve_handlers/2`),
and `safe_decode/1` does not, exactly as in `chart.ex`. Credo's `Specs` check
is scoped to public functions here, so none of this is a gate requirement -
it is house style, and matching the template file is the tiebreak.

```elixir
defp check_version(@format_version), do: :ok
defp check_version(version), do: {:error, {:unsupported_format_version, version}}

defp decode_chart(chart_blob) do
  case Chart.from_binary(chart_blob) do
    {:ok, machine} -> {:ok, machine}
    {:error, reason} -> {:error, {:chart, reason}}
  end
end
```

The `{:chart, reason}` wrap is unflattened by design (decision 4): two
envelopes means two version namespaces, and an unwrapped
`{:unsupported_format_version, v}` would not say which decoder refused.

```elixir
defp encode_opts(opts) do
  Keyword.replace_lazy(opts, :invoke_handlers, fn handlers ->
    Map.new(handlers, fn {type, module} -> {type, Atom.to_string(module)} end)
  end)
end

defp decode_opts(opts) do
  case Keyword.fetch(opts, :invoke_handlers) do
    {:ok, handlers} -> resolve_handlers(opts, handlers)
    :error -> {:ok, opts}
  end
end

defp resolve_handlers(opts, handlers) do
  {resolved, unknown} =
    Enum.reduce(handlers, {%{}, []}, fn {type, name}, {resolved, unknown} ->
      case existing_atom(name) do
        {:ok, module} -> {Map.put(resolved, type, module), unknown}
        :error -> {resolved, [handler_name(name) | unknown]}
      end
    end)

  case unknown do
    [] -> {:ok, Keyword.put(opts, :invoke_handlers, resolved)}
    names -> {:error, {:unknown_handler_modules, Enum.sort(names)}}
  end
end

# `String.to_existing_atom/1` has no non-raising variant, so the rescue is
# function-level here - the same shape `safe_decode/1` below uses, rather
# than a `try` block inline in the reduce. This is not a rescue-to-default
# at a leaf (CLAUDE.md): `:error` is collected into a named error arm, never
# silently substituted for a value.
defp existing_atom(name) when is_binary(name) do
  {:ok, String.to_existing_atom(name)}
rescue
  ArgumentError -> :error
end

defp existing_atom(_name), do: :error

# Keeps `{:unknown_handler_modules, [String.t()]}` honest for a doctored
# blob whose handler map holds a non-binary value.
defp handler_name(name) when is_binary(name), do: name
defp handler_name(name), do: inspect(name)
```

The `is_binary(name)` guard plus the catch-all clause is what keeps a
doctored blob whose handler map holds a non-binary value from raising - it
collects as an unknown name rather than escaping as an exception, and
`handler_name/1` normalizes it so the error arm's declared `[String.t()]`
stays true.

Every failure is collected in one round trip and returned sorted (decision
5) - not the first failure only, so a host learns the whole set of modules it
must load. `Keyword.replace_lazy/3` and `Keyword.fetch/2` leave an opts list
with no `:invoke_handlers` key untouched rather than inventing one, which
keeps `from_binary/1` a restorer rather than a normalizer.

`safe_decode/1` is a verbatim adaptation of `lib/statifier/chart.ex:162-181`
- same justification comment (adjusted to say "one literal five-tuple shape"
and to cite this module's own arms), same `@sobelow_skip ["Misc.BinToTerm"]`
immediately above it, same `rescue ArgumentError -> :error`.

#### 2. The moduledoc section
**File**: `lib/statifier/session/recording.ex`
**Changes**: add a `## The binary contract` section to the existing moduledoc
(after "Nothing here reads a clock", `:76-85`), covering: the envelope's five
slots; why the chart travels as a nested `Chart` blob rather than a compiled
term; why `entries` is written in append order; why handler modules cross as
strings; and the planning-equivalence limit decision 5 records. Cite ADR-0056
and ADR-0034 by number rather than re-arguing them. Match the file's existing
typography (hyphens, no em dashes) - it is already ASCII-only.

Every new public function needs its own `@doc` - `.doctor.exs` holds 100%
thresholds on every axis, so an undocumented public function is a gate
failure, not a style note.

#### 3. Tests
**File**: `test/statifier/session/recording_test.exs`
**Changes**: add a helper that builds an **identified** machine (the existing
`compile!/0` at `:9-24` deliberately does not - it bypasses
`Statifier.compile/2`, so it carries no `identity` and no `source`, and is
exactly the fixture the `:unidentified_chart` test wants):

```elixir
defp compile_identified!(opts \\ []) do
  {:ok, machine} = Statifier.compile(@xml, opts)
  machine
end
```

Hoist the existing inline XML into a module attribute so both helpers share
it. Add a `TestHandler` module for the handler tests, modeled on
`test/statifier/replay_test.exs:14-27`.

New describe blocks, each test carrying a one-line sabotage comment above it
per `docs/testing.md` (name the mutation and the expected reddening; use
`# sabotage: n/a - <reason>` only for structural assertions no single `lib/`
mutation would flip, following `test/statifier/chart_test.exs:132-135` and
`:309-313`):

1. **Live round trip** - `Session.start_link(machine, record: true)` over an
   identified chart, drive it, `Session.recording/1`, `Replay.run/1` on the
   live recording; then `to_binary/1`, `from_binary/1`, `Replay.run/1` on
   the decoded one; assert both results' `:stream` and
   `:machine_state.configuration` (and `:status`) are equal. This is the
   central test.
2. **Append-order stability** - a recording with several distinct entries
   round trips such that `Recording.entries(decoded) ==
   Recording.entries(original)`, in order.
3. **`:unidentified_chart` refusal** - `Recording.new(compile!())` (the
   raw-pipeline machine) gives `{:error, :unidentified_chart}` from
   `to_binary/1`.
4. **Wrapped chart identity mismatch** - hand-build a nested chart blob whose
   stored identity is another chart's (the
   `test/statifier/chart_test.exs:283-295` fixture pattern), wrap it in a
   `{:statifier_recording, Recording.format_version(), chart_blob, opts,
   entries}` envelope, and assert
   `{:error, {:chart, {:identity_mismatch, _, _}}}`.
5. **Wrapped chart version mismatch** - a nested blob whose *chart* version
   is bumped returns `{:error, {:chart, {:unsupported_format_version, 99}}}`,
   distinct from the recording envelope's own arm. This is the test that
   proves the two version namespaces stay independently bumpable.
6. **`:unknown_handler_modules`** - hand-build an envelope whose
   `:invoke_handlers` map names a module string that exists nowhere
   (`"Elixir.Statifier.NoSuchHandler.#{unique}"`), assert
   `{:error, {:unknown_handler_modules, names}}` with `names` sorted and
   carrying **every** unknown name, not just the first.
7. **Handler round trip** - a recording whose `:invoke_handlers` names
   `TestHandler` decodes back to the module **atom**, and
   `Recording.opts(decoded)[:invoke_handlers]` equals the original map.
8. **Recording envelope version mismatch** - a `{:statifier_recording, 99,
   ...}` blob returns `{:error, {:unsupported_format_version, 99}}` unwrapped.
9. **Foreign / malformed blobs** - a foreign `term_to_binary` blob, random
   bytes (must not raise), and a well-formed envelope whose `chart_blob` slot
   is not a binary, all return `{:error, :not_a_statifier_blob}`.
10. **`format_version/0` pin** - it equals the version tag `to_binary/1`
    actually writes, read back with a raw `binary_to_term`.
11. **A non-binary handler value in a doctored blob** - an envelope whose
    `:invoke_handlers` map holds `%{"t" => 42}` returns
    `{:error, {:unknown_handler_modules, ["42"]}}` rather than raising, which
    pins `handler_name/1` and `existing_atom/1`'s catch-all clause.
12. **No compiled term in the blob** -
    `:binary.match(blob, "Predicator.Compiled") == :nomatch`, mirroring
    `test/statifier/chart_test.exs:136-149`.

Every test asserting `lib/` behavior must be sabotaged for real: break the
code it covers, confirm red, revert, and write the mutation into the comment.
A sabotage comment written without running the mutation is the defect
`docs/testing.md` is about.

#### 4. Changelog fragment
**File**: `changelog.d/st-hz2a.md` (new)
**Changes**: this qualifies under `changelog.d/README.md` - it is a public
API addition a caller can see, and a capability v1 never had.

```markdown
### Added

- `Statifier.Session.Recording.to_binary/1` and `from_binary/1` give a
  recording a versioned binary contract that nests the chart's own blob and
  recompiles it on load, never a compiled term.
```

Keep it to the one line the README's format rules allow; `format_version/0`
is an accessory of the pair, not a separate user-facing capability.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix quality --profile loop` while
      iterating; a loop-profile or scoped green does not satisfy this phase).
- [x] `mix gate.verify` confirms the run was full, unprofiled, unscoped, and
      not `--skip`-ed.
- [x] The Sobelow stage passes with no `Misc.BinToTerm` finding, and the
      module carries exactly one real skip *attribute* -
      `grep -c '^  @sobelow_skip \["Misc.BinToTerm"\]'
      lib/statifier/session/recording.ex` is 1. Count the attribute, not the
      substring: the justification comment above it mentions `@sobelow_skip`
      by name (as it does in `lib/statifier/chart.ex`, where a bare
      `grep -rn "@sobelow_skip"` legitimately returns two lines), so a
      substring count would never go green for a correct implementation.
- [x] Dialyzer passes - specifically no opacity violation, which is what
      proves the codec is legal only on the owning module.
- [x] The coverage stage passes `coveralls.json`'s `minimum_coverage: 90`
      (decided by the full gate, not judged by eye), and
      `mix coveralls.html` shows every error arm of `from_binary/1` and both
      arms of `to_binary/1` covered.
- [x] `git diff --stat origin/main -- lib/statifier/replay.ex` is empty.
- [x] `mix quality --format json --report -` is available for a looped runner
      that needs to route on stage results.
- [x] `changelog.d/st-hz2a.md` exists and `CHANGELOG.md` is unmodified.
- [x] No conformance results move, so `mix test.regression` /
      `mix test.baseline add` are not expected to change
      `test/passing_tests.json` - run `mix test.regression` anyway and
      confirm it is green and the file is untouched.

#### Manual Verification:
- [ ] **Spec conformance**: confirm no W3C Appendix D-named procedure was
      touched (`select_transitions`, `microstep`, `enter_states`, and the
      rest are all absent from the diff) - the codec is session-boundary work
      with no pseudocode counterpart, so there is no deviation to justify
      under ADR-0002.
- [ ] Each sabotage comment was actually produced by running its mutation and
      seeing red, not written from inference.
- [ ] The moduledoc section reads as an explanation of the artifact a host
      persists, not a restatement of the code beneath it.
- [ ] `to_binary/1` on a recording over an unidentified chart refuses, while
      recording and replaying that same session in memory still works
      unchanged - persistence is the only thing refused.
- [ ] No regressions in related features (`Replay`, `Session` recording,
      `subscribe(catch_up: true)`).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Document the recording artifact in docs/persistence.md

### Overview

`docs/persistence.md` is the concern-scoped doc where ADR-0052's hazard and
migration stories live; ADR-0056's Consequences direct a recording section to
the implementing branch. Docs only.

### Changes Required:

#### 1. A recording section
**File**: `docs/persistence.md`
**Changes**: add `## Persisting a recording` after `## Persisting the chart
itself` (`:136-169`) and before `## Explicitly not the *compiled* chart`
(`:169`), so the "never a compiled term" section that follows covers all
three artifacts rather than only two. Extend `## What it costs` (`:196-215`)
with the recording's own share of the recompile-on-load cost.

The section covers, in the voice the file already uses:

- What a recording blob carries: the nested chart blob, the normalized
  session opts, and the entries in append order - and what it does *not*
  carry (the compiled `%Machine{}`, any pid/ref/port/fun, any clock reading).
- The compose-two-lines example the chart section already models:

  ```elixir
  {:ok, recording} = Statifier.Session.Recording.from_binary(blob)
  {:ok, result} = Statifier.Replay.run(recording)
  ```

- **The handler-provisioning requirement**: the decoding host must have
  loaded its `:invoke_handlers` modules before decoding, because
  `String.to_existing_atom/1` cannot conjure an atom for a module that is not
  loaded. `{:error, {:unknown_handler_modules, names}}` is the actionable
  error that says so, and it names every missing module at once.
- **The planning-equivalence limit**: a decoded recording replays to the
  recorded stream only where the handlers' *planning* callbacks are
  equivalent to the recorded run's. `perform/2` is never called by replay, so
  it needs no equivalence at all. This is an accepted environmental limit,
  the same class as ADR-0034's OTP `MapSet`-iteration caveat, not a defect.
- **Host-supplied atoms in payloads** remain the host's own `:safe`
  obligation - the codec neither scans for them nor translates them.
- The error vocabulary in the order `from_binary/1` checks it:
  `:not_a_statifier_blob`, `{:unsupported_format_version, version}`,
  `{:chart, reason}` (carrying `Statifier.Chart.from_binary/1`'s own tuple
  unflattened), `{:unknown_handler_modules, names}`; and `to_binary/1`'s one
  refusal, `{:error, :unidentified_chart}`.
- A pointer to the deferred "read a blob's identity without recompiling"
  answer the file already gives for positions: store
  `Identity.to_binary/1` beside each blob at write time.

Match the file's existing typography and its ADR-link style
(`[ADR-0052 decision 3](adr/0052-chart-identity-and-position-serialization.md)`).

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` is green.
- [ ] `mix gate.verify` confirms a full, unscoped run.
- [ ] Every relative link the new section adds resolves
      (`ls docs/adr/0056-recording-identity-and-serialization.md` and the
      ADR-0034/ADR-0052 targets it cites).
- [ ] Every module and function name the section names exists
      (`grep -n "def to_binary\|def from_binary\|def format_version"
      lib/statifier/session/recording.ex`).
- [ ] `git diff --stat` shows only `docs/`.

#### Manual Verification:
- [ ] The new section reads as guidance to a host deciding what to persist,
      not as API reference duplicated from the moduledoc.
- [ ] The elixir example compiles conceptually against the real signatures
      (paste it into `iex -S mix` over a real recording once).
- [ ] The `## Explicitly not the *compiled* chart` section that follows still
      reads correctly now that three artifacts precede it rather than two.
- [ ] No Appendix D-named function was touched (this phase changes no `lib/`
      file - confirm by `git diff --stat`).
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Testing Strategy

### Unit Tests:

All of it lands in `test/statifier/session/recording_test.exs`, which mirrors
`lib/statifier/session/recording.ex` one-to-one per the project's suite
layout. The twelve cases in Phase 2 are the coverage plan; the five ADR-0056
explicitly owes are cases 1, 3, 4, 6, and 2.

Key edge cases:

- A recording over an **unidentified** chart: refused at encode, unchanged in
  memory.
- A blob whose nested chart's identity no longer matches its source, and one
  whose nested chart's *version* is unreadable - the two must produce
  distinguishable errors, both wrapped in `{:chart, _}`.
- Multiple unknown handler modules at once: all collected, sorted, one round
  trip.
- An opts list carrying `:invoke_handlers` as `%{}` (the `new/2` default) -
  encodes and decodes to `%{}` with no error.
- Random bytes and foreign blobs must return an error, never raise -
  `safe_decode/1`'s `rescue` is what makes that true.
- Entries containing every one of the six `entry()` variants, so append-order
  stability is asserted over a heterogeneous list rather than a uniform one.

Every test asserting `lib/` behavior carries its sabotage line, produced by
actually running the mutation. Structural assertions (the no-compiled-term
check, the raw-envelope shape check) state `# sabotage: n/a - <reason>`.

### Manual Testing Steps:

1. In `iex -S mix`, `Statifier.compile/2` a small chart, start a session with
   `record: true`, drive a couple of events, and `Session.recording/1`.
2. `Recording.to_binary/1` it; confirm `byte_size/1` is on the order of the
   source plus entries, not the order of `:erlang.term_to_binary(machine)`.
3. `Recording.from_binary/1` the blob and `Statifier.Replay.run/1` it;
   compare the result against `Replay.run/1` on the live recording.
4. Build a chart with a `:invoke_handlers` entry, encode, then decode in a
   **fresh** `iex` session that has not loaded the handler module (define it
   in a file that is not compiled into the project) and confirm
   `{:error, {:unknown_handler_modules, _}}` rather than
   `:not_a_statifier_blob`. This is the single behavior that most justifies
   ADR-0056 decision 5, and it is the one a unit test can only approximate.
5. Confirm a recording over a `Statifier.Compiler.compile/1`-built machine
   still records and replays in memory while `to_binary/1` refuses it.

## Open Questions Recorded

No human is available to settle these during planning. Each carries the
default this plan implements, so nothing blocks; each is worth a human's
confirmation before or during review.

**OQ-1 - the order of nested-chart decode versus handler resolution.**
ADR-0056 decision 4 fixes only that the *envelope version* is checked before
the nested chart is touched. It does not say whether handler-string
resolution runs before or after the chart decode. **Default implemented:
chart first, handlers second.** Rationale: it matches the envelope's own
field order, it inherits `Chart.from_binary/1`'s whole verification chain
before anything host-specific is consulted, and a blob whose chart no longer
matches is broken regardless of which handler modules happen to be loaded.
Tradeoff: chart-first pays a full `Statifier.compile/2` before discovering a
missing handler module, so a host retrying a decode after loading its
handlers recompiles twice. Handler-first would fail faster in that one case
at the cost of reporting a handler problem for a blob that is not loadable at
all. If a host ever reports the double-compile as a real cost, this is a
one-line reorder inside the `with`, observable only in which error arrives
first.

**OQ-2 - `:invoke_handlers` values that are not atoms.** `new/2` does not
validate the map's values, so a host could put a non-atom there and reach
`Atom.to_string/1` at encode. **Default implemented: no defensive clause -
`Atom.to_string/1` raises `FunctionClauseError` on a non-atom**, which is a
caller error surfaced at its source rather than a blob error surfaced later.
Tradeoff: an `{:error, :invalid_handler_map}` arm would be gentler, but it
widens `to_binary/1`'s public error vocabulary beyond the one arm ADR-0056's
Consequences specify (`{:error, :unidentified_chart}`), and widening a
documented ADR return type is a direction-level call, not a plan-level one.
If it should be an error arm instead, that is an ADR-0056 amendment.

**OQ-3 (deferred by ADR-0056, not this plan's to answer)** - whether a host
needs to read a blob's identity *without* paying the recompile. ADR-0056
defers this until a consumer asks, and points hosts at storing
`Identity.to_binary/1` beside each blob at write time. Phase 3 documents that
workaround; nothing in this plan implements a recompile-free identity read.

**OQ-4 (deferred by ADR-0056, not this plan's to answer)** - whether handler
planning-callback equivalence across builds ever needs a checkable
fingerprint. ADR-0056 decision 5 records the limit instead of solving it, on
the grounds that nothing today could consume the answer. Phase 3 documents
the limit; nothing in this plan computes a fingerprint.

## References

- Source document: `docs/adr/0056-recording-identity-and-serialization.md`
  (the accepted specification this plan implements)
- Related ADRs: `docs/adr/0052-chart-identity-and-position-serialization.md`
  (decision 8 filing this work; the st-i7y7 chart-blob amendment nested
  here), `docs/adr/0034-*.md` (the whole-`%Machine{}` embedding preserved),
  `docs/adr/0051-invoke-handlers-are-registered-per-session.md`
  (`:invoke_handlers` as per-session module atoms),
  `docs/adr/0049-*.md` (the recording as a public catch-up artifact),
  `docs/adr/0048-*.md` (the `entry()` widening precedent),
  `docs/adr/0014-*.md` (item 2: no compiled predicator term in any blob),
  `docs/adr/0003-*.md` (why the codec is not an effect),
  `docs/adr/0011-*.md` (the gate-guard ledger, deliberately not triggered),
  `docs/adr/0018-*.md` (no bead ids in code comments)
- Similar implementation: `lib/statifier/chart.ex:1-182` and
  `test/statifier/chart_test.exs:1-323` (the closest template);
  `lib/statifier/position.ex:1-80`;
  `lib/statifier/machine/identity.ex:112-131` (the `safe_decode/1` shape)
- Concern doc: `docs/persistence.md:120-215`
- Boundary being preserved: `lib/statifier/session/recording.ex:105-109`,
  `lib/statifier/replay.ex:203-231`
- Testing conventions: `docs/testing.md` (sabotage), `CLAUDE.md`
- Bead: `st-hz2a`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The ADR-0052 status line reads as one sentence a reviewer can follow,
      and its clause ordering matches ADR-0054's precedent.
- [ ] No Appendix D-named function was touched (this phase changes no
      `lib/` file at all, so the project's spec-conformance criterion is
      satisfied vacuously - confirm by `git diff --stat` showing only
      `docs/`).
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. This phase touches no Elixir
code, so per CLAUDE.md's authority table it may commit on review of the diff
alone - but run the full gate anyway, since ADR guard and doc stages read
`docs/`. In interactive execution, pause here for the human to confirm the
manual testing before moving to the next phase. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement
automatically (via `/wurk:commit --auto`), and Manual Verification items are
deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] **Spec conformance**: confirm no W3C Appendix D-named procedure was
      touched (`select_transitions`, `microstep`, `enter_states`, and the
      rest are all absent from the diff) - the codec is session-boundary work
      with no pseudocode counterpart, so there is no deviation to justify
      under ADR-0002.
- [ ] Each sabotage comment was actually produced by running its mutation and
      seeing red, not written from inference.
- [ ] The moduledoc section reads as an explanation of the artifact a host
      persists, not a restatement of the code beneath it.
- [ ] `to_binary/1` on a recording over an unidentified chart refuses, while
      recording and replaying that same session in memory still works
      unchanged - persistence is the only thing refused.
- [ ] No regressions in related features (`Replay`, `Session` recording,
      `subscribe(catch_up: true)`).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---
