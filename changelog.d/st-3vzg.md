### Added

- A `<send>` whose type a session registered under `:send_types` is now
  handed to the module registered for it, which implements the new
  `Statifier.Send.Processor` behaviour (ADR-0069): its pure `deliver/3`
  receives the send effect and the event built from it, and its `perform/2`
  does the delivery. The library never parses such a send's `target`. A
  delayed send of a registered type is the processor's timer: the session
  schedules nothing for it. A `<cancel>` naming such a send reaches the same
  processor's `cancel/2`.
- `Statifier.Send.Event.build/3` builds the event a `<send>` delivers from
  its send effect and the sender's session id, with `origin` and
  `origintype` a processor may override. The session's own delivered
  events are built by it, so a host that drives the core without a session
  gets the same event.
- `%Statifier.Effect.Send{}` has an `ordinal` field: an integer on a send
  of a registered type, from the same sequence as the delayed-send and
  cancel ordinals, so a processor can key two sends that share an id inside
  a `<foreach>`; `nil` on a send of a built-in type, which advances no
  counter (ADR-0059).
