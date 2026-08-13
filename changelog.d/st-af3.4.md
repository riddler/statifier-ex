### Added

- `<assign>` is now supported: `expr` or child content writes a value at a
  deep `location` path (`user.profile.name`, `items[0].sku`), auto-vivifying
  intermediate maps and lists along the way.
