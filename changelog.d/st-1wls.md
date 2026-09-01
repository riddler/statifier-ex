### Changed

- `Statifier.Invoke.SyncHandler.Adapter.dispatch/4` now types its `ctx`
  argument as the new `t:Statifier.Invoke.SyncHandler.Adapter.dispatch_ctx/0`
  (any map) instead of `t:Statifier.Invoke.SyncHandler.ctx/0`. `dispatch/4` is
  public for a host driving the pure core with no session to report to, and
  such a host has no `session_id` to put in a plan context; the narrower spec
  made that documented use a dialyzer contract violation. Routing reads no key
  of the context and hands it to the handler untouched. `perform/3` still
  requires the plan context, since reporting an answer needs `ctx.session_id`,
  and every existing caller keeps type-checking unchanged.
