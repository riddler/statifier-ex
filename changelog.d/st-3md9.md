### Fixed

- `Statifier.Testing.HandlerCase`'s check that a handler exception propagates waits up to ten seconds for the session's exit instead of one, so the generated test no longer fails on a loaded CI machine; a passing run returns as soon as the exit arrives.
