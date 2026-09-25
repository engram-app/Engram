defmodule Engram.Workers.EmbedNoteTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.DekCache
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    # Factory users resolve to the Free tier, which embeds like every tier.
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

  # Same stub, minus the exit-time "was it called?" assertion.
  #
  # `Bypass.expect/2` VERIFIES on exit: if no request arrives, the test fails in
  # teardown with "No HTTP request arrived at Bypass" even though its body
  # passed. Every test in the poison-loop block makes `embed_texts` fail, so
  # whether Qdrant is reached at all depends on state an earlier test in the
  # same process may already have warmed — the call is incidental to what these
  # tests assert. That made the block fail intermittently on a teardown
  # assertion nobody wrote on purpose (CI run 33370717102, 1 failure in 4938).
  #
  # `Bypass.pass/1` is the documented escape hatch: it marks retained plugs OK
  # and sets `pass: true` on the instance, which nothing later resets, so
  # ordering against the request does not matter.
  defp stub_qdrant_optional(bypass) do
    stub_qdrant(bypass)
    Bypass.pass(bypass)
  end

  defp drain_embedded do
    receive do
      {:embedded, texts} -> texts ++ drain_embedded()
    after
      0 -> []
    end
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

      # `chunker_version` is part of the skip condition since #1620 — a note at
      # an older version is rebuilt, so this test has to pin the current one to
      # still be testing the hash-match skip.
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [
          set: [
            embed_hash: note.content_hash,
            dense_indexed_hash: note.content_hash,
            chunker_version: Markdown.chunker_version()
          ]
        ],
        skip_tenant_check: true
      )

      # No mock expectations — if it tried to embed, Mox would fail
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    # #1620 — chunker fixes never reached an already-indexed note. Both hashes
    # match, so the skip clause returned :ok and the note kept chunks built by
    # an older splitter forever. A NULL chunker_version is exactly that note:
    # indexed by a chunker that predates the stamp.
    test "re-indexes a note whose chunker_version is stale", %{bypass: bypass, note: note} do
      import Ecto.Query

      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [
          set: [
            embed_hash: note.content_hash,
            dense_indexed_hash: note.content_hash,
            chunker_version: nil
          ]
        ],
        skip_tenant_check: true
      )

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts -> {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)} end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert Repo.get!(Note, note.id, skip_tenant_check: true).chunker_version ==
               Markdown.chunker_version()
    end

    test "stamps the current chunker version on success", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert Repo.get!(Note, note.id, skip_tenant_check: true).chunker_version ==
               Markdown.chunker_version()
    end

    test "backfills dense vectors for a Free note inside the cap", %{
      bypass: bypass,
      note: note
    } do
      import Ecto.Query

      # The shape every Free note was left in while Free was keyword-only:
      # content IS indexed (embed_hash stamped) but it has no dense vectors.
      # Semantic search is now every tier's, so this must embed.
      assert Engram.Billing.tier(Repo.get!(User, note.user_id)) == :free

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

    test "parks an over-budget note with no dense vectors instead of re-indexing it", %{
      note: note
    } do
      import Ecto.Query

      # Same row shape as above, but the lifetime embed budget is spent. The
      # sparse index is already there, so this must neither call Voyage nor
      # rebuild: it parks the note so ReconcileEmbeddings stops re-selecting it
      # every tick.
      Engram.UsageMeters.add_embed_tokens(note.user_id, 20_000_000)

      # Pinned to the current chunker version on purpose: this test is about
      # the BUDGET, not #1620. Left NULL it would match the stale-chunker
      # clause and rebuild.
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [
          set: [
            embed_hash: note.content_hash,
            dense_indexed_hash: nil,
            chunker_version: Markdown.chunker_version()
          ]
        ],
        skip_tenant_check: true
      )

      # No mock expectations and no Qdrant stub: any embed or index fails the test.
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      parked = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert DateTime.compare(parked.embed_retry_after, DateTime.utc_now()) == :gt
      assert is_nil(parked.dense_indexed_hash)
    end

    test "does not stamp chunker_version when content changed mid-embed", %{
      bypass: bypass,
      note: note
    } do
      import Ecto.Query

      # A stale-version rebuild that loses the optimistic lock must leave
      # `chunker_version` alone. Stamping it would assert "the current chunker
      # built these rows" about chunks that were just superseded by an edit,
      # and the note would then be skipped forever at a version it never
      # actually reached.
      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [
          set: [
            embed_hash: note.content_hash,
            dense_indexed_hash: note.content_hash,
            chunker_version: nil
          ]
        ],
        skip_tenant_check: true
      )

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        # Simulate a concurrent edit landing while the embedder is in flight.
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all([set: [content_hash: "changed_mid_embed"]], skip_tenant_check: true)

        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert is_nil(updated.chunker_version)
    end

    test "rebuilds an over-budget note's keyword index when the chunker version is stale", %{
      bypass: bypass,
      note: note
    } do
      import Ecto.Query

      # An over-budget note carries the same bad chunks as everyone else's, and
      # re-chunking it sparse-only calls no embedder, so #1620 rebuilds it too.
      # The absence of a Mox expectation is the assertion that Voyage is NOT hit.
      Engram.UsageMeters.add_embed_tokens(note.user_id, 20_000_000)

      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all(
        [set: [embed_hash: note.content_hash, dense_indexed_hash: nil, chunker_version: nil]],
        skip_tenant_check: true
      )

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.chunker_version == Markdown.chunker_version()
      # Still sparse-only: the rebuild must not invent dense vectors.
      assert is_nil(updated.dense_indexed_hash)
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
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id, note.user_id))

      job = embed_job(note.id)
      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
      assert diff in 25..35
    end

    test "a rapid re-insert keeps a single job and pushes the timer out", %{note: note} do
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id, note.user_id))
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id, note.user_id))

      jobs =
        from(j in Oban.Job, where: fragment("? ->> 'note_id' = ?", j.args, ^to_string(note.id)))
        |> Repo.all()

      assert length(jobs) == 1
      diff = DateTime.diff(hd(jobs).scheduled_at, DateTime.utc_now(), :second)
      assert diff in 25..35
    end

    test "clamps scheduled_at to the max-wait ceiling for a continuously-edited note",
         %{note: note} do
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id, note.user_id))

      # Backdate the burst start to 290s ago — 10s short of the 300s ceiling.
      # The next edit must clamp to the ceiling (~now+10s), NOT the full 30s settle.
      burst_start = DateTime.add(DateTime.utc_now(), -290, :second)

      from(j in Oban.Job, where: fragment("? ->> 'note_id' = ?", j.args, ^to_string(note.id)))
      |> Repo.update_all(set: [inserted_at: burst_start])

      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id, note.user_id))

      job = embed_job(note.id)
      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
      assert diff <= 15
    end
  end

  describe "perform/1 — poison-loop guard" do
    test "stamps embed_retry_after on the final failed attempt", %{bypass: bypass, note: note} do
      stub_qdrant_optional(bypass)

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
      stub_qdrant_optional(bypass)

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
      stub_qdrant_optional(bypass)

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

      stub_qdrant_optional(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts -> {:error, {500, %{"detail" => "boom"}}} end)

      assert {:error, {500, _}} =
               perform_job(EmbedNote, %{note_id: note.id}, attempt: 5, max_attempts: 5)

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_retry_after != nil
    end

    test "does NOT stamp embed_retry_after on a non-final attempt", %{bypass: bypass, note: note} do
      stub_qdrant_optional(bypass)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts -> {:error, {500, %{"detail" => "boom"}}} end)

      assert {:error, {500, _}} =
               perform_job(EmbedNote, %{note_id: note.id}, attempt: 1, max_attempts: 5)

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert is_nil(updated.embed_retry_after)
    end

    test "emits [:engram, :embed, :poison] telemetry on the final failed attempt",
         %{bypass: bypass, note: note} do
      stub_qdrant_optional(bypass)

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

      stub_qdrant_optional(bypass)

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

    test "an exhausted budget still builds the keyword index, without calling Voyage",
         %{bypass: bypass, user: user, note: note} do
      # Cancelling here (the old behaviour) cost an over-budget user their
      # BM25 index too, so the note stopped being searchable at all.
      Engram.UsageMeters.add_embed_tokens(user.id, 20_000_000)
      stub_qdrant(bypass)

      # No Mock expect declared: a Voyage call fails the test.
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert Engram.UsageMeters.lifetime_embed_tokens(user.id) == 20_000_000

      assert Repo.exists?(from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id),
               skip_tenant_check: true
             )

      indexed = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert indexed.embed_hash == indexed.content_hash
      assert is_nil(indexed.dense_indexed_hash)
      # Parked, so ReconcileEmbeddings' dense backfill does not re-run it every tick.
      assert DateTime.compare(indexed.embed_retry_after, DateTime.utc_now()) == :gt
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

    # #1618: since chunk reuse (#1595) a pass embeds only the changed chunks,
    # but the meter kept billing the whole note on every edit.
    test "charges only the chunks a pass actually embeds",
         %{bypass: bypass, user: user, vault: vault} do
      stub_qdrant(bypass)
      test_pid = self()

      stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        send(test_pid, {:embedded, texts})
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      body =
        Enum.map_join(1..6, "\n\n", &"## Section #{&1}\n\n#{String.duplicate("word#{&1} ", 200)}")

      note =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "Test/Long.md",
          content: "# Long\n\n" <> body
        })

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
      first = Engram.UsageMeters.lifetime_embed_tokens(user.id)
      _ = drain_embedded()

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Long.md",
          "content" => "# Long\n\n" <> String.replace(body, "word3 ", "edited3 ", global: false),
          "mtime" => 2_000.0
        })

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      sent = drain_embedded()
      assert sent != [], "the edited section must be re-embedded"
      delta = Engram.UsageMeters.lifetime_embed_tokens(user.id) - first
      assert delta == Engram.UsageMeters.estimate_tokens(Enum.join(sent))
      assert delta < div(first, 2)
    end

    test "a pass that reuses every chunk charges nothing",
         %{bypass: bypass, user: user, note: note} do
      stub_qdrant(bypass)

      # Exactly one embed call: the second pass must reach Voyage with nothing.
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
      first = Engram.UsageMeters.lifetime_embed_tokens(user.id)

      Repo.update_all(from(n in Note, where: n.id == ^note.id), [set: [embed_hash: nil]],
        skip_tenant_check: true
      )

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert Engram.UsageMeters.lifetime_embed_tokens(user.id) == first
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
  end
end
