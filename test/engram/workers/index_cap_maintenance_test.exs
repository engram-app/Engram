defmodule Engram.Workers.IndexCapMaintenanceTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Billing.OverrideCache
  alias Engram.Billing.UserLimitOverride
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.IndexCapMaintenance

  defp cap!(user, n) do
    Repo.insert!(%UserLimitOverride{
      user_id: user.id,
      key: "indexed_notes_cap",
      value: %{"v" => n},
      reason: "test",
      set_by: "test"
    })

    OverrideCache.evict(user.id)
    :ok
  end

  defp insert_chunk!(note) do
    Repo.insert!(%Engram.Notes.Chunk{
      note_id: note.id,
      user_id: note.user_id,
      vault_id: note.vault_id,
      position: 0,
      char_start: 0,
      char_end: 10,
      qdrant_point_id: Ecto.UUID.generate()
    })

    :ok
  end

  describe "enqueue/2" do
    test "a burst of deletes collapses to ONE sweep per user" do
      # The whole point of moving this off the delete path: the sweep is
      # whole-vault, so running it once per deleted note re-scanned the same
      # rows 5,000 times for a 5,000-note folder delete.
      user = insert(:user)

      for _ <- 1..25, do: :ok = IndexCapMaintenance.enqueue(user.id, :backfill_slots)

      assert [_only_one] = all_enqueued(worker: IndexCapMaintenance)
    end

    test "the two kinds do not collapse into each other" do
      user = insert(:user)

      :ok = IndexCapMaintenance.enqueue(user.id, :backfill_slots)
      :ok = IndexCapMaintenance.enqueue(user.id, :evict_over_cap)

      assert length(all_enqueued(worker: IndexCapMaintenance)) == 2
    end

    test "two users do not collapse into each other" do
      a = insert(:user)
      b = insert(:user)

      :ok = IndexCapMaintenance.enqueue(a.id, :evict_over_cap)
      :ok = IndexCapMaintenance.enqueue(b.id, :evict_over_cap)

      assert length(all_enqueued(worker: IndexCapMaintenance)) == 2
    end
  end

  describe "perform/1" do
    test "evict_over_cap re-opens the user's notes past the cap" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      :ok = cap!(user, 0)

      note =
        insert(:note,
          user: user,
          vault: vault,
          content_hash: "abc",
          embed_hash: "abc",
          dense_indexed_hash: "abc"
        )

      :ok = insert_chunk!(note)

      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: "evict_over_cap"})

      assert %Note{embed_hash: nil, dense_indexed_hash: nil} =
               Repo.get!(Note, note.id, skip_tenant_check: true)
    end

    test "a legacy revoke_dense job evicts the notes past the cap" do
      # Jobs enqueued under the old kind (and still enqueued that way for one
      # release, see Billing) must run the over-cap sweep on new nodes.
      user = insert(:user)
      vault = insert(:vault, user: user)
      :ok = cap!(user, 1)

      [kept, evicted] =
        for {hash, seconds} <- [{"old", 0}, {"new", 10}] do
          note =
            insert(:note,
              user: user,
              vault: vault,
              content_hash: hash,
              embed_hash: hash,
              dense_indexed_hash: hash,
              created_at: DateTime.add(~U[2026-01-01 00:00:00Z], seconds, :second)
            )

          :ok = insert_chunk!(note)
          note
        end

      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: "revoke_dense"})

      assert %Note{embed_hash: "old", dense_indexed_hash: "old"} =
               Repo.get!(Note, kept.id, skip_tenant_check: true)

      assert %Note{embed_hash: nil, dense_indexed_hash: nil} =
               Repo.get!(Note, evicted.id, skip_tenant_check: true)
    end

    test "evict_over_cap does not touch another user's notes" do
      # Both sweeps are skip_tenant_check bulk update_alls, so the user_id
      # predicate is the ONLY thing keeping them in one tenant.
      user = insert(:user)
      other = insert(:user)
      :ok = cap!(user, 0)
      :ok = cap!(other, 0)

      mine =
        insert(:note, user: user, content_hash: "a", embed_hash: "a", dense_indexed_hash: "a")

      theirs =
        insert(:note, user: other, content_hash: "b", embed_hash: "b", dense_indexed_hash: "b")

      :ok = insert_chunk!(mine)
      :ok = insert_chunk!(theirs)

      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: "evict_over_cap"})

      assert %Note{dense_indexed_hash: nil} = Repo.get!(Note, mine.id, skip_tenant_check: true)
      assert %Note{dense_indexed_hash: "b"} = Repo.get!(Note, theirs.id, skip_tenant_check: true)
    end

    test "backfill_slots re-opens an in-cap note that a delete freed a slot for" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      :ok = cap!(user, 5)

      note =
        insert(:note,
          user: user,
          vault: vault,
          content_hash: "abc",
          embed_hash: "abc",
          created_at: ~U[2026-01-01 00:00:00Z]
        )

      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: "backfill_slots"})

      # Nulling embed_hash is what puts it back in the reconcile cron's query.
      assert %Note{embed_hash: nil} = Repo.get!(Note, note.id, skip_tenant_check: true)
    end

    test "backfill_slots does not touch another user's notes" do
      user = insert(:user)
      other = insert(:user)
      :ok = cap!(user, 5)
      :ok = cap!(other, 5)

      theirs = insert(:note, user: other, content_hash: "b", embed_hash: "b")

      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: "backfill_slots"})

      assert %Note{embed_hash: "b"} = Repo.get!(Note, theirs.id, skip_tenant_check: true)
    end
  end
end
