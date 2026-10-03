# test/engram/notes/revision_schema_test.exs
defmodule Engram.Notes.RevisionSchemaTest do
  @moduledoc """
  `note_revisions` is a tenant table (#1710). The suite connects as a
  superuser, which bypasses RLS, so a scoped read that comes back green proves
  nothing on its own. The CONTROL test is what makes the others mean anything:
  it shows the role drop actually engaged. See
  docs/context/rls-enforcement-testing-traps.md.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Notes.Revision
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "History.md"})

    {:ok, rev} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert!(Revision.open_changeset(open_attrs(user, vault, note)))
      end)

    %{user: user, vault: vault, note: note, rev: rev}
  end

  defp open_attrs(user, vault, note) do
    %{
      note_id: note.id,
      user_id: user.id,
      vault_id: vault.id,
      actor: "sync",
      origin: "edit",
      session_started_at: DateTime.utc_now()
    }
  end

  defp count_query(rev), do: from(r in Revision, where: r.id == ^rev.id, select: count(r.id))

  test "control: with no tenant set, the app role sees nothing", %{rev: rev} do
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.one(count_query(rev), skip_tenant_check: true) end)
  end

  test "the owning tenant sees its version", %{user: user, rev: rev} do
    assert {:returned, {:ok, 1}} =
             as_prod_role(fn ->
               Repo.with_tenant(user.id, fn -> Repo.one(count_query(rev)) end)
             end)
  end

  test "another tenant does not", %{rev: rev} do
    {:ok, other} = Engram.Fixtures.user_with_dek_fixture()

    assert {:returned, {:ok, 0}} =
             as_prod_role(fn ->
               Repo.with_tenant(other.id, fn -> Repo.one(count_query(rev)) end)
             end)
  end

  # The note-row write fence already serializes saves to one note. This index
  # is the backstop: if a future save path forgets the fence, Postgres refuses
  # the second open version instead of quietly storing two.
  test "a note can have only one open version", %{user: user, vault: vault, note: note} do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        Repo.insert(Revision.open_changeset(open_attrs(user, vault, note)), mode: :savepoint)
      end)

    assert {:error, %Ecto.Changeset{errors: errors}} = result

    assert {_, [constraint: :unique, constraint_name: "note_revisions_one_open_per_note"]} =
             errors[:note_id]
  end
end
