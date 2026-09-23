### Added

- Adds `Statifier.Chart.diff/3`, which classifies two compiled charts as `:identical`, `:compatible`, `:mapped` or `:breaking` and lists the reasons (a state an execution could hold with no counterpart, a removed transition, event or `<data>` key, each addition); a caller passes renamed states as a plain `mapping:` from old state ids to new ones, and the function never moves an execution.
