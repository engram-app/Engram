defmodule Engram.Workers.EmbedNoteTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Accounts.User
  alias Engram.Billing.OverrideCache
  alias Engram.Crypto
  alias Engram.Crypto.DekCache
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    # Factory users resolve to the Free tier, which is keyword-only and never
    # calls the embedder. Every test in this file exercises the DENSE path, so
    # the fixture user has to be one that is actually entitled to it.
    :ok = Engram.Fixtures.grant_semantic!(user)
    vault = insert(:vault, user: user)

    # Phase B.3 requires Phase B ciphertext on every note row, so go through
    # the public upsert path rather than the raw factory shortcut.
    note =
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "Test/Hello.md",
        content: "# Hello\n\nWorld."
      })

    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  defp stub_qdrant(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  describe "perform/1" do
    test "indexes note and returns :ok", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "stamps embed_hash on success", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_hash == updated.content_hash
    end

    test "skips embedding when both hashes match content_hash", %{note: note} do
      import Ecto.Query

      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [set: [embed_hash: note.content_hash, dense_indexed_hash: note.content_hash]],
        skip_tenant_check: true
      )

      # No mock expectations — if it tried to embed, Mox would fail
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "re-embeds an entitled user's note that has no dense vectors (upgrade backfill)", %{
      bypass: bypass,
      note: note
    } do
      import Ecto.Query

      # The shape a note is left in by a keyword-only tier: content IS indexed
      # (embed_hash stamped, so ReconcileEmbeddings leaves it alone) but it has
      # no dense vectors. Once the user is entitled, this must re-embed —
      # otherwise someone pays for semantic search and gets zero vectors.
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [set: [embed_hash: note.content_hash, dense_indexed_hash: nil]],
        skip_tenant_check: true
      )

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts -> {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)} end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert Repo.get!(Note, note.id, skip_tenant_check: true).dense_indexed_hash ==
               note.content_hash
    end

    test "does NOT re-embed a keyword-only user's note with no dense vectors", %{note: note} do
      import Ecto.Query

      # Same row shape as above, but the user is not entitled. This MUST be a
      # no-op: ReconcileEmbeddings re-enqueues on a 15-minute cron, so embedding
      # here would bill Voyage for a free user every 15 minutes, forever.
      Engram.Repo.delete_all(
        from(o in Engram.Billing.UserLimitOverride,
          where: o.user_id == ^note.user_id and o.key == "search_semantic_enabled"
        )
      )

      OverrideCache.evict(note.user_id)

      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [set: [embed_hash: note.content_hash, dense_indexed_hash: nil]],
        skip_tenant_check: true
      )

      # No mock expectations — any embed call fails the test.
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "optimistic lock: does not stamp embed_hash if content changed mid-embed", %{
      bypass: bypass,
      note: note
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        # Simulate concurrent edit: change content_hash while embedding
        import Ecto.Query

        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all([set: [content_hash: "changed_during_embed"]],
          skip_tenant_check: true
        )

        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      # embed_hash should NOT have been set (content_hash changed)
      assert is_nil(updated.embed_hash)
    end

    test "discards job when note doesn't exist" do
      assert {:discard, _} =
               perform_job(EmbedNote, %{note_id: "00000000-0000-0000-0000-000000999999"})
    end

    # Voyage rate-limit (429) must not burn an Oban attempt. Five 429s in a
    # row would otherwise discard the job (see handoff
    # 2026-05-24-embed-rate-limit-defenses.md: 1167 discards from free-tier
    # 3-RPM bucket).
    test "snoozes job when Voyage returns 429 rate-limit error", %{bypass: bypass, note: note} do
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts ->
        {:error, {429, %{"detail" => "rate limit exceeded"}}}
      end)

      assert {:snooze, 60} = perform_job(EmbedNote, %{note_id: note.id})
    end

    # Integration regression: pins the `{:error, {429, _}}` contract
    # end-to-end through the real Voyage adapter → Indexing → worker.
    # If a future change wraps the error tuple anywhere in the pipeline
    # (e.g. `{:error, %{stage: :embed, reason: {429, _}}}`), the snooze
    # arm in run_embed silently regresses to the discard cascade — the
    # very incident this whole PR exists to prevent.
    test "integration: real Voyage HTTP 429 → snooze (no MockEmbedder)",
         %{bypass: bypass, note: note} do
      voyage_bypass = Bypass.open()

      prev_embedder = Application.get_env(:engram, :embedder)
      prev_voyage_url = Application.get_env(:engram, :voyage_url)
      prev_voyage_key = Application.get_env(:engram, :voyage_api_key)

      Application.put_env(:engram, :embedder, Engram.Embedders.Voyage)
      Application.put_env(:engram, :voyage_url, "http://localhost:#{voyage_bypass.port}")
      Application.put_env(:engram, :voyage_api_key, "test-key")

      on_exit(fn ->
        Application.put_env(:engram, :embedder, prev_embedder)

        if prev_voyage_url,
          do: Application.put_env(:engram, :voyage_url, prev_voyage_url),
          else: Application.delete_env(:engram, :voyage_url)

        if prev_voyage_key,
          do: Application.put_env(:engram, :voyage_api_key, prev_voyage_key),
          else: Application.delete_env(:engram, :voyage_api_key)
      end)

      stub_qdrant(bypass)

      # `expect` (not `expect_once`) because Req's default
      # `retry: :transient, max_retries: 3` retries 429 up to three times
      # before giving up. Bypass returning 500 on a missing route after the
      # first call would short-circuit the snooze path.
      Bypass.expect(voyage_bypass, "POST", "/v1/embeddings", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, ~s({"detail":"rate limit exceeded"}))
      end)

      assert {:snooze, 60} =
               perform_job(EmbedNote, %{note_id: note.id},
                 attempt: 1,
                 max_attempts: 5
               )
    end

    test "returns {:error, _} for non-429 embed failures (preserves retry behavior)",
         %{bypass: bypass, note: note} do
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts ->
        {:error, {500, %{"detail" => "internal error"}}}
      end)

      assert {:error, {500, _}} = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "logs the per-attempt failure with note_id + bounded error_kind (not silent until discard)",
         %{bypass: bypass, note: note} do
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts ->
        {:error, {500, %{"detail" => "secret-internal-detail"}}}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {500, _}} = perform_job(EmbedNote, %{note_id: note.id})
        end)

      assert log =~ "embed_attempt_failed"
      assert log =~ "note_id=#{note.id}"
      # The HTTP status is the triage signal (401 vs 429 vs 500 vs 503).
      assert log =~ "status=500"
      # The raw upstream body never lands in the log.
      refute log =~ "secret-internal-detail"
    end

    test "discards job when note is soft-deleted", %{user: user} do
      note = insert(:note, user: user, deleted_at: DateTime.utc_now())
      assert {:discard, _} = perform_job(EmbedNote, %{note_id: note.id})
    end

    # T3.7 — RotationGate
    test "snoozes for 60 seconds when user's DEK rotation is in progress", %{
      note: note,
      user: user
    } do
      # Set lock directly — do NOT use RotationLock.acquire/2 (advisory lock
      # does not survive across a Sandbox checkout in non-async tests).
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      # No mock expectations — if it reached the embedder, Mox would fail
      assert {:snooze, 60} = perform_job(EmbedNote, %{note_id: note.id})
    end

    # Note: the {:discard, :user_deleted} arm is triggered when RotationGate.check/1
    # returns {:error, :user_not_found}. Because notes carry a FK to users, it is
    # not possible to have a valid note_id for a hard-deleted user within the DB
    # constraints. The user_not_found path is covered by rotation_gate_test.exs
    # (check/1 with id 0). The worker arm exists as a safety net for any future
    # scenario where notes outlive users (e.g., deferred FK, cascade delay).

    test "decrypts content before indexing for encrypted vault", %{bypass: bypass} do
      DekCache.invalidate_all()

      user = insert(:user)
      {:ok, user} = Crypto.ensure_user_dek(user)
      :ok = Engram.Fixtures.grant_semantic!(user)
      vault = insert(:vault, user: user)

      # upsert_note encrypts content on the way in
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "secure/secret.md",
          "content" => "# Secret\n\nClassified content.",
          "mtime" => 1_000.0
        })

      # Embedder should receive non-empty texts (plaintext chunks, not "")
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        # texts come from Markdown.parse on the decrypted content — must be non-empty
        assert texts != []
        assert Enum.all?(texts, fn t -> is_binary(t) and t != "" end)
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        if String.contains?(conn.request_path, "/points") and conn.method == "PUT" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:upsert_body, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        else
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        end
      end)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      # Confirms the worker loaded the (encrypted) vault and passed it into the
      # indexing pipeline: payloads must carry nonces and ciphertext, not plaintext.
      assert_received {:upsert_body, body}
      points = body["points"]
      assert points != []

      Enum.each(points, fn p ->
        payload = p["payload"]
        assert Map.has_key?(payload, "text_nonce")
        assert Map.has_key?(payload, "title_nonce")
        refute payload["text"] =~ "Classified"
      end)

      # embed_hash should be stamped, confirming the job ran to completion
      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_hash == updated.content_hash
    end
  end

  describe "new_debounced — settle debounce" do
    setup do
      prev_settle = Application.get_env(:engram, :embed_settle_seconds)
      prev_max = Application.get_env(:engram, :embed_settle_max_wait_seconds)
      Application.put_env(:engram, :embed_settle_seconds, 30)
      Application.put_env(:engram, :embed_settle_max_wait_seconds, 300)

      on_exit(fn ->
        restore = fn key, val ->
          if is_nil(val),
            do: Application.delete_env(:engram, key),
            else: Application.put_env(:engram, key, val)
        end

        restore.(:embed_settle_seconds, prev_settle)
        restore.(:embed_settle_max_wait_seconds, prev_max)
      end)

      :ok
    end

    defp embed_job(note_id) do
      from(j in Oban.Job, where: fragment("? ->> 'note_id' = ?", j.args, ^to_string(note_id)))
      |> Repo.one!()
    end

    test "schedules ~settle seconds out by default", %{note: note} do
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id))

      job = embed_job(note.id)
      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
      assert diff in 25..35
    end

    test "a rapid re-insert keeps a single job and pushes the timer out", %{note: note} do
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id))
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id))

      jobs =
        from(j in Oban.Job, where: fragment("? ->> 'note_id' = ?", j.args, ^to_string(note.id)))
        |> Repo.all()

      assert length(jobs) == 1
      diff = DateTime.diff(hd(jobs).scheduled_at, DateTime.utc_now(), :second)
      assert diff in 25..35
    end

    test "clamps scheduled_at to the max-wait ceiling for a continuously-edited note",
         %{note: note} do
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id))

      # Backdate the burst start to 290s ago — 10s short of the 300s ceiling.
      # The next edit must clamp to the ceiling (~now+10s), NOT the full 30s settle.
      burst_start = DateTime.add(DateTime.utc_now(), -290, :second)

      from(j in Oban.Job, where: fragment("? ->> 'note_id' = ?", j.args, ^to_string(note.id)))
      |> Repo.update_all(set: [inserted_at: burst_start])

      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id))

      job = embed_job(note.id)
      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
      assert diff <= 15
    end
  end

  describe "perform/1 — poison-loop guard" do
    test "stamps embed_retry_after on the final failed attempt", %{bypass: bypass, note: note} do
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts -> {:error, {500, %{"detail" => "boom"}}} end)

      assert {:error, {500, _}} =
               perform_job(EmbedNote, %{note_id: note.id}, attempt: 5, max_attempts: 5)

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_retry_after != nil
      assert DateTime.compare(updated.embed_retry_after, DateTime.utc_now()) == :gt
    end

    test "a transient transport failure gets a SHORT cooldown, not the 6h poison",
         %{bypass: bypass, note: note} do
      # "Qdrant/Ollama not reachable" recovers on its own — a 6h park stranded
      # notes through the 2026-07-19 Qdrant outage. Transport errors get a short
      # cooldown so the note re-embeds on the next reconcile.
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, %Req.TransportError{}} =
               perform_job(EmbedNote, %{note_id: note.id}, attempt: 5, max_attempts: 5)

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      cooldown = DateTime.diff(updated.embed_retry_after, DateTime.utc_now())

      assert 60 <= cooldown and cooldown <= 900,
             "transient cooldown was #{cooldown}s, expected ~300s (not the 6h poison)"
    end

    test "a persistent content (4xx) failure keeps the long 6h poison cooldown",
         %{bypass: bypass, note: note} do
      # A 4xx (bad request / unembeddable content) won't fix itself on retry —
      # keep the long cooldown so ReconcileEmbeddings stops re-enqueuing it.
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts -> {:error, {400, %{"detail" => "unembeddable"}}} end)

      assert {:error, {400, _}} =
               perform_job(EmbedNote, %{note_id: note.id}, attempt: 5, max_attempts: 5)

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      cooldown = DateTime.diff(updated.embed_retry_after, DateTime.utc_now())
      assert cooldown > 20_000, "persistent cooldown was #{cooldown}s, expected ~21600s (6h)"
    end

    test "parks a nil-content_hash note on the final attempt (id-only match)",
         %{bypass: bypass, note: note} do
      # A nil content_hash must still park — otherwise the optimistic
      # `content_hash = NULL` guard never matches and the loop persists.
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all([set: [content_hash: nil]], skip_tenant_check: true)

      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts -> {:error, {500, %{"detail" => "boom"}}} end)

      assert {:error, {500, _}} =
               perform_job(EmbedNote, %{note_id: note.id}, attempt: 5, max_attempts: 5)

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_retry_after != nil
    end

    test "does NOT stamp embed_retry_after on a non-final attempt", %{bypass: bypass, note: note} do
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts -> {:error, {500, %{"detail" => "boom"}}} end)

      assert {:error, {500, _}} =
               perform_job(EmbedNote, %{note_id: note.id}, attempt: 1, max_attempts: 5)

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert is_nil(updated.embed_retry_after)
    end

    test "emits [:engram, :embed, :poison] telemetry on the final failed attempt",
         %{bypass: bypass, note: note} do
      stub_qdrant(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts -> {:error, {503, %{"detail" => "boom"}}} end)

      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:engram, :embed, :poison],
        fn _e, measurements, metadata, _ ->
          send(test_pid, {:poison, measurements, metadata})
        end,
        nil
      )

      try do
        assert {:error, {503, _}} =
                 perform_job(EmbedNote, %{note_id: note.id}, attempt: 5, max_attempts: 5)
      after
        :telemetry.detach(handler_id)
      end

      assert_received {:poison, %{count: 1}, %{status: 503, note_id: note_id}}
      assert note_id == note.id
    end

    test "clears embed_retry_after on a successful embed", %{bypass: bypass, note: note} do
      # Simulate a previously-poisoned note still carrying a cooldown stamp.
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [set: [embed_retry_after: DateTime.add(DateTime.utc_now(), 3600, :second)]],
        skip_tenant_check: true
      )

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert is_nil(updated.embed_retry_after)
    end
  end

  describe "job scheduling" do
    test "Notes.upsert_note enqueues EmbedNote job", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Scheduled.md",
          "content" => "# Scheduled",
          "mtime" => 1_000.0
        })

      # Oban is in :manual mode globally — jobs stay in 'scheduled' state for assertion
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "upsert with unchanged content does not enqueue embed job", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/NoChange.md",
          "content" => "# Same content",
          "mtime" => 1_000.0
        })

      # First upsert triggers embed
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      # Re-upsert with same content — should not enqueue another
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/NoChange.md",
          "content" => "# Same content",
          "mtime" => 2_000.0
        })

      # Still only one job
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 1
    end

    test "delete_note does not enqueue an additional embed job", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      # Stub all Qdrant requests — the background delete_note_index Task may hit Qdrant
      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Gone.md",
          "content" => "# Gone",
          "mtime" => 1_000.0
        })

      Notes.delete_note(user, vault, note.path)
      # Allow the background Task to complete before checking job count
      Process.sleep(100)

      # Only the upsert job, nothing from delete
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 1
    end
  end

  # The pricing v2 §A phone-verification gate was removed along with
  # REQUIRE_PHONE_FOR_EMBED: it never ran outside its own tests (prod pinned
  # the flag to "false" for its whole life). An unverified phone must NOT
  # affect embedding — this is the regression guard for that.
  describe "perform/1 — phone verification" do
    test "embeds normally for a user with no verified phone",
         %{bypass: bypass, note: note, user: user} do
      assert is_nil(user.phone_verified_at)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end
  end

  # A user with no semantic override — the real Free tier. Cannot reuse the
  # setup fixture, which grants semantic to exercise the dense path.
  defp keyword_only_user! do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    note =
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "Test/Keyword.md",
        content: "# Keyword\n\nOnly."
      })

    {user, note}
  end

  describe "perform/1 — losing semantic entitlement" do
    test "a keyword-only re-index clears dense_indexed_hash, so an upgrade can backfill it",
         %{bypass: bypass, user: user, note: note} do
      # Index once WITH dense vectors (setup user is entitled).
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts -> {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)} end)

      stub_qdrant(bypass)
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
      assert %Note{dense_indexed_hash: dense} = Repo.get!(Note, note.id, skip_tenant_check: true)
      refute is_nil(dense)

      # Lose entitlement, then edit. The re-index rebuilds the note's points
      # sparse-only, so the dense vectors this column names no longer exist.
      Repo.delete_all(
        from(o in Engram.Billing.UserLimitOverride,
          where: o.user_id == ^user.id and o.key == "search_semantic_enabled"
        ),
        skip_tenant_check: true
      )

      OverrideCache.evict(user.id)

      {:ok, note} =
        Notes.upsert_note(
          user,
          Repo.get!(Engram.Vaults.Vault, note.vault_id, skip_tenant_check: true),
          %{
            "path" => note.path,
            "content" => "# Hello\n\nDifferent words entirely.",
            "mtime" => 2_000.0
          }
        )

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      # Leaving the old hash would make ReconcileEmbeddings' upgrade backfill
      # (which selects on `is_nil(dense_indexed_hash)`) skip this note forever:
      # the user would pay for semantic search over a silent hole.
      assert %Note{dense_indexed_hash: nil} = Repo.get!(Note, note.id, skip_tenant_check: true)
    end
  end

  describe "perform/1 — entitled but over the index cap" do
    test "an over-cap note is not stamped as dense-indexed, so raising the cap re-opens it",
         %{user: user, note: note} do
      # A SEMANTIC user can still be over an indexed_notes_cap — a per-user
      # override is exactly how a promo grant or a throttled abuser is
      # expressed. Entitlement alone must not stamp the dense hash: nothing
      # was written, and ReconcileEmbeddings' backfill selects on
      # `is_nil(dense_indexed_hash)`, so a stamp locks the note out forever.
      Repo.insert!(%Engram.Billing.UserLimitOverride{
        user_id: user.id,
        key: "indexed_notes_cap",
        value: %{"v" => 0},
        reason: "test",
        set_by: "test"
      })

      OverrideCache.evict(user.id)

      # No MockEmbedder expectation and no Qdrant stub: an over-cap note must
      # reach neither.
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert %Note{dense_indexed_hash: nil} = Repo.get!(Note, note.id, skip_tenant_check: true)
    end
  end

  describe "perform/1 — lifetime embed-token budget (pricing v2 §B)" do
    setup do
      # Users without a Subscription default to :free tier (Billing.tier/1).
      # Free's lifetime_embed_token_cap = 20M per LimitKeys catalog.
      prev = Application.get_env(:engram, :limits_enforced)
      Application.put_env(:engram, :limits_enforced, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :limits_enforced),
          else: Application.put_env(:engram, :limits_enforced, prev)
      end)

      :ok
    end

    test "discards job when lifetime_embed_token_cap is exhausted", %{user: user, note: note} do
      Engram.UsageMeters.add_embed_tokens(user.id, 20_000_000)

      assert {:cancel, _reason} = perform_job(EmbedNote, %{note_id: note.id})

      # No Voyage call should have happened (no Mock expect declared).
      assert Engram.UsageMeters.lifetime_embed_tokens(user.id) == 20_000_000
    end

    test "proceeds and increments the counter on success",
         %{bypass: bypass, user: user, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert Engram.UsageMeters.lifetime_embed_tokens(user.id) > 0
    end

    test "user override raises the cap above the default",
         %{bypass: bypass, user: user, note: note} do
      Engram.UsageMeters.add_embed_tokens(user.id, 20_000_000)

      insert(:user_limit_override,
        user: user,
        key: "lifetime_embed_token_cap",
        value: %{"v" => 100_000_000}
      )

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "keyword-only users accrue no embed tokens — they never call Voyage",
         %{bypass: bypass} do
      {user, note} = keyword_only_user!()
      stub_qdrant(bypass)

      # No MockEmbedder expectation: a Voyage call here would fail the test.
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      # Charging anyway is not cosmetic — phantom tokens reach the 20M cap and
      # embed_budget_gate/1 then cancels the job, costing the user their BM25
      # index for spend that never happened.
      assert Engram.UsageMeters.lifetime_embed_tokens(user.id) == 0
    end

    test "an exhausted token budget does not block a keyword-only user's indexing",
         %{bypass: bypass} do
      {user, note} = keyword_only_user!()
      Engram.UsageMeters.add_embed_tokens(user.id, 20_000_000)
      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert Repo.exists?(from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id),
               skip_tenant_check: true
             )
    end
  end
end
