### Changed

- `Statifier.Validator.validate/3` decides whether a `<state>`'s `initial` target is its descendant by the document's structure for every state: a document where two states share an id and one's `initial` names a state under the other now reports `{:initial_not_descendant, target, id}` beside the `{:duplicate_id, id}` it already reported.
