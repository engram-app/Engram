defmodule Engram.Workers.OrphanSweepPointsTest do
  @moduledoc """
  Point-level orphan reaping. The user-level sweep only catches points whose
  `user_id` has left the `users` table — a live user's stranded points (rename
  → delete inside the debounce window) were invisible to every cleanup path.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Workers.OrphanSweep

  setup do
    bypass = Bypass.open()
    prior_collection = Application.get_env(:engram, :qdrant_collection)
    prior_storage = Application.get_env(:engram, :storage)

    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :qdrant_collection, "test_col")
    Application.put_env(:engram, :storage, Engram.Storage.InMemory)
    Application.put_env(:engram, :orphan_sweep_point_grace_seconds, 0)
    Engram.Storage.InMemory.ensure_table()
    :ets.delete_all_objects(:engram_test_storage_in_memory)

    on_exit(fn ->
      Application.delete_env(:engram, :qdrant_url)
      Application.delete_env(:engram, :orphan_sweep_point_grace_seconds)
      Application.put_env(:engram, :qdrant_collection, prior_collection)
      Application.put_env(:engram, :storage, prior_storage)
    end)

    %{bypass: bypass}
  end

  defp stub_scroll(bypass, points) do
    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"result" => %{"points" => points, "next_page_offset" => nil}})
      )
    end)
  end

  test "deletes points with no chunk row and keeps the ones that have one", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    kept = Ecto.UUID.generate()
    stranded = Ecto.UUID.generate()

    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        position: 0,
        char_start: 0,
        char_end: 10,
        qdrant_point_id: kept
      },
      skip_tenant_check: true
    )

    stub_scroll(bypass, [
      %{"id" => kept, "payload" => %{"user_id" => user.id}},
      %{"id" => stranded, "payload" => %{"user_id" => user.id}}
    ])

    test_pid = self()

    Bypass.expect(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert_received {:qdrant_delete, %{"points" => ids}}
    assert ids == [stranded]
    refute Enum.member?(ids, kept)
  end

  test "deletes nothing when every point has a chunk row", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    kept = Ecto.UUID.generate()

    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        position: 0,
        char_start: 0,
        char_end: 10,
        qdrant_point_id: kept
      },
      skip_tenant_check: true
    )

    stub_scroll(bypass, [%{"id" => kept, "payload" => %{"user_id" => user.id}}])

    test_pid = self()

    Bypass.stub(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    refute_received {:qdrant_delete, %{"points" => _}}
  end

  test "a point whose chunk row appears during the grace window is spared", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    racing = Ecto.UUID.generate()

    # Seen in Qdrant, absent from the first DB read — the shape of a chunk row
    # landing mid-sweep. The re-check must see it and spare the point.
    stub_scroll(bypass, [%{"id" => racing, "payload" => %{"user_id" => user.id}}])

    Application.put_env(:engram, :orphan_sweep_point_grace_fun, fn ->
      Repo.insert!(
        %Chunk{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          position: 0,
          char_start: 0,
          char_end: 10,
          qdrant_point_id: racing
        },
        skip_tenant_check: true
      )

      :ok
    end)

    on_exit(fn -> Application.delete_env(:engram, :orphan_sweep_point_grace_fun) end)

    test_pid = self()

    Bypass.stub(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    refute_received {:qdrant_delete, %{"points" => _}}
  end
end
