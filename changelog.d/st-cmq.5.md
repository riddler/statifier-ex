### Added

- `<send>` targets beyond the sending session: `#_internal`/`_internal`
  route to the internal queue, `#_scxml_<sessionid>` addressed at the
  sending session's own id delivers to its own inbox, and any other
  `#_scxml_<sessionid>`, `#_parent`, or `#_<invokeid>` raises
  `error.communication` on the sending session. An unsupported `type` or
  an unrecognized target raises `error.execution`, evaluated at `<send>`
  time rather than at dispatch. Delivered events now carry `origin`,
  `origintype`, and `sendid` per spec 5.10.1/C.1.
- `Statifier.Supervisor`, the optional session runtime an embedder places
  in their own supervision tree, holding the library's session registry
  and the dynamic supervisor sessions start on. The library ships no
  application callback, so a host that never places it starts no
  processes.
- `Statifier.start_session/2`, which starts a session on that runtime and
  registers it, making it reachable by `#_scxml_<sessionid>` from another
  session. A bare `Statifier.Session.start_link/2` session stays legal and
  unregistered, and is not reachable that way.

### Changed

- `Statifier.Session` is now `restart: :temporary` (was `:transient`). A
  supervisor restart would mint a fresh `sess_` id and lose the crashed
  session's state, so restarting was never recoverable.
