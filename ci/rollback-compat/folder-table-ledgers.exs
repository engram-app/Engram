# Phase 1, on OLD (release J or K, before any seed): close FolderTable, the
# ledger explicit listings wait on (Rows.explicit_reads?/0), so the writers
# take the marker stop path as in prod and write no markers (J and K cannot
# delete one: they retired FolderMarkerDelete). `mode` is bound by the workflow.
alias Engram.DataMigrations, as: DM
alias Engram.Workers.DataMigrationsRunner, as: Runner

# Done in prod; its heal needs the vector store this stack lacks (as in the
# explicit-folders pair).
nps = Engram.DataMigrations.NotePayloadStamps
:ok = DM.mark_done(nps.name(), nps.version())

ft = Engram.DataMigrations.FolderTable

Enum.reduce_while(1..30, nil, fn i, _ ->
  r = Runner.run(ft)
  IO.puts("LEDGERS pass #{i}: folder_table=#{inspect(r)}")
  if DM.done?(ft.name(), ft.version()), do: {:halt, nil}, else: (Process.sleep(2_000); {:cont, nil})
end)

Engram.Cache.evict_local(:explicit_folders, :done)
IO.puts("LEDGERS_DONE=#{DM.done?(ft.name(), ft.version())}")
IO.puts("EXPLICIT_READS=#{Engram.Folders.Rows.explicit_reads?()}")
IO.puts("MARKER_STOP=#{Engram.Folders.MarkerStop.on?()}")
