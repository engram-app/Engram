# Phase 3, on OLD, every pair: every registered data migration once through
# DataMigrationsRunner.run/2 with the re-verify forced, then a class per
# result for the workflow's verdict (rollback-compat.yml). A :skipped is
# explained, never silent: disabled, or done and not re-verified (it never
# runs again after a rollback in prod either), or anything else.
alias Engram.DataMigrations, as: DM
alias Engram.Workers.DataMigrationsRunner, as: Runner

opt = fn m, f, d ->
  _ = Code.ensure_loaded(m)
  if function_exported?(m, f, 0), do: apply(m, f, []), else: d
end

ms = Runner.migrations()
IO.puts("MIGRATIONS_TOTAL=#{length(ms)}")

for m <- ms do
  class =
    case Runner.run(m, true) do
      :done -> "done"
      :more -> "more"
      :error -> "error"
      :skipped ->
        cond do
          not opt.(m, :enabled?, true) -> "skipped-disabled"
          DM.done?(m.name(), m.version()) and not opt.(m, :reverify?, false) -> "skipped-done-noreverify"
          true -> "skipped-other"
        end
      other -> "other:#{inspect(other)}"
    end

  IO.puts("MIGRATION #{m.name()} #{class}")
end

IO.puts("MIGRATIONS_END")
