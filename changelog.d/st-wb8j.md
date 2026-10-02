### Changed

- `Statifier.Lowering.lower/2`, and so `Statifier.compile/2`, answers `{:error, [%Statifier.Lowering.Error{reason: {:unexpected_root, name}}]}` for a document whose root is any SCXML element other than `<scxml>` (`<state>`, `<parallel>`, `<final>`, `<history>`, `<transition>`, ...) instead of raising `BadMapError`, and `{:unsupported_element, "scxml"}` for an `<scxml>` nested below the root instead of raising `FunctionClauseError`. A caller that rescued either raise matches the error tuple instead.
