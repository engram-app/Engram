defmodule Engram.Notes.FieldCatalogRlsTest do
  @moduledoc """
  The field catalog reads `note_attrs` and `frontmatter_keys` under the
  tenant, so a user sees only their own fields, and names and values are
  decrypted only for their owner. Runs as the RLS-enforced app role
  (`docs/context/rls-enforcement-testing-traps.md`); the CONTROL proves the
  role drop bites.
  """
  use Engram.DataCase, async: false

  import Engram.FieldCatalogHelpers
  import Engram.RlsCase

  alias Engram.Notes.FieldCatalog
  alias Engram.Notes.FrontmatterKey
  alias Engram.Notes.NoteAttr
  alias Engram.Repo

  @moduletag :rls_unsafe

  setup do
    [a, b] =
      for word <- ~w(apple banana) do
        {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
        vault = insert(:vault, user: user)

        write_indexed!(
          user,
          vault,
          "n.md",
          "---\nstatus: #{word}\nfruit_#{word}: #{word}\n---\nb\n"
        )

        %{user: Repo.get!(Engram.Accounts.User, user.id), vault: vault}
      end

    {:ok, a: a, b: b}
  end

  test "CONTROL: engram_app with no tenant sees zero rows" do
    assert length(Repo.all(NoteAttr, skip_tenant_check: true)) > 0
    assert length(Repo.all(FrontmatterKey, skip_tenant_check: true)) == 2
    assert {:returned, []} = as_prod_role(fn -> Repo.all(NoteAttr, skip_tenant_check: true) end)

    assert {:returned, []} =
             as_prod_role(fn -> Repo.all(FrontmatterKey, skip_tenant_check: true) end)
  end

  test "a user sees their own fields under the enforced role", %{a: a} do
    FieldCatalog.evict(a.vault.id)
    assert {:returned, {:ok, fields}} = as_prod_role(fn -> FieldCatalog.list(a.user, a.vault) end)

    assert Enum.map(fields, & &1.name) |> Enum.sort() == ["fruit_apple", "status"]
    assert %{values: [%{value: "apple", count: 1}]} = Enum.find(fields, &(&1.name == "status"))
  end

  test "another user's vault yields nothing, and nothing of theirs is decrypted", %{a: a, b: b} do
    FieldCatalog.evict(b.vault.id)

    assert {:returned, {:ok, []}} = as_prod_role(fn -> FieldCatalog.list(a.user, b.vault) end)
  end
end
