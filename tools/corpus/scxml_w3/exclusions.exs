# W3C IRP tests the predicator datamodel cannot run, with the reason.
#
# Reasons:
#   :needs_predicator_feature - blocked on an upstream predicator capability
#   :needs_invoke_src        - the case passes only when <invoke src> is
#                              resolved to a document; the library never
#                              dereferences src (ADR-0038) and the corpus
#                              harness supplies no invoke_source resolver on
#                              purpose. An entry is added only when the case
#                              is observed to pass with a resolver supplied
#                              and to fail without one - a case that also
#                              fails for another reason stays emitted and
#                              failing. Like every reason here, it is an atom
#                              beside prose, the record of the exclusion
#                              ADR-0004 has the corpus tooling keep.
#
# NOTE: no boundness test is excluded here. Boundness is spelled
# `=== undefined` / `!== undefined` against predicator 5.0's `undefined`
# literal, tested against a root the datamodel binds - conf:emptyEventData
# (test343, test488, test528) is emitted as `_event.data === undefined`. A
# `Var<n>` boundness cond depends on st-af3.3 seeding the declared `<data>` it
# names, not on an exclusion here.

%{
  "test216" =>
    {:needs_invoke_src,
     "<invoke srcexpr> evaluated as src: the child is loaded from src, which is never dereferenced (ADR-0038)"},
  "test226" =>
    {:needs_invoke_src,
     "<invoke src> with <param>: the child is loaded from src, which is never dereferenced (ADR-0038)"},
  "test239" =>
    {:needs_invoke_src,
     "<invoke src> markup executed as SCXML: the child is loaded from src, which is never dereferenced (ADR-0038)"},
  "test242" =>
    {:needs_invoke_src,
     "<invoke src> and <content> treated identically: the src child is never loaded, as src is never dereferenced (ADR-0038)"},
  "test276" =>
    {:needs_invoke_src,
     "top-level <data> values supplied at instantiation: the child is loaded from src, which is never dereferenced (ADR-0038)"}
}
