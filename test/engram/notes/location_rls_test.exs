defmodule Engram.Notes.LocationRlsTest do
  @moduledoc """
  The S3 by-path lookup (`Engram.Notes.Location`) under an ENFORCED row-level
  security policy (`docs/context/rls-enforcement-testing-traps.md`). The
  folder walk is a subquery of the notes statement, so it reads `folders`
  (FORCE RLS) under the caller's tenant. The path key is corrupted first, so
  only the walk can find the note: a walk that saw no folder rows (no tenant
  inside the statement) would miss it.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.{Crypto, Notes, Repo}
  alias Engram.Folders.{Folder, Rows}

  setup do
    {:ok, owner} = Crypto.ensure_user_dek(insert(:user))
    {:ok, other} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: owner)
    theirs = insert(:vault, user: other)

    {:ok, note} =
      Notes.upsert_note(owner, vault, %{"path" => "A/B/x.md", "content" => "x"}, actor: "api")

    {:ok, _} =
      Notes.upsert_note(other, theirs, %{"path" => "A/B/x.md", "content" => "y"}, actor: "api")

    Repo.query!("UPDATE notes SET path_hmac = $2 WHERE id = $1", [
      Ecto.UUID.dump!(note.id),
      :crypto.strong_rand_bytes(32)
    ])

    %{owner: owner, other: other, vault: vault, theirs: theirs, note: note}
  end

  # CONTROL: without it a green file cannot tell "scoped" from "the role drop
  # never engaged".
  test "control: the dropped role sees no folder rows without a tenant" do
    assert Repo.aggregate(Folder, :count, skip_tenant_check: true) > 0

    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Folder, :count, skip_tenant_check: true) end)
  end

  test "the owner's lookup walks its own folders under its tenant",
       %{owner: owner, vault: vault, note: note} do
    assert {:returned, {:ok, %{id: id}}} =
             as_prod_role(fn -> Notes.get_note(owner, vault, "A/B/x.md") end)

    assert id == note.id
  end

  # The walk names the other user's vault and folder keys exactly, so only
  # the `folders` policy can hide the row: as the suite's superuser the same
  # statement finds it (the control below), as `engram_app` under this
  # user's tenant it must not.
  test "the folder walk cannot see another tenant's folder rows",
       %{owner: owner, other: other, theirs: theirs} do
    theirs_id = Repo.with_tenant!(other.id, fn -> Rows.id_by_walk(other, theirs.id, "A/B") end)
    assert is_binary(theirs_id), "precondition: the walk finds the folder as its owner"

    assert Repo.with_tenant!(owner.id, fn -> Rows.id_by_walk(other, theirs.id, "A/B") end) ==
             theirs_id,
           "control: without RLS (superuser) the cross-tenant walk sees the row"

    assert {:returned, nil} =
             as_prod_role(fn ->
               Repo.with_tenant!(owner.id, fn -> Rows.id_by_walk(other, theirs.id, "A/B") end)
             end)
  end
end
