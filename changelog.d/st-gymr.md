### Added

- `Statifier.Publish.findings/2` reports row S19: a literal write location (an `<assign>`'s `location`, a `<send>`'s or an `<invoke>`'s `idlocation`, or a target an empty `<finalize>` writes) that does not parse (`:parse_error`) or is not an assignable location (`:not_assignable`, `:invalid_node`, `:computed_key`), at the attribute's location with `data: %{attribute: :location | :idlocation | :namelist, source: source}`, before the runtime write refuses it.
