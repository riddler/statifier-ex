### Added

- `Statifier.Publish.findings/2` reports row S11: a literal write location (an `<assign>`'s `location`, a `<send>`'s or an `<invoke>`'s `idlocation`, or a target an empty `<finalize>` writes) whose root begins with `_` (`:system_variable`) or is not one the chart declares with a `<data>` id, a `<foreach>` name or a `<script>` assignment (`:unbound_location`), at the attribute's location with `data: %{attribute: :location | :idlocation | :namelist, source: source, root: root}`, before the runtime write refuses it.
