### Removed

- Drops the `uxid` dependency. Session ids keep the same `sess_`-prefixed,
  hyphen-free, time-sortable format, so nothing that reads `_sessionid` needs
  to change.
