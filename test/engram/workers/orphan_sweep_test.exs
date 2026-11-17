defmodule Engram.Workers.OrphanSweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.QdrantFilterView
  import ExUnit.CaptureLog

  alias Engram.Storage
  alias Engram.Test.LogCapture
  alias Engram.Vector.FilterId
  alias Engram.Workers.OrphanSweep

  # The legacy-only tenant scroll's filter (`is_empty(u)`).
  @legacy_only %{"must" => [%{"is_empty" => %{"key" => "u"}}]}

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

  # Tenant discovery reads the `u` index through one facet request. It was a
  # scroll of every point with payload `["user_id", "u"]`: in prod
  # (2026-11-16, 1.35M points) ~2.7k requests and ~550 MB of payload reads a
  # run, visible as a daily page-cache jump on the Qdrant node.
  test "discovers tenants with one facet on `u` and deletes the departed ones", %{
    bypass: bypass
  } do
    live = insert(:user)
    ghost_id = Ecto.UUID.generate()
    test_pid = self()

    # Undashed, as `u` is written (`FilterId.uuid/1`).
    stub_qdrant(bypass, [FilterId.uuid(live.id), FilterId.uuid(ghost_id)])

    Bypass.expect(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, body})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert_received {:qdrant_facet, %{"key" => "u", "exact" => true}}
    refute_received {:qdrant_facet, _second}

    for {:scroll, body} <- drain(:scroll) do
      assert body["with_payload"] in [false, ["user_id"]],
             "a scroll read payload it does not need: #{inspect(body)}"

      if body["with_payload"] == ["user_id"], do: assert(body["filter"] == @legacy_only)
    end

    assert_received {:qdrant_delete, body}
    decoded = Jason.decode!(body)
    assert get_in(hd(legacy_view(decoded["filter"]["must"])), ["match", "value"]) == ghost_id
    refute_received {:qdrant_delete, _live_user}
  end

  # A point written before `u` existed (a self-hoster skipping releases) has
  # only `user_id`, which the facet cannot see. The `is_empty(u)` scroll finds
  # it; with no such point it is one empty page.
  test "a legacy-only point (user_id, no u) still gets its departed tenant swept", %{
    bypass: bypass
  } do
    live = insert(:user)
    ghost_id = Ecto.UUID.generate()
    test_pid = self()

    stub_qdrant(bypass, [FilterId.uuid(live.id)], [ghost_id])

    Bypass.expect(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, body})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    assert :ok = perform_job(OrphanSweep, %{})

    assert_received {:qdrant_delete, body}
    decoded = Jason.decode!(body)
    assert get_in(hd(legacy_view(decoded["filter"]["must"])), ["match", "value"]) == ghost_id
  end

  # Fail closed: this pass deletes a whole user's vectors, irreversible
  # without a paid re-embed. A discovery error, an id in another spelling, a
  # signup that commits mid-run or an implausible departed share must all
  # delete nothing.
  test "a single departure on a small self-host is still swept", %{bypass: bypass} do
    ghost_id = Ecto.UUID.generate()
    stub_qdrant(bypass, [ghost_id])
    stub_delete(bypass)

    assert :ok = perform_job(OrphanSweep, %{})
    assert_received {:qdrant_delete, body}

    assert get_in(hd(legacy_view(Jason.decode!(body)["filter"]["must"])), ["match", "value"]) ==
             ghost_id
  end

  # Departed tenants found mostly through legacy points (no `u`), one of them
  # spelled uppercase: each is deleted, and by the spelling its points carry.
  test "a mostly-legacy departed set is swept", %{bypass: bypass} do
    live = for _ <- 1..5, do: insert(:user)
    v5_ghost = Ecto.UUID.generate()
    legacy_ghost = Ecto.UUID.generate()
    upper_ghost = String.upcase(Ecto.UUID.generate())

    stub_qdrant(bypass, [FilterId.uuid(v5_ghost) | Enum.map(live, &FilterId.uuid(&1.id))], [
      legacy_ghost,
      upper_ghost,
      hd(live).id
    ])

    stub_delete(bypass)

    assert :ok = perform_job(OrphanSweep, %{})

    deleted =
      for {:qdrant_delete, body} <- drain(:qdrant_delete) do
        get_in(hd(legacy_view(Jason.decode!(body)["filter"]["must"])), ["match", "value"])
      end

    assert Enum.sort(deleted) == Enum.sort([v5_ghost, legacy_ghost, upper_ghost])
  end

  # A departed user found by the facet who ALSO has legacy-only points spelled
  # another way: the legacy arm of the delete is an exact keyword match, so
  # each spelling gets its own delete, or those points are re-found forever.
  test "a departed tenant is deleted under every spelling its points carry", %{
    bypass: bypass
  } do
    live = for _ <- 1..3, do: insert(:user)
    ghost = Ecto.UUID.generate()

    stub_qdrant(bypass, [FilterId.uuid(ghost) | Enum.map(live, &FilterId.uuid(&1.id))], [
      String.upcase(ghost)
    ])

    stub_delete(bypass)

    assert :ok = perform_job(OrphanSweep, %{})

    deleted =
      for {:qdrant_delete, body} <- drain(:qdrant_delete) do
        get_in(hd(legacy_view(Jason.decode!(body)["filter"]["must"])), ["match", "value"])
      end

    assert Enum.sort(deleted) == Enum.sort([ghost, String.upcase(ghost)])
  end

  describe "the Qdrant tenant pass deletes nothing when" do
    test "the facet request fails", %{bypass: bypass} do
      stub_qdrant(bypass, [Ecto.UUID.generate()], [], facet_status: 500)
      stub_delete(bypass)

      assert :ok = perform_job(OrphanSweep, %{})
      refute_received {:qdrant_delete, _}
    end

    test "the legacy-only scroll fails", %{bypass: bypass} do
      stub_qdrant(bypass, [Ecto.UUID.generate()], [], legacy_status: 500)
      stub_delete(bypass)

      assert :ok = perform_job(OrphanSweep, %{})
      refute_received {:qdrant_delete, _}
    end

    # Real Qdrant answers a uuid index value dashed (the integration test in
    # qdrant_strict_mode_test).
    test "a live tenant comes back dashed", %{bypass: bypass} do
      live = insert(:user)
      stub_qdrant(bypass, [live.id])
      stub_delete(bypass)

      assert :ok = perform_job(OrphanSweep, %{})
      refute_received {:qdrant_delete, _}
    end

    test "a live tenant comes back uppercase, from the facet or a legacy point", %{
      bypass: bypass
    } do
      live = insert(:user)
      upper = String.upcase(live.id)
      stub_qdrant(bypass, [String.upcase(FilterId.uuid(live.id))], [upper])
      stub_delete(bypass)

      assert :ok = perform_job(OrphanSweep, %{})
      refute_received {:qdrant_delete, _}
    end

    # The departed share is `runaway?/2`'s: 100+ departed tenants that are
    # over 10% of all tenants means the `users` read is wrong (a restore, a
    # repointed database), not that that many users left.
    test "the departed share is implausible", %{bypass: bypass} do
      stub_qdrant(bypass, for(_ <- 1..150, do: Ecto.UUID.generate()))
      stub_delete(bypass)

      {_result, log} = with_log(fn -> perform_job(OrphanSweep, %{}) end)
      refute_received {:qdrant_delete, _}
      assert log =~ "orphan_sweep aborting"
    end

    # `runaway?/2` only fires at 100+ departed, so a small deployment (most
    # self-hosts) needs its own floor: two or more departed that are over half
    # of every tenant found means the `users` read is wrong.
    test "most of a small deployment's tenants look departed", %{bypass: bypass} do
      stub_qdrant(bypass, for(_ <- 1..3, do: Ecto.UUID.generate()))
      stub_delete(bypass)

      {_result, log} = with_log(fn -> perform_job(OrphanSweep, %{}) end)
      refute_received {:qdrant_delete, _}
      assert log =~ "orphan_sweep aborting"
    end

    # The re-read is the last word before a delete; failing it must not
    # fall back to the stale snapshot. Renaming `users` inside the sandbox
    # transaction (rolled back with the test) fails exactly that query.
    test "the candidate re-read from users fails", %{bypass: bypass} do
      stub_qdrant(bypass, [Ecto.UUID.generate()], [],
        on_legacy: fn -> Repo.query!("ALTER TABLE users RENAME TO users_gone") end
      )

      stub_delete(bypass)

      assert_raise Postgrex.Error, fn -> perform_job(OrphanSweep, %{}) end
      refute_received {:qdrant_delete, _}
    end

    # Staging 2026-11-16: the exact facet answered 4 tenant ids with count 0
    # (index entries left by deleted points) and no users row. Counted as
    # departed they tripped the share guard, so every run refused.
    test "the facet answers stale tenant ids with count 0", %{bypass: bypass} do
      live = insert(:user)
      stale = for _ <- 1..3, do: Ecto.UUID.generate()
      stub_qdrant(bypass, [FilterId.uuid(live.id)], [], stale: stale)
      stub_delete(bypass)

      {result, log} = with_log(fn -> perform_job(OrphanSweep, %{}) end)
      assert result == :ok
      refute_received {:qdrant_delete, _}
      refute log =~ "orphan_sweep aborting"
    end

    # `runaway?/2` on its own: 100 departed is its floor, and 100 of 250 is
    # under half, so the small-deployment share check stays quiet.
    test "100+ departed tenants are over the runaway ratio but under half", %{
      bypass: bypass
    } do
      live = for _ <- 1..150, do: insert(:user)
      departed = for _ <- 1..100, do: Ecto.UUID.generate()
      stub_qdrant(bypass, departed ++ Enum.map(live, &FilterId.uuid(&1.id)))
      stub_delete(bypass)

      {_result, log} = with_log(fn -> perform_job(OrphanSweep, %{}) end)
      refute_received {:qdrant_delete, _}
      assert log =~ "orphan_sweep aborting qdrant"
    end

    # A user who signs up after `users` was read but before the facet answers
    # is in Qdrant and not in the snapshot. The candidates are re-read right
    # before deleting.
    test "a tenant signs up after the users snapshot", %{bypass: bypass} do
      late_id = Ecto.UUID.generate()

      stub_qdrant(bypass, [late_id], [], on_facet: fn -> insert(:user, id: late_id) end)

      stub_delete(bypass)

      assert :ok = perform_job(OrphanSweep, %{})
      refute_received {:qdrant_delete, _}
    end
  end

  test "deletes S3 prefix for users that no longer exist", %{bypass: bypass} do
    live = insert(:user)
    ghost_id = Ecto.UUID.generate()

    Storage.adapter().put("#{live.id}/1/keep.bin", "live data")
    Storage.adapter().put("#{ghost_id}/1/orphan.bin", "orphan data")

    # Qdrant has no orphans to find.
    stub_qdrant(bypass, [])

    assert :ok = perform_job(OrphanSweep, %{})

    assert {:error, :not_found} = Storage.adapter().get("#{ghost_id}/1/orphan.bin")
    assert {:ok, "live data"} = Storage.adapter().get("#{live.id}/1/keep.bin")
  end

  # The attachment-prefix pass diffs the same `users` read and drops a whole
  # user's attachments, so it goes through the same guard.
  test "S3 refuses when most attachment prefixes look departed", %{bypass: bypass} do
    ghosts = for _ <- 1..3, do: Ecto.UUID.generate()
    for g <- ghosts, do: Storage.adapter().put("#{g}/1/a.bin", "data")
    stub_qdrant(bypass, [])

    {_result, log} = with_log(fn -> perform_job(OrphanSweep, %{}) end)

    for g <- ghosts, do: assert({:ok, "data"} = Storage.adapter().get("#{g}/1/a.bin"))
    assert log =~ "orphan_sweep aborting s3"
  end

  # The kill switch stops a run already going: it is re-read before each
  # delete and each pass, so flipping it mid-run leaves the rest alone.
  test "turning the kill switch off mid-run stops at the next delete", %{bypass: bypass} do
    live = for _ <- 1..3, do: insert(:user)
    ghosts = for _ <- 1..2, do: Ecto.UUID.generate()
    for g <- ghosts, do: Storage.adapter().put("#{g}/1/orphan.bin", "orphan data")
    test_pid = self()
    on_exit(fn -> Application.delete_env(:engram, :orphan_sweep) end)
    # The stop line is :info; the test env logger level is :warning.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    stub_qdrant(
      bypass,
      Enum.map(live, &FilterId.uuid(&1.id)) ++ Enum.map(ghosts, &FilterId.uuid/1)
    )

    Bypass.expect(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      send(test_pid, :qdrant_delete)
      Application.put_env(:engram, :orphan_sweep, false)
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)

    {result, events} = LogCapture.with_events(fn -> perform_job(OrphanSweep, %{}) end)
    assert result == :ok

    assert_received :qdrant_delete
    refute_received :qdrant_delete

    assert [stop] =
             Enum.filter(
               events,
               &match?({:string, "orphan_sweep stopped: kill switch off"}, &1.msg)
             )

    assert stop.level == :info
    assert stop.meta[:result] == %{pass: :qdrant}
    for g <- ghosts, do: assert({:ok, "orphan data"} = Storage.adapter().get("#{g}/1/orphan.bin"))
  end

  test "no-op when both stores are clean", %{bypass: bypass} do
    user = insert(:user)
    Storage.adapter().put("#{user.id}/1/keep.bin", "live")

    stub_qdrant(bypass, [FilterId.uuid(user.id)])

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

    stub_qdrant(bypass, [FilterId.uuid(user.id)])

    {result, events} = LogCapture.with_events(fn -> perform_job(OrphanSweep, %{}) end)
    assert result == :ok

    summary = Enum.find(events, &match?({:string, "orphan_sweep complete"}, &1.msg))

    assert summary, "expected an 'orphan_sweep complete' summary log line"
    assert summary.level == :info
    assert summary.meta[:category] == :oban
    assert summary.meta[:loki_ship] == true
    assert summary.meta[:total_count] == 0
  end

  # The sweep's Qdrant reads, routed the way one collection answers them: the
  # tenant facet on `u` answers `tenants`; the `is_empty(u)` scroll answers a
  # legacy-only point per id in `legacy`; the point pass's id-only scroll
  # finds nothing. Each request is sent to the test process. `opts`:
  # `facet_status`/`legacy_status` fail that request, `on_facet`/`on_legacy`
  # run as that request is answered, `stale` adds count-0 facet hits.
  defp stub_qdrant(bypass, tenants, legacy \\ [], opts \\ []) do
    test_pid = self()
    on_facet = Keyword.get(opts, :on_facet, fn -> :ok end)
    on_legacy = Keyword.get(opts, :on_legacy, fn -> :ok end)

    Bypass.expect(bypass, "POST", "/collections/test_col/facet", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_facet, Jason.decode!(body)})
      on_facet.()

      case Keyword.get(opts, :facet_status, 200) do
        200 ->
          stale = Keyword.get(opts, :stale, [])

          hits =
            Enum.map(tenants, &%{"value" => &1, "count" => 1}) ++
              Enum.map(stale, &%{"value" => &1, "count" => 0})

          json(conn, %{"result" => %{"hits" => hits}})

        status ->
          Plug.Conn.resp(conn, status, ~s({"status":{"error":"boom"}}))
      end
    end)

    Bypass.stub(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(test_pid, {:scroll, decoded})
      legacy? = decoded["filter"] == @legacy_only
      if legacy?, do: on_legacy.()

      points =
        if legacy?,
          do: Enum.map(legacy, &%{"id" => Ecto.UUID.generate(), "payload" => %{"user_id" => &1}}),
          else: []

      case {legacy?, Keyword.get(opts, :legacy_status, 200)} do
        {true, status} when status != 200 ->
          Plug.Conn.resp(conn, status, ~s({"status":{"error":"boom"}}))

        _ ->
          json(conn, %{"result" => %{"points" => points, "next_page_offset" => nil}})
      end
    end)
  end

  defp stub_delete(bypass) do
    test_pid = self()

    Bypass.stub(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:qdrant_delete, body})
      Plug.Conn.resp(conn, 200, ~s({"result":{}}))
    end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp drain(tag) do
    receive do
      {^tag, body} -> [{tag, body} | drain(tag)]
    after
      0 -> []
    end
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
    # The chunk reads live in Engram.Vector.PointIds; the guard follows them
    # there.
    sweep =
      authority_bodies("lib/engram/workers/orphan_sweep.ex", :defp, [
        :live_user_ids,
        :trashed_page,
        :stranded_index
      ])

    shared = authority_bodies("lib/engram/vector/point_ids.ex", :def, [:chunk_page, :known])

    assert sweep |> Map.keys() |> Enum.sort() == [:live_user_ids, :stranded_index, :trashed_page]

    assert shared |> Map.keys() |> Enum.sort() == [:chunk_page, :known],
           "all three authority reads must still exist under these names"

    for {name, body} <- sweep, do: assert(body =~ "maintenance_repo()", "#{name} pool")
    for {name, body} <- shared, do: assert(body =~ "Repo.maintenance()", "#{name} pool")

    for {name, body} <- Map.merge(sweep, shared) do
      refute body =~ ~r/\bRepo\.(all|one|stream|exists\?|aggregate|update_all)\b/,
             "#{name} must not read on Repo. That is the #1746 deletion path"
    end

    source = File.read!("lib/engram/workers/orphan_sweep.ex")
    assert source =~ "PointIds.known(ids)"
    assert source =~ "PointIds.chunk_page(after_id"
  end

  defp authority_bodies(file, kind, names) do
    {:ok, ast} = Code.string_to_quoted(File.read!(file))

    ast
    |> Macro.prewalk(%{}, fn
      {^kind, _, [{name, _, _}, [do: body]]} = node, acc ->
        if name in names,
          do: {node, Map.put(acc, name, Macro.to_string(body))},
          else: {node, acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # The write half of the same bug. `flag_notes_for_rebuild/2`'s two `update_all`s
  # hit FORCE-RLS tables; filtered, they report {0, nil} and this worker logs a
  # successful repair having changed nothing — silently disabling #1576.
  test "the re-index flag write is handed the maintenance pool" do
    source = File.read!("lib/engram/workers/orphan_sweep.ex")

    assert source =~ "Indexing.flag_notes_for_rebuild(note_ids, maintenance_repo())",
           "the flag write must be routed to the maintenance pool explicitly — " <>
             "its default is Repo, which is correct only for tenant-scoped callers"
  end
end
