# Quality Configuration for Statifier v2
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
# Agents: prefer `--format json --report -` when you want to route on results.

[
  compile: [
    warnings_as_errors: true
  ],

  credo: [
    strict: true
  ],

  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ]
  ],

  # The gate guard reads the branch's diff for changes to the gate's own config
  # and fails when docs/quality-gate-changes.md does not justify them (ADR-0011).
  # It reads git and source and writes nothing, so it is a reader. It is absent
  # from the loop profile's stages, so it is a pre-commit concern rather than an
  # every-edit one.
  #
  # Once the conformance corpus is ported, the regression ratchet joins it as a
  # stage of its own, so a regression is a named failure rather than a buried
  # test count:
  #
  #   [key: :regression, name: "Regression ratchet", command: "mix",
  #    args: ["test.regression"]]
  custom: [
    [
      key: :gate_guard,
      name: "Gate guard",
      command: "mix",
      args: ["gate.check", "--format", "json"],
      kind: :reader,
      skip_exit_code: 2
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
    ]
  ]
]
