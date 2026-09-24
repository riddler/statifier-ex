# W3C IRP tests the predicator datamodel cannot run, with the reason.
#
# Reasons:
#   :needs_predicator_feature - blocked on an upstream predicator capability
#   :needs_basichttp         - BasicHTTP Event I/O Processor, out of scope
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
  "test201" =>
    {:needs_basichttp,
     "BasicHTTP Event I/O Processor as a <send type>: the event is delivered only by a processor that implements HTTP POST"},
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
     "top-level <data> values supplied at instantiation: the child is loaded from src, which is never dereferenced (ADR-0038)"},
  "test509" => {:needs_basichttp, "BasicHTTP Event I/O Processor MUST accept POST requests"},
  "test510" =>
    {:needs_basichttp, "BasicHTTP Event I/O Processor MUST validate and enqueue the message"},
  "test518" =>
    {:needs_basichttp, "BasicHTTP Event I/O Processor namelist -> POST parameter mapping"},
  "test519" =>
    {:needs_basichttp, "BasicHTTP Event I/O Processor param children -> POST parameter mapping"},
  "test520" => {:needs_basichttp, "BasicHTTP Event I/O Processor content child -> message body"},
  "test522" =>
    {:needs_basichttp, "BasicHTTP Event I/O Processor _ioprocessors['basichttp'] entry"},
  "test531" => {:needs_basichttp, "BasicHTTP Event I/O Processor _scxmleventname -> event name"},
  "test532" =>
    {:needs_basichttp, "BasicHTTP Event I/O Processor HTTP method -> event name fallback"},
  "test534" => {:needs_basichttp, "BasicHTTP Event I/O Processor send/@event -> _scxmleventname"},
  "test567" => {:needs_basichttp, "BasicHTTP Event I/O Processor message content -> _event.data"},
  "test577" =>
    {:needs_basichttp, "BasicHTTP Event I/O Processor missing target -> error.communication"}
}
