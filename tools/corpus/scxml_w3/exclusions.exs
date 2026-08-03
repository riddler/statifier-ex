# W3C IRP tests the predicator datamodel cannot run, with the reason.
#
# Reasons:
#   :needs_script            - <script>/statements; permanently out (ADR-0004)
#   :needs_predicator_feature - blocked on an upstream predicator capability
#   :needs_basichttp         - BasicHTTP Event I/O Processor, out of scope
#
# NOTE: conf:emptyEventData (test343, test488, test528) is NOT excluded - it is
# emitted as `_event.data === _statifier_unbound`, which holds only if the
# engine represents absent event data as undefined rather than %{}. If the
# datamodel decides otherwise, those three move here.

%{
  "test302" => {:needs_script, "conf:script - predicator has no statement layer"},
  "test303" => {:needs_script, "conf:script"},
  "test304" => {:needs_script, "conf:script"},
  "test224" =>
    {:needs_predicator_feature,
     "conf:varPrefix - no string prefix/substring function (docs/datamodel.md seam 5)"},
  "test525" =>
    {:needs_predicator_feature,
     "conf:extendArray - no list concatenation; `Var1 + [4]` raises TypeMismatchError (docs/datamodel.md seam 6)"},
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
