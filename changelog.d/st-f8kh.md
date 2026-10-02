### Added

- `Statifier.Session.refresh_ioprocessors/1` answers `{:error, {:ioprocessors_entry, type, exception}}` when a registered processor's entry raises during the refresh, and the session keeps running at the position it held before the call: no entry is stored. `Statifier.MachineState.refresh_ioprocessors/1` still raises the entry's exception. See ADR-0075's Amendments of 2026-10-02.
