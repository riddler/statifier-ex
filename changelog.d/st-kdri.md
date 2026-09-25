### Added

- `Statifier.Publish.findings/2` reports row S12: an expression or `<script>` body that reads a root no `<data>`, `<foreach>` name or `<script>` assignment in the chart declares and that is not a system variable (`:undeclared_root`), at the attribute's location with `data: %{root: root, source: source}`, before the runtime raises predicator's undefined-variable error.
