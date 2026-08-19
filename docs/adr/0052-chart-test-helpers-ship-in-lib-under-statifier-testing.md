# ADR-0052: The chart-author test helpers ship in `lib/` under `Statifier.Testing`

Status: accepted (2026-08-19) - amends 0006 in part (the harness modules'
home: "feature detection moves to `test/support`" stops being a placement
rule and becomes a reference-direction rule; the corpus coupling constraint
itself stands unamended)

## Context

`st-hbdr` asks for the chart-author test helpers to become a supported
surface. `Statifier.Case` gives a declarative chart test - `test_scxml/4`
takes the XML, the expected initial configuration, and a list of
`{event, expected_configuration}` steps - and `Statifier.FeatureDetector`
is what makes an unsupported-feature test fail with the feature named
instead of passing by accident. That pairing is exactly how this engine
tests itself, and exactly what a downstream chart author needs to test
their charts. It is also the engine half of the statifier-ui executable
expectations story: ADR-0006's corpus shape (a document plus expected
configurations per step) is the fixture format, and a published runner is
what makes such a fixture executable outside this repo.

Today none of it is reachable downstream. Both modules live under
`test/support/`, and `mix.exs` compiles that directory only in the test
env:

    defp elixirc_paths(:test), do: ["lib", "test/support"]
    defp elixirc_paths(_), do: ["lib"]

A downstream app that depends on `statifier` gets `lib/` only. Writing
declarative chart tests today means copying harness files out of this
repo, which is the unsupported state this record ends.

Two written rules stand in the way, and they are the same rule stated
twice. `docs/testing.md`:

> Unsupported-feature tests **fail, not skip** (v1's FeatureDetector rule,
> kept): a test that depends on an unsupported feature flunks with the
> feature named, so it can never masquerade as passing. Feature detection
> lives in `test/support`, not `lib/` - it is harness code, not library
> surface.

And `test/support/feature_detector.ex`'s own moduledoc:

> This is harness code, not library surface: nothing in `lib/` may
> reference it.

The rule has two distinguishable halves. The **placement** half -
"lives in `test/support`, not `lib/`" - exists so the harness is not
silently compiled into the library. The **reference-direction** half -
"nothing in `lib/` may reference it" - is the load-bearing one: the
engine must never consult feature detection to decide behavior. Engine
semantics come from the Appendix D port (ADR-0002); an unsupported
feature must surface as a real error or a real conformance failure, never
as a detection-gated branch that lets the engine dodge the test that
would catch it. The fail-not-skip discipline lives on the harness side
for the same reason.

The constraints the decision must fit:

- ADR-0006's closed driving surface: the corpus couples to the library
  through `Statifier.Case` and the nine enumerated public functions, and
  widening that set reopens ADR-0006, not this record.
- One package at `2.0.0-dev` (`mix.exs`), unreleased, with a
  fragment-based changelog (`changelog.d/`).
- The coverage floor measures `lib/` only - `coveralls.json` skips
  `test/support/` - and Doctor holds 100% documentation thresholds on
  everything in `lib/`.
- 281 generated corpus files say `use Statifier.Case`, and the corpus
  generators (`tools/corpus/scion/cases.exs`,
  `tools/corpus/scxml_w3/cases.exs`) call
  `Statifier.FeatureDetector.detect_features/1` by that name.

## Decision

1. **The helpers are promoted into `lib/` under an explicit
   `Statifier.Testing` namespace.** `Statifier.Case` becomes
   `Statifier.Testing.Case` (at `lib/statifier/testing/case.ex`), keeping
   `test_scxml/4`'s shape, and `Statifier.FeatureDetector` becomes
   `Statifier.Testing.FeatureDetector`. The namespace is the boundary
   made self-documenting: everything under it is test-side surface for
   chart authors, supported and versioned with the engine, and nothing
   under it is engine.

2. **No separate `statifier_test` hex package.** The package route was
   the bead's alternative because it sidesteps the placement rule, but it
   sidesteps a one-paragraph amendment at the price of a second artifact
   held in permanent lockstep: `FeatureDetector`'s registry is a mirror
   of exactly what the engine supports at a given commit, so every
   feature the engine gains would demand a paired release of the helper
   package, before this repo has shipped even once. Add a second release
   process, a second changelog, downstream needing two deps, and the
   cross-repo coordination overhead this project already pays elsewhere
   (ADR-0025), all to preserve the letter of a rule whose purpose is
   served more directly by amending it. Rejected.

3. **The FeatureDetector rule is amended, not deleted.** The placement
   half is withdrawn: feature detection may live in `lib/`, inside
   `Statifier.Testing`. The reference-direction half is kept and
   restated in namespace terms: **no module in `lib/` outside
   `Statifier.Testing.*` may reference anything inside it.** The engine
   still never gates behavior on detected features, unsupported-feature
   tests still fail with the feature named rather than skip, and the
   fail-not-skip behavior now ships to downstream authors instead of
   being private discipline. `docs/testing.md` is updated to say this on
   the implementing branch; ADR-0006 carries the amendment marker.

