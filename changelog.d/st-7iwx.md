### Changed

- `Statifier.Send.BasicHTTP` sends a `<content expr>` that evaluates to a struct (a `Date`, for example) as its `inspect/1` text, as `text/plain`: a struct that does not enumerate as parameter pairs (a `Date`) made planning the send raise and the session performing it exit, and one that does (a `MapSet` of two-element tuples) was sent as a form body of those pairs.
