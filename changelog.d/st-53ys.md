### Added

- `<invoke><content><scxml>...</scxml></content></invoke>` now compiles, and
  starts the inline child document as a session when that child declares its
  own namespace. `<content>`'s element children are preserved as the verbatim
  source they were written as, and compiled when the invocation runs; a
  `<content>` that specifies both an `expr` and inline markup is rejected as
  the same 5.6.2 violation as `expr` alongside inline text.
- Two limitations on that inline markup, both at invoke time rather than
  compile time. The child is compiled as a standalone document, so it must
  carry its own `xmlns="http://www.w3.org/2005/07/scxml"`: a child element
  relying on the enclosing document's default namespace raises
  `error.communication` when the invocation runs. For the same reason, markup
  whose root uses a namespace prefix declared on an ancestor outside
  `<content>` is not yet supported.
