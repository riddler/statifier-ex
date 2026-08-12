### Changed

- Expression syntax follows predicator 5.0. `if`, `else`, `while` and
  `undefined` are now reserved words: using one as a bare identifier, as a
  property name after `.`, or as an unquoted object key is a compile error.
  Quote an object key (`{"if": 1}`) to keep it. A bare `undefined` is now the
  undefined literal rather than a variable load. The conformance corpus uses
  none of the four, so no bundled test changed.
