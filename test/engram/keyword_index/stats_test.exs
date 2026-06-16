defmodule Engram.KeywordIndex.StatsTest do
  use Engram.DataCase, async: true

  alias Engram.KeywordIndex.Stats
  alias Engram.Notes.Chunk
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    %{user: user, vault: vault, note: note}
  end

  test "returns the default when the vault has no indexed chunks", %{vault: vault} do
    assert Stats.avgdl(vault.id) == 100.0
  end

  test "averages token_count across the vault's chunks", %{user: u, vault: v, note: n} do
    for {pos, tc} <- [{0, 10}, {1, 20}, {2, 30}] do
      Repo.insert!(%Chunk{
        position: pos,
        char_start: 0,
        char_end: 1,
        token_count: tc,
        qdrant_point_id: Ecto.UUID.generate(),
        note_id: n.id,
        user_id: u.id,
        vault_id: v.id
      })
    end

    assert Stats.avgdl(v.id) == 20.0
  end
end
