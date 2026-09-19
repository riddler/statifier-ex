### Added

- `Statifier.Session.start_link/2` takes `:send_types`, a map of host Event
  I/O Processor types to modules, and `:inherit_send_types` to hand that map
  to invoked children (ADR-0069). A map naming a built-in type (`"scxml"`,
  the SCXML Event I/O Processor URI, or `nil`) is refused with
  `{:error, {:send_types, {:built_in_types, types}}}`.
- `Statifier.Send.Types`, the registered `<send type>` set: `from_send_types/1`
  builds it from that map, `classify/2` answers built-in, registered or
  unsupported for a type, and `unsupported_sends/2` lists every `<send>` in a
  compiled chart whose literal `type` a set does not contain, with its
  location, so a host can refuse a chart before starting it.
- `Statifier.MachineState` carries the set as `send_types` (the `:send_types`
  option on `new/2`, and `put_send_types/2`). The core accepts a `<send>` of a
  registered type without reading its `target` or the route snapshot; any
  other non-built-in type still raises `error.execution`. With no
  `:send_types` passed nothing changes.
