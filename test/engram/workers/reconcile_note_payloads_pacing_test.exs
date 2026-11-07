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
    # Run on each point read, in the fake's process: stands in for other
    # jobs waking between this job's gate and its first write.
    {:ok, on_read} = Agent.start_link(fn -> fn -> :ok end end)
    stub_qdrant(bypass, health, points, on_read)

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
    %{user: user, note: note, health: health, points: points, ref: ref, on_read: on_read}
  end

  defp stub_qdrant(bypass, health, points, on_read) do
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
            Agent.get(on_read, & &1).()
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

  # Pulled because Qdrant is struggling: the job must not even read it.
  # Every gate runs before the job's first Postgres or Qdrant read.
  test "with the kill switch off, the job makes no Repo and no Qdrant call", ctx do
    ServiceConfig.put_override(:payload_backfill, false)
    # A Qdrant with no routes: any request fails the test.
    silent = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{silent.port}")
    job = build_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    {result, queries} = Engram.QueryRecorder.record(fn -> ReconcileNotePayloads.perform(job) end)

    assert {:snooze, s} = result
    assert s == Engram.Rebuild.gate_snooze(0)
    assert Enum.filter(queries, &(&1.pid == self())) == []
  end

  test "a gated job's snooze grows and is jittered (Rebuild.gate_snooze/1)", ctx do
    ServiceConfig.put_override(:payload_backfill, false)
    job = build_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    snoozes =
      for _ <- 1..20, do: elem(ReconcileNotePayloads.perform(%{job | meta: %{"snoozed" => 3}}), 1)

    assert Enum.all?(snoozes, &(&1 in 240..300))
    assert length(Enum.uniq(snoozes)) > 1
  end

  # The hourly ledger pass stops with the switch too: no notes walk, no
  # job inserts, no Qdrant scroll or unstamp.
  test "with the kill switch off, the ledger pass makes no Repo and no Qdrant call", _ctx do
    ServiceConfig.put_override(:payload_backfill, false)
    silent = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{silent.port}")

    {result, queries} =
      Engram.QueryRecorder.record(fn -> Engram.DataMigrations.NotePayloadStamps.run_pass() end)

    assert result == :more
    assert Enum.filter(queries, &(&1.pid == self())) == []
  end

  # Jobs waking between this job's gate and its first page take bucket
  # points too. The gate reserved a whole page, so the page still goes
  # through, and the crowd is denied a full page each (they read nothing).
  test "a crowd of waking jobs cannot starve a reserved page", ctx do
    crowd = fn ->
      for _ <- 1..300,
          do: EngramWeb.RateLimiter.hit("payload_backfill_points", 60_000, 500, :other, 256)
    end

    Agent.update(ctx.on_read, fn _ -> crowd end)

    assert :ok = sweep(ctx)
    assert_received :rewrite
    assert all_n?(ctx)
  end

  test "the kill switch snoozes it, and it resumes once back on", ctx do
    ServiceConfig.put_override(:payload_backfill, false)

    assert {:snooze, 30} = sweep(ctx)
    refute_received :rewrite

    ServiceConfig.put_override(:payload_backfill, true)
    assert :ok = sweep(ctx)
    assert_received :rewrite
    assert all_n?(ctx)
  end

  test "a spent points-per-minute bucket snoozes before any read", ctx do
    {:allow, _} =
      EngramWeb.RateLimiter.hit("payload_backfill_points", 60_000, 500, :other, 500)

    {result, queries} = Engram.QueryRecorder.record(fn -> sweep(ctx) end)
    assert {:snooze, 30} = result
    refute Enum.any?(queries, &(&1.pid == self() and &1.source in ["notes", "chunks"]))
    refute_received :rewrite
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

    # In the next limiter window: every wake reserves a page, so a rerun in
    # the same minute is denied before it reads (nothing written either way).
    EngramWeb.RateLimiter.reset_buckets!()
    assert :ok = sweep(ctx)
    refute_received :rewrite
  end
end
