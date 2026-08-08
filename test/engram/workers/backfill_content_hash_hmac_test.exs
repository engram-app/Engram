defmodule Engram.Workers.BackfillContentHashHmacTest do
  # async: false — the #1230 regression test below drives a REAL Oban dispatch
  # (`Oban.drain_queue/1`) rather than `perform_job/2`, which is the only way to
  # reproduce the self-collision it guards. Real dispatch needs a stable sandbox
  # connection owner; running it async invites the ownership flake class in
  # docs/context/channel-parallelism-db-pool.md. Matches
  # Engram.Workers.BackfillNoteLinksTest, which made the same call for the same
  # test.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Engram.Fixtures

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.BackfillContentHashHmac

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "BackfillTest"})

    %{user: user, vault: vault}
  end

  describe "perform/1 — notes scope" do
    test "rehashes a note whose content_hash is legacy MD5", %{user: user, vault: vault} do
      content = "# Backfill me\nbody bytes"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

      note = insert_note!(user, vault, %{"content" => content, "content_hash" => legacy_md5})

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      {:ok, content_key} = Crypto.dek_content_hash_key(user)
      expected = Crypto.hmac_content_hash(content_key, content)

      assert reloaded.content_hash == expected
      assert String.length(reloaded.content_hash) == 64
      refute reloaded.content_hash == legacy_md5
    end

    test "skips notes that already have HMAC-format content_hash", %{user: user, vault: vault} do
      content = "already hashed"
      {:ok, content_key} = Crypto.dek_content_hash_key(user)
      hmac_hash = Crypto.hmac_content_hash(content_key, content)

      note = insert_note!(user, vault, %{"content" => content, "content_hash" => hmac_hash})

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      assert reloaded.content_hash == hmac_hash
    end

    test "rewrites embed_hash in lock-step when row was already embedded",
         %{user: user, vault: vault} do
      content = "indexed body"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

      note =
        insert_note!(user, vault, %{"content" => content, "content_hash" => legacy_md5})

      stamp_embed_hash!(user.id, note.id, legacy_md5)

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      assert reloaded.embed_hash == reloaded.content_hash
    end

    test "leaves embed_hash alone when content has unembedded changes",
         %{user: user, vault: vault} do
      content = "modified after embed"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
      stale_embed = "stale_md5_from_prior_content"

      note =
        insert_note!(user, vault, %{"content" => content, "content_hash" => legacy_md5})

      stamp_embed_hash!(user.id, note.id, stale_embed)

      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })

      {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      refute reloaded.content_hash == legacy_md5
      assert reloaded.embed_hash == stale_embed
    end

    defp stamp_embed_hash!(user_id, note_id, hash) do
      import Ecto.Query

      {:ok, _} =
        Repo.with_tenant(user_id, fn ->
          from(n in Note, where: n.id == ^note_id)
          |> Repo.update_all(set: [embed_hash: hash])
        end)
    end

    test "no-op when no legacy MD5 rows remain", %{user: user, vault: vault} do
      assert :ok =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })
    end
  end

  # ---------------------------------------------------------------------------
  # T3.7 — RotationGate
  # ---------------------------------------------------------------------------

  describe "perform/1 — T3.7 rotation gate" do
    test "snoozes for 60 seconds when user's DEK rotation is in progress", %{
      user: user,
      vault: vault
    } do
      # Set lock directly — do NOT use RotationLock.acquire/2 (advisory lock
      # does not survive across a Sandbox checkout in non-async tests).
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      assert {:snooze, 60} =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })
    end

    test "discards job when user does not exist", %{vault: vault} do
      assert {:discard, :user_deleted} =
               perform_job(BackfillContentHashHmac, %{
                 "user_id" => Ecto.UUID.generate(),
                 "vault_id" => vault.id,
                 "cursor" => 0,
                 "scope" => "notes"
               })
    end
  end

  describe "decrypt-failure log redaction" do
    # Security invariant (Engram.Logger.DecryptFailure): the raw decrypt
    # reason can wrap Req/Postgrex terms carrying secrets and must never be
    # interpolated into the message or metadata — only the bounded
    # error_kind atom escapes. EmbedNote follows this; this worker didn't.
    test "skip log carries no raw reason; telemetry reason is a bounded atom",
         %{user: user, vault: vault} do
      content = "# corrupt me"
      legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
      note = insert_note!(user, vault, %{"content" => content, "content_hash" => legacy_md5})

      # Corrupt the nonce so Envelope.decrypt fails with :decrypt_failed.
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          from(n in Note, where: n.id == ^note.id)
          |> Repo.update_all(set: [content_nonce: :crypto.strong_rand_bytes(12)])
        end)

      handler_id = "backfill-skip-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:engram, :backfill, :content_hash_skipped],
        fn _event, _meas, meta, _cfg -> send(parent, {:skip_meta, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   perform_job(BackfillContentHashHmac, %{
                     "user_id" => user.id,
                     "vault_id" => vault.id,
                     "cursor" => 0,
                     "scope" => "notes"
                   })
        end)

      # Scope to THIS worker's lines — capture_log sees concurrent async
      # tests' output, and other modules legitimately log bounded reason=
      # atoms (e.g. Engram.Vaults decrypt_or_log).
      worker_lines =
        log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "BackfillContentHashHmac"))

      assert Enum.any?(worker_lines, &String.contains?(&1, "skipping note"))

      refute Enum.any?(worker_lines, &String.contains?(&1, "(:decrypt_failed)")),
             "raw inspect(reason) must not reach the log message"

      refute Enum.any?(worker_lines, &String.contains?(&1, " reason=")),
             "raw reason must not reach the log metadata (only error_kind)"

      assert_received {:skip_meta, meta}
      assert is_atom(meta.reason), "telemetry reason must be the bounded error_kind atom"
    end
  end

  describe "cursor chain under real dispatch (#1230)" do
    # Regression for #1230: the worker carried
    # `unique: [keys: [:user_id, :vault_id, :scope], states: :incomplete]`.
    # A cursor worker re-enqueues its OWN successor mid-run, and because
    # `cursor` is not a unique key, that successor matched the still-
    # "executing" job. Oban's unique-insert then silently returned the
    # existing job instead of inserting the successor — no error, insert
    # "succeeds" — so the chain died after batch 1 and every row past the
    # batch size stayed on its legacy MD5 hash forever.
    #
    # `perform_job/2` CANNOT catch this: it never creates a DB row for the
    # "currently running" job, so there is nothing for the successor to
    # collide with and the insert always looks fine. Only `Oban.drain_queue/1`
    # goes through the real fetch path (state -> "executing" before perform
    # runs), which is what makes the collision observable.
    #
    # Proof this test catches the regression: re-adding the `unique:` option
    # to the worker makes it fail with only the first note rehashed.
    test "rehashes every row across multiple batches, not just the first",
         %{user: user, vault: vault} do
      contents = for i <- 1..3, do: "# Note #{i}\nbody"

      notes =
        for {content, i} <- Enum.with_index(contents, 1) do
          legacy_md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

          insert_note!(user, vault, %{
            "path" => "Chain#{i}.md",
            "content" => content,
            "content_hash" => legacy_md5
          })
        end

      {:ok, _job} =
        BackfillContentHashHmac.new(%{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "cursor" => 0,
          "scope" => "notes",
          "batch_size" => 1
        })
        |> Oban.insert()

      result = Oban.drain_queue(queue: :crypto_backfill, with_recursion: true)
      assert result.failure == 0, "chain must not fail: #{inspect(result)}"

      {:ok, content_key} = Crypto.dek_content_hash_key(user)

      for {note, content} <- Enum.zip(notes, contents) do
        {:ok, reloaded} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)

        assert reloaded.content_hash == Crypto.hmac_content_hash(content_key, content),
               "note #{note.id} still on its legacy hash — the cursor chain stalled after the first batch"
      end
    end
  end
end
