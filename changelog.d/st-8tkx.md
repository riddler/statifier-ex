### Changed

- `Statifier.Validator.validate/2`, and so `Statifier.compile/2`, now checks a `<send>`'s `<param>` children as it already checked `<donedata>` and `<invoke>` params (spec 5.7: exactly one of `expr` and `location`). A `<send>` `<param>` with neither attribute is refused as `{:param_no_value, name}` instead of `Statifier.compile/2` raising `FunctionClauseError`. A `<send>` `<param>` with both attributes is now refused as `{:param_expr_and_location, name}`; it compiled before, taking `location`, so a chart that carried one must drop one of the two attributes.
