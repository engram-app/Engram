defmodule Engram.Indexing.IndexCapTest do
  use Engram.DataCase, async: true

  import Engram.Factory

  alias Engram.Billing.UserLimitOverride
  alias Engram.Indexing.IndexCap
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
end