4. **The rest of `test/support/` stays private test plumbing.** Each for
   its own reason:
   - `Statifier.ContextRecorder` and `Statifier.TestContent` are
     protocol-poking test doubles for engine internals (the
     executable-content context contract, stop-on-error, the pending
     error channel). Their `defimpl`s exist precisely so they consolidate
     only in the test env; publishing them would freeze internal contract
     details into public API.
   - `Statifier.StreamOrder` asserts the ADR-0044/0046 subscriber-stream
     ordering invariants - an internal delivery contract, not a chart
     author's concern. If downstream ever wants stream assertions, that
     is its own decision, not a rider on this one.
   - `Statifier.TmpDir` exists to fix this repo's own concurrent-gate
     scratch race and carries a repo-internal env-var contract
     (`STATIFIER_TMP_ROOT`).
   - `Mix.Statifier.AdrJudgeCorpus` is repo tooling for the ADR judge
     corpus tests.

5. **The corpus keeps coupling through `test/support` shims.**
   `Statifier.Case` remains in `test/support` as a thin wrapper whose
   `using` delegates to `Statifier.Testing.Case`, and
   `Statifier.FeatureDetector` remains as a `defdelegate` module, so the
   281 generated files and the corpus generators need no regeneration on
   the promoting branch. ADR-0006's constraint is untouched: the corpus
   still drives the library through exactly the nine sanctioned
   functions, because `Statifier.Testing.Case`'s internals are the same
   internals - promotion moves the module, not the coupling. Whether a
   later corpus regeneration adopts the new names and retires the shims
   is a housekeeping call, not a reopen of either record.

6. **Downstream consumption is the ordinary dep.** A downstream app
   depends on `statifier` and writes
   `use Statifier.Testing.Case, async: true` in its chart tests. No
   `only: :test` companion dep exists or is needed. The helpers compile
   in every env, including `:prod` - the ecosystem's standard shape
   (`Plug.Test`, `Phoenix.ConnTest`, `Phoenix.LiveViewTest` all ship in
   `lib/`), and ExUnit ships with Elixir, so `use ExUnit.CaseTemplate`
   adds no dependency edge. The dead weight in a prod build is two
   modules that are never called.

## Consequences

- `mix.exs` `elixirc_paths` is untouched; `test/support` remains
  test-env-only for the modules that stay.
- The promoted modules join the `lib/` quality regime: the 90% coverage
  floor and Doctor's 100% documentation thresholds now count them. Both
  already have direct tests (`test/statifier/feature_detector_test.exs`,
  `test/statifier/case_test.exs`) and moduledocs/specs, so this is
  pressure to keep, not a gap to open. No gate config file changes, so
  no ADR-0011 ledger entry is owed.
- Dialyzer analyzes the promoted modules; if the PLT lacks `:ex_unit`,
  adding it to the PLT apps is implementation detail, not a gate-config
  weakening.
- Versioning is solved by construction: the helpers ship inside
  `statifier 2.0.0` when it ships, and the feature registry can never
  drift from the engine it describes because they are one artifact.
  `mix.exs` stays `2.0.0-dev`; the change gets a user-facing fragment at
  `changelog.d/st-hbdr.md`.
- The follow-on implementation, in broad strokes (the plan stage owns
  the details): move and rename the two modules into
  `lib/statifier/testing/`; leave the `test/support` shims; update
  `docs/testing.md`'s rule paragraph and the moduledoc rule statement to
  the namespace form; point the existing harness tests at the new names;
  write the downstream-facing documentation the acceptance criteria
  require; add the changelog fragment.
- statifier-ui's executable expectations gain their runner as public
  API: a fixture in the ADR-0006 corpus shape is executable downstream
  via `Statifier.Testing.Case.test_scxml/4`.

Open questions, recorded rather than resolved here:

1. Whether the public entry point keeps the name `test_scxml/4` or gains
   a friendlier alias. ADR-0006 pins the corpus-facing shape, not the
   downstream-facing name; the default is to keep `test_scxml/4`
   unaliased and let real downstream friction argue for more.
2. Whether the session path's corpus-tuned timing constants
   (`@settle_window_ms 100`, `@configuration_deadline_ms 4_000`) become
   caller options with today's values as defaults. They were sized to
   this corpus's delay populations; a downstream chart with a
   longer load-bearing delay would need the knob. Leaning yes; the plan
   decides the option names.
3. Whether `Statifier.StreamOrder` ever joins the public surface for
   subscriber-stream assertions. Out of scope here; it would be its own
   decision record.
