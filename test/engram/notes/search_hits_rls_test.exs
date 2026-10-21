defmodule Engram.Notes.SearchHitsRlsTest do
  @moduledoc """
  `Notes.search_hits_by_qdrant_points/2` (Task 11.3) under enforced RLS, as
  `engram_app` (see `docs/context/rls-enforcement-testing-traps.md`). The
  query reads `chunks` and `chunk_points` (both FORCE RLS) for each hit's
  encrypted text. Unscoped it
  returns zero rows, every hit reads as stale and is dropped: a search that
  silently finds nothing. The control proves the role drop engages, so the
  other assertions are not vacuous.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.{Crypto, Notes}
  alias Engram.Notes.{Chunk, ChunkPoint}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Health/Iron.md", content: "x"})
    {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
    other_vault = insert(:vault, user: other)
    other_note = Engram.Fixtures.insert_note!(other, other_vault, %{path: "Theirs.md"})

    mine = seed_chunk!(user, vault, note, "my ferritin")
    theirs = seed_chunk!(other, other_vault, other_note, "their ferritin")

    {:ok, user: user, mine: mine, theirs: theirs}
  end

  defp seed_chunk!(user, vault, note, text) do
    point_id = Ecto.UUID.generate()
    {:ok, dek} = Crypto.get_dek(user)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        %Chunk{}
        |> Chunk.changeset(%{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          position: 0,
          char_start: 0,
          char_end: 1,
          qdrant_point_id: point_id
        })
        |> Repo.insert!()

        %ChunkPoint{point_id: point_id, note_id: note.id, user_id: user.id, position: 0}
        |> struct(Crypto.encrypt_chunk_text(text, "H", dek, point_id))
        |> Repo.insert!()
      end)

    point_id
  end

  # CONTROL. Without this a green file is ambiguous between "correctly
  # scoped" and "the role drop never engaged".
  test "control: the dropped role sees zero chunk rows", %{mine: mine} do
    outcome =
      as_prod_role(fn ->
        Repo.one(
          from(c in Chunk, where: c.qdrant_point_id == ^mine, select: count(c.id)),
          skip_tenant_check: true
        )
      end)

    assert outcome == {:returned, 0},
           "harness is not engaging RLS: #{inspect(outcome)}; every assertion here is meaningless"
  end

  test "returns the user's hit with its decrypted text", %{user: user, mine: mine} do
    assert {:returned, {:ok, %{^mine => hit}}} =
             as_prod_role(fn -> Notes.search_hits_by_qdrant_points(user, [mine]) end),
           "no row came back: the read was filtered by RLS and the hit would drop as stale"

    assert hit.text == "my ferritin"
    assert hit.source_path == "Health/Iron.md"
  end

  test "never returns another user's point, even by its id", ctx do
    assert {:returned, {:ok, hits}} =
             as_prod_role(fn ->
               Notes.search_hits_by_qdrant_points(ctx.user, [ctx.mine, ctx.theirs])
             end)

    assert Map.keys(hits) == [ctx.mine]
  end
end
