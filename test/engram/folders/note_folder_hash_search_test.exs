defmodule Engram.Folders.NoteFolderHashSearchTest do
  # R9 release E, end to end against a real Qdrant: a note written with no
  # folder hash (the write stop, `note_payload_stamps` done) is found by a
  # folder-filtered `Engram.Search.search/4`, which resolves the folder to
  # note ids in Postgres by `folder_ref_id` (the `n` path). The chunk `f`
  # fallback is gone by E (R3a removed every reader), so it is not exercised.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.DataMigrations
  alias Engram.DataMigrations.NotePayloadStamps, as: Stamps
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.Vector.Qdrant
  alias Engram.Workers.RepathNoteIndex

  @moduletag :qdrant_integration

  setup do
    Engram.ServiceConfig.put_override(:qdrant_url, qdrant_url())
    # The search path's prod budget is 5 s (`:qdrant_search_timeout`) with no
    # retry; each test searches a fresh collection on the shared test Qdrant
    # right after its payload indexes were built, so it gets the budget the
    # other real-search tests use (search_hybrid_test.exs:25).
    Engram.ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    dims = Application.get_env(:engram, :embed_dims, 1024)
    vector = List.duplicate(0.1, dims)

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> vector end)}
    end)

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts, _ ->
      {:ok, Enum.map(texts, fn _ -> vector end)}
    end)

    Engram.Crypto.DekCache.invalidate_all()
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "R9E", Ecto.UUID.generate())

    col =
      "engram_test_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    old_col = Application.get_env(:engram, :qdrant_collection)
    Application.put_env(:engram, :qdrant_collection, col)

    Engram.QdrantIntegration.drop_on_exit(col, fn ->
      Application.put_env(:engram, :qdrant_collection, old_col)
    end)

    # The `n` path (`Search.n_indexed?/0`), as on a collection with the index.
    :ok = Engram.Cache.put(:note_id_filter, {:n_index, Qdrant.base_url()}, true)
    done!()
    %{user: user, vault: vault}
  end

  defp qdrant_url,
    do:
      System.get_env("QDRANT_URL") ||
        Application.get_env(:engram, :qdrant_url, "http://localhost:6333")

  defp done! do
    :ok = DataMigrations.mark_done(Stamps.name(), Stamps.version())
    Engram.Cache.clear_local(:folder_hash_gate)
  end

  defp write!(u, v, path, body) do
    {:ok, n} =
      Notes.upsert_note(u, v, %{"path" => path, "content" => "# T\n\n" <> body}, actor: "api")

    n
  end

  defp index!(u, v, path) do
    {:ok, note} = Notes.get_note(u, v, path)
    {:ok, chunks} = Engram.Indexing.index_note(note, v)
    assert chunks > 0
    note
  end

  defp hash_at(id) do
    %{rows: [[h]]} =
      Repo.query!("SELECT folder_hmac FROM notes WHERE id = $1", [Ecto.UUID.dump!(id)])

    h
  end

  defp found(u, v, folder) do
    {:ok, results} = Engram.Search.search(u, v, "body", folder: folder)
    results |> Enum.map(& &1.source_path) |> Enum.uniq() |> Enum.sort()
  end

  defp run_repaths! do
    for job <- all_enqueued(worker: RepathNoteIndex),
        do: :ok = perform_job(RepathNoteIndex, job.args)
  end

  test "a note written hashless is found by folder search, also after the ledger reopens",
       %{user: u, vault: v} do
    n = write!(u, v, "Proj/a.md", "alpha body")
    write!(u, v, "Other/c.md", "gamma body")
    index!(u, v, "Proj/a.md")
    index!(u, v, "Other/c.md")
    assert hash_at(n.id) == nil
    assert found(u, v, "Proj") == ["Proj/a.md"]

    :ok = DataMigrations.reopen(Stamps.name(), Stamps.version())
    m = write!(u, v, "Proj/b.md", "beta body")
    index!(u, v, "Proj/b.md")
    assert is_binary(hash_at(m.id))
    assert found(u, v, "Proj") == ["Proj/a.md", "Proj/b.md"]
  end

  test "a rename and a folder rename of hashless notes move them in folder search",
       %{user: u, vault: v} do
    write!(u, v, "Proj/a.md", "alpha body")
    write!(u, v, "A/S/b.md", "beta body")
    index!(u, v, "Proj/a.md")
    index!(u, v, "A/S/b.md")

    {:ok, _} = Notes.rename_note(u, v, "Proj/a.md", "Dest/a.md")
    {:ok, _} = Notes.rename_folder(u, v, "A", "Z")
    run_repaths!()

    assert found(u, v, "Dest") == ["Dest/a.md"]
    assert found(u, v, "Proj") == []
    assert found(u, v, "Z/S") == ["Z/S/b.md"]
    assert found(u, v, "A/S") == []
  end
end
