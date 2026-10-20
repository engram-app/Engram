defmodule Engram.Crypto.TenantSweepChunkTest do
  # DEK rotation and envelope re-encode sweep `chunks` only for their text,
  # so a sweep visits only rows that hold any. With the chunk-text write flag
  # off (no row has text) it visits none: flag-off rotation pays nothing per
  # chunk.
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.Crypto.TenantSweep
  alias Engram.Notes.Chunk

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "a.md", content: "a"})
    {:ok, dek} = Crypto.get_dek(user)
    %{user: user, vault: vault, note: note, dek: dek}
  end

  defp insert_rows!(ctx, specs) do
    rows =
      for {pos, text?} <- specs do
        point_id = Ecto.UUID.generate()

        %{
          note_id: ctx.note.id,
          user_id: ctx.user.id,
          vault_id: ctx.vault.id,
          position: pos,
          char_start: 0,
          char_end: 1,
          qdrant_point_id: point_id,
          created_at: DateTime.utc_now(:second)
        }
        |> Map.merge(
          if text?, do: Crypto.encrypt_chunk_text("t", "h", ctx.dek, point_id), else: %{}
        )
      end

    {:ok, {_, ids}} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.insert_all(Chunk, rows, returning: [:id], skip_tenant_check: true)
      end)

    Enum.zip(specs, Enum.map(ids, & &1.id))
  end

  defp swept(user) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :ok =
      TenantSweep.each_batch(user.id, Chunk, fn ids ->
        Agent.update(agent, &(&1 ++ ids))
        :ok
      end)

    Agent.get(agent, & &1)
  end

  test "rows without text are never visited", ctx do
    insert_rows!(ctx, for(pos <- 0..4, do: {pos, false}))
    assert swept(ctx.user) == []
  end

  test "only rows with text are visited", ctx do
    rows = insert_rows!(ctx, [{0, false}, {1, true}, {2, false}, {3, true}])
    with_text = for {{_pos, true}, id} <- rows, do: id

    assert Enum.sort(swept(ctx.user)) == Enum.sort(with_text)
  end
end
