### Added

- `Statifier.Session.failed_send/3` lets a host report that the processor
  it registered for a `<send>` type could not deliver a send while the
  sender still exists (ADR-0069). The sender then sees `error.communication`
  on its internal queue, with `_event.sendid` set to the send's id. A call
  for a sender that has finished or no longer exists writes nothing, and
  recording that miss is the host's job. A host with no session process
  makes the same write through `Statifier.Interpreter.deliver_internal/5`.
- `_ioprocessors` now has an entry for each send type a session registers
  under `:send_types`, keyed by the type string. The value is the map the
  processor returns from the new optional
  `Statifier.Send.Processor.ioprocessors_entry/1` callback, or an empty map
  when the processor does not implement it. The SCXML processor's own entry
  is unchanged. A resumed session keeps the entries it started with.
  `Statifier.Send.Types` carries each type's value in a new `entries` field,
  and `Statifier.Evaluator.SystemVariables.initial/3` takes the registered
  set as an optional third argument.
