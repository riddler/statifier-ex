### Fixed

- A string literal holding a non-ASCII character (U+00E9, U+20AC or U+1D11E, for example) in an expression evaluates to the UTF-8 string written, so it reaches `_event.data` and a `Statifier.Send.BasicHTTP` text body unchanged, where before each such character became one byte, the low eight bits of its code point; the fix is predicator's, so the requirement moves from `{:predicator, "~> 9.0"}` to `{:predicator, "~> 9.4"}`, and a host that holds predicator at 9.0 to 9.3 moves to 9.4 with it (`mix deps.update predicator`).

### Changed

- With predicator 9.4, a `\u` or `\U` escape in an expression's string literal is refused when the expression is evaluated, so a `<data expr>` or any other expression carrying one raises `error.execution`, where before the backslash was dropped and the letters kept (`'caf\u00e9'` read as `cafu00e9`); write the character itself instead.
