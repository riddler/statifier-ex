### Changed

- Narrows one of the two `<invoke><content>` inline-markup limitations
  `st-53ys`'s fragment documented: a child `<scxml>` that declares no
  `xmlns` at all now compiles and starts, per spec Appendix G.6's rule that
  such markup is placed in the SCXML namespace. A child that declares a
  namespace other than SCXML's still raises `error.communication` when the
  invocation runs. A root using a namespace prefix declared on an ancestor
  outside `<content>` is unchanged in intent - the declaration is still lost
  with the slice, and only happens to compile when the prefix was bound to
  the SCXML namespace anyway.

### Added

- `Statifier.compile/2` accepts an options list (`compile/1`'s existing
  behavior is `compile/2` with no options). The one recognized option,
  `invoke_content_markup: true`, is for compiling an `<invoke><content>`
  markup slice standalone; it is not a general validation off-switch.
