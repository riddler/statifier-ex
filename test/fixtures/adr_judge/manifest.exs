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
      "the same helper generalization as its clean partner, except one of the three callers now reports the element's own location instead of the id attribute's - a location is still reported, at coarser granularity, for that check only"
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
      "the exit-set trace effect is built after the departure reduce instead of before it, so it no longer records the exit-set phase boundary it names and any state-derived field it stamps would take post-departure values - payload and list position unchanged. Re-anchored 2026-08-18 (st-ntf5): the trace call already sits below the reduce in production code, so the captured edit is now the sharper instance of the same violation - it deletes the `pre_exit_state` capture that existed for exactly this reason and stamps `Effect.trace/3` from the post-departure `machine_state` directly; `indexes` and `configuration` are untouched. Judged 2026-08-18 (st-ntf5) with the real CLI: caught as captured. A variant keeping the ADR-0012 comment in place and deleting only the binding line was measured a false negative, so some of this row's signal is the deleted comment naming the rule rather than the stamp swap alone - st-xsb1 holds that gap"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_trace_prestate_captured.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "the exit-set trace call moves below the departure reduce but reads a binding captured before it, so the state it is stamped against is the same one the unmoved call read. Re-anchored 2026-08-18 (st-ntf5): that move is now the production code itself, so the captured edit is a different meaning-preserving change over the same shape - the captured pre-exit binding is renamed `pre_exit_state` -> `exit_set_state` and the post-departure configuration read is hoisted into a local (`resulting_configuration`) immediately before the trace call; neither the state the payload is stamped against nor the carried configuration changes"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_trace_stamp_swapped_comment_kept.diff",
    expect: :violation,
    tier: :subtle,
    note:
      "the exit-set trace's counters are stamped from the post-departure state ... " <>
        "the six-line ADR-0012 comment naming the rule is left in place, so the only " <>
        "signal is the stamp swap itself. Measured a FALSE NEGATIVE by hand on " <>
        "2026-08-18 (st-ntf5) against the real CLI, which is why ADR-0012 grew its " <>
        "pre-mutation-stamping amendment under st-xsb1. Re-measured 2026-08-18 " <>
        "against the amended rubric at seeds 101/202/303 on claude-sonnet-5: caught " <>
        "on all three. The gap this row isolates is closed; it now guards against " <>
        "the amendment being dropped. No gate path runs this row"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_configuration_read_post_departure.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "the payload's `configuration` is read from an explicitly named " <>
        "post-departure binding, which is what ADR-0012 requires of that field - " <>
        "the state the counters are stamped against is unchanged. The adversarial " <>
        "partner to the row above: a judge that learned 'read after the reduce is a " <>
        "violation' scores a false positive here"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_exit_sweep_stamp_swapped_beside_done.diff",
    expect: :violation,
    tier: :subtle,
    note:
      "the exit sweep's `Trace.ExitSet` counters are stamped from the post-sweep " <>
        "state - the `pre_exit_state` binding is deleted and the six-line ADR-0012 " <>
        "comment naming the rule is left standing. The hunk is cut wide " <>
        "(--unified=14) so the `Trace.Done` call eight lines below is visible in " <>
        "the same chunk, stamped post-sweep and correctly so: the row asks the " <>
        "judge to indict one trace call and acquit the other from the same bytes, " <>
        "which no other fixture does. This is the second `Trace.ExitSet` stamp " <>
        "site; `enter_states/2` is a third and is deliberately unfixtured, because " <>
        "the corpus is indexed by rule and tier rather than by production site and " <>
        "this row earns its place on the two-trace discrimination, not on the path " <>
        "string. MEASURED 2026-08-19 (st-6f7h Phase 2): claude-sonnet-5, seeds " <>
        "101/202/303, unanimous majority false negative, no flap. Seeds 202 and " <>
        "303 each 'produced no surviving finding'; seed 101 also missed (exit " <>
        "status 2) but its assertion text was not captured (terminal output " <>
        "truncated before it could be read), so that cell is recorded as an " <>
        "uncaptured miss rather than inferred from the other two. The judge's " <>
        "propose step returned no candidate at all on this row, so the miss is a " <>
        "failure to propose, not a refute-pass over-rejection. Verified " <>
        "2026-08-19: this row's CHANGED LINES are byte-identical to " <>
        "0012_trace_stamp_swapped_comment_kept.diff (same four lines; this row " <>
        "is that edit re-cut at --unified=14 against site B). That row is caught " <>
        "3/3 and this one missed 3/3 on identical bytes, so the edit is " <>
        "exonerated as the cause and only the surrounding context explains the " <>
        "divergence - hunk width, the second trace call, or the production site, " <>
        "unseparated. What is new in this PAIR is the clean half and the wide " <>
        "two-trace hunk, not this row's edit - see " <>
        "docs/plans/260819-st-6f7h-interpreter-exitset-trace-coverage.md Phase 2"
  },
  %{
    key: "adr-0012-debuggability",
    file: "0012_done_trace_stamped_post_sweep.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "the `Trace.Done` payload is stamped from an explicitly named post-sweep " <>
        "binding, which is correct: the boundary this trace names is the end of " <>
        "the run, so the counters that stood at it are the post-sweep ones. The " <>
        "`Trace.ExitSet` stamp above it is untouched and visible in the same hunk. " <>
        "The adversarial partner to the row above, and the corpus's only probe of " <>
        "a legitimately post-mutation STAMP - " <>
        "0012_configuration_read_post_departure.diff probes a legitimately " <>
        "post-mutation FIELD. A judge that learned 'stamp pre-mutation' as an " <>
        "unconditional rule scores a false positive here. MEASURED 2026-08-19 " <>
        "(st-6f7h Phase 2): claude-sonnet-5, seeds 101/202/303, unanimous ok " <>
        "(no finding survived on any seed), no flap. The judge did not fire the " <>
        "over-generalization this row was cut to catch - see " <>
        "docs/plans/260819-st-6f7h-interpreter-exitset-trace-coverage.md Phase 2"
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
    key: "adr-0014-expression-spans",
    file: "0014_trimmed_before_compile.diff",
    expect: :violation,
    tier: :subtle,
    note:
      "the cond source is trimmed before compiling while the location anchor is not adjusted, so the retained span table is offset from the document positions it is resolved against"
  },
  %{
    key: "adr-0014-expression-spans",
    file: "0014_trim_with_anchor_adjust.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "the cond source is trimmed and the location anchor advanced by the trimmed prefix, so resolved spans still land on the document positions they name"
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
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_refusal_reduced_to_check.diff",
    expect: :violation,
    tier: :subtle,
    note:
      "the sabotage refusal is replaced by a check on the script's own missing-notes list, so the clause forbidding an invented note is gone while the surrounding prose still reads as policy"
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_refusal_restated_with_script.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "the sabotage step names the script for the mechanics and restates the refusal in prose, which ADR-0017 point 1 permits"
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_manifest_policy_key.diff",
    expect: :violation,
    tier: :subtle,
    note:
      "a new not-applicable skip pattern reclassifies a stage that would otherwise block, with no prose stating the policy it points back to - ADR-0017 point 6"
  },
  %{
    key: "adr-0015-swallowed-judgment",
    file: "0015_manifest_constant_change.diff",
    expect: :clean,
    tier: :subtle,
    note:
      "an output-format flag is added to a gate command array - a project fact, not a choice about what blocks - which ADR-0017 point 6 says must not be reported"
  }
]
