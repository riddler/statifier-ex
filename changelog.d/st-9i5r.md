### Added

- `Statifier.Machine.State` and `Statifier.Machine.Transition` each carry an
  `attribute_locations` field, the source node's written-attribute value
  spans carried through compilation verbatim - the same treatment
  `Statifier.Machine.Invoke` already had. An entry exists only for an
  attribute the author actually wrote, so `Map.has_key?/2` on the map answers
  "was this written or defaulted" for a transition's `type` or a history's
  `type`, which the compiled field's value alone cannot. The root state
  (index 0) carries the `<scxml>` element's own attribute spans; the
  interpreter-synthesized initial transition carries `%{}`.
