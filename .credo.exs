%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        {Credo.Check.Warning.StructFieldAmount, max_fields: 40},
        {Credo.Check.Warning.ExpensiveEmptyEnumCheck, files: %{excluded: ["test/**/*"]}},
        {Credo.Check.Refactor.Nesting, max_nesting: 3},
        {Credo.Check.Warning.LazyLogging, false},
        {Credo.Check.Warning.IExPry, []},
        {Credo.Check.Warning.IoInspect, []},
        {Credo.Check.Warning.UnusedEnumOperation, []},
        {Credo.Check.Warning.BoolOperationOnSameValues, []},
        {Credo.Check.Readability.ModuleDoc, false}
      ]
    }
  ]
}
