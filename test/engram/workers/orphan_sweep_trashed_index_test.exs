defmodule Engram.Workers.OrphanSweepTrashedIndexTest do
  @moduledoc """
  `DeleteNoteIndex` gives up after `max_attempts`. A trashed note whose job
  was discarded keeps its chunk rows and Qdrant points, and the point pass
  keeps any point a chunk row names, so nothing else ever cleans them (prod
  audit 2026-11-16: 4 such rows in one tenant). The sweep re-enqueues the
  job for trashed notes that still have chunk rows, and leaves notes in a
  soft-deleted vault to `CleanupVault`.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Workers.DeleteNoteIndex
  alias Engram.Workers.OrphanSweep

  setup do
    bypass = Bypass.open()
    prior_collection = Application.get_env(:engram, :qdrant_collection)
    prior_storage = Application.get_env(:engram, :storage)

    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :qdrant_collection, "test_col")
    Application.put_env(:engram, :storage, Engram.Storage.InMemory)
    Engram.Storage.InMemory.ensure_table()
    :ets.delete_all_objects(:engram_test_storage_in_memory)

    on_exit(fn ->
      Application.delete_env(:engram, :qdrant_url)
      Application.put_env(:engram, :qdrant_collection, prior_collection)
      Application.put_env(:engram, :storage, prior_storage)
    end)

    # The other passes find nothing in Qdrant.
    Engram.QdrantStub.stub_facet(bypass, "test_col", [])

    Bypass.stub(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"result":{"points":[],"next_page_offset":null}}))
    end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{bypass: bypass, user: user}
  end

  defp trashed_note_with_chunk(user, vault_attrs \\ []) do
    vault = insert(:vault, [user: user] ++ vault_attrs)
    note = insert(:note, user: user, vault: vault, deleted_at: DateTime.utc_now())

    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        position: 0,
        char_start: 0,
        char_end: 1,
        qdrant_point_id: Ecto.UUID.generate()
      },
      skip_tenant_check: true
    )

    note
  end

  defp chunk_count(note) do
    Repo.aggregate(from(c in Chunk, where: c.note_id == ^note.id), :count,
      skip_tenant_check: true
    )
  end

  defp open_jobs(note) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "Engram.Workers.DeleteNoteIndex",
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("?->>'note_id' = ?", j.args, ^note.id)
      )
    )
  end

  test "a trashed note whose delete job was discarded is cleaned on the next sweep", %{
    bypass: bypass,
    user: user
  } do
    note = trashed_note_with_chunk(user)

    {:ok, gave_up} = Oban.insert(DeleteNoteIndex.job(note))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^gave_up.id), set: [state: "discarded"])

    assert :ok = perform_job(OrphanSweep, %{})
    assert [job] = open_jobs(note)

    Bypass.stub(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"result":{"status":"completed"}}))
    end)

    assert :ok = perform_job(DeleteNoteIndex, job.args)
    assert chunk_count(note) == 0
  end

  test "a second sweep does not enqueue the same note twice", %{user: user} do
    note = trashed_note_with_chunk(user)

    assert :ok = perform_job(OrphanSweep, %{})
    assert :ok = perform_job(OrphanSweep, %{})
    assert [_one] = open_jobs(note)
  end

  test "a soft-deleted vault's notes are left to CleanupVault", %{user: user} do
    note = trashed_note_with_chunk(user, deleted_at: DateTime.utc_now())

    assert :ok = perform_job(OrphanSweep, %{})
    assert open_jobs(note) == []
    assert chunk_count(note) == 1
  end

  test "a live note's chunk rows are not touched", %{user: user} do
    note = trashed_note_with_chunk(user)

    Repo.update_all(
      from(n in Engram.Notes.Note, where: n.id == ^note.id),
      [set: [deleted_at: nil]],
      skip_tenant_check: true
    )

    assert :ok = perform_job(OrphanSweep, %{})
    assert open_jobs(note) == []
  end

  # Constant per run: one notes_path_tomb page, resumed from a cursor.
  test "a run reads one page of trashed notes and the next resumes after it", %{user: user} do
    Application.put_env(:engram, :orphan_sweep_trashed_page, 1)
    on_exit(fn -> Application.delete_env(:engram, :orphan_sweep_trashed_page) end)

    a = trashed_note_with_chunk(user)
    b = trashed_note_with_chunk(user)

    assert :ok = perform_job(OrphanSweep, %{})
    assert length(open_jobs(a) ++ open_jobs(b)) == 1

    assert :ok = perform_job(OrphanSweep, %{})
    assert length(open_jobs(a) ++ open_jobs(b)) == 2
  end

  # The page must be an index walk, not a scan of every trashed note: both
  # shapes (first page, and after a cursor) read `notes_path_tomb`, planned
  # as `engram_maintenance` (the sweep's prod login) under FORCE RLS.
  test "both trashed-page statements read notes_path_tomb", %{user: user} do
    Application.put_env(:engram, :orphan_sweep_trashed_page, 1)
    on_exit(fn -> Application.delete_env(:engram, :orphan_sweep_trashed_page) end)
    for _ <- 1..3, do: trashed_note_with_chunk(user)

    statements =
      for _ <- 1..2,
          {_, queries} = Engram.QueryRecorder.record(fn -> perform_job(OrphanSweep, %{}) end),
          %{sql: sql} <- queries,
          sql =~ ~r/ORDER BY n0\."vault_id", n0\."path_id", n0\."seq"/,
          uniq: true,
          do: sql

    assert length(statements) == 2, inspect(statements)

    for sql <- statements do
      plan =
        Engram.QueryPlan.generic_plan(sql,
          analyze: ["notes"],
          bitmapscan: false,
          role: "engram_maintenance"
        )

      assert plan =~ "notes_path_tomb", plan
    end
  end
end
