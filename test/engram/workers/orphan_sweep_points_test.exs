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
    Engram.Storage.InMemory.ensure_table()
    :ets.delete_all_objects(:engram_test_storage_in_memory)

    # NOT delete_env: `config/test.exs` sets the grace to 0 for the whole VM,
    # and deleting the key restores the 60s production default for every later
    # test that produces candidates — a real minute of sleep, once per test.
    on_exit(fn ->
      Application.delete_env(:engram, :qdrant_url)
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

  test "walks every scroll page and probes each one", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    kept = Ecto.UUID.generate()
    stranded_p1 = Ecto.UUID.generate()
    stranded_p2 = Ecto.UUID.generate()

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

    test_pid = self()

    # Page one hands back an offset; the sweep must follow it rather than
    # stopping at the first page.
    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(test_pid, {:scroll, decoded["offset"]})

      result =
        case decoded["offset"] do
          nil ->
            %{
              "points" => [%{"id" => kept}, %{"id" => stranded_p1}],
              "next_page_offset" => "page2"
            }

          "page2" ->
            %{"points" => [%{"id" => stranded_p2}], "next_page_offset" => nil}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"result" => result}))
    end)

    Bypass.stub(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert_received {:scroll, nil}
    assert_received {:scroll, "page2"}

    assert_received {:qdrant_delete, %{"points" => ids}}
    assert Enum.sort(ids) == Enum.sort([stranded_p1, stranded_p2])
    refute Enum.member?(ids, kept)
  end

  test "aborts without deleting when the candidate ratio implies a bad authority", %{
    bypass: bypass
  } do
    user = insert(:user)

    # 200 points, none with a chunk row: what a Postgres restore from before
    # the last embed wave looks like. Deleting is irreversible without a paid
    # re-embed, so the sweep must refuse rather than "clean up". Over the
    # absolute floor so the ratio is meaningful.
    points =
      for _ <- 1..200, do: %{"id" => Ecto.UUID.generate(), "payload" => %{"user_id" => user.id}}

    stub_scroll(bypass, points)

    test_pid = self()

    Bypass.stub(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, Jason.decode!(body)})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    refute_received {:qdrant_delete, %{"points" => _}}
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

  test "a point whose chunk row commits during the grace window is spared", %{bypass: bypass} do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    racing = Ecto.UUID.generate()

    # The real race this guards: `commit_index/1` under a `Repo.with_tenant/2`
    # transaction has already made the point public while its chunk row is
    # still uncommitted and invisible to this worker's connection. The row
    # landing during the grace window is that transaction committing.
    #
    # NOT a re-index reusing the id — re-index mints a fresh uuid per chunk, so
    # a candidate id can never come back that way.
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
