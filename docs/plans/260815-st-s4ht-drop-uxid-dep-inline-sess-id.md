# Drop the uxid dependency; mint the `sess_` id inline - Implementation Plan

## Overview

Implements the 2026-08-15 st-mvna amendment to
[ADR-0008](../adr/0008-uxid-for-identifiers.md): the `uxid` dependency leaves
`mix.exs`, `MachineState.new/2` mints the session id inline in the same
timestamp-then-randomness layout, the ADR guard's ADR-0008 finding message is
reworded around the format instead of the library, and prose that reads
"`sess_` UXID" becomes "`sess_` id". Beads issue: `st-s4ht`.

Every design choice below is already settled by that amendment. This plan
cites it; it re-decides nothing. In particular the monotonicity question
(ADR-0008 lines 187-199) and the id layout (lines 176-185) are closed.

## Current State Analysis

`UXID.generate!` has exactly one call site left in the library:

```elixir
# lib/statifier/machine_state.ex:423
session_id = Keyword.get_lazy(opts, :session_id, fn -> UXID.generate!(prefix: "sess") end)
```

Invoke ids (`invoke_counter`) and send ids (`send_counter`) are already
`%MachineState{}` counters and are permanently out of reach - ADR-0003 forbids
the pure core a clock or a CSPRNG, and ADR-0008's invoke amendment plus
ADR-0035 already decided both. Nothing else in `lib/` calls `UXID.`.

`{:uxid, "~> 2.9"}` sits at `mix.exs:43` among the runtime deps, with a
matching `mix.lock` entry. v1 (`../statifier/mix.exs:22`) carries
`{:uxid, "~> 2.1"}`, so this is a real v1-to-v2 difference in the dependency
tree an embedder inherits.

The ADR guard's `@uxid_adhoc_pattern`
(`lib/mix/statifier/adr_guard.ex:106-109`) matches `:crypto.strong_rand_bytes(`
and its scope predicate is `@core_prefix` = `"lib/statifier/"`, so
`machine_state.ex` is in scope and the new generator will trip it unless the
site carries an `@escape_pattern` citation (`ADR-0\d{3}`, on the flagged line
or the line directly above it - `adr_guard.ex:111`). The finding message
(`adr_guard.ex:295`) reads "identifier generated ad hoc; ADR-0008 makes
generated IDs UXIDs", which stops being true once the library is gone.

Uppercase `UXID` also appears as prose in nine `lib/` files and two `docs/`
files (enumerated per phase below).

### Key Discoveries:

- **The single call site**: `lib/statifier/machine_state.ex:423`, inside
  `Keyword.get_lazy/3` - already an injection seam, already outside the replay
  boundary (ADR-0029 records the session id as an input).
- **The guard clears on a citation, not on the reword**:
  `lib/mix/statifier/adr_guard.ex:111` (`@escape_pattern`) and
  `adr_guard.ex:289-297` (`uxid_findings/1`). The reword is a correctness fix
  to the message, not what keeps the stage green.
- **The citation clears exactly one line.** `AdrGuard.cited?/1`
  (`lib/mix/statifier/adr_guard.ex:433-436`) reads `entry.text` and
  `entry.previous` - a comment block above a `defp` does not reach a call two
  lines below it. Phase 2 places a one-line citation immediately above the
  `:crypto.strong_rand_bytes(` line for this reason.
- **ADR-0018's bead-ID check does not clear on an ADR citation.**
  `bead_id_findings/2` (`adr_guard.ex:117,304-318`) flags any `st-<id>` token
  in a `lib/` or `test/` comment or doc string and clears only on
  `ADR-0018-exempt` (`@bead_escape_pattern`, `adr_guard.ex:120`); the general
  `ADR-0\d{3}|deviation` escape is deliberately not wired to it. So no comment
  or sabotage note this plan adds may name `st-s4ht` or `st-mvna` - the bead
  attribution goes in the commit message.
- **`adr_guard.ex` itself is out of the check's scope** - it lives under
  `lib/mix/`, and `uxid_findings/1` is scoped to `lib/statifier/`. Editing the
  pattern file cannot trip the pattern.
