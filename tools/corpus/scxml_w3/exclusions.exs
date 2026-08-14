# W3C IRP tests the predicator datamodel cannot run, with the reason.
#
# Reasons:
#   :needs_predicator_feature - blocked on an upstream predicator capability
#   :needs_basichttp         - BasicHTTP Event I/O Processor, out of scope
#
# NOTE: no boundness test is excluded here. Boundness is spelled
# `=== undefined` / `!== undefined` against predicator 5.0's `undefined`
# literal, tested against a root the datamodel binds - conf:emptyEventData
# (test343, test488, test528) is emitted as `_event.data === undefined`. A
# `Var<n>` boundness cond depends on st-af3.3 seeding the declared `<data>` it
# names, not on an exclusion here.

%{
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
