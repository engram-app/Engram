defmodule Engram.NotesSetCtimesRlsTest do
  @moduledoc """
  `Notes.set_client_ctimes/3` under an ENFORCED row-level security policy.
  See `docs/context/rls-enforcement-testing-traps.md`: an unscoped `update_all`
  reports zero rows and `:ok`, so these assert the PERSISTED effect, and each
  seeded ctime precondition is nil so a no-op cannot pass.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.{Notes, Repo}
  alias Engram.Notes.Note

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{"path" => "a/one.md"})
    %{user: user, vault: vault, note: note}
  end

  defp ctime_of(id),
    do: Repo.one(from(n in Note, where: n.id == ^id, select: n.ctime), skip_tenant_check: true)

  # CONTROL: proves the role drop engaged; without it green is ambiguous.
  test "control: the dropped role sees none of the user's notes", %{vault: vault} do
    assert {:returned, 0} =
             as_prod_role(fn ->
               Repo.one(from(n in Note, where: n.vault_id == ^vault.id, select: count(n.id)),
                 skip_tenant_check: true
               )
             end)
  end

  test "writes the ctime under enforced RLS (persisted effect)", ctx do
    assert is_nil(ctime_of(ctx.note.id))

    assert {:ok, 1} =
             as_prod_role_committing(fn ->
               Notes.set_client_ctimes(ctx.user, ctx.vault, [%{path: "a/one.md", ctime: 42.5}])
             end)

    assert ctime_of(ctx.note.id) == 42.5
  end

  test "another user's call cannot touch this user's note", ctx do
    other = insert(:user)
    {:ok, other} = Engram.Crypto.ensure_user_dek(other)

    assert {:ok, 0} =
             as_prod_role_committing(fn ->
               Notes.set_client_ctimes(other, ctx.vault, [%{path: "a/one.md", ctime: 9.0}])
             end)

    assert is_nil(ctime_of(ctx.note.id))
  end
end
