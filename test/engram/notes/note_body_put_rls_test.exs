defmodule Engram.Notes.NoteBodyPutRlsTest do
  @moduledoc """
  `NoteBody.put!/2` is raw SQL that reaches a note through its `notes` row,
  so under the runtime role (`engram_app`, FORCE RLS) it can only write the
  body of a note its tenant scope can see. Run as `engram_app` with
  `SESSION AUTHORIZATION` (`Engram.RlsCase`); the suite's superuser would
  bypass every policy.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.NoteBody
  alias Engram.Repo

  setup do
    [owner, other] =
      for name <- ["Owner", "Other"] do
        user = insert(:user)
        insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
        {:ok, user} = Crypto.ensure_user_dek(user)
        {:ok, vault, _} = Engram.Vaults.register_vault(user, name, Ecto.UUID.generate())
        {user, vault}
      end

    {u, v} = owner

    {:ok, note} =
      Notes.upsert_note(u, v, %{"path" => "a.md", "content" => "first"}, actor: "api")

    %{owner: elem(owner, 0), other: elem(other, 0), note: note}
  end

  # A head the row does not hold yet, so an in-scope put! writes one row.
  defp put_head(note),
    do: NoteBody.put!({note.id, crdt_head: String.duplicate("B", 43)})

  test "control: as engram_app with no tenant, notes are invisible", %{note: note} do
    assert {:returned, 0} =
             as_prod_role(fn ->
               Repo.query!("SELECT count(*)::int FROM notes WHERE id = $1", [
                 Ecto.UUID.dump!(note.id)
               ]).rows
               |> then(fn [[n]] -> n end)
             end)
  end

  test "another tenant's put! writes nothing", %{other: other, note: note} do
    assert {:returned, {:ok, 0}} =
             as_prod_role(fn -> Repo.with_tenant(other.id, fn -> put_head(note) end) end)
  end

  test "the owner's put! writes its body row", %{owner: owner, note: note} do
    assert {:returned, {:ok, 1}} =
             as_prod_role(fn -> Repo.with_tenant(owner.id, fn -> put_head(note) end) end)
  end
end
