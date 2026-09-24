### Changed

- `<invoke type="http://www.w3.org/TR/scxml">`, the SCXML type URI without its trailing slash, now starts an SCXML child session like `"scxml"` and `http://www.w3.org/TR/scxml/` instead of raising `error.execution`; `Statifier.Send.Target.supported_invoke_type?/1` answers `true` for it, and `<send type>` is unchanged.
