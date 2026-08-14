### Fixed

- `<scxml initial="...">` naming a state nested under a wrapper state no
  longer fails validation. The document enters that state together with
  every ancestor between it and the root, per spec 3.11.
