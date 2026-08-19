# ADR-0059: A per-execution ordinal joins the durable-timer effects

Status: accepted (2026-08-19) - closes the residual collision ADR-0054
decision 3 recorded ("the library has no per-iteration ordinal on
`%SendDelayed{}` to add"): it grows one, `%Cancel{}` grows it alongside,
and the author-side foreach guidance retires; amends 0054 in part
(decision 3's dedup key gains `ordinal` and its residual paragraph is
withdrawn) and reopens 0040 additively per that record's own consequence
terms, the same way 0046 did

## Context

ADR-0054 decision 3 keys a durable host's at-least-once dedup on
`{session scope, send_id, macrostep, microstep, round, c_index, owner}`,
read off the `%SendDelayed{}` itself, and states its residual honestly:
the key is not strictly per-instance. A `<send id="x" delay="...">`
inside a `<foreach>` body executes once per iteration from the same
content position - `run_content/2` folds the same static, document-order
`c_index` list on every iteration
(`lib/statifier/machine/content/foreach.ex`, the fold near the end of the
file) - in the same microstep, under the same author-written id, so every
iteration yields an identical key and a durable store dedups genuine
distinct timers down to one. The library keeps them as two
(`Timers.put/3` appends per `send_id`,
`lib/statifier/session/timers.ex:39-44`), so the store silently drops
timers the state chart expects to fire.

The recorded mitigation was author guidance, restated by
`docs/durable-timers.md`'s "Honest residual" paragraph: do not hand-write
an `id` on a `<send delay="...">` inside a `<foreach>` under a durable
scheduler; a generated id advances `send_counter` per execution
(`lib/statifier/machine/content/send.ex:383-389`), so each iteration gets
its own `send_N` and the key is per-instance again. st-q6b6, raised by
st-ifa3's verification pass, asks whether that constraint should stand or
whether the effect structs should grow a per-execution ordinal. (The bead
cites "ADR-0052 decision 3"; that citation predates PR #196's
renumbering, and the decision it names is ADR-0054 decision 3 today -
verified against the files, per ADR-0056 this note is the pointer fix.)

Four facts bound the answer.

**1. The guidance is not free.** An author-written shared `id` is the
only way to cancel a whole family of delayed sends with one `<cancel>`:
spec 6.3 cancels every timer under a sendid, and the cancellation key
`{session scope, send_id}` matches them all by design. The workaround
takes exactly that capability away - an author who wants N foreach
iterations' sends cancellable as a group must hand-write the shared id
the workaround forbids. The constraint is also invisible until it fails:
no validator warning fires, nothing errors, and the failure mode is a
timer that silently never fires in production under a durable scheduler
while every in-process test run (where `Timers.put/3` appends) passes.
Downstream it already costs code: statifier_oban's tracker carries
sob-7yx, a standing workaround bead that retires only when the ordinal
ships here.

**2. A deterministic per-execution value must live in fold state.** The
hard requirement is that the ordinal survive a crash-and-replay re-run
byte-identically - that property is the entire reason the rest of the key
exists (ADR-0054 decision 3, ADR-0034). A session-side stamp at delivery
or plan time fails replay, for the reason ADR-0046 already recorded when
it rejected the same shape for `round` ("the stamp is the core's, not the
session's"). The library's precedent for a replay-deterministic
per-execution value is a plain `%MachineState{}` counter: ADR-0035 chose
one for `send_id` over a generated id precisely because "a counter that
is a pure field on `%MachineState{}` replays identically", and
`invoke_counter` made the same choice before it
(`lib/statifier/machine_state.ex:337-360`).

**3. `send_counter` itself cannot be the ordinal.** It advances only when
an id is generated - an author-written id is used verbatim and leaves it
untouched (`lib/statifier/machine/content/send.ex:383-389`, ADR-0035) -
and the colliding case is exactly the author-written one. Making every
`<send>` execution advance it would renumber the generated sequence in
any document that mixes author ids with generated ones: `send_N` values
are observable through `idlocation` writes and delivered events' `sendid`
fields, so existing recorded runs and ADR-0035's locally-readable-ids
argument both break for a field whose meaning ("the generated-id
sequence") the change would quietly overload.

**4. `%Cancel{}` has the same collision, and idempotence does not excuse
it.** A cancel is idempotent in isolation - deleting every row under
`{session scope, send_id}` twice is the same as once, and ADR-0054
records a no-match cancel as a no-op. But dedup is not about
double-apply; it is about a host mistaking a genuinely distinct second
effect for a redelivery of the first and skipping it. A `<foreach>` body
of `<send id="x" delay>` then `<cancel sendid="x"/>` interleaves, per
iteration: send#1, cancel#1, send#2, cancel#2, all in one microstep. With
ordinals on the sends alone, cancel#1 and cancel#2 share every key
component; a host that dedups cancel#2 away as already-processed never
deletes send#2's row, and a timer fires that spec 6.3 says was cancelled.
`%Cancel{}` carries the same position fields for the same keying purpose
(`lib/statifier/effect/cancel.ex:21`), so it needs the same
disambiguator.

## Decision

**1. `%SendDelayed{}` and `%Cancel{}` each gain
`ordinal :: pos_integer()`, in `@enforce_keys`, stamped at their existing
construction sites.** The two sites are `build_effect/6`'s delayed clause
(`lib/statifier/machine/content/send.ex`) and `<cancel>`'s effect
construction (`lib/statifier/machine/content/cancel.ex`). No other effect
gains the field - see decision 5.

**2. The ordinal is read off a new session-global `%MachineState{}`
counter, `timer_counter`.** It starts at `0` in `new/2`, is incremented
immediately before use (the first ordinal is `1`, matching
`invoke_counter`/`send_counter`'s increment-before-read idiom), advances
on every construction of either effect - author-written id or not, inside
a `<foreach>` or not - is never reset, and has no setter, written
directly at its two call sites exactly as `send_counter` is at its one
(ADR-0035's precedent). Determinism across a crash-and-replay re-run is
ADR-0035's argument unchanged: the counter is pure fold state,
`(state, event) -> {state, [effect]}`, and ADR-0034's replay re-drives
the same fold from the same inputs, so the re-run mints byte-identical
ordinals. One shared counter rather than one per effect kind: the two
effects are one durable-timer vocabulary (ADR-0054 decision 1), a shared
sequence additionally preserves their relative emission order in the
value itself, and nothing is gained by letting a cancel and a send reuse
the same ordinal.

**3. The dedup key gains `ordinal` as its eighth component:
`{session scope, send_id, macrostep, microstep, round, c_index, owner,
ordinal}`.** This amends ADR-0054 decision 3's key in the additive
direction only; the cancellation key `{session scope, send_id}` is
untouched, because spec 6.3's cancel-them-all semantics is exactly what
it exists to express. Since `timer_counter` is session-global and
monotone, `{session scope, ordinal}` is already unique on its own, and a
host may use that pair as its compact stored key with the remaining
fields kept as row data rather than key components - both forms are
conformant. The full compound form stays the documented default because
it is self-describing in a store: a row readable as "this send, at this
position, in this step" is worth more during an incident than a bare
sequence number. The residual-collision paragraph of ADR-0054 decision 3
is withdrawn, and with it the author guidance: a hand-written `id` on a
`<send delay="...">` inside a `<foreach>` is fully supported under a
durable scheduler once the field ships.

**4. `timer_counter` serializes with the position; recordings are
untouched.** The counter joins `Statifier.Position`'s exported map and
`@required_export_keys` (`lib/statifier/position.ex:187-191`), carried
verbatim like `send_counter`, and `Position`'s `@format_version`
(`lib/statifier/position.ex:66`) bumps `1 -> 2` - the exact mechanism
ADR-0052 decision 2 built for a shape change, a bump at one call site. It
must serialize: a process-less host that resumes a persisted position
with a reset counter would mint already-used ordinals and its store would
dedup live timers against dead rows. `Machine.Identity`'s format version
is untouched (the chart did not change shape), and `Session.Recording`
needs nothing: a recording stores the four replay inputs and re-drives
the core (ADR-0034, ADR-0057), so the counter is recomputed, not stored.

**5. The ordinal stays off every other effect.** ADR-0046 chose
uniformity for `round`, but the cases are not alike: `round` was already
a `%MachineState{}` step counter whose value every effect *has* and every
timeline consumer needs, so stamping it everywhere emptied an exemption
table without inventing anything. `ordinal` exists only where a durable
store keys rows - the two effects ADR-0054 names as the whole seam.
Stamping it on the other core effects would advance the counter per
emission (changing every stamped value's meaning), or demand a second
counter per effect kind, to serve a consumer that does not exist:
immediate `%Send{}` is delivered inside the drive that produced it and is
never stored. The one-line rule after this record: the two durable-timer
effects carry `ordinal`; no other effect does, because no other effect is
durably stored.

**6. ADR-0040 is reopened additively, on its own terms.** A new field on
the two structs rides verbatim into their `:telemetry` events' `effect`
metadata; ADR-0040's measurements rule ("counters are numbers, so they
are measurements") puts `ordinal` into the measurements of
`[:statifier, :session, :effect, :send_delayed]` and `[..., :cancel]`,
alongside the existing counter triple. Addition is the direction
ADR-0040's st-ii9v amendment calls non-breaking, and a host
pattern-matching the structs off the subscriber stream reads new keys
through unchanged - the same reasoning ADR-0046 recorded when it made
this same reopening.

## Consequences

- ADR-0054's status line gains an amendment note pointing here; its
  decision 3 gains an inline note marking the residual-collision
  paragraph and its author guidance as decided away by this record, with
  the body text standing as written (the house amendment shape).
  ADR-0040's status line gains the matching amended-in-part note.
  `docs/durable-timers.md`'s dedup-key row and "Honest residual"
  paragraph are rewritten to the eighth component. All three edits land
  with this record.
- The implementation is sized separately on this bead, per ADR-0046's
  precedent (this record changes no code): the field, `@enforce_keys`
  entry, and `@type` line on the two effect modules; `timer_counter` on
  `%MachineState{}` with its moduledoc section; the stamp at the two
  construction sites; `Position`'s export/import/allowlist and format
  version bump `1 -> 2` with its round-trip tests; the two telemetry
  measurement clauses and `Statifier.Session.Telemetry`'s contract table;
  and the test/support literal builds. Because the doc edits above land
  with this record, the implementing change is owed on this same branch
  before it merges - `docs/durable-timers.md` must not describe a field
  `lib/` does not carry on `origin/main`.
- statifier_oban's sob-7yx retires its foreach workaround once the
  implementing change ships; its dedup key gains the eighth component (or
  collapses to `{session scope, ordinal}`, which decision 3 blesses).
  Per ADR-0025 the mirrored bead is re-read and re-noted before anyone
  schedules against it.
- A position blob written before the bump decodes as
  `{:error, {:unsupported_format_version, 1}}` against a build that only
  reads 2, unless the implementing change chooses to read version-1 blobs
  and default `timer_counter: 0` on import. That choice is safe exactly
  when the position predates the field (no ordinal was ever minted from
  it), which is always true of a version-1 blob; the implementing change
  should take it, and this record blesses the default rather than leaving
  it to taste.
- The hot path cost is one counter increment and one map read per
  delayed-send or cancel emission - the bill ADR-0020/0046 already
  accepted for far more frequent stamps.
- What would reopen this record: a third effect becoming durably stored
  (it would claim the same stamp, and decision 5's rule extends rather
  than breaks), a change to the counter triple or to `c_index`'s
  document-order meaning (ADR-0020's and ADR-0012's territory), or
  `Position` learning cross-revision migration semantics that make
  carrying `timer_counter` verbatim wrong.
