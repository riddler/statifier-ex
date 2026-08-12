# Doctor configuration for Statifier-ex (st-1xz).
#
# Read by `mix doctor` and, in the quality gate, by ExQuality's Doctor stage,
# which shells out to `mix doctor --raise` and parses the coverage summary to
# decide pass or fail.
#
# ADR-0011 guards this path: an edit here needs an entry in
# docs/quality-gate-changes.md. That is deliberate. Doc-coverage thresholds are
# a discipline decision, and a discipline decision should be a thing a human
# signs for when it moves.
#
# Every threshold below is 100% - at or above doctor's own defaults on every
# axis (deps/doctor/lib/config.ex:37-52), never bent to fit the codebase.
# `ignore_modules` and `ignore_paths` stay empty: the measured codebase meets
# every threshold without excluding anything.
#
# `raise: false` below is not the enforcement switch, and turning it on would
# change nothing that matters: a shortfall exits non-zero either way, whether
# the gate runs `mix doctor --raise` or a developer runs a bare `mix doctor`.
# The flag only picks how the failure surfaces - an exception versus a report
# and a non-zero status - and the report is the more readable of the two.
%Doctor.Config{
  ignore_modules: [],
  ignore_paths: [],
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 100,
  min_overall_doc_coverage: 100,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 100,
  exception_moduledoc_required: true,
  raise: false,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false,
  failed: false
}
