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

  alias Engram.{Crypto, DataMigrations, Notes, Repo}
  alias Engram.Folders.Folder

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

    :ok = DataMigrations.mark_done("note_name", 1)
    Engram.Cache.clear_local(:note_name)
    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)

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

  test "another user's lookup in the owner's vault finds nothing",
       %{other: other, vault: vault} do
    assert {:returned, {:error, :not_found}} =
             as_prod_role(fn -> Notes.get_note(other, vault, "A/B/x.md") end)
  end
end
