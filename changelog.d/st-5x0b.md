### Fixed

- Character data is folded per XML 1.0 2.11: a literal CRLF pair or a lone
  literal CR in a `<script>`, `<content>`, `<data>`, or `<assign>` text body
  becomes a single `\n`, while a `\r` decoded from a character reference such
  as `&#13;` keeps its character. `Script.text`, `Content.text`, `Data.text`,
  and `Assign.text` now match what a conforming XML processor hands the
  engine on a CRLF checkout.
