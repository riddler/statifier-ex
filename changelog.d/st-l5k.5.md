### Changed

- Rejects an SCXML document whose root is missing `xmlns` or `version`, or whose
  `version` is not `"1.0"`. v1 silently inserted both into the source and
  accepted any version.
