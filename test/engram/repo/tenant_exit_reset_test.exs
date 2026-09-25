defmodule Engram.Repo.TenantExitResetTest do
  @moduledoc """
  engram-app/Engram#1761. `with_tenant/2` must clear `app.current_tenant` on
  exit, not only the role.

  Nested inside a plain transaction, `with_tenant` runs as a savepoint, and a
  `SET LOCAL` survives `RELEASE SAVEPOINT` until the OUTER transaction ends.
  Without the reset, every later statement in that outer transaction is still
  scoped to the tenant in Postgres while the app believes it is unscoped: an
  unscoped read on a tenant table sees that tenant's rows instead of zero, and
  the `api_keys_discovery` policy (open only while no tenant is set) stays shut.

  `as_prod_role/1` is itself the plain outer transaction, which is exactly the
  production shape (`Onboarding.accept_terms/6`).
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    insert(:note, user: user, vault: vault)
    %{user: user}
  end

  defp unscoped_note_count(user_id) do
    Repo.cross_tenant(fn ->
      Repo.aggregate(from(n in Note, where: n.user_id == ^user_id), :count)
    end)
  end

  defp current_tenant do
    %{rows: [[value]]} = Repo.query!("SELECT current_setting('app.current_tenant', true)")
    value
  end

  test "an unscoped read after a nested block sees nothing again", %{user: user} do
    assert {:returned, {inside, after_block}} =
             as_prod_role(fn ->
               inside = Repo.with_tenant!(user.id, fn -> unscoped_note_count(user.id) end)
               {inside, unscoped_note_count(user.id)}
             end)

    # CONTROL: inside the block the tenant really is in force.
    assert inside == 1
    assert after_block == 0
  end

  test "the tenant setting is empty after the block exits", %{user: user} do
    assert {:returned, value} =
             as_prod_role(fn ->
               Repo.with_tenant!(user.id, fn -> :ok end)
               current_tenant()
             end)

    # Empty, not the uuid: the tenant policies never match '' and
    # `api_keys_discovery` treats coalesce(..., '') = '' as "no tenant".
    assert value in [nil, ""]
  end
end
