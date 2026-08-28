defmodule Engram.Indexing.IndexCapTest do
  use Engram.DataCase, async: true

  import Engram.Factory

  alias Engram.Billing.UserLimitOverride
  alias Engram.Indexing.IndexCap
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo

  # Free defaults to 2_000, which would need 2k rows to exercise. Override to a
  # small cap instead — the override resolves through the same 4-layer chain the
  # real tier default does, so the ranking behaviour under test is identical.
  defp cap!(user, n) do
    Repo.insert!(%UserLimitOverride{
      user_id: user.id,
      key: "indexed_notes_cap",
      value: %{"v" => n},
      reason: "test",
      set_by: "test"
    })

    Engram.Billing.OverrideCache.evict(user.id)
    :ok
  end

  defp note_at(user, vault, seconds) do
    insert(:note,
      user: user,
      vault: vault,
      created_at: DateTime.add(~U[2026-01-01 00:00:00Z], seconds, :second)
    )
  end

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "within_cap?/1" do
    test "admits notes below the cap and rejects the ones past it", %{user: u, vault: v} do
      :ok = cap!(u, 2)

      first = note_at(u, v, 0)
      second = note_at(u, v, 10)
      third = note_at(u, v, 20)

      assert IndexCap.within_cap?(first)
      assert IndexCap.within_cap?(second)
      refute IndexCap.within_cap?(third)
    end

    test "deleting an indexed note frees a slot for a later one", %{user: u, vault: v} do
      :ok = cap!(u, 2)

      first = note_at(u, v, 0)
      _second = note_at(u, v, 10)
      third = note_at(u, v, 20)

      refute IndexCap.within_cap?(third)

      # Tidying a vault must not permanently consume slots, or "I deleted 500
      # notes and it still will not index my new ones" becomes a support ticket.
      first
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      assert IndexCap.within_cap?(third)
    end

    test "an uncapped tier admits everything", %{user: u, vault: v} do
      :ok = cap!(u, -1)
      notes = for s <- 0..5, do: note_at(u, v, s * 10)
      assert Enum.all?(notes, &IndexCap.within_cap?/1)
    end
  end

  describe "counts/1" do
    test "reports min(total, cap) against the live total", %{user: u, vault: v} do
      :ok = cap!(u, 2)
      for s <- 0..3, do: note_at(u, v, s * 10)

      assert %{indexed: 2, total: 4} = IndexCap.counts(u)
    end

    test "indexed equals total when under the cap", %{user: u, vault: v} do
      :ok = cap!(u, 10)
      for s <- 0..2, do: note_at(u, v, s * 10)

      assert %{indexed: 3, total: 3} = IndexCap.counts(u)
    end
  end

  describe "backfill_freed_slots/1" do
    test "re-opens an in-cap note that has no chunks", %{user: u, vault: v} do
      :ok = cap!(u, 2)

      # Shape a prior indexing pass leaves behind for a note it skipped for the
      # cap: embed_hash stamped (so reconcile ignores it) but no chunk rows.
      note = note_at(u, v, 0)

      note
      |> Ecto.Changeset.change(embed_hash: note.content_hash)
      |> Repo.update!()

      :ok = IndexCap.backfill_freed_slots(u.id)

      # embed_hash nulled -> ReconcileEmbeddings' stale-note query picks it up.
      assert Repo.get!(Note, note.id, skip_tenant_check: true).embed_hash == nil
    end

    test "leaves an already-indexed note alone", %{user: u, vault: v} do
      :ok = cap!(u, 2)
      note = note_at(u, v, 0)

      note
      |> Ecto.Changeset.change(embed_hash: note.content_hash)
      |> Repo.update!()

      Repo.insert!(%Chunk{
        note_id: note.id,
        user_id: u.id,
        vault_id: v.id,
        position: 0,
        char_start: 0,
        char_end: 10,
        token_count: 2,
        qdrant_point_id: Ecto.UUID.generate()
      })

      :ok = IndexCap.backfill_freed_slots(u.id)

      assert Repo.get!(Note, note.id, skip_tenant_check: true).embed_hash == note.content_hash
    end

    test "is a no-op on an uncapped tier", %{user: u, vault: v} do
      :ok = cap!(u, -1)
      note = note_at(u, v, 0)

      note
      |> Ecto.Changeset.change(embed_hash: note.content_hash)
      |> Repo.update!()

      :ok = IndexCap.backfill_freed_slots(u.id)

      assert Repo.get!(Note, note.id, skip_tenant_check: true).embed_hash == note.content_hash
    end
  end

  describe "revoke_dense_index/1" do
    test "nulls both hashes so the rebuild drops the dense vectors", %{user: u, vault: v} do
      note = note_at(u, v, 0)

      note
      |> Ecto.Changeset.change(
        embed_hash: note.content_hash,
        dense_indexed_hash: note.content_hash
      )
      |> Repo.update!()

      :ok = IndexCap.revoke_dense_index(u.id)

      reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)
      # BOTH must be nil. Clearing only dense_indexed_hash would leave
      # EmbedNote's skip clause matching for a now-unentitled user, so nothing
      # would ever rebuild and the dense vectors would stay in Qdrant.
      assert reloaded.embed_hash == nil
      assert reloaded.dense_indexed_hash == nil
    end

    test "leaves a note that never had dense vectors untouched", %{user: u, vault: v} do
      note = note_at(u, v, 0)

      note
      |> Ecto.Changeset.change(embed_hash: note.content_hash, dense_indexed_hash: nil)
      |> Repo.update!()

      :ok = IndexCap.revoke_dense_index(u.id)

      # Not re-queued: it is already sparse-only, so a rebuild would be pure waste.
      assert Repo.get!(Note, note.id, skip_tenant_check: true).embed_hash == note.content_hash
    end
  end
end
