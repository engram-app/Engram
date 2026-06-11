defmodule Engram.Workers.OrphanSweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Storage
  alias Engram.Workers.OrphanSweep

  setup do
    bypass = Bypass.open()
    prior_collection = Application.get_env(:engram, :qdrant_collection)
    prior_storage = Application.get_env(:engram, :storage)

    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :qdrant_collection, "test_col")
    Application.put_env(:engram, :storage, Engram.Storage.InMemory)
    Engram.Storage.InMemory.ensure_table()

    # Wipe ETS so prior tests don't pollute the user-prefix scan.
    :ets.delete_all_objects(:engram_test_storage_in_memory)

    on_exit(fn ->
      Application.delete_env(:engram, :qdrant_url)
      Application.put_env(:engram, :qdrant_collection, prior_collection)
      Application.put_env(:engram, :storage, prior_storage)
    end)

    %{bypass: bypass}
  end

  test "deletes Qdrant points for users that no longer exist", %{bypass: bypass} do
    live = insert(:user)
    ghost_id = Ecto.UUID.generate()

    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "result" => %{
            "points" => [
              %{"id" => 1, "payload" => %{"user_id" => live.id}},
              %{"id" => 2, "payload" => %{"user_id" => ghost_id}}
            ],
            "next_page_offset" => nil
          }
        })
      )
    end)

    # Capture the delete_by_user call for the ghost.
    test_pid = self()

    Bypass.expect(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, body})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert_received {:qdrant_delete, body}
    decoded = Jason.decode!(body)
    assert get_in(decoded, ["filter", "must", Access.at(0), "match", "value"]) == ghost_id
  end

  test "deletes S3 prefix for users that no longer exist", %{bypass: bypass} do
    live = insert(:user)
    ghost_id = Ecto.UUID.generate()

    Storage.adapter().put("#{live.id}/1/keep.bin", "live data")
    Storage.adapter().put("#{ghost_id}/1/orphan.bin", "orphan data")

    # Qdrant has no orphans to find.
    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
      )
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert {:error, :not_found} = Storage.adapter().get("#{ghost_id}/1/orphan.bin")
    assert {:ok, "live data"} = Storage.adapter().get("#{live.id}/1/keep.bin")
  end

  test "no-op when both stores are clean", %{bypass: bypass} do
    user = insert(:user)
    Storage.adapter().put("#{user.id}/1/keep.bin", "live")

    Bypass.expect(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "result" => %{
            "points" => [%{"id" => 1, "payload" => %{"user_id" => user.id}}],
            "next_page_offset" => nil
          }
        })
      )
    end)

    # No delete_by_user call should fire.
    Bypass.stub(bypass, "POST", "/collections/test_col/points/delete", fn _ ->
      flunk("should not call Qdrant delete when there are no orphans")
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert {:ok, "live"} = Storage.adapter().get("#{user.id}/1/keep.bin")
  end
end
