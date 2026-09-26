# Quality Configuration for Statifier-ex
#
# Two ways to run:
#
#   mix quality                 - full gate: format, compile, credo, dialyzer,
#                                 deps audit, full test suite with coverage.
#                                 Run before every commit/push and in CI.
#
#   mix quality --profile loop  - inner loop while implementing: skips dialyzer
#                                 and coverage, runs only the tests covering
#                                 changed code. Use between edits.
#
#   mix quality --profile merge - the full gate plus the ADR judge (mix
#                                 adr.judge). It makes real `claude` CLI calls,
#                                 so it is opt-in rather than part of every
#                                 gate run; /wurk:mr runs it before pushing.
#
# Agents: prefer `--format json --report -` when you want to route on results.

[
  format: [
    check: true
  ],

  compile: [
    warnings_as_errors: true
  ],

  credo: [
    strict: true
  ],

  # The published docs are part of the package, so the gate checks them the
  # way HexDocs and hex.pm will read them. The Docs stage runs `mix docs` and
  # fails on any ExDoc warning. The Doc links stage fails on the link rules
  # ExDoc accepts silently: a README relative link to a file not in the
  # package files, a relative link in a Markdown extra to a file that is not
  # itself an extra (moduledoc links are the Docs stage's), two extras sharing
  # a basename, and a silent rewrite to a different extra.
  # `:auto` runs both whenever ex_doc is installed, which it is in dev.
  docs: [enabled: :auto],
  doc_links: [enabled: :auto],
  
  # Disabled by default (and so absent from both a bare `mix quality` and
  # `--profile loop`) because it makes real `claude` CLI calls; the :merge
  # profile below re-enables it for the one path that wants it. See the
  # adr_judge custom stage entry for why this stage exists at all.
  adr_judge: [enabled: false],

  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ],
    merge: [
      adr_judge: [enabled: true]
    ]
  ],

  # The gate guard reads the branch's diff for changes to the gate's own config
  # and fails when docs/quality-gate-changes.md does not justify them (ADR-0011).
  # It reads git and source and writes nothing, so it is a reader. It is absent
  # from the loop profile's stages, so it is a pre-commit concern rather than an
  # every-edit one.
  custom: [
    [
      key: :gate_guard,
      name: "Gate guard",
      command: "mix",
      args: ["gate.check", "--format", "json"],
      kind: :reader,
      skip_exit_code: 2
    ],
    # The regression ratchet (test/passing_tests.json) is the set of tests that
    # must always pass; `mix test.regression` runs exactly what it expands to,
    # so a regression is a named stage failure instead of a count buried in the
    # Tests stage's own output (docs/testing.md). Compile has already built
    # dev and test by the time the analysis phase starts, so - like the Tests
    # stage itself - this reads the existing build rather than writing to it,
    # and is a reader. `stages:` in a profile is an allow-list, so leaving
    # :regression off the loop profile's explicit list below is what keeps it
    # out - no separate opt-out is needed - and it runs only on a bare
    # `mix quality`.
    #
    # Today `internal_tests` globs cover nearly the whole internal suite, so on
    # a bare `mix quality` this largely re-runs work the Tests stage already
    # did. That duplication is accepted for now rather than narrowing the
    # registry to dodge it: `test/passing_tests.json` is itself a guarded path
    # (ADR-0011), so trimming it to avoid overlap would need its own ledger
    # entry and would weaken the ratchet's coverage to make the gate faster -
    # backwards for what this stage exists to protect. The conformance lists
    # (`scion_tests`, `w3c_tests`) are populated now, so this stage's marginal
    # cost over the Tests stage has already shrunk toward zero and its value -
    # a named failure instead of a buried count - is the point.
    [
      key: :regression,
      name: "Regression ratchet",
      command: "mix",
      args: ["test.regression"],
      kind: :reader
    ],
    # The conformance corpus check (ADR-0070): `mix statifier.corpus --check`
    # re-runs every case in conformance/corpus/ and fails when a committed
    # corpus file, the manifest, the exclusions or the registry differs from
    # what the emitter writes from the committed inputs, or when there is
    # nothing to check - an absent or empty corpus is a red stage, not a green
    # one. It needs no network and no upstream tree, so it runs in CI as it
    # runs here. It writes nothing and reads the build Compile produced, so it
    # is a reader, and like the regression stage it is off the loop profile's
    # allow-list. A command stage runs in its own `mix` process, so the
    # session runtime the task starts ends with that process rather than
    # outliving the check inside another task's VM.
    [
      key: :corpus,
      name: "Conformance corpus",
      command: "mix",
      args: ["statifier.corpus", "--check"],
      kind: :reader
    ],
    # The ADR guard reads the same diff for lines that look like violations of
    # the mechanically-checkable ADRs (0002 naming, 0003 effects, 0004 eval,
    # 0008 UXIDs), so architectural drift is a named failure rather than
    # something review has to catch. Reader, and absent from the loop profile,
    # for the same reasons as the gate guard above.
    [
      key: :adr_guard,
      name: "ADR guard",
      command: "mix",
      args: ["adr.check", "--format", "json"],
      kind: :reader,
      skip_exit_code: 2
    ],
    # The ADR judge scopes to ADR-0012 (debuggability), the one in-scope ADR
    # whose rule is a judgment call rather than a name or call-site pattern.
    # It shells out to the developer's own `claude` CLI, so it is local-only
    # by design: disabled by default (see adr_judge: above), never in CI,
    # never in the loop profile, and it skips cleanly (claude CLI not on
    # PATH, no lib/statifier/ changes, or no base ref) rather than failing
    # when it cannot run. The :merge profile re-enables it.
    [
      key: :adr_judge,
      name: "ADR judge",
      command: "mix",
      args: ["adr.judge", "--format", "json"],
      kind: :reader,
      skip_exit_code: 2
    ]
  ]
]
