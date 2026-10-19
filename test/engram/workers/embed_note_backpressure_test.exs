defmodule Engram.Workers.EmbedNoteBackpressureTest do
  # async: false: the Qdrant pressure reading and the retained-vector cache
  # are node-wide.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Vector.Qdrant
  alias Engram.Workers.EmbedNote

  setup :verify_on_exit!

  @disk_refusal ~S|{"status":{"error":"Bad request: Disk usage is at 87% of total capacity, exceeding the configured limit of 85%. Help: Reduce disk usage (e.g. delete points or drop collections) or raise `max_disk_usage_percent` in strict mode."},"time":0.0001}|

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_backpressure_preflight, true)
    Qdrant.forget_pressure()
    on_exit(&Qdrant.forget_pressure/0)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    note =
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "Test/Pressure.md",
        content: "# Pressure\n\nSome text worth embedding."
      })

    %{bypass: bypass, note: note}
  end

  # Every Qdrant route answers OK, except the ones a test overrides:
  # `upsert` (PUT .../points) and the pressure sources.
  defp fake_qdrant(bypass, opts) do
    test_pid = self()
    upserts = Keyword.get(opts, :upserts, fn -> {200, ~s({"result":true})} end)
    sys_metrics = Keyword.get(opts, :sys_metrics, {404, ""})

    Bypass.stub(bypass, :any, :any, fn conn ->
      {status, body} =
        case {conn.method, conn.request_path} do
          {"PUT", "/collections/engram_notes/points"} ->
            send(test_pid, :upsert)
            upserts.()

          {"GET", "/sys_metrics"} ->
            sys_metrics

          {"GET", "/metrics"} ->
            {404, ""}

          _ ->
            {200, ~s({"result":true,"status":"ok"})}
        end

      # Prometheus text is not JSON: Req would try to decode it.
      type =
        if conn.request_path in ["/sys_metrics", "/metrics"],
          do: "text/plain",
          else: "application/json"

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp volume(used_pct) do
    {200,
     """
     kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} 100
     kubelet_volume_stats_used_bytes{persistentvolumeclaim="qdrant-storage-qdrant-0"} #{used_pct}
     """}
  end

  defp embeds_ok(count \\ 1) do
    expect(Engram.MockEmbedder, :embed_texts, count, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp reloaded(note), do: Repo.get!(Note, note.id, skip_tenant_check: true)

  test "preflight over 80% disk snoozes before the embedder or the meter", %{
    bypass: bypass,
    note: note
  } do
    fake_qdrant(bypass, sys_metrics: volume(86))
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, :backpressure]])
    before = UsageMeters.lifetime_embed_tokens(note.user_id)

    # No embedder expectation: any call fails verify_on_exit!.
    assert {:snooze, seconds} = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    assert seconds in 30..90
    refute_received :upsert
    assert UsageMeters.lifetime_embed_tokens(note.user_id) == before
    assert reloaded(note).embed_hash == nil
    assert_received {[:engram, :qdrant, :backpressure], ^ref, %{count: 1}, %{reason: :preflight}}
  end

  test "unknown pressure fails open and embeds", %{bypass: bypass, note: note} do
    fake_qdrant(bypass, [])
    embeds_ok()

    assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    assert_received :upsert
    assert reloaded(note).embed_hash == note.content_hash
  end

  test "pressure under 80% embeds", %{bypass: bypass, note: note} do
    fake_qdrant(bypass, sys_metrics: volume(79))
    embeds_ok()

    assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
  end

  test "a refused upsert snoozes, keeps the paid vectors, and the retry does not re-embed",
       %{bypass: bypass, note: note} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    upserts = fn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {400, @disk_refusal}
        _ -> {200, ~s({"result":true})}
      end
    end

    fake_qdrant(bypass, upserts: upserts)
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, :backpressure]])
    before = UsageMeters.lifetime_embed_tokens(note.user_id)

    # Exactly ONE embed across both attempts.
    embeds_ok(1)

    assert {:snooze, seconds} = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    assert seconds in 30..90
    assert_received {[:engram, :qdrant, :backpressure], ^ref, %{count: 1}, %{reason: :refused}}

    charged = UsageMeters.lifetime_embed_tokens(note.user_id)
    assert charged > before, "Voyage was paid, so the reservation stays charged"
    assert reloaded(note).embed_hash == nil
    # Not a poison: a snooze never parks the note.
    assert reloaded(note).embed_retry_after == nil

    assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    assert reloaded(note).embed_hash == note.content_hash
    assert reloaded(note).dense_indexed_hash == note.content_hash
    assert UsageMeters.lifetime_embed_tokens(note.user_id) == charged
  end
end
