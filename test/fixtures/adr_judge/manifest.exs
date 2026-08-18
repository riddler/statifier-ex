[
  %{
    key: "adr-0012-debuggability",
    file: "0012_dropped_location.diff",
    expect: :violation,
    tier: :blatant,
    note: "live repro: enforced :location dropped from Document.Content"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_dropped_trace.diff",
    expect: :violation,
    tier: :blatant,
    note: "trace effect removed from a phase boundary in the interpreter"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_rename_keeps_location.diff",
    expect: :clean,
    tier: :blatant,
    note: "field rename threads :location through unchanged"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_pure_docs_change.diff",
    expect: :clean,
    tier: :blatant,
    note: "moduledoc-only edit inside lib/statifier/"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_location_precision_one_caller.diff",
    expect: :violation,
    tier: :subtle,
    note:
      "one of three callers of the shared id-location helper now reports the element span instead of the id attribute's - a location is still reported, at coarser granularity, for that check only"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_location_helper_extracted.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "the shared id-location helper is generalized and renamed; every caller still resolves the attribute-level location"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_trace_after_departure.diff",
    expect: :violation,
    tier: :subtle,
    note:
      "the exit-set trace effect is built after the departure reduce instead of before it, so it is stamped against post-departure state while its payload and list position are unchanged"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_trace_binding_renamed.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "the exit-set trace call moves below the departure reduce but reads a binding captured before it, so the stamped state is unchanged"
  },
  %{
    key: "adr-0014-expression-spans",
    file: "0014_span_table_dropped.diff",
    expect: :violation,
    tier: :blatant,
    note: "compiled-expression value loses its span table"
  },
  %{
    key: "adr-0014-expression-spans",
    file: "0014_span_preserving_refactor.diff",
    expect: :clean,
    tier: :blatant,
    note: "helper extracted, spans preserved on both sides"
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_delegated_judgment.diff",
    expect: :violation,
    tier: :blatant,
    note: "a wurk extension step that stated a policy now delegates it to a script"
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_mechanics_only.diff",
    expect: :clean,
    tier: :blatant,
    note: "wurk extension step names a script for mechanics, restates the policy in prose"
  }
]
