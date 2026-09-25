defmodule Engram.Repo.MaintenanceRoleTest do
  @moduledoc """
  Pins the `engram_maintenance` role: the credential behind
  `MAINTENANCE_DATABASE_URL` on SaaS.

  RDS will not grant BYPASSRLS to a custom role (the master is CREATEROLE, not
  superuser, and PG16+ only lets a CREATEROLE role hand out attributes it holds
  itself). So cross-tenant reach comes from one permissive `maintenance_all`
  policy per tenant table, scoped `TO engram_maintenance`. These tests prove
  three things, and each one fails on its own if the mechanism breaks:

    * the role has no bypass attributes, so its reach is the policy and nothing
      else (a BYPASSRLS role would pass the visibility tests vacuously);
    * as that role, with NO tenant set, another tenant's rows are visible and
      updatable in every tenant table;
    * CONTROL: `engram_app` under the same conditions still sees zero, so the
      policy widened one role and not the table.

  Drops `session_user` with `SET LOCAL SESSION AUTHORIZATION`, not `SET ROLE`,
  for the reason `Engram.Repo.SessionRoleTest` pins. The sandbox rollback
  reverts it.
  """
  use Engram.DataCase, async: false

  import Engram.Factory

  # Role-dependent by construction: it switches roles itself.
  @moduletag :rls_unsafe

  @tenant_tables Enum.map(Engram.Repo.tenant_tables(), &Atom.to_string/1)

  # Rows owned by a user who is never set as the tenant. Five of the eleven
  # tables have cheap factories; the rest are covered by the count-parity and
  # policy-shape tests below, which do not need rows of their own.
  defp seed_foreign_tenant do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    insert(:attachment, user: user, vault: vault)
    insert(:api_key, user: user)
    insert(:agreement, user: user)
    %{user: user, note: note}
  end

  defp as_role(role, fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT set_config('app.current_tenant', '', true)")
      Repo.query!("SET LOCAL SESSION AUTHORIZATION #{role}")
      result = fun.()
      Repo.query!("RESET SESSION AUTHORIZATION")
      result
    end)
  end

  defp count(table), do: Repo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

  defp self_update(table),
    do: Repo.query!("UPDATE #{table} SET user_id = user_id").num_rows

  test "engram_maintenance holds no bypass or admin attributes" do
    assert %{rows: [[false, false, false, false, true, false]]} =
             Repo.query!("""
             SELECT rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolcanlogin, rolinherit
             FROM pg_roles WHERE rolname = 'engram_maintenance'
             """)
  end

  test "engram_maintenance is a member of no role" do
    assert %{rows: [[0]]} =
             Repo.query!("""
             SELECT count(*) FROM pg_auth_members m
             JOIN pg_roles r ON r.oid = m.member
             WHERE r.rolname = 'engram_maintenance'
             """)
  end

  test "sees and updates another tenant's rows in every tenant table, with no tenant set" do
    seed_foreign_tenant()

    # The superuser's view is the reference: everything in the table.
    expected = Map.new(@tenant_tables, &{&1, count(&1)})

    for t <- ~w(notes vaults attachments api_keys user_agreements) do
      assert expected[t] > 0, "fixture did not seed #{t}; the assertion below would be vacuous"
    end

    {:ok, {seen, updated}} =
      as_role("engram_maintenance", fn ->
        {Map.new(@tenant_tables, &{&1, count(&1)}),
         Map.new(@tenant_tables, &{&1, self_update(&1)})}
      end)

    assert seen == expected
    assert updated == expected
  end

  test "CONTROL: engram_app with no tenant set still sees and updates nothing" do
    seed_foreign_tenant()

    # api_keys is excluded: `api_keys_discovery` deliberately widens SELECT when
    # no tenant is set (see 20260918120000). Its UPDATE is still filtered.
    readable = @tenant_tables -- ["api_keys"]

    {:ok, {seen, updated}} =
      as_role("engram_app", fn ->
        {Map.new(readable, &{&1, count(&1)}), Map.new(@tenant_tables, &{&1, self_update(&1)})}
      end)

    assert Enum.all?(seen, fn {_, n} -> n == 0 end), inspect(seen)
    assert Enum.all?(updated, fn {_, n} -> n == 0 end), inspect(updated)
  end

  test "every tenant table carries maintenance_all, permissive, ALL, TO engram_maintenance only" do
    # Drift guard. A tenant table added without this policy would make the
    # maintenance pool read zero rows from it, which is the silent-sweep bug
    # this role exists to fix.
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname, p.polpermissive, p.polcmd,
               ARRAY(SELECT rolname FROM pg_roles WHERE oid = ANY(p.polroles) ORDER BY 1),
               pg_get_expr(p.polqual, p.polrelid),
               pg_get_expr(p.polwithcheck, p.polrelid)
        FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        WHERE p.polname = 'maintenance_all' AND c.relname = ANY($1)
        """,
        [@tenant_tables]
      )

    by_table = Map.new(rows, fn [t | rest] -> {t, rest} end)

    assert Enum.sort(Map.keys(by_table)) == Enum.sort(@tenant_tables),
           "tenant tables missing maintenance_all: #{inspect(@tenant_tables -- Map.keys(by_table))}"

    for {t, shape} <- by_table do
      assert shape == [true, "*", ["engram_maintenance"], "true", "true"],
             "maintenance_all on #{t} has the wrong shape: #{inspect(shape)}"
    end
  end

  test "engram_maintenance has DML on every tenant table and no DDL on the schema" do
    # One privilege per call: given a comma list, has_table_privilege answers
    # true if ANY of them is held, which let a SELECT-only grant pass here.
    for t <- @tenant_tables, priv <- ~w(SELECT INSERT UPDATE DELETE) do
      assert %{rows: [[true]]} =
               Repo.query!("SELECT has_table_privilege('engram_maintenance', $1, $2)", [t, priv]),
             "missing #{priv} grant on #{t}"
    end

    assert %{rows: [[true, false]]} =
             Repo.query!("""
             SELECT has_schema_privilege('engram_maintenance', 'public', 'USAGE'),
                    has_schema_privilege('engram_maintenance', 'public', 'CREATE')
             """)
  end
end
