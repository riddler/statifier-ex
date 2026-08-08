[
  %{
    key: "adr-0012-debuggability",
    file: "0012_dropped_location.diff",
    expect: :violation,
    note: "st-6f7 live repro: enforced :location dropped from Document.Content"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_dropped_trace.diff",
    expect: :violation,
    note: "trace effect removed from a phase boundary in the interpreter"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_rename_keeps_location.diff",
    expect: :clean,
    note: "field rename threads :location through unchanged"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_pure_docs_change.diff",
    expect: :clean,
    note: "moduledoc-only edit inside lib/statifier/"
  },
  %{
    key: "adr-0014-expression-spans",
    file: "0014_span_table_dropped.diff",
    expect: :violation,
    note: "compiled-expression value loses its span table"
  },
  %{
    key: "adr-0014-expression-spans",
    file: "0014_span_preserving_refactor.diff",
    expect: :clean,
    note: "helper extracted, spans preserved on both sides"
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_delegated_judgment.diff",
    expect: :violation,
    note: "a SKILL.md step that stated a policy now delegates it to a script"
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_mechanics_only.diff",
    expect: :clean,
    note: "SKILL.md step names a script for mechanics, restates the policy in prose"
  }
]
