### Added

- `<invoke><content><scxml>...</scxml></content></invoke>` now compiles and
  starts the inline child document as a session. `<content>`'s element
  children are preserved as the verbatim source they were written as, and
  compiled when the invocation runs; a `<content>` that specifies both an
  `expr` and inline markup is rejected as the same 5.6.2 violation as `expr`
  alongside inline text. Markup whose root element uses a namespace prefix
  declared on an ancestor outside `<content>` is not yet supported.
