# Phase 1, on OLD (release I): close the folder ledgers the way the target
# install has them. `mode` ("prod" | "selfhost") is bound by the workflow.
# prod: folder_table, explicit_folder_reconcile and folder_marker_delete done
# (markers deleted, every marker-era row stamped), as prod since release D.
# selfhost: folder_marker_delete ships off, so markers stay.
alias Engram.DataMigrations, as: DM
alias Engram.Workers.DataMigrationsRunner, as: Runner

mods =
  [Engram.DataMigrations.FolderTable, Engram.DataMigrations.ExplicitFolderReconcile] ++
    if mode == "prod", do: [Engram.DataMigrations.FolderMarkerDelete], else: []

if mode == "prod", do: Engram.ServiceConfig.override(:folder_marker_delete, true)

# note_payload_stamps is done in prod (and on any install past release E), but
# its heal needs the vector store this stack lacks. Closed by hand so
# NoteFolderHashNull, which it blocks, really walks in phase 3; with the vector
# gate shut its own re-verify then stays :done.
nps = Engram.DataMigrations.NotePayloadStamps
:ok = DM.mark_done(nps.name(), nps.version())

done? = fn -> Enum.all?(mods, &DM.done?(&1.name(), &1.version())) end

Enum.reduce_while(1..30, nil, fn i, _ ->
  # explicit_reads? is cached a minute; FolderMarkerDelete waits on it.
  Engram.Cache.evict_local(:explicit_folders, :done)
  res = Enum.map(mods, &{&1.name(), Runner.run(&1)})
  IO.puts("LEDGERS pass #{i}: #{inspect(res)}")
  if done?.(), do: {:halt, nil}, else: (Process.sleep(2_000); {:cont, nil})
end)

Engram.Cache.evict_local(:explicit_folders, :done)
IO.puts("LEDGERS_DONE=#{done?.()}")
IO.puts("EXPLICIT_READS=#{Engram.Folders.Rows.explicit_reads?()}")
