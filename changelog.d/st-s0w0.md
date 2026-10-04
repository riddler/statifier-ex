### Changed

- `conformance/schema/case.json` refuses a step's `expect_position` whose `history_values` gives a history state anything but an array of unique, non-empty state ids, and the `statifier/library/loan_lost_after_timer` case states the position after the step that stops its chart (`running` false, an empty configuration, `lost` still in `states_to_invoke`); the corpus hash in `conformance/manifest.json` moves, so a sibling implementation that vendors the corpus re-vendors it at the next tag.
