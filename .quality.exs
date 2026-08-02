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
  ]

  # Once the conformance corpus is ported, the regression ratchet runs as its
  # own stage so a regression is a named failure, not a buried test count:
  #
  # custom: [
  #   regression: [
  #     command: "mix",
  #     args: ["test.regression"],
  #     description: "SCION/W3C regression ratchet"
  #   ]
  # ]
]
