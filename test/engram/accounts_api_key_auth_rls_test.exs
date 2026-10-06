defmodule Engram.AccountsApiKeyAuthRlsTest do
  @moduledoc """
  Pins API-key authentication against an ENFORCED row-level security policy.

  ## What broke

  `api_keys` carried `FORCE ROW LEVEL SECURITY` with a `tenant_isolation_*`
  policy keyed on `current_setting('app.current_tenant')`. But
  `validate_api_key/1` is the one lookup that CANNOT name a tenant: it resolves
  a `key_hash` to the user, so the user_id is the thing being discovered, not an
  input. It ran inside `Repo.cross_tenant/1`, which sets a process flag that
  suppresses the app-level `prepare_query/3` tripwire and NO Postgres session
  state, so the policy still applied and the row was filtered to nothing.

  Every API-key request therefore 401'd with `invalid_key` for a key that
  existed. Measured on staging 2026-09-18, where the app pool had been dropped
  to `engram_app`:

      A) app pool, NO tenant     -> [[0]]
      B) app pool, WITH tenant   -> [[1]]
      C) validate_api_key/1      -> {:error, :invalid_key}

  The fix adds a permissive `FOR SELECT` discovery policy predicated on "no
  tenant is set", so the authentication read succeeds while INSERT keeps
  `tenant_isolation_api_keys`'s WITH CHECK and UPDATE/DELETE keep its USING.
  `api_keys` stays in the policy set and in `@tenant_tables`.

  The predicate is "no tenant" rather than `true` on purpose, and the second
  test below is what pins the difference: under `USING (true)` a tenant-scoped
  connection could read every user's keys, and that test would fail. See
  `docs/context/rls-cutover-breaks-api-key-auth.md` for why dropping the policy
  outright, a `SECURITY DEFINER` lookup and a second BYPASSRLS pool were all
  rejected.

  ## Why the control reads `vaults` and not `api_keys`

  A control has to prove the role drop actually engaged, otherwise a green file
  cannot distinguish "correctly fixed" from "RLS was never enforced here". It
  cannot read `api_keys` to do that, because after this fix those rows are
  legitimately visible with no tenant. So it reads `vaults`, which still
  carries the policy.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Accounts
  alias Engram.Accounts.ApiKey
  alias Engram.Repo
  alias Engram.Vaults.Vault

  setup do
    user = insert(:user)
    {:ok, raw_key, api_key} = Accounts.create_api_key(user, "rls auth test")

    %{user: user, raw_key: raw_key, api_key: api_key}
  end

  describe "API-key authentication under enforced RLS" do
    # CONTROL. Proves the dropped role is genuinely subject to the policy, so a
    # pass on the tests below means something.
    test "control: the dropped role cannot see the user's vaults", %{user: user} do
      insert(:vault, user: user)

      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(v in Vault, where: v.user_id == ^user.id, select: count(v.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "a valid API key authenticates with no tenant in scope", %{
      user: user,
      raw_key: raw_key
    } do
      outcome = as_prod_role(fn -> Accounts.validate_api_key(raw_key) end)

      assert {:returned, {:ok, found_user, _api_key}} = outcome,
             """
             API-key auth failed for a key that exists. The `key_hash` lookup was
             filtered by a tenant policy, so `EngramWeb.Plugs.Auth` returns 401
             `invalid_key` and every plugin sync, MCP client and script is locked
             out.

               got: #{inspect(outcome)}
             """

      assert found_user.id == user.id
    end

    test "a bogus API key is still rejected" do
      assert {:returned, {:error, :invalid_key}} =
               as_prod_role(fn -> Accounts.validate_api_key("engram_bogus") end)
    end

    # THE discriminating test for the policy's SHAPE. The discovery policy is
    # predicated on "no tenant is set", not on `true`. Both fix authentication,
    # so the test above passes either way. Only this one fails under
    # `USING (true)`, where a tenant-scoped connection can read every user's
    # keys. Without it, nothing stops a future edit from widening the predicate
    # and silently surrendering read isolation.
    test "a tenant-scoped connection still cannot read another user's keys", %{user: user} do
      other = insert(:user)
      {:ok, _raw, _key} = Accounts.create_api_key(other, "other user's key")

      count = fn ->
        Repo.one(
          from(k in ApiKey, where: k.user_id == ^other.id, select: count(k.id)),
          skip_tenant_check: true
        )
      end

      # The tenant is passed as TEXT, matching the policy's `(user_id)::text`
      # comparison and what `Repo.with_tenant/2` itself sends. `user` comes from
      # setup rather than being inserted here, because a factory insert under
      # the dropped role is a different failure waiting to be misread.
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [user.id])

                 count.()
               end),
             "a scoped connection read another user's api_keys: the discovery " <>
               "policy is too permissive (USING (true) rather than tenant-unset)"

      # Contrast: with no tenant, plain engram_app still sees nothing (#1867);
      # only the dedicated lookup role, which `validate_api_key/1` assumes, does.
      assert {:returned, 0} = as_prod_role(count)

      assert {:returned, 1} =
               as_prod_role(fn ->
                 Repo.query!("SET LOCAL ROLE engram_key_lookup")
                 count.()
               end)
    end

    # #1867. `api_keys_discovery` used to apply to every role, so ANY unscoped
    # query as engram_app (here a join from users) returned every user's key
    # hashes. Scoped `TO engram_key_lookup`, which engram_app holds without
    # INHERIT, plain engram_app with no tenant sees zero rows.
    test "an unscoped join from users to api_keys sees no keys", %{user: user} do
      other = insert(:user)
      {:ok, _raw, _key} = Accounts.create_api_key(other, "other user's key")

      # Precondition: the superuser sees both keys, so 0 below is not vacuous.
      assert %{rows: [[2]]} =
               Repo.query!(
                 "SELECT count(*) FROM users u JOIN api_keys k ON k.user_id = u.id " <>
                   "WHERE u.id = ANY($1)",
                 [[Ecto.UUID.dump!(user.id), Ecto.UUID.dump!(other.id)]]
               )

      assert {:returned, %{rows: []}} =
               as_prod_role(fn ->
                 Repo.query!(
                   "SELECT u.email, k.name, k.key_hash, k.user_id " <>
                     "FROM users u JOIN api_keys k ON k.user_id = u.id"
                 )
               end)
    end
  end

  describe "the engram_key_lookup role" do
    test "holds no login, bypass or admin attributes" do
      assert %{rows: [[false, false, false, false, false]]} =
               Repo.query!("""
               SELECT rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolcanlogin
               FROM pg_roles WHERE rolname = 'engram_key_lookup'
               """)
    end

    # SET (so validate_api_key can switch to it) but NOT INHERIT: an inherited
    # membership would put engram_app under the policy on every query.
    test "engram_app may SET it but does not inherit it" do
      assert %{rows: [[true, false]]} =
               Repo.query!("""
               SELECT pg_has_role('engram_app', 'engram_key_lookup', 'SET'),
                      pg_has_role('engram_app', 'engram_key_lookup', 'USAGE')
               """)
    end
  end
end
