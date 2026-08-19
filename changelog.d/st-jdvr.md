### Added

- Documents how to depend on v2 before its release: pin a commit reachable
  from `main` as a git dependency, and read
  `git diff <old>..<new> -- changelog.d/ CHANGELOG.md` as the upgrade
  briefing. Any public API or behavior may change between two pins
  (see ADR-0061).
