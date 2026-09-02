### Added

- `Statifier.Effect.Done` and `Statifier.Effect.Trace.Done` carry
  `donedata_error`, so a top-level `<final>` whose `<donedata>` expression
  failed is distinguishable from one that declared no `<donedata>` at all -
  both leave `donedata: :undefined`, and the `error.execution` the failure
  raises is discarded with the internal queue at exit (ADR-0021's 2026-09-02
  note). It is `nil` on success and on a bare final, and carries the first
  failure in document order when several `<param>`s fail.

### Changed

- `Statifier.Session.Recording`'s binary format version is 5. Version-4 blobs
  still decode, defaulting `donedata_error: nil` onto their stored done
  effects. Hosts reading `Effect.Done` off a recording gain the field; hosts
  that ignore it are unaffected. `statifier_persistence`'s donedata-failure
  handling, which asserts `donedata: :undefined`, keeps passing unchanged.
