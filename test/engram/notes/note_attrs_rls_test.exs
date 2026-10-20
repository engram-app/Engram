defmodule Engram.Notes.NoteAttrsRlsTest do
  @moduledoc """
  `note_attrs` and `frontmatter_keys` are tenant-isolated by RLS. Every assertion runs as a
  non-superuser role (the suite connects as a superuser, which bypasses RLS
  even when FORCED); the CONTROL proves the harness bites.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Notes.FrontmatterKey
  alias Engram.Notes.NoteAttr
  alias Engram.Repo
  alias Engram.Vector.FilterId

  @moduletag :rls_unsafe

  setup do
    seeded =
      for _ <- 1..2 do
        # Real per-user filter keys, so "equal values HMAC differently" is a
        # property of the key derivation, not of two random test keys.
        {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
        vault = insert(:vault, user: user)
        note = insert(:note, user: user, vault: vault)
        {:ok, fk} = Engram.Crypto.dek_filter_key(user)

        Repo.insert_all(
          NoteAttr,
          [
            %{
              note_id: note.id,
              user_id: user.id,
              vault_id: vault.id,
              key_id: 64,
              h: FilterId.value_hmac(fk, "draft")
            }
          ],
          skip_tenant_check: true
        )

        Repo.insert_all(
          FrontmatterKey,
          [
            %{
              user_id: user.id,
              key_id: 64,
              key_hmac: FilterId.key_hmac(fk, "phase"),
              name_ct: "ct",
              name_nonce: "nonce"
            }
          ],
          skip_tenant_check: true
        )

        %{user: user, fk: fk, note: note, vault: vault}
      end

    {:ok, a: Enum.at(seeded, 0), b: Enum.at(seeded, 1)}
  end

  defp rows, do: Repo.all(NoteAttr, skip_tenant_check: true)
  defp keys, do: Repo.all(FrontmatterKey, skip_tenant_check: true)

  defp as_tenant(user_id, fun) do
    as_prod_role(fn ->
      Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [to_string(user_id)])
      fun.()
    end)
  end

  test "CONTROL: engram_app with no tenant sees zero rows" do
    assert length(rows()) == 2
    assert as_prod_role(&rows/0) == {:returned, []}
    assert length(keys()) == 2
    assert as_prod_role(&keys/0) == {:returned, []}
  end

  test "a tenant sees only its own rows; equal values HMAC differently", %{a: a, b: b} do
    assert {:returned, [row]} = as_tenant(a.user.id, &rows/0)
    assert row.user_id == a.user.id
    assert row.h == FilterId.value_hmac(a.fk, "draft")
    refute row.h == FilterId.value_hmac(b.fk, "draft")
  end

  test "a tenant sees only its own dictionary; the same key, the same id, other HMACs",
       %{a: a, b: b} do
    assert {:returned, [key]} = as_tenant(a.user.id, &keys/0)
    assert key.user_id == a.user.id and key.key_id == 64
    assert key.key_hmac == FilterId.key_hmac(a.fk, "phase")
    refute key.key_hmac == FilterId.key_hmac(b.fk, "phase")
  end

  test "a tenant cannot write another tenant's dictionary", %{a: a, b: b} do
    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             as_tenant(a.user.id, fn ->
               Repo.insert_all(
                 FrontmatterKey,
                 [
                   %{user_id: b.user.id, key_id: 65, key_hmac: "k", name_ct: "c", name_nonce: "n"}
                 ],
                 skip_tenant_check: true
               )
             end)
  end

  test "a tenant cannot write another tenant's row", %{a: a, b: b} do
    {:returned, [_]} = as_tenant(a.user.id, &rows/0)

    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             as_tenant(a.user.id, fn ->
               Repo.insert_all(
                 NoteAttr,
                 [
                   %{
                     note_id: b.note.id,
                     user_id: b.user.id,
                     vault_id: b.vault.id,
                     key_id: 64,
                     n: 1.0
                   }
                 ],
                 skip_tenant_check: true
               )
             end)
  end

  # CONTROL for the test below: the maintenance role reaches other tenants'
  # rows through the maintenance_all POLICY, not through a bypass attribute.
  test "CONTROL: engram_maintenance has no BYPASSRLS and note_attrs carries maintenance_all" do
    assert Repo.query!(
             "SELECT rolbypassrls, rolsuper FROM pg_roles WHERE rolname = 'engram_maintenance'"
           ).rows ==
             [[false, false]]

    for table <- ~w(note_attrs frontmatter_keys) do
      assert Repo.query!(
               "SELECT roles::text[] FROM pg_policies WHERE tablename = $1 AND policyname = 'maintenance_all'",
               [table]
             ).rows == [[["engram_maintenance"]]]
    end
  end

  test "real users get different filter keys", %{a: a, b: b} do
    refute a.fk == b.fk
  end

  # CONTROL: the maintenance role's access comes from the maintenance_all
  # policy itself. Without it, the same role with no tenant sees nothing.
  test "CONTROL: without maintenance_all, engram_maintenance sees zero rows" do
    {:error, n} =
      Repo.transaction(fn ->
        Repo.query!("DROP POLICY maintenance_all ON note_attrs")
        Repo.query!("DROP POLICY maintenance_all ON frontmatter_keys")
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_maintenance")
        n = length(rows()) + length(keys())
        Repo.query!("RESET SESSION AUTHORIZATION")
        Repo.rollback(n)
      end)

    assert n == 0
  end

  test "maintenance_all sees every tenant's rows" do
    {:ok, n} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_maintenance")
        n = length(rows()) + length(keys())
        Repo.query!("RESET SESSION AUTHORIZATION")
        n
      end)

    assert n == 4
  end
end
