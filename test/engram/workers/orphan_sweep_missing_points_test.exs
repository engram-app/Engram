defmodule Engram.Workers.OrphanSweepMissingPointsTest do
  @moduledoc """
  The Postgres→Qdrant half of the sweep (#1576). A chunk row naming a point
  Qdrant does not have means that note is unsearchable, and nothing else
  notices: `ReconcileEmbeddings` compares `embed_hash` to `content_hash`, both
  Postgres columns, so a note whose vectors vanished still looks freshly
  indexed. Nulling the index hashes hands it back to that worker.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
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

    %{bypass: bypass}
  end

  # Both passes POST to /points/scroll. The forward pass sends an empty filter
  # (walk everything); this one sends `has_id` (do these specific ids exist?).
  # Routing on the body is what lets a single `perform_job` exercise both, the
  # same way one real collection answers both queries.
  defp stub_qdrant(bypass, present_ids) do
    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      ids =
        case Jason.decode!(body) do
          %{"filter" => %{"must" => [%{"has_id" => asked}]}} ->
            Enum.filter(asked, &(&1 in present_ids))

          _ ->
            present_ids
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "result" => %{
            "points" => Enum.map(ids, &%{"id" => &1}),
            "next_page_offset" => nil
          }
        })
      )
    end)
  end

  defp insert_chunk!(note, point_id) do
    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: note.user_id,
        vault_id: note.vault_id,
        position: 0,
        char_start: 0,
        char_end: 10,
        qdrant_point_id: point_id
      },
      skip_tenant_check: true
    )
  end

  defp reload(note), do: Repo.get!(Note, note.id, skip_tenant_check: true)

  test "nulls the index hashes when a chunk names a point Qdrant does not have", %{
    bypass: bypass
  } do
    user = insert(:user)
    vault = insert(:vault, user: user)

    note =
      insert(:note,
        user: user,
        vault: vault,
        embed_hash: "cafe",
        content_hash: "cafe",
        dense_indexed_hash: "cafe"
      )

    insert_chunk!(note, Ecto.UUID.generate())

    stub_qdrant(bypass, [])

    assert :ok = perform_job(OrphanSweep, %{})

    reloaded = reload(note)
    assert is_nil(reloaded.embed_hash)
    assert is_nil(reloaded.dense_indexed_hash)
  end

  test "leaves a note alone when Qdrant has every point its chunks name", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)

    note =
      insert(:note,
        user: user,
        vault: vault,
        embed_hash: "cafe",
        content_hash: "cafe",
        dense_indexed_hash: "cafe"
      )

    point_id = Ecto.UUID.generate()
    insert_chunk!(note, point_id)

    stub_qdrant(bypass, [point_id])

    assert :ok = perform_job(OrphanSweep, %{})

    assert reload(note).embed_hash == "cafe"
  end

  test "aborts without flagging anything when nearly every point looks missing", %{
    bypass: bypass
  } do
    user = insert(:user)
    vault = insert(:vault, user: user)

    # Above @runaway_floor (100) and far above @max_candidate_ratio (10%): the
    # shape of Qdrant being down or repointed, not of real drift.
    notes =
      for _ <- 1..101 do
        note =
          insert(:note,
            user: user,
            vault: vault,
            embed_hash: "cafe",
            content_hash: "cafe",
            dense_indexed_hash: "cafe"
          )

        insert_chunk!(note, Ecto.UUID.generate())
        note
      end

    stub_qdrant(bypass, [])

    assert :ok = perform_job(OrphanSweep, %{})

    for note <- notes, do: assert(reload(note).embed_hash == "cafe")
  end

  test "flags nothing when the Qdrant probe fails", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)

    note =
      insert(:note,
        user: user,
        vault: vault,
        embed_hash: "cafe",
        content_hash: "cafe",
        dense_indexed_hash: "cafe"
      )

    insert_chunk!(note, Ecto.UUID.generate())

    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"status":"error"}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert reload(note).embed_hash == "cafe"
  end

  test "does not flag a note whose point lands during the grace window", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)

    note =
      insert(:note,
        user: user,
        vault: vault,
        embed_hash: "cafe",
        content_hash: "cafe",
        dense_indexed_hash: "cafe"
      )

    point_id = Ecto.UUID.generate()
    insert_chunk!(note, point_id)

    # The write-order race: `commit_index/1` inserts the chunk row and upserts
    # the point after it, so a note indexing right now is legitimately absent
    # on the first probe and present moments later.
    {:ok, present} = Agent.start_link(fn -> [] end)
    stub_qdrant_agent(bypass, present)

    prior = Application.get_env(:engram, :orphan_sweep_point_grace_fun)

    Application.put_env(:engram, :orphan_sweep_point_grace_fun, fn ->
      Agent.update(present, fn _ -> [point_id] end)
    end)

    on_exit(fn -> Application.put_env(:engram, :orphan_sweep_point_grace_fun, prior) end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert reload(note).embed_hash == "cafe"
  end

  test "ignores chunks belonging to a soft-deleted note", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)

    note =
      insert(:note,
        user: user,
        vault: vault,
        embed_hash: "cafe",
        content_hash: "cafe",
        dense_indexed_hash: "cafe",
        deleted_at: DateTime.utc_now(:second)
      )

    insert_chunk!(note, Ecto.UUID.generate())

    stub_qdrant(bypass, [])

    assert :ok = perform_job(OrphanSweep, %{})

    assert reload(note).embed_hash == "cafe"
  end

  test "probes every page when the chunk table exceeds one batch", %{bypass: bypass} do
    prior = Application.get_env(:engram, :orphan_sweep_chunk_probe_batch)
    Application.put_env(:engram, :orphan_sweep_chunk_probe_batch, 2)
    on_exit(fn -> Application.put_env(:engram, :orphan_sweep_chunk_probe_batch, prior) end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    # Five chunks over a batch of 2 is three pages, the last one short. The
    # note on the final page is the one a broken cursor would never reach.
    kept =
      for _ <- 1..4 do
        note = insert(:note, user: user, vault: vault, embed_hash: "cafe", content_hash: "cafe")
        point_id = Ecto.UUID.generate()
        insert_chunk!(note, point_id)
        {note, point_id}
      end

    last = insert(:note, user: user, vault: vault, embed_hash: "cafe", content_hash: "cafe")
    insert_chunk!(last, Ecto.UUID.generate())

    stub_qdrant(bypass, Enum.map(kept, fn {_note, point_id} -> point_id end))

    assert :ok = perform_job(OrphanSweep, %{})

    assert is_nil(reload(last).embed_hash)
    for {note, _} <- kept, do: assert(reload(note).embed_hash == "cafe")
  end

  defp stub_qdrant_agent(bypass, agent) do
    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      present = Agent.get(agent, & &1)

      ids =
        case Jason.decode!(body) do
          %{"filter" => %{"must" => [%{"has_id" => asked}]}} ->
            Enum.filter(asked, &(&1 in present))

          _ ->
            present
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "result" => %{
            "points" => Enum.map(ids, &%{"id" => &1}),
            "next_page_offset" => nil
          }
        })
      )
    end)
  end
end
