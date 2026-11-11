defmodule Engram.Folders.WireRlsTest do
  @moduledoc """
  `Engram.Folders.Wire.apply_op/4` with another user's folder id, under an
  ENFORCED row-level security policy (`docs/context/rls-enforcement-testing-traps.md`).
  The ops refuse without writing, so `as_prod_role_committing/1` is used and
  the victim's row is read back afterwards as the suite's superuser.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.{Crypto, Folders, Repo, Vaults}
  alias Engram.Folders.{Folder, Rows, Wire}

  setup do
    {:ok, attacker} = Crypto.ensure_user_dek(insert(:user))
    {:ok, victim} = Crypto.ensure_user_dek(insert(:user))
    {:ok, vault, _} = Vaults.register_vault(attacker, "Mine", Ecto.UUID.generate())
    {:ok, theirs, _} = Vaults.register_vault(victim, "Theirs", Ecto.UUID.generate())
    {:ok, _} = Folders.create_markers(attacker, vault, ["A"])
    {:ok, _} = Folders.create_markers(victim, theirs, ["F"])

    f = Repo.with_tenant!(victim.id, fn -> Rows.ids_by_path(victim, theirs.id, ["F"]) end)["F"]
    %{attacker: attacker, vault: vault, victim: victim, theirs: theirs, f: f}
  end

  # CONTROL: without it a green file cannot tell "scoped" from "the role drop
  # never engaged".
  test "control: the dropped role sees no folder rows without a tenant" do
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Folder, :count, skip_tenant_check: true) end)
  end

  test "another user's folder id is not_found and their row is unchanged",
       %{attacker: attacker, vault: vault, victim: victim, theirs: theirs, f: f} do
    move = %{"op" => "move", "folder_id" => f, "parent_id" => nil, "name" => "Stolen"}
    into = %{"op" => "create", "parent_id" => f, "name" => "In"}

    assert {:error, "not_found"} =
             as_prod_role_committing(fn -> Wire.apply_op(attacker, vault, move, nil) end)

    assert {:error, "not_found"} =
             as_prod_role_committing(fn -> Wire.apply_op(attacker, vault, into, nil) end)

    ids =
      Repo.with_tenant!(victim.id, fn -> Rows.ids_by_path(victim, theirs.id, ["F", "F/In"]) end)

    assert ids == %{"F" => f, "F/In" => nil}
  end
end
