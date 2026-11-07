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
    stub_qdrant(bypass, health, points)

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
    %{user: user, note: note, health: health, points: points, ref: ref}
  end

  defp stub_qdrant(bypass, health, points) do
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

            Agent.update(points, fn held ->
              Enum.reduce(body["operations"], held, fn
                %{"set_payload" => %{"points" => [id], "payload" => pl}}, acc ->
                  Map.update(acc, id, pl, &Map.merge(&1, pl))
              end)
            end)

            ops = Enum.map(body["operations"], fn _ -> %{"status" => "completed"} end)
            {"application/json", Jason.encode!(%{"result" => ops, "status" => "ok"})}

          # `set_payloads/3`'s read-back.
          {"POST", path} when path == col <> "/points" ->
            held = Agent.get(points, &Map.take(&1, body["ids"]))
            found = for {id, p} <- held, do: %{"id" => id, "payload" => p}
            {"application/json", Jason.encode!(%{"result" => found, "status" => "ok"})}

          _ ->
            {"application/json", ~s({"result":true,"status":"ok"})}
        end

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, reply)
    end)
  end

  defp volume(nil), do: ""

  defp volume(pct) do
    """
    kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 100
    kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} #{pct}
    """
  end

  # The `n` backfill job (`mode: "n"`); `heal/1` is the heal job.
  defp sweep(ctx),
    do: perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id, "mode" => "n"})

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

    assert {:snooze, 30} = sweep(ctx)
    refute_received :rewrite
    assert_received {[:engram, :rebuild, :gated], _, %{count: 1}, %{reason: :disk}}
  end

  test "an optimizer backlog snoozes before any write", ctx do
    Agent.update(ctx.health, fn _ -> {@green, 50_001, nil} end)

    assert {:snooze, 30} = sweep(ctx)
    refute_received :rewrite
  end

  # A paused `n` job reads nothing: every gate runs before its first
  # Postgres or Qdrant read (only the cached Qdrant health gate is asked).
  for gate <- [:switch_off, :disk_gate, :bucket_spent] do
    @gate gate
    test "#{gate}: a paused n job snoozes with 0 Repo queries and 0 point reads", ctx do
      close(@gate, ctx)
      {result, queries} = reads(fn -> sweep(ctx) end)

      assert {:snooze, _} = result
      assert queries == []
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

    assert {:snooze, _} = sweep(ctx)
    refute_received :rewrite
    assert versions(ctx) |> Enum.all?(&is_nil/1)

    ServiceConfig.put_override(:payload_backfill, true)
    assert :ok = sweep(ctx)
    assert_received :rewrite
    assert all_n?(ctx)
  end

  # The disk and optimizer gate keeps `Rebuild.gate_snooze/1`'s growing,
  # jittered backoff (it is temporary; the bucket's edge snooze is not this).
  test "a disk-gated job's snooze grows and is jittered (Rebuild.gate_snooze/1)", ctx do
    Agent.update(ctx.health, fn _ -> {@green, 0, 76} end)
    job = build_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id, "mode" => "n"})

    snoozes =
      for _ <- 1..20, do: elem(ReconcileNotePayloads.perform(%{job | meta: %{"snoozed" => 3}}), 1)

    assert Enum.all?(snoozes, &(&1 in 240..300))
    assert length(Enum.uniq(snoozes)) > 1
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

  # A spent bucket: the job still heals, writes no `n`, and snoozes to the
  # window's edge (plus jitter), not into a growing backoff.
  test "an exhausted bucket snoozes to the window edge, not into a backoff", ctx do
    close(:bucket_spent, ctx)

    assert {:snooze, s} = sweep(ctx)
    assert s in 1..70
    refute_received :rewrite
    assert versions(ctx) |> Enum.all?(&is_nil/1)
  end

  # Each page is capped at what the window has left, so the whole budget
  # goes through: 256 + 244 at 500/min, then the job waits for the edge.
  # The held window is queued again as a fresh job at the window's edge
  # (its cursor exact), so the next window carries on from it.
  test "at 500/min a window lets 500 points through, then the rest waits for its edge", ctx do
    more_points(ctx, 600)

    assert :ok = sweep(ctx)
    assert written(ctx) == 500

    [next] = all_enqueued(worker: ReconcileNotePayloads, args: %{"mode" => "n"})
    wait = DateTime.diff(next.scheduled_at, DateTime.utc_now(), :second)
    assert wait in 0..70
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

  # Waking jobs with nothing to write spend no budget: the peek is free and
  # the bucket is spent only right before a write, with the page's points.
  test "many waking jobs with nothing to write spend 0, and a full page still goes through",
       ctx do
    for _ <- 1..50 do
      {:ok, idle} = Crypto.ensure_user_dek(insert(:user))
      assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => idle.id, "mode" => "n"})
    end

    assert EngramWeb.RateLimiter.peek("payload_backfill_points", 60_000, 500) == 500

    assert :ok = sweep(ctx)
    assert_received :rewrite
    assert all_n?(ctx)

    written = map_size(Agent.get(ctx.points, & &1))
    assert EngramWeb.RateLimiter.peek("payload_backfill_points", 60_000, 500) == 500 - written
  end

  test "the per-minute cap is a runtime override", ctx do
    ServiceConfig.put_override(:payload_backfill_points_per_min, 1)
    {:allow, _} = EngramWeb.RateLimiter.hit("payload_backfill_points", 60_000, 1, :other, 1)

    assert {:snooze, _} = sweep(ctx)
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
          user = insert(:user)
          vault = insert(:vault, user: user)
          note = insert(:note, user: user, vault: vault, payload_hash: :crypto.strong_rand_bytes(32))
          points = for _ <- 1..per, do: Ecto.UUID.generate()
          {user, note, points}
        end

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
      assert {:cancel, :superseded} = sweep(ctx)
      refute_received :read
      assert [_] = fleet_jobs()

      # A second legacy job does not add another.
      assert {:cancel, :superseded} = sweep(ctx)
      assert [_] = fleet_jobs()
    end

    # ~1,250 users at the 500 setting, ten windows on a fake clock (the
    # bucket reset is the window edge): every window delivers the setting,
    # spread over the users in cursor order, through ONE job.
    @tag timeout: 300_000
    test "the sustained rate is the setting across 1,250 users over ten windows", ctx do
      users = stale_users(ctx, 1_250, 4)
      clear_jobs()
      before = written(ctx)

      totals =
        for _window <- 1..10, reduce: [] do
          acc ->
            fresh_window()
            clear_jobs()
            assert :ok = fleet()
            assert [next] = fleet_jobs()
            assert DateTime.diff(next.scheduled_at, DateTime.utc_now(), :second) in 0..70
            [written(ctx) - before | acc]
        end

      deltas =
        totals |> Enum.reverse() |> then(&Enum.zip([0 | &1], &1)) |> Enum.map(fn {a, b} -> b - a end)

      assert deltas == List.duplicate(500, 10)
      # 5,000 points, 4 a user (the setup's user holds a few too).
      assert length(users_written(ctx, users)) >= 1_240
    end

    # The bucket is Hammer's real 60 s fix window: start each fake window
    # with 15 s ahead of the real edge, so one run never spans two.
    defp fresh_window do
      EngramWeb.RateLimiter.clear_buckets!()
      left = 60_000 - rem(System.system_time(:millisecond), 60_000)
      if left < 15_000, do: Process.sleep(left + 1)
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
