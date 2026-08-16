### Added

- `<send target="#_<invokeid>">`, addressing one specific `<invoke>`d child
  session directly, now delivers the event to that child's external queue
  when the invocation is still live. An invokeid naming no live
  invocation - never invoked, or since cancelled or exited - raises
  `error.communication` on the sending session, per the SCXML Event I/O
  Processor (C.1).
