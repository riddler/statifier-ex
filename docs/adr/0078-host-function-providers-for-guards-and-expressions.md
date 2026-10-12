# ADR-0078: A host registers named functions for `cond` and `expr` through `:function_providers`, checked by name at compile

Status: proposed (2026-10-12) - extends ADR-0030 (the evaluation context
gains a per-session functions map beside `In/1`); follows ADR-0051 and
ADR-0069 for how a per-session registration is stamped, dropped from a
persisted position (ADR-0064) and recorded (ADR-0057); adds one
recognized option to ADR-0052's closed `compile_opts` allowlist; adds a
compile-time refusal that ADR-0073's publish-time checks do not cover

## Context

A host application building rich charts wants pure named guards - a
blast radius over a list of paths, business hours at a timestamp in a
zone, whether two intervals overlap - callable from `cond` and `expr`,
instead of precomputing every such fact into the event payload.

predicator already has the seam. A `Predicator.FunctionProvider` module
answers `functions/0` with `name => {arity, atom}`, and predicator calls
the named function as `fun(args, context)`. statifier does not expose it.
Every evaluation context starts from one compile-time constant,
`Statifier.Evaluator.Functions.base_context/0`, which holds `In/1` and
predicator's builtins and nothing else (ADR-0030), and no option adds
to it. Read at `35ae9f7`.

A chart that calls a function the context lacks compiles today: the
call is one `["call", name, arity]` instruction, and the failure arrives
at evaluation as `error.execution`. For a guard that is the worst place
for it: the transition is simply not taken, every time.

## Decision

**1. One option, three entry points.** `:function_providers` is a list
of `Predicator.FunctionProvider` modules. `Statifier.compile/2`,
`Statifier.MachineState.new/2` and `Statifier.Session.start_link/2` each
accept it. `nil` and `[]` mean "no host function", the behaviour before
this record.

**2. The functions map lives on `%MachineState{}`, not the context.**
`Statifier.Evaluator.Functions.from_providers/1` resolves the list once,
through predicator's own provider validation, into the full dispatch map
(`In/1`, the builtins and the host's functions). It is stamped onto a new
`functions` field. `Statifier.Evaluator.context/1` swaps that map into
the constant context's `functions` field, one field write; with the field
`nil` it uses the constant unchanged, so a session that registers nothing
pays nothing. No context is stored on `%MachineState{}`: ADR-0030's rule
stands, and the map holds no closure.

**3. `In` and the builtins cannot be shadowed.** A provider that names a
function the base context already holds is refused
(`{:shadowed_names, names}`), so `In/1` keeps meaning spec 5.9.1's
predicate in every chart.

**4. Dropped from a position, re-stamped by the driver.** The `functions`
field is a per-session snapshot like `invoke_types` and `send_types`.
`Statifier.Position.to_binary/1`, `from_binary/2`, `export/1` and
`import/2` leave it out or blank it to `nil`; a driver re-stamps it with
`Statifier.MachineState.put_function_providers/2`. A session does this
itself on `:resume`. A recording keeps the list as module name strings,
and `Statifier.Replay` stamps it on both of its start branches.

**5. Refused at the caller, not inside the process.** `start_link/2`
resolves the list before it spawns anything and answers
`{:error, {:function_providers, reason}}`. `MachineState.new/2` and
`put_function_providers/2` raise `ArgumentError`, as `new/2` already
does for a bad `:datamodel`.

**6. Unknown names are refused at compile.** After the compiler runs,
`Statifier.Compiler.FunctionCalls.check/2` reads every compiled
expression and program in the machine and refuses each call whose name
is not `In`, a builtin, or a declared name, with a
`Statifier.Compiler.Error` of reason `{:unknown_function, name, source}`
at the element that holds the expression. Only names are checked, not
arity.

This is a compile-time check, not a publish-time twin, so ADR-0073's
rule that its checks leave `compile/2` alone does not cover it. It does
narrow what compiles: a chart that calls a function nothing declares,
which compiled before this record and failed at every evaluation of that
call, now fails to compile.

**7. Declared names persist; modules do not.** `compile/2` also accepts
`:function_names`, a list of name strings declared as they are, for a
caller that does not load the provider modules. The names both options
declare are persisted as one sorted `:function_names` entry in
`compile_opts`, the one entry ADR-0052's allowlist gains, so a
`Statifier.Chart` blob recompiles without the modules and a `:safe`
decode creates no atom. A chart that declares nothing persists the
options it did before. Compile declares names only; evaluation uses what
the session stamps.

**8. The purity contract.** A registered function reads only its
arguments and the context's `host` term, performs no I/O and reads no
clock or random source, so evaluating it again - on a replay, or after a
resume - gives the same value. The library cannot check this; the guide
states it.

## Consequences

- A host calls its own guards from charts without moving facts into the
  event payload.
- A chart that calls an undeclared function now fails to compile instead
  of raising `error.execution` at the call. That is a behaviour change
  for such a chart, and the changelog says so.
- A child session started for an `<invoke>` does not inherit the list,
  and a chart compiled from `<invoke>` content declares no host name, so
  a child chart that calls a host function is refused. Inheritance, on
  the model of `:inherit_send_types`, is left for a later record.
- The recording format version does not move: a recording that names no
  provider is byte-identical to one written before this record.

## Related

- ADR-0030 - `In/1` as a provider; the context stays off `MachineState`.
- ADR-0051, ADR-0069 - per-session registrations and their snapshots.
- ADR-0052 - `compile_opts` and the closed allowlist.
- ADR-0057 - module names cross the recording boundary as strings.
- ADR-0064 - snapshots are dropped from a persisted position.
- ADR-0073 - publish-time checks; this check is not one of them.
- `docs/extending.md`, "Host functions for `cond` and `expr`".
