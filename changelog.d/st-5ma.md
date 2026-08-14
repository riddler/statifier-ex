### Changed

- Expression syntax follows predicator 7.0. `null` is now a reserved word
  alongside `if`, `else`, `while`, and `undefined`: using it as a bare
  identifier, as a property name after `.`, or as an unquoted object key is
  a compile error. Quote an object key (`{"null": 1}`) to keep it. A bare
  `null` is now the null literal rather than a variable load. A declared
  datamodel entry with no value still reads as `undefined`, not `null`, so
  `x === undefined` keeps its previous answer.
- `Math.pow` and `Math.sqrt` return an integer, not a float, when both the
  base/radicand and the result are integer-exact (`Math.pow(2, 3)` is now
  `8`, not `8.0`); a float argument or a non-integer result is unaffected.
- Raises the `predicator` dependency floor from `~> 5.0` to `~> 7.0`.
