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

  defp sweep(ctx), do: perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

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

  # The switch gates only the `n` write and the version stamp: the job
  # still heals (a DEK rotation or FileTimes may have queued it), writes no
  # `n`, stamps no version, and ends rather than retrying while off.
  test "with the kill switch off, the job writes no n, stamps nothing, and ends", ctx do
    ServiceConfig.put_override(:payload_backfill, false)

    assert :ok = sweep(ctx)
    refute_received :rewrite
    refute all_n?(ctx)
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
    job = build_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

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
  test "an exhausted bucket holds the n write and snoozes to the window edge", ctx do
    {:allow, _} =
      EngramWeb.RateLimiter.hit("payload_backfill_points", 60_000, 500, :other, 500)

    assert {:snooze, s} = sweep(ctx)
    assert s in 1..70
    refute_received :rewrite
    assert versions(ctx) |> Enum.all?(&is_nil/1)
  end

  # Each page is capped at what the window has left, so the whole budget
  # goes through: 256 + 244 at 500/min, then the job waits for the edge.
  test "at 500/min a window lets 500 points through, then the job snoozes to its edge", ctx do
    more_points(ctx, 600)

    assert {:snooze, s} = sweep(ctx)
    assert s in 1..70
    assert written(ctx) == 500
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
      assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => idle.id})
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
end
