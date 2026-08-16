### Added

- `<invoke type="scxml">` now starts a real child session, under an
  embedder-placed `Statifier.Supervisor`. The child's datamodel is seeded
  from `<param>`/namelist values whose names match one of its own top-level
  `<data>` ids; the parent monitors the child and the child monitors the
  parent. `<send target="#_parent">` (or `_parent`, both spellings accepted)
  reaches the parent, running the invoking state's `<finalize>` first; a
  child that reaches a top-level final delivers `done.invoke.<invokeid>`
  to the parent carrying its `<donedata>`; every external event the parent
  processes is forwarded verbatim to each `autoforward="true"` invocation;
  and exiting the invoking state stops the child (running its `<onexit>`
  handlers) and discards any of its events still queued at the parent.
  `<send target="#_<invokeid>">`, addressing one specific invocation
  directly rather than `#_parent`, is not yet routed and still raises
  `error.communication`.
- A new `invoke_source` option on `Statifier.start_session/2` and
  `Statifier.Session.start_link/2`: a function `src -> {:ok, Machine.t()} |
  {:error, term()}` an embedder supplies to resolve `<invoke src="...">`.
  The library never fetches a `src` itself - with no `invoke_source`
  configured, a `src`-based `<invoke>` raises `error.communication` on the
  parent, the same as any other failure to start the invoked child. An
  `<invoke>` with an inline `<content><scxml>...</scxml></content>` child
  does not start a session either - the document fails to compile at all,
  independent of invoke - but a `<content>` holding the child document as
  literal markup text (for example CDATA-wrapped) works today, and is the
  supported way to embed a child document inline until element children of
  `<content>` are supported.
