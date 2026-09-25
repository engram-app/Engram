defmodule Engram.Workers.OrphanSweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Storage
  alias Engram.Test.LogCapture
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

  test "emits a Loki-shipping :oban summary line on completion", %{bypass: bypass} do
    # Test env logger level is :warning; the summary is :info, so lower it
    # for the duration of this test to let the capture handler see it.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

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

    {result, events} = LogCapture.with_events(fn -> perform_job(OrphanSweep, %{}) end)
    assert result == :ok

    summary = Enum.find(events, &match?({:string, "orphan_sweep complete"}, &1.msg))

    assert summary, "expected an 'orphan_sweep complete' summary log line"
    assert summary.level == :info
    assert summary.meta[:category] == :oban
    assert summary.meta[:loki_ship] == true
    assert summary.meta[:total_count] == 0
  end

  # engram-app/Engram#1746. `tenancy_unsafe?/0` clears the moment a maintenance
  # repo is configured, so every read that feeds a delete or a flag must be on
  # that same pool. They were not: they ran on `Repo` under `cross_tenant/1`,
  # which sets a process-local flag and NO Postgres session state. Setting
  # `MAINTENANCE_DATABASE_URL` opened the gate while leaving those reads
  # filtered by RLS.
  #
  # Parsed rather than string-sliced. An earlier version split the source on
  # ~r/\n  end\n/ and grepped for one spelling of `|> Repo.all()`, which a
  # second unpiped `Repo.one(...)` in the same function would have walked
  # straight past while both assertions stayed green.
  test "every authority read runs on the maintenance pool, not on Repo" do
    {:ok, ast} = Code.string_to_quoted(File.read!("lib/engram/workers/orphan_sweep.ex"))

    bodies =
      ast
      |> Macro.prewalk(%{}, fn
        {:defp, _, [{name, _, _}, [do: body]]} = node, acc
        when name in [:chunk_page, :chunk_point_ids, :live_user_ids] ->
          {node, Map.put(acc, name, Macro.to_string(body))}

        node, acc ->
          {node, acc}
      end)
      |> elem(1)

    assert bodies |> Map.keys() |> Enum.sort() ==
             [:chunk_page, :chunk_point_ids, :live_user_ids],
           "all three authority reads must still exist under these names"

    for {name, body} <- bodies do
      assert body =~ "maintenance_repo()",
             "#{name} must resolve its pool via maintenance_repo/0"

      refute body =~ ~r/\bRepo\.(all|one|stream|exists\?|aggregate|update_all)\b/,
             "#{name} must not read on Repo. That is the #1746 deletion path"
    end
  end

  # The write half of the same bug. `flag_notes_for_rebuild/2`'s two `update_all`s
  # hit FORCE-RLS tables; filtered, they report {0, nil} and this worker logs a
  # successful repair having changed nothing — silently disabling #1576.
  test "the re-index flag write is handed the maintenance pool" do
    source = File.read!("lib/engram/workers/orphan_sweep.ex")

    assert source =~ "Indexing.flag_notes_for_rebuild(note_ids, maintenance_repo())",
           "the flag write must be routed to the maintenance pool explicitly — " <>
             "its default is Repo, which is correct only for ReindexKeyword"
  end
end
