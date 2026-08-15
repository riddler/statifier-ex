### Added

- `<send>` targets beyond the sending session: `#_internal`/`_internal`
  route to the internal queue, `#_scxml_<sessionid>` addressed at the
  sending session's own id delivers to its own inbox, and any other
  `#_scxml_<sessionid>`, `#_parent`, or `#_<invokeid>` raises
  `error.communication` on the sending session. An unsupported `type` or
  an unrecognized target raises `error.execution`, evaluated at `<send>`
  time rather than at dispatch. Delivered events now carry `origin`,
  `origintype`, and `sendid` per spec 5.10.1/C.1.
