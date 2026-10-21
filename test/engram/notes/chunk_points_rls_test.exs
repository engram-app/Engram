defmodule Engram.Notes.ChunkPointsRlsTest do
  @moduledoc """
  `chunk_points` under an ENFORCED policy (ENABLE + FORCE, tenant on
  `user_id`), as `engram_app` (`Engram.RlsCase`): the suite's superuser
  bypasses RLS, so only the role drop proves anything. The first test is the
  CONTROL: with no tenant the dropped role sees zero rows, so a green file
  cannot mean "the role drop never engaged".
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.{Crypto, Notes}
  alias Engram.Notes.{Chunk, ChunkPoint}

  setup do
    {:ok, a} = insert(:user) |> Crypto.ensure_user_dek()
    {:ok, b} = insert(:user) |> Crypto.ensure_user_dek()
    %{a: owned_point(a), b: owned_point(b)}
  end

  # A user, a note, its chunk row and its point row (the envelope set), as
  # the superuser.
  defp owned_point(user) do
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "a.md", "content" => "# A\n\nBody.", "mtime" => 1.0},
        actor: "api"
      )

    {:ok, dek} = Crypto.get_dek(user)
    id = Ecto.UUID.generate()

    Repo.insert_all(
      Chunk,
      [
        %{
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id,
          position: 0,
          char_start: 0,
          char_end: 1,
          qdrant_point_id: id,
          created_at: DateTime.utc_now(:second)
        }
      ],
      skip_tenant_check: true
    )

    Repo.insert!(
      struct(
        %ChunkPoint{point_id: id, note_id: note.id, user_id: user.id, position: 0},
        Crypto.encrypt_chunk_text("Body of #{user.id}.", "A", dek, id)
      ),
      skip_tenant_check: true
    )

    %{user: user, note: note, id: id}
  end

  defp ids(rows), do: rows |> Enum.map(& &1.point_id) |> Enum.sort()

  test "CONTROL: with no tenant the app role sees zero rows", ctx do
    # Both rows exist (the superuser sees them).
    assert length(Repo.all(ChunkPoint, skip_tenant_check: true)) == 2
    assert {:returned, []} = as_prod_role(fn -> Repo.all(ChunkPoint, skip_tenant_check: true) end)
    assert ctx.a.id != ctx.b.id
  end

  test "a tenant sees only its own rows", ctx do
    assert {:returned, {:ok, rows}} =
             as_prod_role(fn ->
               Repo.with_tenant(ctx.a.user.id, fn -> Repo.all(ChunkPoint) end)
             end)

    assert ids(rows) == [ctx.a.id]
  end

  test "a tenant cannot write a row for another user", ctx do
    row = %{point_id: Ecto.UUID.generate(), note_id: ctx.b.note.id, user_id: ctx.b.user.id}

    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             as_prod_role(fn ->
               Repo.with_tenant(ctx.a.user.id, fn ->
                 Repo.insert_all(ChunkPoint, [row], skip_tenant_check: true)
               end)
             end)
  end

  test "another tenant's delete removes nothing", ctx do
    as_prod_role_committing(fn ->
      Repo.with_tenant(ctx.a.user.id, fn ->
        Repo.delete_all(from(p in ChunkPoint, where: p.note_id == ^ctx.b.note.id))
      end)
    end)

    assert [_] =
             Repo.all(from(p in ChunkPoint, where: p.user_id == ^ctx.b.user.id),
               skip_tenant_check: true
             )
  end

  test "search reads its own point's text under the enforced policy", ctx do
    id = to_string(ctx.a.id)

    assert {:returned, {:ok, %{^id => %{text: text}}}} =
             as_prod_role(fn -> Notes.search_hits_by_qdrant_points(ctx.a.user, [id]) end)

    assert text == "Body of #{ctx.a.user.id}."
  end
end