- **The gate guard will not demand a ledger entry for this `mix.exs` edit**:
  `Mix.Statifier.GateGuard`'s `@mix_exs_pattern`
  (`lib/mix/statifier/gate_guard.ex:43`) matches only
  `test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir|:sobelow|:doctor`.
  `{:uxid, "~> 2.9"},` matches none of them, and a deletion adds no line for
  the guard to read. **If it fires anyway, stop and report** - per
  `.claude/wurk/commit.md`, writing the ADR-0011 ledger entry is a human's
  call, never the implementing session's.
- **`area:build` is `lands_alone`** (`.claude/wurk.json`
  `beads.areas.lands_alone`). That is a cross-branch collision rule, not an
  intra-branch one: no *other* branch may be batched alongside this bead while
  it holds `area:build`. Within this branch it means the `mix.exs`/`mix.lock`
  edit is confined to one phase that touches nothing else, so the build-visible
  change is one reviewable, one-file-pair commit.
- **The layout is verified**: `<<System.os_time(:millisecond)::48,
  :crypto.strong_rand_bytes(10)::binary>>` is 16 bytes, which Crockford base32
  encodes to exactly 26 characters with no padding, giving
  `sess_` + 26 = a 31-character id with no hyphens, e.g.
  `sess_06g0f9zrd45ecxyrq6heq9wm5r`. Because base32 over a fixed-width
  big-endian bit string is order-preserving and the lowercase Crockford
  alphabet (`0123456789abcdefghjkmnpqrstvwxyz`) is itself in ASCII order,
  a later millisecond always sorts lexicographically later. Both properties
  were checked by running the encoder before this plan was written.
- **Elixir ships no Crockford encoder**, but `Base.hex_encode32/2` uses
  `0-9a-v`, which is the same 32 symbols in the same order as Crockford's
  `0-9` + `abcdefghjkmnpqrstvwxyz` differ only by symbol choice. A 32-entry
  character translation over the `hex_encode32` output is therefore exact and
  order-preserving, and needs no bit-twiddling of our own.

## Desired End State

`grep -rn UXID lib/ mix.exs` returns nothing. `mix.exs` and `mix.lock` carry
no `uxid` entry. `MachineState.new/2`'s default `:session_id` is a `sess_`
id whose 26-character body is lowercase Crockford base32, hyphen-free, and
sorts by creation millisecond. The ADR guard still flags an uncited
`:crypto.strong_rand_bytes/1` under `lib/statifier/`, with a message that
describes the rule rather than the departed library. A bare `mix quality` is
green, including the `ADR guard` stage over the branch's whole diff.
`docs/research/` and `docs/adr/` are untouched.

## What We're NOT Doing

- **Not touching `docs/research/`.** Dated snapshots of what was true when
  written; never retro-edited.
- **Not touching `docs/adr/`.** st-mvna already amended ADR-0008 on this
  branch (`d24f91a`); re-amending it is out of scope, and the amendment's
  historical framing (which names UXID as the library that was dropped) is
  supposed to keep naming it.
- **Not touching `docs/plans/`.** Prior plans are the same kind of dated
  snapshot as research documents; several of them describe the invoke id as a
  UXID because that is what the plan said at the time.
