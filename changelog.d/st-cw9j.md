### Changed

- `Mix.Statifier.Corpus.PositionExpectation.compare/3`, which the conformance runner uses to check a step's `expect_position`, compares numbers by JSON value: a float the chart holds agrees with an expected integer of the same value (`2.0` with `2`), where before it disagreed and named no member; a number that differs in value still disagrees, and the message names the member with both values.
