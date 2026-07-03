defmodule Engram.Workers.ReconcileEmbeddingsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes.Note
  alias Engram.Workers.{EmbedNote, ReconcileEmbeddings}

  describe "perform/1" do
    test "queues jobs for notes with nil embed_hash" do
      user = insert(:user)
      note = insert(:note, user: user, embed_hash: nil)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "queues jobs for notes with stale embed_hash" do
      user = insert(:user)

      note =
        insert(:note,
          user: user,
          content_hash: "new_hash",
          embed_hash: "old_hash"
        )

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "skips notes where embed_hash matches content_hash" do
      user = insert(:user)
      _note = insert(:note, user: user, content_hash: "abc123", embed_hash: "abc123")

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote)
    end

    test "skips soft-deleted notes" do
      user = insert(:user)

      _note =
        insert(:note,
          user: user,
          embed_hash: nil,
          deleted_at: DateTime.utc_now()
        )

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote)
    end

    test "skips folder marker rows (kind='folder')" do
      user = insert(:user)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})

      {:ok, marker} = Engram.Notes.create_folder_marker(user, vault, "Empty")
      # Sanity: marker has nil embed_hash, so the unfiltered query would pick it up.
      assert marker.kind == "folder"
      assert is_nil(marker.embed_hash)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => marker.id})
    end

    test "caps the batch globally at 500 across all vaults" do
      # One query over the partial index with a global cap — the old shape
      # loaded EVERY vault then ran one query per vault every 15 minutes
      # (O(total vaults) queries at scale).
      user = insert(:user)
      vault_a = insert(:vault, user: user)
      vault_b = insert(:vault, user: user)

      for {vault, label, count} <- [{vault_a, "a", 300}, {vault_b, "b", 205}],
          i <- 1..count do
        Engram.Fixtures.insert_note!(user, vault,
          path: "batch-#{label}/note-#{i}.md",
          content: "# Note #{label} #{i}",
          embed_hash: nil
        )
      end

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 500
    end

    test "runs a single notes query regardless of vault count" do
      user = insert(:user)

      for i <- 1..3 do
        vault = insert(:vault, user: user)

        Engram.Fixtures.insert_note!(user, vault,
          path: "v#{i}/note.md",
          content: "# v#{i}",
          embed_hash: nil
        )
      end

      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:engram, :repo, :query],
        fn _e, _m, %{source: src}, _c ->
          if src in ["notes", "vaults"] and self() == test_pid,
            do: send(test_pid, {:query, src})
        end,
        nil
      )

      try do
        assert :ok = perform_job(ReconcileEmbeddings, %{})
      after
        :telemetry.detach(handler_id)
      end

      queries = collect_queries()
      assert Enum.count(queries, &(&1 == "notes")) == 1
      refute Enum.any?(queries, &(&1 == "vaults"))
    end

    test "skips notes whose vault is soft-deleted" do
      user = insert(:user)
      vault = insert(:vault, user: user, deleted_at: DateTime.utc_now())
      note = insert(:note, user: user, vault: vault, embed_hash: nil)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "skips poisoned notes still inside their embed cooldown" do
      user = insert(:user)

      note =
        insert(:note,
          user: user,
          embed_hash: nil,
          embed_retry_after: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "queues poisoned notes whose embed cooldown has elapsed" do
      user = insert(:user)

      note =
        insert(:note,
          user: user,
          embed_hash: nil,
          embed_retry_after: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    # #897 — crash-independent backoff. EmbedNote's poison cooldown only fires
    # on a GRACEFUL terminal {:error, _}; an OOM/node kill bypasses it entirely,
    # leaving embed_retry_after NULL, so reconcile re-enqueues the same poison
    # note every 15 min → self-sustaining crash loop (the 2026-07-03 incident).
    # Reconcile therefore preemptively stamps a short future cooldown on every
    # note it enqueues; a crash can no longer cause immediate re-enqueue, and a
    # successful EmbedNote clears the stamp back to NULL.
    test "stamps a future embed_retry_after on every note it enqueues" do
      user = insert(:user)
      note = insert(:note, user: user, embed_hash: nil, embed_retry_after: nil)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)

      refute is_nil(reloaded.embed_retry_after),
             "reconcile must stamp embed_retry_after so an OOM'd embed can't re-enqueue next tick"

      assert DateTime.compare(reloaded.embed_retry_after, DateTime.utc_now()) == :gt,
             "the preemptive cooldown must be in the future"
    end

    test "does not stamp notes it did not enqueue" do
      user = insert(:user)
      # up-to-date note — not enqueued, so it must not be collaterally cooled.
      fresh = insert(:note, user: user, content_hash: "abc123", embed_hash: "abc123")

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => fresh.id})

      assert is_nil(Repo.get!(Note, fresh.id, skip_tenant_check: true).embed_retry_after)
    end

    test "the stamped cooldown makes a poison note skip the next reconcile tick" do
      # End-to-end crash simulation: enqueue, DON'T run the embed job (mimics an
      # OOM kill — no success clear, no graceful poison stamp), then tick again.
      # The preemptive stamp alone must keep it out of the second batch.
      user = insert(:user)
      note = insert(:note, user: user, embed_hash: nil, embed_retry_after: nil)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      stamped = Repo.get!(Note, note.id, skip_tenant_check: true).embed_retry_after
      refute is_nil(stamped)

      # Second tick, no embed ran. Note is inside its fresh cooldown → not
      # selected. (Its stamp is unchanged — we didn't re-stamp a skipped note.)
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert Repo.get!(Note, note.id, skip_tenant_check: true).embed_retry_after == stamped
    end
  end

  defp collect_queries(acc \\ []) do
    receive do
      {:query, src} -> collect_queries([src | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