- **Not touching `docs/workflow.md:69`** ("Predicator/UXID upstream candidates
  get an `upstream` label"). It is a sentence about which upstream projects get
  a bead label, not a claim about the session id's format, so the bead's
  acceptance criterion ("prose in `lib/` and `docs/` no longer calls the
  session id a UXID") does not reach it, and it is outside the bead's
  enumerated scope. Whether `uxid` is still an upstream this project sweeps is
  a tracker question, not this bead's.
- **Not changing the guard's check id** `"adr-0008-uxid"`. Two tests assert on
  it (`test/mix/statifier/adr_guard_test.exs:135,143`), the ADR's own filename
  is `0008-uxid-for-identifiers.md`, and the id is lowercase so it does not
  affect the `grep -rn UXID` acceptance criterion. Renaming it would be churn
  with a test cost and no acceptance gain.
- **Not making send or invoke ids anything other than the counters they are.**
  ADR-0003 forbids it; ADR-0008's invoke amendment and ADR-0035 already decided
  it.
- **Not extracting a `Statifier.Identifier` module.** ADR-0008's amendment says
  `MachineState.new/2` "mints the session id inline"; a private helper in that
  module is what "inline" means here, and a public module would create a new
  API surface the record did not ask for.
- **Not adding a monotonic-within-millisecond guarantee.** ADR-0008 lines
  187-199 settled this: the engine never had it (UXID's monotonic mode is
  opt-in and was never enabled), nothing in `lib/` sorts a session id, and
  ties within one millisecond stay unordered exactly as before.

## Implementation Approach

Four commits, in an order forced by two mechanical facts.

**The generator must carry its ADR-0008 citation in its own commit**, because
the ADR guard diffs the branch against its merge-base with `origin/main` and
would otherwise flag the added `:crypto.strong_rand_bytes(` line on every
subsequent run. The reword lands first, with the guard-tooling prose, so the
message the stage would print is already accurate by the time a citation is
being written against it - this is the sequencing the bead's design note
requires ("the guard reword and the citation comment must land with or before
the generator").

**The dependency cannot leave before its last call site does**, or the build
breaks on an undefined module. So `mix.exs`/`mix.lock` follow the generator
immediately, rather than trailing the prose sweep - an unused-but-declared
dependency is a state nobody should be able to bisect into for longer than one
commit.

Prose is last because it is the only phase whose diff cannot affect the gate,
and doing it last means it can sweep whatever `grep -rn UXID lib/` still
returns rather than guessing at the set up front.

---

## Phase 1: Reword the ADR-0008 guard finding and its gate-tooling prose

### Overview

Make the ADR guard describe the rule (no ad-hoc id minting outside ADR-0008's
formats) rather than the library that used to implement it. The check's
substance, scope, pattern, escape hatch, and check id are all unchanged; only
strings move. No behavior change, so the stage keeps enforcing exactly what it
enforced before.

### Changes Required:

#### 1. The finding message

**File**: `lib/mix/statifier/adr_guard.ex` (around line 295, in
`uxid_findings/1`)
**Changes**: reword the message.

```elixir
  # `session.ex` is in scope here, unlike the effects check: it is exactly where
  # session IDs are generated, so it is where an ad-hoc ID would appear.
  defp uxid_findings(files) do
    pattern_findings(
      files,
      @uxid_adhoc_pattern,
      "adr-0008-uxid",
      &String.starts_with?(&1, @core_prefix),
      "identifier generated ad hoc; ADR-0008 fixes the format of generated IDs"
    )
  end
```

#### 2. Gate-tooling moduledoc prose

**Files**: `lib/mix/statifier/adr_guard.ex` (moduledoc, around lines 6-7),
`lib/mix/tasks/adr.check.ex` (moduledoc, around line 7),
`lib/mix/statifier/adr_judge.ex` (around line 96)
**Changes**: each reads `ADR-0008 (UXIDs for identifiers)`; each becomes
`ADR-0008 (generated identifier formats)`. These are the only three uppercase
`UXID` tokens under `lib/mix/`.

#### 3. Test describe block

**File**: `test/mix/statifier/adr_guard_test.exs` (line 124)
**Changes**: `describe "ADR-0008 - UXIDs for identifiers"` becomes
`describe "ADR-0008 - generated identifier formats"`. The two tests inside are
unchanged - they assert on the check id `"adr-0008-uxid"`, not on the message,
and their existing sabotage notes (lines 125-126 and 141) stay as written.

**Sabotage discipline for this phase**: no new test and no changed assertion,
so no new `# sabotage:` note is owed. Renaming a `describe` string changes no
`lib/` behavior claim. Do not add a note for it and do not rewrite the two
existing ones.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` while iterating (never as the phase gate).
- [x] Full `mix quality` is green, including the `ADR guard` stage.
- [x] `grep -rn UXID lib/mix/` returns nothing.
- [x] `grep -rn 'adr-0008-uxid' lib/ test/` still returns the definition and
      the two assertions - the check id did not move.
- [x] `git diff --name-only` for this phase lists no file under
      `lib/statifier/`, so the ADR guard's own scope predicate is not
      exercised by this diff.

#### Manual Verification:

- [ ] The reworded message still reads as an instruction to the person who
      trips it: it names the ADR and says what the ADR requires.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: Mint the `sess_` id inline in `MachineState.new/2`

### Overview

Replace the single `UXID.generate!` call with a private generator producing the
layout ADR-0008's amendment specifies, carrying the citation comment the guard
requires. The `uxid` dependency stays declared through this phase - unused but
present - so the phase is independently green.

### Changes Required:

#### 1. The generator

**File**: `lib/statifier/machine_state.ex`
**Changes**: replace the `UXID.generate!` default at line 423 and add two
private helpers plus one module attribute.

**Two guard constraints shape the comment, and both are easy to get wrong:**

1. **The citation must be on the line immediately above the flagged line.**
   `AdrGuard.cited?/1` (`lib/mix/statifier/adr_guard.ex:433-436`) checks
   `entry.text` and `entry.previous` only - one line, not a block. A citation
   block sitting above the `defp` line does **not** clear a
   `:crypto.strong_rand_bytes(` call two lines down. So the crypto call goes
   on its own line inside the body with a one-line `ADR-0008` comment directly
   above it. The longer explanatory block can sit above the `defp`, where it
   reads well and clears nothing - that is fine, as long as the one-liner is
   also there.
2. **No bead ID anywhere in the comment.** ADR-0018's check
   (`bead_id_findings/2`, `adr_guard.ex:117,304-318`) flags any `st-<id>`
   token in a `lib/` comment or doc string and clears **only** on an
   `ADR-0018-exempt` marker - the `ADR-0\d{3}` escape does not reach it. So
   cite "ADR-0008 (2026-08-15 amendment)" and never "st-mvna". The bead
   attribution belongs in the commit message, which is exactly what ADR-0018
   says. The same rule applies to every comment and test note this plan adds.

```elixir
  # Crockford base32's alphabet in `Base.hex_encode32/2`'s symbol order, so a
  # 32-entry character translation is exact and order-preserving. Crockford
  # over a fixed-width big-endian bit string keeps lexicographic order, which
  # is what makes a `sess_` id sort by creation millisecond.
  @hex32_alphabet ~c"0123456789abcdefghijklmnopqrstuv"
  @crockford_alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"

  # ...

  @spec new(machine :: Machine.t(), opts :: keyword()) :: t()
  def new(%Machine{} = machine, opts \\ []) do
    session_id = Keyword.get_lazy(opts, :session_id, &generate_session_id/0)
    # ... unchanged ...
  end

  # ADR-0008 (2026-08-15 amendment): the `sess_` id is minted here rather than
  # by a library - 48-bit big-endian millisecond timestamp then 80 bits of
  # CSPRNG output, Crockford base32. This is the one generation site outside
  # the pure core, exactly where the dependency's call sat; ADR-0003 is
  # untouched, and entropy is kept at full strength because session ids must be
  # unique *across* sessions (the ADR-0027 registry and parent/child routing
  # depend on it).
  defp generate_session_id do
    # ADR-0008: 48-bit millisecond timestamp, then 80 bits of entropy.
    body = <<System.os_time(:millisecond)::48, :crypto.strong_rand_bytes(10)::binary>>
    "sess_" <> crockford32(body)
  end

  defp crockford32(bytes) do
    bytes
    |> Base.hex_encode32(case: :lower, padding: false)
    |> String.to_charlist()
    |> Enum.map(fn char -> Enum.at(@crockford_alphabet, index_of(char)) end)
    |> List.to_string()
  end
```

The exact shape of the translation is the implementer's call as long as it is
total over the 32 symbols and order-preserving; a compile-time map built from
`Enum.zip(@hex32_alphabet, @crockford_alphabet)` is the straightforward form
and avoids a linear `index_of/1` per character. Keep `crockford32/1` and
`generate_session_id/0` private - see "What We're NOT Doing" on why no public
module.

#### 2. The `new/2` moduledoc

**File**: `lib/statifier/machine_state.ex` (around line 408)
**Changes**: "`:session_id` (default a freshly generated `sess_` UXID,
ADR-0008)" becomes "`:session_id` (default a freshly generated `sess_` id,
ADR-0008)". The `invoke_counter` and `send_counter` passages around lines
144-180 also name UXID; those are Phase 4's, not this phase's, because they
argue about the pure core rather than about this constructor.

#### 3. Tests

**File**: `test/statifier/machine_state_test.exs`
**Changes**: re-point the existing sabotage note at lines 291-292, which names
`UXID.generate!(prefix: "sess")`, at the new generator; and add coverage for
the format properties the ADR names.

Re-pointed note, above the existing "carries the sess_ prefix" test:

```elixir
    # sabotage: `generate_session_id/0`'s "sess_" literal is changed to
    # "usr_" -> the prefix assertion reddens.
```

Two new tests, each with its own note:

```elixir
    # sabotage: `crockford32/1` is changed to `Base.encode32/2` (uppercase
    # RFC 4648, which emits `A-Z2-7`) -> the alphabet assertion reddens on
    # the uppercase letters.
    test "the generated :session_id body is 26 hyphen-free lowercase Crockford chars (ADR-0008)" do
      "sess_" <> body = new_machine_state().datamodel["_sessionid"]

      assert String.length(body) == 26
      refute String.contains?(body, "-")
      assert body =~ ~r/\A[0123456789abcdefghjkmnpqrstvwxyz]{26}\z/
    end

    # sabotage: the `System.os_time(:millisecond)::48` prefix in
    # `generate_session_id/0` is replaced with a constant `0::48` -> the two
    # ids no longer order by creation time and the comparison reddens.
    test "generated :session_ids sort by creation millisecond (ADR-0008)" do
      earlier = new_machine_state().datamodel["_sessionid"]
      Process.sleep(2)
      later = new_machine_state().datamodel["_sessionid"]

      assert earlier < later
      assert earlier != later
    end
```

The 2 ms sleep is deliberate rather than incidental: it guarantees a distinct
`System.os_time(:millisecond)` value, so the ordering assertion is
deterministic instead of racing the clock. Within-millisecond ordering is not
asserted anywhere, because ADR-0008 lines 187-199 settled that the engine never
had it.

**Sabotage discipline for this phase**: this phase carries the only new tests
in the plan. Run the full protocol in `.claude/wurk/implement.md` for each of
the two new tests - break the `lib/` code, confirm red for the right reason,
revert, confirm green - and re-verify the re-pointed note on the existing
prefix test against the new generator rather than trusting the old wording.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` while iterating (never as the phase gate).
- [x] Full `mix quality` is green, including the `ADR guard` stage - which is
      the mechanical proof the citation comment cleared
      `@uxid_adhoc_pattern` on the branch's own diff, and that no
      `adr-0018-bead-id` finding fired on a bead ID in a new comment.
- [x] `grep -rn 'UXID\.' lib/` returns nothing: the last call site is gone.
- [x] `grep -n 'st-' lib/statifier/machine_state.ex` returns no bead ID - the
      ADR-0018 check clears only on `ADR-0018-exempt`, never on an ADR
      citation, so the comment must simply not contain one.
- [x] `mix test test/statifier/machine_state_test.exs` is green, with the two
      new tests present.
- [x] Every new test carries a `# sabotage:` note (`/wurk:commit` refuses
      otherwise).

#### Manual Verification:

- [ ] Spec-conformance judgment for `lib/statifier/`: this phase touches no
      Appendix D function. Confirm from the diff that `main_event_loop`,
      `microstep`, `enter_states`, `exit_states` and the rest are untouched,
      so the Appendix D line-for-line rule is satisfied vacuously rather than
      by inspection. No deviation is introduced, mechanical or otherwise.
- [ ] Eyeball a handful of generated ids in IEx: `sess_` prefix, 31 characters
      total, no hyphen, double-clicking selects the whole token.
- [ ] The generator still sits outside any fold - `new/2` only, never reached
      from `main_event_loop/1` - so ADR-0003's core contract is unchanged.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: Drop the `uxid` dependency (`area:build`)

### Overview

Remove `{:uxid, "~> 2.9"}` and its lock entry. Nothing calls it after Phase 2,
so this phase is a two-file deletion plus the changelog fragment. It touches
no `lib/` and no `test/` file, which is what `area:build`'s `lands_alone`
status wants of it.

### Changes Required:

#### 1. The dependency

**File**: `mix.exs` (line 43)
**Changes**: delete the `{:uxid, "~> 2.9"},` line from `deps/0`. `predicator`
and `saxy` stay.

#### 2. The lockfile

**File**: `mix.lock`
**Changes**: regenerate with `mix deps.unlock uxid` (or `mix deps.get`), in the
same commit as the `mix.exs` edit - a lockfile that still pins a dependency
`mix.exs` no longer declares will fail an unused-lock check.

#### 3. Changelog fragment

**File**: `changelog.d/st-s4ht.md` (new)
**Changes**:

```markdown
### Removed

- Drops the `uxid` dependency. Session ids keep the same `sess_`-prefixed,
  hyphen-free, time-sortable format, so nothing that reads `_sessionid` needs
  to change.
```

See "Changelog decision" below for why this fragment is written at all, and
why it rides in this phase rather than another.

**Sabotage discipline for this phase**: no test changes, so no notes are owed.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` while iterating (never as the phase gate).
- [x] Full `mix quality` is green - compilation alone proves no call site
      survived Phase 2.
- [x] `grep -rn uxid mix.exs mix.lock` returns nothing.
- [x] `mix deps.get` is a no-op and leaves `mix.lock` unchanged.
- [x] The `Gate guard` stage does not fire. If it does, **stop and report**
      rather than writing a `docs/quality-gate-changes.md` entry - ADR-0011
      makes that a human's call.
- [x] `changelog.d/st-s4ht.md` exists.
- [x] `git diff --name-only` for this phase lists exactly `mix.exs`,
      `mix.lock`, and `changelog.d/st-s4ht.md` - nothing else. A `lib/` or
      `test/` file in this commit means the phase boundary leaked.
- [x] `mix deps.tree` no longer lists `uxid` anywhere.

#### Manual Verification:

- [ ] A fresh `rm -rf _build deps && mix deps.get && mix compile` succeeds, so
      the drop is real rather than masked by a warm build directory.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 4: Sweep the remaining "`sess_` UXID" prose

### Overview

The format is ADR-0008's, not the library's, so prose says so. Comments and
moduledocs only - no executable line changes in this phase.

### Changes Required:

#### 1. Moduledocs that call the session id a UXID

**Files and sites** (each replaces "UXID" with "id", keeping the surrounding
sentence):

- `lib/statifier/session.ex:40` - "generates a *fresh* `sess_` UXID"
- `lib/statifier/session.ex:221` - "never generates the `sess_` UXID itself"
- `lib/statifier/session.ex:238` - `@doc "This session's `sess_` UXID - ..."`
- `lib/statifier/session.ex:384` - "the `sess_` UXID this session registers
  under"
- `lib/statifier/supervisor.ex:22` - "registers under the `sess_` UXID"
- `lib/statifier/session/recording.ex:25` - "generate a fresh `sess_` UXID
  (ADR-0008)"
- `lib/statifier/evaluator/system_variables.ex:34` - "`_sessionid` stays the
  bare UXID" becomes "`_sessionid` stays the bare session id"

#### 2. Passages that argue *why a counter is not a UXID*

**Files**: `lib/statifier/machine_state.ex` (the `invoke_counter` passage
around lines 144-153 and the `send_counter` passage around lines 179-186),
`lib/statifier/interpreter.ex` (the `generate_invoke_id` comment around line
1419)
**Changes**: these are not "sess_ UXID" prose - they are the ADR-0003 argument
for why the *core's* ids are counters, and they name the library as the thing
that reads a clock and a CSPRNG. The argument is correct and stays; the
library's name goes, because after Phase 3 there is no such library to name.
Rewrite each occurrence to describe the mechanism instead: "a clock-and-CSPRNG
generator", "an entropy-based id", "minted with entropy". The ADR references
already in those passages (ADR-0003, ADR-0008, ADR-0012) stay exactly as they
are.

This is the decision that makes the bead's acceptance criterion mechanically
checkable: after this phase `grep -rn UXID lib/ mix.exs` returns nothing at
all, which satisfies "nothing outside an ADR-0008 citation" without anyone
having to adjudicate which surviving mentions count as citations.

#### 3. Project docs

**File**: `docs/architecture.md` (lines 147-150)
**Changes**: "the session id is a UXID: sortable, prefixed (`sess_`), and
stable per session" becomes a sentence about the format rather than the
library - sortable, prefixed `sess_`, stable per session, minted outside the
core. The following sentence's "UXID reads the wall clock and a CSPRNG" becomes
"an entropy-based id reads the wall clock and a CSPRNG". Both ADR links stay.

**File**: `docs/datamodel.md` (line 41)
**Changes**: "`_sessionid` (a UXID, stable for the session's lifetime)" becomes
"`_sessionid` (a `sess_` id, stable for the session's lifetime)".

Match each file's existing typography rather than converting it: these files
use hyphens and spaced hyphens as they stand, and a stray punctuation change
inside a prose commit reads as an accidental find-and-replace.

**Sabotage discipline for this phase**: no test changes, so no notes are owed.
If a doctest turns out to live inside one of the edited `@doc` blocks, its
assertion must not change; only surrounding prose may.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` while iterating (never as the phase gate).
- [x] Full `mix quality` is green, including Doctor (moduledoc coverage is
      unaffected - no `@doc` or `@moduledoc` is removed, only reworded).
- [x] `grep -rn UXID lib/ mix.exs docs/architecture.md docs/datamodel.md`
      returns nothing.
- [x] `git diff --stat` for this phase names no file under `docs/research/`,
      `docs/adr/`, or `docs/plans/`.

#### Manual Verification:

- [ ] Spec-conformance judgment for `lib/statifier/`: the diff touches comment
      and doc lines only. Confirm no Appendix D function body changed - the
      `generate_invoke_id` edit is the comment above it, not the function.
- [ ] Each rewritten "why a counter is not a UXID" passage still makes the
      ADR-0003 argument intact: a clock and a CSPRNG in the core would turn
      `(state, event) -> {state, [effect]}` into
      `(state, event, clock, entropy) -> ...` and break replay observably.
- [ ] `docs/architecture.md` and `docs/datamodel.md` read naturally rather than
      as mechanical substitutions.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Changelog decision

**Write one fragment, `changelog.d/st-s4ht.md`, under `### Removed`, in Phase
3.**

`changelog.d/README.md` narrows the rule while v2 is unreleased to "write a
fragment when v2 differs from v1", and `.claude/wurk/commit.md` step 1.6
repeats it. This bead clears that bar on exactly one of its four phases: v1
ships `{:uxid, "~> 2.1"}` (`../statifier/mix.exs:22`) and v2 will ship none, so
an embedder upgrading from v1 to v2 inherits a different dependency tree. That
is a difference someone who only ever calls the public API can observe -
in their own `mix.lock`, without reading a line of this library's source.

The other three phases get nothing, and that is the expected outcome rather
than an omission:

- The guard reword (Phase 1) is agent/gate tooling, which the README lists
  under "do not write a fragment for".
- The inline generator (Phase 2) is an internal refactor with no visible
  effect: the id keeps its `sess_` prefix, its hyphen-free body, its
  sortability, and its opacity to every consumer. ADR-0008's own Consequences
  bullet says so - "a `sess_` id is opaque to every consumer - compared,
  registered under, and embedded in routing strings, never parsed or decoded".
  No `### Changed` line is owed for a format that did not change.
- The prose sweep (Phase 4) is documentation, also on the README's exclusion
  list.

The fragment rides in Phase 3 because that is the commit that makes the
statement true.

## Testing Strategy

### Unit Tests:

- `test/statifier/machine_state_test.exs` - the two new format tests in Phase
  2 (Crockford alphabet, length, no hyphen; sort by creation millisecond) plus
  the existing `sess_` prefix test with its re-pointed sabotage note. Edge
  cases worth keeping in mind while writing them: a caller-supplied
  `:session_id` must still win over the generated default (already asserted at
  `machine_state_test.exs:281`), and the generated id must be distinct across
  two `new/2` calls in the same millisecond, which the entropy half guarantees.
- `test/mix/statifier/adr_guard_test.exs` - unchanged assertions. The two
  ADR-0008 tests keep asserting on the check id, which Phase 1 deliberately
  does not move.
- No conformance-suite movement is expected from any phase, so no
  `mix test.baseline add` and no `test/passing_tests.json` change. If
  `mix test.regression` does move, that is a signal something unintended
  happened - stop and investigate rather than ratcheting.

### Manual Testing Steps:

1. In IEx after Phase 2: build a machine, call `MachineState.new/1` a dozen
   times, and read the `_sessionid` values - confirm the `sess_` prefix, 31
   characters, no hyphen, all distinct.
2. Sort those dozen ids and confirm the order matches the order they were
   generated in (allowing ties inside one millisecond to fall anywhere, which
   ADR-0008 explicitly permits).
3. After Phase 3: `rm -rf _build deps && mix deps.get && mix compile` from a
   clean tree, then `mix deps.tree | grep -i uxid` and confirm it is empty.
4. Start a session end to end (`Statifier.start_session/2`) and confirm it
   registers, that `Session.session_id/1` returns the `sess_` id, and that
   `_ioprocessors[...]["location"]` is `#_scxml_` + that id.
5. After Phase 4: read `docs/architecture.md`'s "Generated identifiers"
   paragraph start to finish and confirm the core/non-core split still reads
   correctly with the library's name removed.

## References

- Source document: `docs/adr/0008-uxid-for-identifiers.md` (the 2026-08-15
  st-mvna amendment, lines 163-204 and the Consequences bullets at 230-250,
  committed on this branch as `d24f91a`) - the authority for every choice in
  this plan
- Related ADRs: `docs/adr/0003-pure-core-with-effects.md` (untouched - the
  generator runs outside the core, exactly where the dependency's call sat),
  `docs/adr/0011-*` (the gate-guard ledger),
  `docs/adr/0027-*` (the session registry, which is what the entropy is for),
  `docs/adr/0029-*` (the session id is a recorded input, not a replayed
  output), `docs/adr/0035-*` (the `send_` counter)
- The call site being replaced: `lib/statifier/machine_state.ex:423`
- The guard being reworded: `lib/mix/statifier/adr_guard.ex:106-111,289-297`
- The gate guard's `mix.exs` pattern, checked against this diff:
  `lib/mix/statifier/gate_guard.ex:43`
- Project rules applied: `changelog.d/README.md` ("While v2 is unreleased"),
  `.claude/wurk/commit.md` (step 1.6, ADR-0011 ledger),
  `.claude/wurk/implement.md` (the sabotage protocol), `.claude/wurk/plan.md`
  (always-required criteria, the Appendix D rule)
- Bead: `st-s4ht` (depends on `st-mvna`)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [x] The reworded message still reads as an instruction to the person who
      trips it: it names the ADR and says what the ADR requires.
- [x] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [x] Spec-conformance judgment for `lib/statifier/`: this phase touches no
      Appendix D function. Confirm from the diff that `main_event_loop`,
      `microstep`, `enter_states`, `exit_states` and the rest are untouched,
      so the Appendix D line-for-line rule is satisfied vacuously rather than
      by inspection. No deviation is introduced, mechanical or otherwise.
- [x] Eyeball a handful of generated ids in IEx: `sess_` prefix, 31 characters
      total, no hyphen, double-clicking selects the whole token.
- [x] The generator still sits outside any fold - `new/2` only, never reached
      from `main_event_loop/1` - so ADR-0003's core contract is unchanged.
- [x] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 3

- [x] A fresh `rm -rf _build deps && mix deps.get && mix compile` succeeds, so
      the drop is real rather than masked by a warm build directory.
- [x] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 4

- [x] Spec-conformance judgment for `lib/statifier/`: the diff touches comment
      and doc lines only. Confirm no Appendix D function body changed - the
      `generate_invoke_id` edit is the comment above it, not the function.
- [x] Each rewritten "why a counter is not a UXID" passage still makes the
      ADR-0003 argument intact: a clock and a CSPRNG in the core would turn
      `(state, event) -> {state, [effect]}` into
      `(state, event, clock, entropy) -> ...` and break replay observably.
- [x] `docs/architecture.md` and `docs/datamodel.md` read naturally rather than
      as mechanical substitutions.
- [x] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Verification outcome (2026-08-15)

All twelve items above were confirmed. Two produced follow-up edits, committed
together as the DMV pass rather than amended into their phases:

- **Phase 1.** The reworded finding named the ADR but not what it requires, so
  it now names the formats: "identifier generated ad hoc; ADR-0008 fixes the
  sess_/send_/inv_ id formats".
- **Phase 4.** Substituting the mechanism for the library name left all three
  ADR-0003 passages stating it twice ("minted with a clock-and-CSPRNG
  generator: an entropy-based id reads the wall clock and a CSPRNG"). The
  first clause no longer pre-announces the mechanism, and the two comment
  lines the substitution pushed past the block's ~72-column wrap were rewrapped.

Phase 3's cold-build item was verified with `MIX_DEPS_PATH`/`MIX_BUILD_PATH`
pointed at a scratch directory rather than `rm -rf _build deps` in place, which
proves the same thing without discarding the worktree's warm Dialyzer PLT. It
fetched 23 dependencies, none of them uxid, and compiled 133 files clean.
