### Added

- A send processor may implement the optional `check_registration/2`, which answers `:ok` or `{:error, reason}` for a registration's type string and options. A fresh session start asks it for every registration whose module exports it and refuses the first one rejected with `{:error, {:send_types, {:invalid_registration, type, reason}}}` before any session process is spawned, so with no crash report; a resume does not ask it. A processor that does not implement it is not asked, and a session that registers nothing sees nothing new.

### Changed

- A fresh session start whose `Statifier.Send.BasicHTTP` registration has no string `:base_url`, or options that are not a keyword list, now answers `{:error, {:send_types, {:invalid_registration, type, {:missing_option, :base_url}}}}`, refused before any session process is spawned and so with no crash report, instead of the error a session process that exited gave (`{:error, {%ArgumentError{}, stacktrace}}` for a missing option). A host that matched the `ArgumentError` shape matches the named refusal instead. A resumed session is not refused and does not change: its position carries the `_ioprocessors` entries it started with. `ioprocessors_entry/2` still raises `ArgumentError` for a direct caller.
