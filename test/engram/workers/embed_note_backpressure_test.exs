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

  test "QDRANT_BACKPRESSURE_PREFLIGHT=false embeds even over the limit", %{
    bypass: bypass,
    note: note
  } do
    ServiceConfig.put_override(:qdrant_backpressure_preflight, false)
    fake_qdrant(bypass, sys_metrics: volume(99))
    embeds_ok()

    assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
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

  # A tripped strict breaker (review H2) and a write still queued past its
  # wait (review M2): neither may stamp the note, and neither may re-embed.
  for {label, first_upsert, event} <- [
        {"a tripped max_points_count breaker",
         {400,
          ~S|{"status":{"error":"Bad request: Max points count limit of 1500000 reached!"}}|},
         :backpressure},
        {"a wait_timeout (queued, not applied)",
         {200, ~S|{"result":{"operation_id":9,"status":"wait_timeout"},"status":"ok"}|},
         :wait_timeout}
      ] do
    @first_upsert first_upsert
    @event event
    test "#{label} snoozes unstamped, and the retry neither re-embeds nor re-charges",
         %{bypass: bypass, note: note} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      first = @first_upsert

      upserts = fn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> first
          _ -> {200, ~s({"result":{"status":"completed"}})}
        end
      end

      fake_qdrant(bypass, upserts: upserts)
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, @event]])
      embeds_ok(1)

      assert {:snooze, seconds} =
               perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})

      assert seconds in 30..90
      assert_received {[:engram, :qdrant, @event], ^ref, %{count: 1}, _meta}
      charged = UsageMeters.lifetime_embed_tokens(note.user_id)
      assert reloaded(note).embed_hash == nil
      assert reloaded(note).embed_retry_after == nil

      assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
      assert reloaded(note).embed_hash == note.content_hash
      assert UsageMeters.lifetime_embed_tokens(note.user_id) == charged
    end
  end

  # 2026-10-19 prod: a commit that failed AFTER the embed (the chunk insert
  # overflowed the bind cap) re-embedded and re-charged the whole note on every
  # retry. Retention now spans the commit, so any post-embed failure is paid once.
  test "a commit error after the embed: the retry neither re-embeds nor re-charges",
       %{bypass: bypass, note: note} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    upserts = fn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {400, ~s({"status":{"error":"Wrong input: boom"}})}
        _ -> {200, ~s({"result":true})}
      end
    end

    fake_qdrant(bypass, upserts: upserts)
    before = UsageMeters.lifetime_embed_tokens(note.user_id)
    embeds_ok(1)

    assert {:error, _} = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    charged = UsageMeters.lifetime_embed_tokens(note.user_id)
    assert charged > before, "Voyage was paid, so the reservation stays charged"

    assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    assert reloaded(note).dense_indexed_hash == note.content_hash
    assert UsageMeters.lifetime_embed_tokens(note.user_id) == charged
  end

  test "a raise inside the commit: the retry neither re-embeds nor re-reserves",
       %{bypass: bypass, note: note} do
    fake_qdrant(bypass, [])
    embeds_ok(1)

    user = Engram.Accounts.get_user_with_subscription!(note.user_id)
    vault = Repo.get!(Engram.Vaults.Vault, note.vault_id, skip_tenant_check: true)
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    test_pid = self()

    opts = fn in_commit ->
      [
        reserve_tokens: fn tokens ->
          send(test_pid, {:reserved, tokens})
          true
        end,
        release_tokens: fn tokens -> send(test_pid, {:released, tokens}) end,
        in_commit: in_commit
      ]
    end

    assert_raise RuntimeError, "chunk insert blew up", fn ->
      Engram.Indexing.index_note_with_usage(
        note,
        vault,
        user,
        opts.(fn _count, _dense? -> raise "chunk insert blew up" end)
      )
    end

    assert_received {:reserved, _}

    assert {:ok, _count, 0, true} =
             Engram.Indexing.index_note_with_usage(
               note,
               vault,
               user,
               opts.(fn _count, _dense? -> :ok end)
             )

    refute_received {:reserved, _}
    refute_received {:released, _}
  end

  test "a partial pass that fails after the embed: the retry neither re-embeds nor re-reserves",
       %{bypass: bypass, note: note} do
    fake_qdrant(bypass, [])
    embeds_ok(1)

    user = Engram.Accounts.get_user_with_subscription!(note.user_id)
    vault = Repo.get!(Engram.Vaults.Vault, note.vault_id, skip_tenant_check: true)
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)

    section = fn i, word -> "## Part #{i}\n\n" <> String.duplicate("#{word} ", 120) end

    note = %{
      note
      | content: Enum.map_join(1..3, "\n\n", &section.(&1, Enum.at(~w(ash elm oak), &1 - 1)))
    }

    one_chunk = UsageMeters.estimate_tokens(section.(1, "ash"))
    test_pid = self()

    # Room for one of the three new chunks: the whole pass is refused, one fits.
    opts = fn in_commit ->
      [
        reserve_tokens: fn tokens ->
          send(test_pid, {:reserved, tokens})
          tokens <= one_chunk + div(one_chunk, 2)
        end,
        budget_available: fn -> one_chunk + div(one_chunk, 2) end,
        release_tokens: fn tokens -> send(test_pid, {:released, tokens}) end,
        in_commit: in_commit
      ]
    end

    assert_raise RuntimeError, "chunk insert blew up", fn ->
      Engram.Indexing.index_note_with_usage(
        note,
        vault,
        user,
        opts.(fn _count, _dense?, _deferred -> raise "chunk insert blew up" end)
      )
    end

    assert_received {:reserved, _whole}
    assert_received {:reserved, _partial}

    assert {:ok, _count, 0, false} =
             Engram.Indexing.index_note_with_usage(
               note,
               vault,
               user,
               opts.(fn _count, _dense?, deferred ->
                 send(test_pid, {:deferred, deferred})
                 :ok
               end)
             )

    refute_received {:reserved, _}
    refute_received {:released, _}
    assert_received {:deferred, deferred}
    assert deferred > one_chunk
  end

  # 2026-10-19 prod: a ~3 min Qdrant restart poisoned 11 notes. Oban's default
  # backoff (15s + 2^attempt) spends all 5 attempts in ~90s, so the terminal
  # attempt landed inside the outage.
  describe "backoff/1 on an unavailable upstream" do
    defp failed_job(attempt, reason) do
      %Oban.Job{
        attempt: attempt,
        max_attempts: 5,
        unsaved_error: %{
          kind: :error,
          reason: Oban.PerformError.exception({EmbedNote, {:error, reason}}),
          stacktrace: []
        }
      }
    end

    defp total_wait(reason),
      do: Enum.sum(for a <- 1..4, do: EmbedNote.backoff(failed_job(a, reason)))

    test "a Qdrant 5xx or transport error outlasts a multi-minute restart, capped at ~10 min" do
      for reason <- [{503, "unavailable"}, {502, ""}, %Req.TransportError{reason: :econnrefused}] do
        assert total_wait(reason) >= 600, "4 retries must span more than a 3 min restart"

        for a <- 1..4 do
          assert EmbedNote.backoff(failed_job(a, reason)) <= 660
        end
      end
    end

    test "a persistent error keeps the default quick backoff" do
      assert total_wait({400, "bad input"}) < 200
      assert total_wait(:no_dek) < 200
    end

    test "a crash (no PerformError) keeps the default backoff" do
      job = %Oban.Job{
        attempt: 1,
        max_attempts: 5,
        unsaved_error: %{kind: :error, reason: %RuntimeError{message: "boom"}, stacktrace: []}
      }

      assert EmbedNote.backoff(job) < 60
    end
  end

  test "a Qdrant 503 on upsert: no poison yet, and the retry reuses the paid vectors",
       %{bypass: bypass, note: note} do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    upserts = fn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {503, ~s({"status":{"error":"Service Unavailable"}})}
        _ -> {200, ~s({"result":true})}
      end
    end

    fake_qdrant(bypass, upserts: upserts)
    embeds_ok(1)

    assert {:error, {503, _}} = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    assert reloaded(note).embed_retry_after == nil

    assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: note.user_id})
    assert reloaded(note).dense_indexed_hash == note.content_hash
  end
end
