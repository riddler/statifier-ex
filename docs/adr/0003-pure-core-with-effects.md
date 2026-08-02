# ADR-0003: Pure functional core returning effects

Status: accepted (2026-08-02)

## Context

v1 mixed execution with I/O: delayed `<send>` scheduled timers via a GenServer pid
stored *inside* the state struct, and in the pure/synchronous API the same delayed
send silently degraded to an immediate send - the same document had different
semantics depending on entry point. Logging threaded the state through every
function purely to accumulate entries, producing discarded-return bugs.

## Decision

The core interpreter is pure: `(state, event) -> {state, [effect]}`. Effects are
data - `{:send, ...}`, `{:send_delayed, id, ms, ...}`, `{:cancel, id}`,
`{:invoke, ...}`, `{:done, donedata}`, `{:log, ...}` - and are interpreted outside
the core. `Statifier.Session` (GenServer) is the production effect interpreter
owning timers, invoke lifecycles, and parent/child session routing. Tests interpret
effects directly, no processes required. No pids, adapters, or log buffers live in
core state.

## Consequences

- One semantics for every entry point; delay/cancel/invoke are unit-testable.
- Deterministic replay: a session is (machine, initial data, event log).
- Embedders can supply their own effect interpreter (e.g. queue delayed sends into
  Oban instead of process timers).
- The Session layer stays thin and boring; all statechart logic is in the core.
