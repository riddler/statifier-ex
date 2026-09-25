### Added

- `Statifier.Publish.findings/2` reports row S13 of `docs/publish-time-checks.md`: every compile failure the compiler defers to run time (a `<data expr>`, an `<assign expr>`, a `<script>` body in executable content or at the top level, a `<send>` or `<invoke>` `namelist` entry), as kind `:compile_error` at the failing expression's location with `data: %{element: :data | :assign | :script | :send | :invoke, source: source}`, in document order, before the node raises `error.execution` at run time.
