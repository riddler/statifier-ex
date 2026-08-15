### Added

- `<invoke>` is now lowered, validated, and compiled, including `<param>`,
  `<content>`, and `<finalize>`. The interpreter runs the Appendix D
  invoke and cancel-invoke passes and emits `{:invoke, _}`,
  `{:cancel_invoke, _}`, and `{:autoforward, _}` effects; `<finalize>` runs
  in the core before transition selection. Child sessions are not started
  yet - no process is spawned and no data is delivered to or from an
  invocation.
