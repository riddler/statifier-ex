### Added

- `<send delay>`/`delayexpr` accepts a native predicator duration value
  (e.g. a computed `2s + backoff`) as well as a string, and recognizes the
  full `{y,mo,w,d,h,m,s,ms}` unit set rather than the SCXML schema's
  `{ms,s,m,h,d}` subset.
