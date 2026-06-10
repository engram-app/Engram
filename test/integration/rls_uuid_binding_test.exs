defmodule Engram.RlsUuidBindingTest do
  @moduledoc """
  Phase E.4 — sanity test the uuid `app.current_tenant` RLS binder.

  Confirms the binder accepts uuid strings and that PG18 RLS policies
  comparing `(user_id)::text = current_setting('app.current_tenant')`
  enforce isolation. Both safe outcomes — empty rows OR a Postgrex
  raise — are accepted for the malformed-setting case; the only
  unacceptable behavior is silently returning all rows.
  """

  use Engram.DataCase, async: false

  alias Engram.Repo
  alias Engram.Vaults.Vault

  @moduletag :integration

  test "rows are visible only under matching uuid app.current_tenant" do
    user_a = insert(:user)
    user_b = insert(:user)
    vault_a = insert(:vault, user: user_a)
    _vault_b = insert(:vault, user: user_b)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL app.current_tenant = '#{user_a.id}'")
      Repo.query!("SET LOCAL ROLE engram_app")

      ids =
        from(v in Vault, where: v.user_id == ^user_a.id, select: v.id)
        |> Repo.all(skip_tenant_check: true)

      assert vault_a.id in ids
      Repo.query!("RESET ROLE")
    end)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL app.current_tenant = '#{user_b.id}'")
      Repo.query!("SET LOCAL ROLE engram_app")

      ids =
        from(v in Vault, where: v.user_id == ^user_a.id, select: v.id)
        |> Repo.all(skip_tenant_check: true)

      refute vault_a.id in ids
      Repo.query!("RESET ROLE")
    end)
  end

  test "malformed app.current_tenant fails closed (no row leak)" do
    user = insert(:user)
    _vault = insert(:vault, user: user)

    result =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL app.current_tenant = 'not-a-uuid'")
        Repo.query!("SET LOCAL ROLE engram_app")

        try do
          rows =
            from(v in Vault, select: v.id)
            |> Repo.all(skip_tenant_check: true)

          {:rows, rows}
        rescue
          Postgrex.Error -> :postgrex_raise
        after
          Repo.query!("RESET ROLE")
        end
      end)

    case result do
      {:ok, {:rows, []}} -> :ok
      {:ok, :postgrex_raise} -> :ok
      {:ok, {:rows, rows}} -> flunk("RLS leaked #{length(rows)} rows under malformed tenant")
      other -> flunk("Unexpected transaction outcome: #{inspect(other)}")
    end
  end
end
