### Fixed

- Attribute values are normalized per XML 1.0 3.3.3: a literal tab, newline, or
  carriage return inside an attribute value becomes a space, while a character
  reference such as `&#10;` keeps its character. A `cond` or `expr` wrapped
  across source lines now compiles from a single-line string.
