### Changed

- `Statifier.Send.BasicHTTP` sends a `<content expr>` that evaluates to a struct (a `Date`, for example) as its `inspect/1` text, as `text/plain`, where planning the send raised and the session performing it exited.
