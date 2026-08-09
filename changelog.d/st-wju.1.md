### Added

- `Statifier.Compiler.compile/1` compiles a validated `Statifier.Document` into
  a `Statifier.Machine`: states interned to a flat, document-order tuple with
  parent pointers and descendant ranges, transitions and executable content
  given dense document-order indexes, and every `cond`/`expr`/`<content>`
  compiled once into `Statifier.Machine.expr()`.

### Changed

- Raises the `predicator` dependency floor from `~> 3.8` to `~> 4.0`.
