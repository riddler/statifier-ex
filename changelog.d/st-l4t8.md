### Changed

- `Statifier.Validator.validate/2`, and so `Statifier.compile/2`, decides whether a `<history>` default target sits under the history's parent by the document's structure for every parent, so a target under another state that shares the parent's `id` is reported as `{:initial_not_descendant, target, parent_id}`: such a document was already refused for the shared `id` (as a duplicate, or as empty) and now carries this entry too.
