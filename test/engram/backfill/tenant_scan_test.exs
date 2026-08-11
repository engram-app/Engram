defmodule Engram.Backfill.TenantScanTest do
  @moduledoc """
  The regression guard for #1349.

  The bug — a cross-tenant discovery read that returns zero rows under prod's
  FORCE ROW LEVEL SECURITY — is **invisible to a direct assertion here**,
  because the dev/CI Postgres user is a superuser and bypasses RLS regardless
  of FORCE. Asserting "the backfill found the rows" would pass on both the
  fixed and the broken version.

  So these assert the *structural* property instead: a discovery scan must
  never read a tenant table outside a tenant context. `Engram.Repo` already
  emits `[:engram, :repo, :tenant_check_skipped]` whenever
  `skip_tenant_check: true` is used, so listening for that event detects the
  broken shape on any Postgres role.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.Fixtures

  alias Engram.Backfill.TenantScan
  alias Engram.ContentHash
  alias Engram.Crypto
  alias Engram.Links
  alias Engram.Notes.Note
  alias Engram.Onboarding
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "TenantScan"})

    %{user: user, vault: vault}
  end

  defp capture_skips(fun) do
    handler_id = "tenant-skip-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :tenant_check_skipped],
      fn _e, _m, meta, _c -> send(parent, {:skipped, meta[:table]}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    fun.()
    drain_skips([])
  end

  defp drain_skips(acc) do
    receive do
      {:skipped, table} -> drain_skips([table | acc])
    after
      0 -> Enum.uniq(acc)
    end
  end

  test "flat_map_users runs its function inside a tenant context", %{user: user} do
    tenants =
      TenantScan.flat_map_users(fn user_id -> [{user_id, Process.get(:engram_tenant)}] end)

    assert {user.id, user.id} in tenants,
           "fun must see app.current_tenant set to the user it was called for"
  end

  test "flat_map_users can read a tenant table with no skip_tenant_check", %{
    user: user,
    vault: vault
  } do
    insert_note!(user, vault, %{"content" => "x"})

    skipped =
      capture_skips(fn ->
        rows = TenantScan.flat_map_users(fn _uid -> Repo.all(from(n in Note, select: n.id)) end)
        refute rows == []
      end)

    assert skipped == [], "reading inside a tenant context must not bypass the guard"
  end

  # One per backfill. NOTE the coverage boundary: this detects the *Ecto*
  # route to a cross-tenant read, because `prepare_query/3` — and therefore the
  # telemetry — only fires for Ecto.Query operations. The onboarding backfill's
  # pre-#1349 shape was `Repo.query!` raw SQL, which bypasses that callback
  # entirely and would NOT trip this assertion. That route is covered instead
  # by raw_sql_tenant_table_lint_test.exs, whose allowlist entry for this file
  # #1349 deleted — so reverting to raw SQL now fails there. Between the two
  # lints and this test, both routes are closed; neither closes both.
  for {label, mod, fun} <- [
        {"content hash", ContentHash.Backfill, :enqueue_all},
        {"note links", Links.Backfill, :enqueue_all},
        {"onboarding", Onboarding.Backfill, :first_vault_created}
      ] do
    test "#{label} backfill discovery never reads a tenant table cross-tenant", %{
      user: user,
      vault: vault
    } do
      insert_note!(user, vault, %{"content" => "discoverable"})

      skipped = capture_skips(fn -> apply(unquote(mod), unquote(fun), []) end)

      assert skipped == [],
             "#{unquote(label)} discovery bypassed the tenant guard on #{inspect(skipped)} — " <>
               "on prod those reads return zero rows under FORCE RLS (#1349)"
    end
  end
end
