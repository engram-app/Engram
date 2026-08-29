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
      :ok = IndexCapMaintenance.enqueue(user.id, :revoke_dense)

      assert length(all_enqueued(worker: IndexCapMaintenance)) == 2
    end

    test "two users do not collapse into each other" do
      a = insert(:user)
      b = insert(:user)

      :ok = IndexCapMaintenance.enqueue(a.id, :revoke_dense)
      :ok = IndexCapMaintenance.enqueue(b.id, :revoke_dense)

      assert length(all_enqueued(worker: IndexCapMaintenance)) == 2
    end
  end

  describe "perform/1" do
    test "revoke_dense nulls both index hashes for the user's live notes" do
      user = insert(:user)
      vault = insert(:vault, user: user)

      note =
        insert(:note,
          user: user,
          vault: vault,
          content_hash: "abc",
          embed_hash: "abc",
          dense_indexed_hash: "abc"
        )

      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: "revoke_dense"})

      assert %Note{embed_hash: nil, dense_indexed_hash: nil} =
               Repo.get!(Note, note.id, skip_tenant_check: true)
    end

    test "revoke_dense does not touch another user's notes" do
      # Both sweeps are skip_tenant_check bulk update_alls, so the user_id
      # predicate is the ONLY thing keeping them in one tenant.
      user = insert(:user)
      other = insert(:user)

      mine =
        insert(:note, user: user, content_hash: "a", embed_hash: "a", dense_indexed_hash: "a")

      theirs =
        insert(:note, user: other, content_hash: "b", embed_hash: "b", dense_indexed_hash: "b")

      assert :ok = perform_job(IndexCapMaintenance, %{user_id: user.id, kind: "revoke_dense"})

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
