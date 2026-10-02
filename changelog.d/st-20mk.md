### Changed

- The W3C Basic HTTP documents test518, test519, test520 and test534 now check the decoded event their transition takes, not its name alone: test518 that the namelist location arrives in `_event.data` with its value, test519 that the named parameter does, test520 that `_event.data` is the sent body text under both of the suite's encoded spellings, and test534 that the `_scxmleventname` parameter is the event's name. No claim narrows. The corpus hash in `conformance/manifest.json` moves, so an implementation that vendors the corpus re-vendors it at the next tag.
