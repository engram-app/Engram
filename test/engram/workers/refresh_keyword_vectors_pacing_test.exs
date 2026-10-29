defmodule Engram.Workers.RefreshKeywordVectorsPacingTest do
  @moduledoc """
  The keyword sweep's in-place rewrite (`RefreshKeywordVectors`) goes through
  the same Qdrant gate as the v5 rebuild (`Engram.Rebuild.qdrant_pace/0`):
  every rewrite leaves a dead copy until the optimizer vacuums the segment,
  so an unpaced sweep over the whole corpus can push disk into strict mode's
  write refusal, and users' own writes are refused with it. A user's edit
  (`EmbedNote`) is never gated.

  async: false: the Qdrant pressure reading is node-wide.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Rebuild
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Workers.{EmbedNote, RefreshKeywordVectors}

  setup :set_mox_global
  setup :verify_on_exit!

  @green %{"status" => "green", "optimizer_status" => "ok", "update_queue" => %{"length" => 0}}

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    # The token bucket and the gate verdict are node-wide: leave neither spent.
    on_exit(&EngramWeb.RateLimiter.reset_buckets!/0)
    Engram.Cache.clear_local(:rebuild)
    on_exit(fn -> Engram.Cache.clear_local(:rebuild) end)
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Qdrant.forget_pressure()
    on_exit(&Qdrant.forget_pressure/0)

    # {collection info, queued points, disk percent or nil (self-host)}
    {:ok, health} = Agent.start_link(fn -> {@green, 0, nil} end)
    stub_qdrant(bypass, health)

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

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :rebuild, :gated]])
    %{user: user, vault: vault, note: note, health: health, ref: ref}
  end

  defp stub_qdrant(bypass, health) do
    test_pid = self()
    col = "/collections/#{Qdrant.collection_name()}"

    Bypass.stub(bypass, :any, :any, fn conn ->
      {info, queued, disk} = Agent.get(health, & &1)

      {type, body} =
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

          {"PUT", path} when path == col <> "/points/vectors" ->
            send(test_pid, :rewrite)
            {"application/json", ~s({"result":true,"status":"ok"})}

          {"POST", path} when path == col <> "/points/count" ->
            {"application/json", ~s({"result":{"count":2}})}

          _ ->
            {"application/json", ~s({"result":true,"status":"ok"})}
        end

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp volume(nil), do: ""

  defp volume(pct) do
    """
    kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 100
    kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} #{pct}
    """
  end

  defp refresh(ctx),
    do: perform_job(RefreshKeywordVectors, %{note_id: ctx.note.id, user_id: ctx.user.id})

  describe "RefreshKeywordVectors is paced" do
    for {name, state, reason} <- [
          {"an update queue over 100", {put_in(@green, ["update_queue", "length"], 101), 0, nil},
           :queue},
          {"a queued-points backlog", {@green, 50_001, nil}, :optimizer},
          {"a yellow (optimizing) collection", {%{@green | "status" => "yellow"}, 0, nil},
           :optimizer},
          {"disk over the headroom threshold", {@green, 0, 76}, :disk}
        ] do
      test "#{name} snoozes it before any rewrite", ctx do
        Agent.update(ctx.health, fn _ -> unquote(Macro.escape(state)) end)

        assert {:snooze, 30} = refresh(ctx)
        refute_received :rewrite

        assert_received {[:engram, :rebuild, :gated], _, %{count: 1}, %{reason: unquote(reason)}}
      end
    end

    test "it runs at the limits", ctx do
      Agent.update(ctx.health, fn _ ->
        {put_in(@green, ["update_queue", "length"], 100), 50_000, 75 - 1}
      end)

      assert :ok = refresh(ctx)
      assert_received :rewrite
    end

    test "unknown disk capacity (self-host) does not block", ctx do
      assert :ok = refresh(ctx)
      assert_received :rewrite
    end

    test "the disk threshold is configurable", ctx do
      ServiceConfig.put_override(:rebuild_max_disk_percent, 50)
      Agent.update(ctx.health, fn _ -> {@green, 0, 60} end)

      assert {:snooze, 30} = refresh(ctx)
    end

    test "a spent maintenance token bucket does not gate it (no Voyage cost)", ctx do
      EngramWeb.RateLimiter.hit("voyage_maintenance_tpm", 60_000, 150_000, :voyage_embed, 200_000)

      assert :ok = refresh(ctx)
      assert_received :rewrite
    end
  end

  test "the rebuild's pace/0 snoozes on disk headroom too", ctx do
    Agent.update(ctx.health, fn _ -> {@green, 0, 80} end)

    assert {:snooze, 30} = Rebuild.pace()
    assert_received {[:engram, :rebuild, :gated], _, %{count: 1}, %{reason: :disk}}
  end

  test "a user's edit (EmbedNote) is never gated", ctx do
    Agent.update(ctx.health, fn _ ->
      {put_in(@green, ["update_queue", "length"], 10_000), 1_000_000, 79}
    end)

    {:ok, _} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => "plan.md", "content" => "# Plan\n\nEdited.", "mtime" => 2.0},
        actor: "api"
      )

    assert :ok = perform_job(EmbedNote, %{note_id: ctx.note.id, user_id: ctx.user.id})
    refute_received {[:engram, :rebuild, :gated], _, _, _}
  end
end
