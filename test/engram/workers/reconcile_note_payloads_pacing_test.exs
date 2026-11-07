defmodule Engram.Workers.ReconcileNotePayloadsPacingTest do
  @moduledoc """
  The `n` backfill (`ReconcileNotePayloads`, payload version 6) rewrites
  every point once, so it waits on the same Qdrant gate as the keyword sweep
  (`Engram.Rebuild.qdrant_pace/1`: disk at 75%, optimizer, queue), on its
  kill switch (`:payload_backfill`) and on a fleet-wide points-per-minute
  bucket (`:payload_backfill_points_per_min`, default 500). Every gate is
  checked before a write, and a snoozed job resumes without rewriting.

  async: false: the Qdrant pressure reading and the token bucket are node-wide.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.NoteIndexState
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Workers.ReconcileNotePayloads

  setup :set_mox_global
  setup :verify_on_exit!

  @green %{"status" => "green", "optimizer_status" => "ok", "update_queue" => %{"length" => 0}}

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(&EngramWeb.RateLimiter.reset_buckets!/0)
    Engram.Cache.clear_local(:rebuild)
    on_exit(fn -> Engram.Cache.clear_local(:rebuild) end)
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Qdrant.forget_pressure()
    on_exit(&Qdrant.forget_pressure/0)

    # {collection info, queued points, disk percent or nil (self-host)}
    {:ok, health} = Agent.start_link(fn -> {@green, 0, nil} end)
    # point id => payload, as the fake Qdrant holds it
    {:ok, points} = Agent.start_link(fn -> %{} end)
    # point ids whose payload write Qdrant refuses with a 400
    {:ok, refuse} = Agent.start_link(fn -> MapSet.new() end)
    stub_qdrant(bypass, health, points, refuse)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "plan.md", "content" => "# Plan\n\nRunning daily.", "mtime" => 1.0},
        actor: "api"
      )

    {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(note, user)
    {:ok, _} = Indexing.index_note(decrypted, vault, user)

    # The state the sweep meets: points from before `n`, no version stamp.
    Agent.update(points, &Map.new(&1, fn {id, p} -> {id, Map.delete(p, "n")} end))
    assert map_size(Agent.get(points, & &1)) > 0

    {_, _} =
      Repo.update_all(
        from(s in NoteIndexState, where: s.user_id == ^user.id),
        [set: [payload_version: nil]],
        skip_tenant_check: true
      )

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :rebuild, :gated]])
    %{user: user, note: note, health: health, points: points, refuse: refuse, ref: ref}
  end

  defp stub_qdrant(bypass, health, points, refuse) do
    test_pid = self()
    col = "/collections/#{Qdrant.collection_name()}"

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      {info, queued, disk} = Agent.get(health, & &1)

      {type, reply} =
        case {conn.method, conn.request_path} do
          {"GET", ^col} ->
            {"application/json", Jason.encode!(%{"result" => info, "status" => "ok"})}

          {"GET", path} when path == col <> "/optimizations" ->
            summary = %{"queued_points" => queued}
            {"application/json", Jason.encode!(%{"result" => %{"summary" => summary}})}

          {"GET", "/sys_metrics"} ->
            {"text/plain", volume(disk)}

          {"GET", "/metrics"} ->
            {"text/plain", ""}

          {"PUT", path} when path == col <> "/points" ->
            Agent.update(points, fn held ->
              Enum.into(body["points"], held, &{&1["id"], &1["payload"]})
            end)

            {"application/json", ~s({"result":{"status":"completed"},"status":"ok"})}

          {"POST", path} when path == col <> "/points/scroll" ->
            send(test_pid, :read)
            ids = for %{"has_id" => ids} <- body["filter"]["must"], id <- ids, do: id
            held = Agent.get(points, &Map.take(&1, ids))
            found = for {id, p} <- held, do: %{"id" => id, "payload" => p}
            result = %{"points" => found, "next_page_offset" => nil}
            {"application/json", Jason.encode!(%{"result" => result, "status" => "ok"})}

          {"POST", path} when path == col <> "/points/batch" ->
            send(test_pid, :rewrite)
            ids = for %{"set_payload" => %{"points" => [id]}} <- body["operations"], do: id
            refused = Agent.get(refuse, &Enum.any?(ids, fn id -> MapSet.member?(&1, id) end))

            if refused do
              {:refused, ~s({"status":{"error":"Bad request: refused"}})}
            else
              Agent.update(points, fn held ->
                Enum.reduce(body["operations"], held, fn
                  %{"set_payload" => %{"points" => [id], "payload" => pl}}, acc ->
                    Map.update(acc, id, pl, &Map.merge(&1, pl))
                end)
              end)

              ops = Enum.map(body["operations"], fn _ -> %{"status" => "completed"} end)
              {"application/json", Jason.encode!(%{"result" => ops, "status" => "ok"})}
            end

          # `set_payloads/3`'s read-back.
          {"POST", path} when path == col <> "/points" ->
            held = Agent.get(points, &Map.take(&1, body["ids"]))
            found = for {id, p} <- held, do: %{"id" => id, "payload" => p}
            {"application/json", Jason.encode!(%{"result" => found, "status" => "ok"})}

          _ ->
            {"application/json", ~s({"result":true,"status":"ok"})}
        end

      {type, status} = if type == :refused, do: {"application/json", 400}, else: {type, 200}

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(status, reply)
    end)
  end

  defp volume(nil), do: ""

  defp volume(pct) do
    """
    kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 100
    kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} #{pct}
    """
  end

  # The fleet `n` backfill job; `heal/1` is the heal job, `legacy/1` a
  # 0.77.0 per-user `n` job.
  defp sweep(_ctx), do: perform_job(ReconcileNotePayloads, %{"mode" => "n_fleet"})

  defp legacy(ctx),
    do: perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id, "mode" => "n"})

  # Seconds until the one queued fleet job runs.
  defp requeued_in do
    assert [next] = all_enqueued(worker: ReconcileNotePayloads, args: %{"mode" => "n_fleet"})
    DateTime.diff(next.scheduled_at, DateTime.utc_now(), :second)
  end

  # A query that reads the backfill's data, not its own job row.
  defp data_read?(query),
    do: query.sql =~ ~r/"(notes|chunks|users|note_index_state|maintenance_cursors)"/

  defp heal(ctx), do: perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

  # Every Repo query this process made, and whether a point was read.
  defp reads(fun) do
    {result, queries} = Engram.QueryRecorder.record(fun)
    {result, Enum.filter(queries, &(&1.pid == self()))}
  end

  defp versions(ctx) do
    Repo.all(
      from(s in NoteIndexState, where: s.user_id == ^ctx.user.id, select: s.payload_version),
      skip_tenant_check: true
    )
  end

  # Points of the note that carry `n` now.
  defp written(ctx),
    do: Agent.get(ctx.points, &Enum.count(&1, fn {_id, p} -> Map.has_key?(p, "n") end))

  # `count` more v5 points without `n` on the note (chunk rows + the fake's payloads).
  defp more_points(ctx, count) do
    u = Engram.Vector.FilterId.uuid(ctx.user.id)

    for i <- 1..count do
      point = Ecto.UUID.generate()
      Engram.Fixtures.insert_chunk!(ctx.user, ctx.note, point, position: 1000 + i)
      Agent.update(ctx.points, &Map.put(&1, point, %{"u" => u}))
    end
  end

  defp all_n?(ctx), do: Enum.all?(Agent.get(ctx.points, &Map.values/1), &Map.has_key?(&1, "n"))

  test "disk at the gate snoozes before any write", ctx do
    Agent.update(ctx.health, fn _ -> {@green, 0, 76} end)

    assert :ok = sweep(ctx)
    assert requeued_in() in 25..30
    refute_received :rewrite
    assert_received {[:engram, :rebuild, :gated], _, %{count: 1}, %{reason: :disk}}
  end

  test "an optimizer backlog snoozes before any write", ctx do
    Agent.update(ctx.health, fn _ -> {@green, 50_001, nil} end)

    assert :ok = sweep(ctx)
    assert requeued_in() in 25..30
    refute_received :rewrite
  end

  # A gated `n` job reads nothing: every gate runs before its first
  # Postgres or Qdrant read (only the cached Qdrant health gate is asked).
  # The switch cancels it with no query at all; a shut gate or a spent
  # bucket only queues its own successor.
  test "switch_off: the n job cancels as paused with 0 Repo queries and 0 point reads", ctx do
    close(:switch_off, ctx)
    {result, queries} = reads(fn -> sweep(ctx) end)

    assert {:cancel, :paused} = result
    assert queries == []
    refute_received :read
    refute_received :rewrite
  end

  for gate <- [:disk_gate, :bucket_spent] do
    @gate gate
    test "#{gate}: a gated n job re-queues itself having read no data and no point", ctx do
      close(@gate, ctx)
      {result, queries} = reads(fn -> sweep(ctx) end)

      assert :ok = result
      refute Enum.any?(queries, &data_read?/1)
      refute_received :read
      refute_received :rewrite
    end
  end

  defp close(:switch_off, _ctx), do: ServiceConfig.put_override(:payload_backfill, false)
  defp close(:disk_gate, ctx), do: Agent.update(ctx.health, fn _ -> {@green, 0, 76} end)

  defp close(:bucket_spent, _ctx),
    do:
      {:allow, _} = EngramWeb.RateLimiter.hit("payload_backfill_points", 60_000, 500, :other, 500)

  # The heal job never asks an `n` gate: under the disk gate a DEK
  # rotation's heal completes as on main. The fixture's points lack `n` (the
  # setup strips it), so a heal that still touched the `n` path would pause.
  test "disk gate closed: a DEK rotation's heal job completes as on main", ctx do
    close(:disk_gate, ctx)

    {1, _} =
      Repo.update_all(
        from(n in Engram.Notes.Note, where: n.id == ^ctx.note.id),
        [set: [payload_hash: nil, keyword_version: nil]],
        skip_tenant_check: true
      )

    assert :ok = heal(ctx)

    assert Repo.one!(
             from(n in Engram.Notes.Note, where: n.id == ^ctx.note.id, select: n.payload_hash),
             skip_tenant_check: true
           )

    refute_received :rewrite
    refute all_n?(ctx)
  end

  test "the kill switch pauses it, and it resumes once back on", ctx do
    ServiceConfig.put_override(:payload_backfill, false)

    assert {:cancel, :paused} = sweep(ctx)
    refute_received :rewrite
    assert versions(ctx) |> Enum.all?(&is_nil/1)

    ServiceConfig.put_override(:payload_backfill, true)
    assert :ok = sweep(ctx)
    assert_received :rewrite
    assert all_n?(ctx)
  end

  # The disk and optimizer gate keeps `Rebuild.gate_snooze/1`'s growing,
  # jittered backoff (it is temporary; the bucket's edge wait is not this),
  # counted in the job's own meta `"gated"`.
  test "a disk-gated job's wait grows and is jittered (Rebuild.gate_snooze/1)", ctx do
    Agent.update(ctx.health, fn _ -> {@green, 0, 76} end)
    job = build_job(ReconcileNotePayloads, %{"mode" => "n_fleet"})

    waits =
      for _ <- 1..20 do
        Repo.delete_all(Oban.Job)
        assert :ok = ReconcileNotePayloads.perform(%{job | meta: %{"gated" => 3}})
        requeued_in()
      end

    assert Enum.all?(waits, &(&1 in 235..300))
    assert length(Enum.uniq(waits)) > 1
  end

  # The runner pauses the ledger on the switch (`enabled?/0`, as FileTimes):
  # no pass, so no notes walk, no jobs, no Qdrant scroll, and no stuck alert.
  test "with the kill switch off, the runner runs no ledger pass", _ctx do
    alias Engram.DataMigrations.NotePayloadStamps

    ServiceConfig.put_override(:payload_backfill, false)
    silent = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{silent.port}")

    refute NotePayloadStamps.enabled?()
    assert Engram.Workers.DataMigrationsRunner.run(NotePayloadStamps) == :skipped
    refute_enqueued(worker: ReconcileNotePayloads)

    ServiceConfig.put_override(:payload_backfill, true)
    assert NotePayloadStamps.enabled?()
  end

  # A spent bucket: the job writes no `n`, and re-queues to the window's
  # edge (plus jitter), not into a growing backoff.
  test "an exhausted bucket re-queues to the window edge, not into a backoff", ctx do
    close(:bucket_spent, ctx)

    assert :ok = sweep(ctx)
    assert requeued_in() in 0..70
    refute_received :rewrite
    assert versions(ctx) |> Enum.all?(&is_nil/1)
  end

  # Each page is capped at what the window has left, so the whole budget
  # goes through: 256 + 244 at 500/min, then the job waits for the edge.
  # The held window's cursor is stored and the job queues itself again at
  # the window's edge, so the next window carries on from it.
  test "at 500/min a window lets 500 points through, then the rest waits for its edge", ctx do
    more_points(ctx, 600)

    assert :ok = sweep(ctx)
    assert written(ctx) == 500

    assert requeued_in() in 0..70
    assert EngramWeb.RateLimiter.peek("payload_backfill_points", 60_000, 500) == 0
  end

  # The sustained rate, on a fake clock: every edge snooze lands in the next
  # window (never skips one), so one job writes every window: 500/min at
  # 500, 1,000/min at 1,000. A growing backoff after a denial would not.
  test "the edge snooze always wakes in the next window, never later" do
    for now <- [0, 1, 30_000, 59_000, 59_999, 60_000, 61_234, 119_999] do
      for _ <- 1..20 do
        s = ReconcileNotePayloads.edge_snooze(now)
        wake = now + s * 1_000
        assert div(wake, 60_000) == div(now, 60_000) + 1, "now=#{now} s=#{s}"
        assert s >= 1
      end
    end
  end

  # Users with nothing to write spend no budget: the peek is free and the
  # bucket is spent only right before a write, with the page's points.
  test "many users with nothing to write spend 0, and a full page still goes through", ctx do
    for _ <- 1..50, do: {:ok, _} = Crypto.ensure_user_dek(insert(:user))

    assert :ok = sweep(ctx)
    assert_received :rewrite
    assert all_n?(ctx)

    written = map_size(Agent.get(ctx.points, & &1))
    assert EngramWeb.RateLimiter.peek("payload_backfill_points", 60_000, 500) == 500 - written
  end

  test "the per-minute cap is a runtime override", ctx do
    ServiceConfig.put_override(:payload_backfill_points_per_min, 1)
    {:allow, _} = EngramWeb.RateLimiter.hit("payload_backfill_points", 60_000, 1, :other, 1)

    assert :ok = sweep(ctx)
    assert requeued_in() in 0..70
    refute_received :rewrite
  end

  test "it runs at the limits, and a rerun writes nothing (resume-safe)", ctx do
    Agent.update(ctx.health, fn _ ->
      {put_in(@green, ["update_queue", "length"], 100), 50_000, 75 - 1}
    end)

    assert :ok = sweep(ctx)
    assert_received :rewrite
    assert all_n?(ctx)

    # Restarted mid-way or rerun: nothing selected, nothing written twice.
    {_, _} =
      Repo.update_all(
        from(s in NoteIndexState, where: s.user_id == ^ctx.user.id),
        [set: [payload_version: nil]],
        skip_tenant_check: true
      )

    assert :ok = sweep(ctx)
    refute_received :rewrite
  end

  # One fleet-wide `n` job (`mode: "n_fleet"`), never one per user: prod
  # 0.77.0 queued ~1,160 per-user jobs whose bucket snoozes all woke in the
  # same ~70 s band (~20 oban_jobs UPDATEs a second, ~0 points delivered).
  describe "the fleet n job" do
    alias Engram.DataMigrations.NotePayloadStamps

    @fleet %{"mode" => "n_fleet"}

    defp fleet, do: perform_job(ReconcileNotePayloads, @fleet)
    defp fleet(meta), do: ReconcileNotePayloads.perform(%{fleet_job() | meta: meta})
    defp fleet_job, do: build_job(ReconcileNotePayloads, @fleet)

    defp fleet_jobs, do: all_enqueued(worker: ReconcileNotePayloads, args: @fleet)
    defp n_jobs, do: all_enqueued(worker: ReconcileNotePayloads, args: %{"mode" => "n"})

    defp clear_jobs, do: Repo.delete_all(Oban.Job)

    defp ledger, do: NotePayloadStamps.run_pass(peers: fn -> [] end)

    # `count` users, each with one stamped note behind the version and `per`
    # v5 points without `n`. Returns `{user id, [point id]}` pairs.
    defp stale_users(ctx, count, per) do
      users =
        for _ <- 1..count do
          user = build(:user)
          vault = build(:vault, user: nil, user_id: user.id)

          note =
            build(:note,
              user: nil,
              vault: nil,
              user_id: user.id,
              vault_id: vault.id,
              payload_hash: :crypto.strong_rand_bytes(32)
            )

          {user, vault, note, for(_ <- 1..per, do: Ecto.UUID.generate())}
        end

      bulk_insert!(Engram.Accounts.User, for({u, _, _, _} <- users, do: u))
      bulk_insert!(Engram.Vaults.Vault, for({_, v, _, _} <- users, do: v))
      bulk_insert!(Engram.Notes.Note, for({_, _, n, _} <- users, do: n))
      users = for {u, _v, n, points} <- users, do: {u, n, points}

      rows =
        for {user, note, points} <- users, {point, i} <- Enum.with_index(points) do
          %{
            note_id: note.id,
            user_id: user.id,
            vault_id: note.vault_id,
            position: i,
            char_start: 0,
            char_end: 1,
            qdrant_point_id: point
          }
        end

      rows
      |> Enum.chunk_every(5_000)
      |> Enum.each(&Repo.insert_all(Engram.Notes.Chunk, &1, skip_tenant_check: true))

      Agent.update(ctx.points, fn held ->
        for {user, _note, points} <- users,
            point <- points,
            into: held,
            do: {point, %{"u" => Engram.Vector.FilterId.uuid(user.id)}}
      end)

      {_, _} =
        Repo.update_all(
          from(s in NoteIndexState, where: not is_nil(s.note_id)),
          [set: [payload_version: nil]],
          skip_tenant_check: true
        )

      for {user, _note, points} <- users, do: {user.id, points}
    end

    # One INSERT per 1,000 rows of factory-built structs (unset columns take
    # their database default): many users in one statement, not one each.
    defp bulk_insert!(schema, structs) do
      fields = schema.__schema__(:fields)

      auto =
        for {names, {m, f, a}} <- schema.__schema__(:autogenerate),
            name <- names,
            into: %{},
            do: {name, apply(m, f, a)}

      structs
      |> Enum.map(fn struct ->
        struct
        |> Map.take(fields)
        |> Map.merge(auto)
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
      end)
      |> Enum.chunk_every(1_000)
      |> Enum.each(&Repo.insert_all(schema, &1, skip_tenant_check: true))
    end

    # User ids whose points carry `n` now.
    defp users_written(ctx, users) do
      held = Agent.get(ctx.points, & &1)

      for {uid, points} <- users,
          Enum.any?(points, &Map.has_key?(held[&1], "n")),
          do: uid
    end

    test "many users needing n queue exactly one fleet job, never one per user", ctx do
      stale_users(ctx, 20, 1)

      assert {:more, _} = ledger()
      assert [_] = fleet_jobs()
      assert n_jobs() == []

      # Every later pass keeps it at one.
      assert {:more, _} = ledger()
      assert [_] = fleet_jobs()
    end

    test "a spent bucket re-queues the fleet job once at the window edge, never N wakes", ctx do
      stale_users(ctx, 30, 1)
      close(:bucket_spent, ctx)

      {result, queries} = reads(fn -> fleet() end)
      assert :ok = result
      refute_received :read
      refute_received :rewrite
      refute Enum.any?(queries, &(&1.sql =~ ~r/"(notes|chunks|users)"/))

      assert [next] = fleet_jobs()
      assert DateTime.diff(next.scheduled_at, DateTime.utc_now(), :second) in 0..70
      assert n_jobs() == []
    end

    test "with the switch off it cancels as paused, reads nothing, and the ledger re-adds it",
         ctx do
      stale_users(ctx, 5, 1)
      ServiceConfig.put_override(:payload_backfill, false)

      {result, queries} = reads(fn -> fleet() end)
      assert {:cancel, :paused} = result
      assert queries == []
      refute_received :read
      assert fleet_jobs() == []

      refute NotePayloadStamps.enabled?()
      assert Engram.Workers.DataMigrationsRunner.run(NotePayloadStamps) == :skipped
      assert fleet_jobs() == []

      ServiceConfig.put_override(:payload_backfill, true)
      assert {:more, _} = ledger()
      assert [_] = fleet_jobs()
    end

    test "the optimizer gate backs off on its own count, not on bucket snoozes", ctx do
      Agent.update(ctx.health, fn _ -> {@green, 50_001, nil} end)

      # Fifty bucket waits behind it (`snoozed`), never a gate hit: 30 s.
      assert :ok = fleet(%{"snoozed" => 50})
      assert [first] = fleet_jobs()
      assert first.meta["gated"] == 1
      assert DateTime.diff(first.scheduled_at, DateTime.utc_now(), :second) in 25..30

      # Its third gate hit: 240 s jittered to 300, whatever `snoozed` says.
      clear_jobs()
      assert :ok = fleet(%{"snoozed" => 50, "gated" => 3})
      assert [third] = fleet_jobs()
      assert third.meta["gated"] == 4
      assert DateTime.diff(third.scheduled_at, DateTime.utc_now(), :second) in 235..300

      # A bucket wait neither grows it nor is grown by it.
      Agent.update(ctx.health, fn _ -> {@green, 0, nil} end)
      Engram.Cache.clear_local(:rebuild)
      close(:bucket_spent, ctx)
      clear_jobs()
      assert :ok = fleet(%{"snoozed" => 50, "gated" => 3})
      assert [edge] = fleet_jobs()
      assert edge.meta["gated"] == 0
    end

    test "a legacy per-user n job cancels itself and makes sure the fleet job exists", ctx do
      assert {:cancel, :superseded} = legacy(ctx)
      refute_received :read
      assert [_] = fleet_jobs()

      # A second legacy job does not add another.
      assert {:cancel, :superseded} = legacy(ctx)
      assert [_] = fleet_jobs()
    end

    # A user whose payload write Qdrant refuses (4xx) is logged and counted
    # once, and the run carries on: the users after it are written in the
    # same run, and the job does not end.
    test "a 4xx on one user does not stop the others in the same run", ctx do
      users = stale_users(ctx, 3, 1) |> Enum.sort()
      [{_, first}, {refused_uid, refused}, {_, last}] = users
      Agent.update(ctx.refuse, fn _ -> MapSet.new(refused) end)

      cancelled =
        :telemetry_test.attach_event_handlers(self(), [
          [:engram, :indexing, :payload_reconcile_cancelled]
        ])

      assert :ok = fleet()

      held = Agent.get(ctx.points, & &1)
      assert Enum.all?(first ++ last, &Map.has_key?(held[&1], "n"))
      refute Enum.any?(refused, &Map.has_key?(held[&1], "n"))

      assert_received {[:engram, :indexing, :payload_reconcile_cancelled], ^cancelled,
                       %{count: 1}, %{http_status: 400}}

      assert length(users_written(ctx, users)) == 2
      refute refused_uid in users_written(ctx, users)
    end

    # A lap over users with nothing behind costs one probe each: no
    # per-window note reads (`IdWindows` + the window selection), no chunk
    # read. Main walked only users the ledger found behind; the fleet walks
    # every user, so a done one must be near free.
    test "a lap over done users costs one cheap probe each, no note-page reads", ctx do
      users = stale_users(ctx, 20, 1)

      {_, _} =
        Repo.update_all(NoteIndexState, [set: [payload_version: 6]], skip_tenant_check: true)

      {result, queries} = reads(fn -> fleet() end)
      assert :ok = result
      assert users_written(ctx, users) == []
      refute_received :read

      # No id window and no chunk read but the probe's own EXISTS.
      assert Enum.filter(queries, &(&1.sql =~ "unnest")) == []
      assert Enum.all?(queries, &(not (&1.sql =~ ~s("chunks")) or &1.sql =~ "payload_version"))
      # One probe per user (the setup's user too), each one tenant
      # transaction (begin, two set_configs, the EXISTS, commit), plus the
      # users page, the cursor and the job check.
      probes = Enum.count(queries, &(&1.sql =~ "payload_version"))
      assert probes == length(users) + 1
      assert length(queries) <= 5 * (length(users) + 1) + 10
    end

    # With the switch off a legacy job cancels having read nothing, and
    # queues no fleet job (the ledger adds it once the switch is on).
    test "with the switch off a legacy n job cancels with 0 queries", ctx do
      close(:switch_off, ctx)
      {result, queries} = reads(fn -> legacy(ctx) end)

      assert {:cancel, :superseded} = result
      assert queries == []
      assert fleet_jobs() == []
    end

    # Prod held users with two scheduled per-user jobs (the unique race):
    # each one cancels itself on wake, and only one fleet job results.
    test "a user holding two legacy n jobs gets both cancelled and one fleet job", ctx do
      args = %{"user_id" => ctx.user.id, "mode" => "n"}

      jobs =
        for _ <- 1..2 do
          {:ok, job} = Oban.insert(ReconcileNotePayloads.new(args, unique: false))
          job
        end

      assert length(n_jobs()) == 2

      for job <- jobs,
          do: assert({:cancel, :superseded} = ReconcileNotePayloads.perform(job))

      assert [_] = fleet_jobs()
      refute_received :read
    end

    # The same race on the fleet slot: two pending fleet jobs. One running
    # beside another cancels (no double write, no double spend); two pending
    # ones run in turn, and the re-queue conflicts, so one stays pending.
    test "simultaneous fleet jobs give one writer and one pending, converging to one", ctx do
      users = stale_users(ctx, 6, 1)

      [a, b] =
        for _ <- 1..2 do
          {:ok, job} = Oban.insert(ReconcileNotePayloads.new(@fleet, unique: false))
          job
        end

      assert length(fleet_jobs()) == 2

      # Two nodes fetch both at once. The higher id yields to the lower one
      # executing: it snoozes (stays pending, the chain is never dropped),
      # reading and spending nothing.
      state!(a, "executing")
      state!(b, "executing")
      assert {:snooze, 60} = ReconcileNotePayloads.perform(b)
      state!(b, "scheduled")
      refute_received :read
      refute_received :rewrite
      assert EngramWeb.RateLimiter.peek("payload_backfill_points", 60_000, 500) == 500

      # `a` is the one writer: it spends the window, and its re-queue
      # conflicts with the snoozed `b`, so exactly one stays pending.
      ServiceConfig.put_override(:payload_backfill_points_per_min, 3)
      assert :ok = ReconcileNotePayloads.perform(a)
      state!(a, "completed")
      assert [%{id: b_id}] = fleet_jobs()
      assert b_id == b.id
      assert length(users_written(ctx, users)) <= 3
      # Two pending again (`b` and a racing `d`): they run in turn, `b`'s
      # re-queue conflicts with `d`, and one stays pending.
      {:ok, d} = Oban.insert(ReconcileNotePayloads.new(@fleet, unique: false))
      EngramWeb.RateLimiter.reset_buckets!()
      state!(b, "executing")
      assert :ok = ReconcileNotePayloads.perform(b)
      state!(b, "completed")
      assert [%{id: id}] = fleet_jobs()
      assert id == d.id

      ServiceConfig.put_override(:payload_backfill_points_per_min, 500)
      EngramWeb.RateLimiter.reset_buckets!()
      state!(d, "executing")
      assert :ok = ReconcileNotePayloads.perform(d)
      state!(d, "completed")
      assert length(users_written(ctx, users)) == 6
      assert fleet_jobs() == []
    end

    # A fleet job stuck in `executing` (its node died) never strands the
    # chain: its successor snoozes while it looks alive, and takes over once
    # Oban's Lifeline rescues it.
    test "a stuck executing fleet job does not strand the chain", ctx do
      users = stale_users(ctx, 3, 1)

      [stuck, next] =
        for _ <- 1..2 do
          {:ok, job} = Oban.insert(ReconcileNotePayloads.new(@fleet, unique: false))
          job
        end

      state!(stuck, "executing")
      state!(next, "executing")
      assert {:snooze, 60} = ReconcileNotePayloads.perform(next)
      state!(next, "scheduled")
      assert [_] = fleet_jobs()

      # Lifeline rescues the orphan (back to available); the snoozer runs.
      state!(stuck, "available")
      state!(next, "executing")
      assert :ok = ReconcileNotePayloads.perform(next)
      assert length(users_written(ctx, users)) == 3
    end

    defp state!(job, state) do
      {1, _} = Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
    end

    # 50 users x 100 points at the 500 setting, ten windows on a fake clock
    # (the bucket reset is the window edge): every window delivers exactly
    # the setting through ONE job, about five users a window in cursor
    # order, and the ten windows reach every user. Few users, so a window
    # runs in well under a second.
    test "the sustained rate is the setting across 50 users over ten windows", ctx do
      users = stale_users(ctx, 50, 100)
      clear_jobs()

      per_window =
        for _window <- 1..10 do
          before = written(ctx)
          touched = users_written(ctx, users)
          fresh_window()
          clear_jobs()
          assert :ok = fleet()
          assert [next] = fleet_jobs()
          assert DateTime.diff(next.scheduled_at, DateTime.utc_now(), :second) in 0..70
          {written(ctx) - before, length(users_written(ctx, users) -- touched)}
        end

      assert Enum.map(per_window, &elem(&1, 0)) == List.duplicate(500, 10)
      # About five new users a window (one may straddle two windows).
      assert Enum.all?(per_window, fn {_, new} -> new >= 4 end)
      assert length(users_written(ctx, users)) == 50
    end

    # The bucket is Hammer's real 60 s fix window: start each fake window
    # with 3 s ahead of the real edge, so one run (well under 1 s) never
    # spans two.
    defp fresh_window do
      EngramWeb.RateLimiter.clear_buckets!()
      left = 60_000 - rem(System.system_time(:millisecond), 60_000)
      if left < 3_000, do: Process.sleep(left + 1)
    end

    # The insert_unique advisory-lock race: the self re-queue reports a
    # conflict and inserts nothing, so no fleet job is pending. The next
    # hourly ledger pass re-adds it, and the backfill finishes.
    test "a lost self re-queue is logged, re-added by the next ledger pass, and nothing strands",
         ctx do
      users = stale_users(ctx, 10, 1)
      ServiceConfig.put_override(:payload_backfill_points_per_min, 4)

      Application.put_env(:engram, :reconcile_n_insert_fun, fn changeset ->
        {:ok, %{Ecto.Changeset.apply_action!(changeset, :insert) | conflict?: true}}
      end)

      on_exit(fn -> Application.delete_env(:engram, :reconcile_n_insert_fun) end)

      log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = fleet() end)
      assert log =~ "fleet re-queue lost"
      assert fleet_jobs() == []

      Application.delete_env(:engram, :reconcile_n_insert_fun)
      ServiceConfig.put_override(:payload_backfill_points_per_min, 500)
      EngramWeb.RateLimiter.reset_buckets!()

      assert {:more, _} = ledger()
      assert [_] = fleet_jobs()

      assert :ok = fleet()
      assert length(users_written(ctx, users)) == 10
    end
  end
end
