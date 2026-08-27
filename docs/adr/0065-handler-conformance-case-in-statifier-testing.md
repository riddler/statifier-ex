# ADR-0065: A handler conformance case joins the `Statifier.Testing` surface

Status: accepted (2026-08-22); illustration amended 2026-08-27 - the example
invoke type moved onto the family's canonical example domains (illustration
only, no decision changed)

## Context

`st-718j` asks for a reusable conformance case any `Statifier.Invoke.Handler`
implementation can run against itself. The behaviour contract is already
decided and documented - ADR-0051 decision 4 (three pure planning callbacks,
one optional performing callback, `perform/2` idempotent on `invoke_id`),
decision 1 (`{:error, _}` from `start/2` is planned as `error.execution`),
and `docs/extending.md` (the at-least-once section, and "it never rescues a
handler exception into an event"). What does not exist is a mechanical pin a
downstream implementor runs: today the contract binds their handler only as
prose, and this repository's own tests
(`test/statifier/session/invoke_handler_test.exs`) pin the library's half
without touching anyone's implementation.

ADR-0053 already decided where downstream-facing test surface lives (`lib/`,
under `Statifier.Testing`, with the reference-direction rule that nothing in
`lib/` outside that namespace may reference anything inside it) and why no
separate test package exists. Neither question is reopened here.

## Decision

1. **`Statifier.Testing.HandlerCase` ships in `lib/`, beside
   `Statifier.Testing.Case`**, under ADR-0053's placement and
   reference-direction rules unchanged. A host module runs the case as

       use ExUnit.Case, async: false
       use Statifier.Testing.HandlerCase, handler: MyHandler, type: "myapp:authorize"

2. **It is a `use`-injected test generator alongside the host's own
   `use ExUnit.Case`, not a second `ExUnit.CaseTemplate`.** A CaseTemplate
   forwards its `use` options to `ExUnit.Case`, so `:handler` and `:type`
   would ride into machinery that has no business seeing them, and the
   implementor would lose direct control of their own case options. The
   split-`use` shape is the ecosystem's own for exactly this job
   (`Oban.Testing`), and `Statifier.Testing.Case` keeps CaseTemplate because
   its job - being the corpus's case - is the job CaseTemplate is for.

3. **Every check is a public, documented function on the module; the
   generated tests are thin wrappers.** A suite that wants one check, or
   different fixtures, calls the function directly. This is also what makes
   the case's own negative tests possible: each violation of the contract is
   asserted to be caught, not assumed.

4. **The two library-half pins - `{:error, _}` from `start/2` surfacing as
   `error.execution` in a driving chart, and handler exceptions propagating
   un-rescued - run with case-internal probe handlers registered under the
   implementor's own type string**, so they execute in every downstream
   suite, not only here. That is deliberate: the contract an implementor
   builds against stays enforced by tests where the implementations live,
   and the probes exercise the implementor's own type registration path on
   the way. A handler with a real failing-start path asserts its own half
   with `assert_erroring_start/3`.

5. **Idempotency is judged against a declared observation point, and the
   absence of one fails rather than skips.** The case cannot see a host's
   job queue or database; the implementor overrides `observed_effects/1` to
   read the effects attributable to an `invoke_id`. When the handler routes
   instructions to `perform/2` and no observation point is declared, the
   generated test flunks naming the override to write - ADR-0053's
   fail-not-skip discipline, applied to the one property that cannot be
   checked from outside. A handler that routes nothing to `perform/2`
   asserts exactly that instead and needs no observation point.

## Consequences

- The module joins the `lib/` quality regime (coverage floor, Doctor's 100%
  documentation thresholds), like the ADR-0053 promotions before it.
- The contract's clauses are now pinned three times over: the library's own
  session tests, this case run against the repo's reference handlers, and
  every downstream handler suite that adopts it. A change that reshapes the
  behaviour contract reddens all three.
- The probe chart drives `Statifier.Session` through public API only
  (`Statifier.compile/1`, `Session.start_link/2`, `Session.status/1`,
  `Session.stop/2`); ADR-0006's closed corpus-driving surface is untouched -
  this case is not the corpus's driver and adds nothing to it.
- `caller_context` (ADR-0063) assertions are deliberately absent: the
  conformance fixtures predate that field's arrival on this seam's effects,
  and adding caller-context-aware checks is a follow-up once the field's
  branch lands, not a rider here.

## Related

- ADR-0051 (the behaviour contract this case pins; decisions 1 and 4)
- ADR-0053 (the `Statifier.Testing` namespace, its placement and
  reference-direction rules, fail-not-skip)
- ADR-0008 as amended (`invoke_id` as the stable idempotency key)
- ADR-0003 (planning callbacks are pure because the core is)
