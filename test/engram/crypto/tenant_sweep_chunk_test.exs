defmodule Engram.Crypto.TenantSweepChunkTest do
  # DEK rotation sweeps `chunk_points` only for their display envelope, so a
  # sweep visits only rows that hold one (notes over the display threshold).
  # Rows with only a checksum, the common case, are never visited.
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.Crypto.TenantSweep
  alias Engram.Notes.ChunkPoint

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "a.md", content: "a"})
    {:ok, dek} = Crypto.get_dek(user)
    %{user: user, vault: vault, note: note, dek: dek}
  end

  defp insert_rows!(ctx, specs) do
    rows =
      for {pos, sealed?} <- specs do
        point_id = Ecto.UUID.generate()

        %{
          point_id: point_id,
          note_id: ctx.note.id,
          user_id: ctx.user.id,
          position: pos,
          slice_sum: 1
        }
        |> Map.merge(
          if sealed?, do: Crypto.encrypt_chunk_text("t", "h", ctx.dek, point_id), else: %{}
        )
      end

    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.insert_all(ChunkPoint, rows, skip_tenant_check: true)
      end)

    Enum.zip(specs, Enum.map(rows, & &1.point_id))
  end

  defp swept(user) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :ok =
      TenantSweep.each_batch(user.id, ChunkPoint, fn ids ->
        Agent.update(agent, &(&1 ++ ids))
        :ok
      end)

    Agent.get(agent, & &1)
  end

  test "rows without an envelope are never visited", ctx do
    insert_rows!(ctx, for(pos <- 0..4, do: {pos, false}))
    assert swept(ctx.user) == []
  end

  test "only rows with an envelope are visited", ctx do
    rows = insert_rows!(ctx, [{0, false}, {1, true}, {2, false}, {3, true}])
    sealed = for {{_pos, true}, id} <- rows, do: id

    assert Enum.sort(swept(ctx.user)) == Enum.sort(sealed)
  end
end
