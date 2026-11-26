# Phase 3, on OLD: release I's ExplicitFolderReconcile through the runner's own
# entry point, re-verify forced (the pass runs even on a done ledger).
r = Engram.Workers.DataMigrationsRunner.run(Engram.DataMigrations.ExplicitFolderReconcile, true)
IO.puts("RECONCILE_RESULT=#{inspect(r)}")
