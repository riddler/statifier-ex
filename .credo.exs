# Credo configuration, generated with `mix credo gen.config` and then edited
# (st-vbu).
#
# Generating this file means the repo now owns the full check list. That is the
# tradeoff made deliberately: explicit control over which checks run, at the
# cost of new checks in future credo releases no longer switching themselves on.
# `Credo.Check.Design.MissingCheckInConfig` is enabled below to keep that cost
# from going unnoticed - it fails the run when a check credo ships appears in
# neither list, so a version bump surfaces the new checks as a decision to make
# rather than silently skipping them.
#
# Checks are excluded by path or by check parameter, with a comment giving the
# reason. Never by weakening or removing a check.
#
# `strict: true` mirrors what .quality.exs passes, so a bare `mix credo` and the
# quality gate agree on what passing means.
#
# If you find anything wrong or unclear in this file, please report an
# issue on GitHub: https://github.com/rrrene/credo/issues
#
%{
  #
  # You can have as many configs as you like in the `configs:` field.
  configs: [
    %{
      #
      # Run any config using `mix credo -C <name>`. If no config name is given
      # "default" is used.
      #
      name: "default",
      #
      # These are the files included in the analysis:
      files: %{
        #
        # You can give explicit globs or simply directories.
        # In the latter case `**/*.{ex,exs}` will be used.
        #
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      #
      # Load and configure plugins here:
      #
      plugins: [],
      #
      # If you create your own checks, you must specify the source files for
      # them here, so they can be loaded by Credo before running the analysis.
      #
      requires: [],
      #
      # If you want to enforce a style guide and need a more traditional linting
      # experience, you can change `strict` to `true` below:
      #
      strict: true,
      #
      # To modify the timeout for parsing files, change this value:
      #
      parse_timeout: 5000,
      #
      # If you want to use uncolored output by default, you can change `color`
      # to `false` below:
      #
      color: true,
      #
      # You can customize the parameters of any check by adding a second element
      # to the tuple.
      #
      checks: %{
        #
        # To disable a check move it to the `:disabled` section.
        #
        enabled: [
          #
          ## Consistency Checks
          #
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},

          #
          ## Design Checks
          #
          # You can customize the priority of any check
          # Priority values are: `low, normal, high, higher`
          #
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},
          {Credo.Check.Design.TagFIXME, []},
          # You can also customize the exit_status of each check.
          # If you don't want TODO comments to cause `mix credo` to fail, just
          # set this value to 0 (zero).
          #
          {Credo.Check.Design.TagTODO, [exit_status: 2]},
          #
          {Credo.Check.Design.MissingCheckInConfig, []},
          {Credo.Check.Design.RedundantConfigComments, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},

          #
          ## Readability Checks
          #
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          # Specs and SpecParameterNames enforce the CLAUDE.md rule that public
          # functions carry a @spec. Deliberately not scoped off test/: the
          # harness code under test/support/ is the only test code that defines
          # public functions, and it already specs them.
          {Credo.Check.Readability.SpecParameterNames, []},
          {Credo.Check.Readability.Specs, []},
          # Excluded from the generated W3C corpus: the description strings are
          # copied verbatim from the IRP manifest and often quote spec text like
          # 'type' or "internal", which the check would rather see as a sigil.
          # Machine-emitted, not hand-authored - not worth reshaping (docs/testing.md).
          {Credo.Check.Readability.StringSigils, [files: %{excluded: ["test/scxml_tests/"]}]},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.UnusedFunctionParameterPattern, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Readability.WithSingleClause, []},

          #
          ## Refactoring Opportunities
          #
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.FunctionArity, []},
          # Excluded where printing to stdout is the point, not a leftover
          # debug statement: test helpers and the harness may print freely, and
          # the mix tasks under lib/mix/tasks/ (test.regression, test.baseline)
          # report their results to stdout as their entire purpose. Both paths
          # are needed - the tasks live under lib/, so a test/ exclusion alone
          # would not cover them.
          {Credo.Check.Refactor.IoPuts, [files: %{excluded: ["test/", "lib/mix/tasks/"]}]},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.PreferDateTimeShift, []},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.UtcNowTruncate, []},
          {Credo.Check.Refactor.WithClauses, []},

          #
          ## Warnings
          #
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.ForbiddenFunction, []},
          {Credo.Check.Warning.ForbiddenModule, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.LazyLogging, []},
          # Excluded where clearing the environment would break the subprocess rather
          # than protect it: every System.cmd/3 under lib/mix/ and test/ shells out to
          # git, mix, grep or the claude CLI, which need PATH, HOME and the developer's
          # own auth to run at all. None of the 8 sites is in lib/statifier/, where this
          # check now runs and where ADR-0003 already means no System.cmd should appear
          # (st-383).
          {Credo.Check.Warning.LeakyEnvironment, [files: %{excluded: ["lib/mix/", "test/"]}]},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          # Excluded where reading Mix.env/0 is legitimate rather than a
          # runtime leak: mix.exs is build configuration, and mix tasks only
          # ever run under Mix in the first place. The mix.exs entry is belt and
          # braces - `included:` above does not reach the project root today -
          # but it keeps the exclusion correct if that ever changes.
          {Credo.Check.Warning.MixEnv, [files: %{excluded: ["mix.exs", "lib/mix/tasks/"]}]},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.StructFieldAmount, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedMapOperation, []},
          {Credo.Check.Warning.UnusedOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFilename, []}
        ],
        disabled: [
          #
          # Checks scheduled for next check update (opt-in for now)

          #
          # Controversial and experimental checks (opt-in, just move the check to `:enabled`
          #   and be sure to use `mix credo --strict` to see low priority checks)
          #
          # Disabled under protest: on credo 1.8.0-dev this check reports one
          # false positive per entry in the `disabled:` list below, because the
          # config merge rewrites those entries to `{Check, false}` - the very
          # deprecated form the check exists to find. credo's own gen.config
          # output therefore fails it. Re-enable when upstream fixes it.
          {Credo.Check.Design.DeprecatedChecksConfig, []},
          # Deliberately left off, not merely un-enabled: the interpreter
          # functions are literal ports of the W3C SCXML Appendix D pseudocode,
          # so structurally similar functions are intentional and correct. This
          # check would fight spec fidelity. Do not enable without revisiting
          # that (st-vbu).
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.CaptureOperator, []},
          # Stays disabled deliberately: this check forbids the grouped alias form
          # outright, which is the direct contradiction of st-383 rather than a
          # companion to it - the tree was rewritten to the grouped form on purpose and
          # Consistency.MultiAliasImportRequireUse above now enforces it. Enabling this
          # would fight that decision, not reinforce it.
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.SinglePipe, []},
          # Left out on measurement, not on assumption (st-383): the obvious argument
          # for skipping it - that it duplicates Refactor.CyclomaticComplexity, already
          # enabled - does not hold here. CyclomaticComplexity (max 9) reports zero
          # findings on this tree, so ABCSize's 28 findings overlap nothing. They
          # concentrate in lowering/builders.ex, interpreter.ex, compiler.ex and
          # interpreter/datamodel.ex - the literal W3C Appendix D port - so enabling it
          # would trade spec fidelity for a size metric, the same trade that already
          # keeps Design.DuplicatedCode and Refactor.CondInsteadOfIfElse out (ADR-0002).
          # Not enabled with a raised max_size either: a threshold picked to clear the
          # current tree is a weakening dressed as a widening.
          {Credo.Check.Refactor.ABCSize, []},
          # Left out after classifying all 23 findings, not by default (st-383): 17 of
          # them are correct as written. Eleven are one-shot appends to short, bounded
          # lists (the `errors ++ [Error....]` idiom repeated across lowering/builders.ex,
          # a compile-time module attribute in parser/markup.ex, per-call argument lists
          # in the mix tooling), and six are order-critical - the datamodel-write-before-
          # effect rule in interpreter.ex and machine/content/send.ex, Appendix D's
          # removeConflictingTransitions in interpreter/selection.ex, session.ex's FIFO
          # deferred queue (ADR-0044), and timers.ex's scheduling order (spec 6.3) - where
          # prepend-and-reverse changes behavior rather than cost. The six genuinely hot
          # appends were rewritten under st-383; enabling the check would leave 17
          # standing findings, and the path exclusion that silenced them would have to
          # name nine files, which is a worse record than this paragraph.
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.CondInsteadOfIfElse, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.VariableRebinding, []}

          # {Credo.Check.Refactor.MapInto, []},

          #
          # Custom checks can be created using `mix credo.gen.check`.
          #
        ]
      }
    }
  ]
}
