defmodule Engram.Accounts.ExportRlsTest do
  @moduledoc """
  Pins account export against an ENFORCED row-level security policy.

  ## Two bugs, both silent, in opposite directions

  `Export.estimate_bytes/1` sums `attachments.size_bytes` and counts `notes`.
  Both tables carry `FORCE ROW LEVEL SECURITY`, so unscoped both reads return
  ZERO — and zero is under every cap. The size gate therefore **fails open**:
  an account far past `account_export_max_bytes` is admitted, which is the
  direction a cap must never fail in.

  `Streamer.run/2` then lists the user's vaults, and `zip_entries/2` lists that
  vault's notes. Unscoped both return `[]`, so `zip_vault/2` short-circuits on
  empty entries, `run/2` returns `{:ok, [], 0}`, and the worker marks the export
  **`:ready` with `s3_keys: []`**. The user is handed a successful, empty
  export of their own data, and nothing logs an error.

  ## Why the existing tests do not catch either

  `export_test.exs` and `export/streamer_test.exs` both assert the right things
  (`:too_large` for a 2GB attachment; `total bytes > 0` for a non-empty vault)
  and both pass today, because the suite connects as a Postgres superuser and a
  superuser bypasses RLS even under `FORCE`.

  Note `streamer_test.exs`'s "user with one empty vault -> s3_keys: []" asserts
  the EMPTY direction, so it passes under a dropped role for the wrong reason.
  The assertions below are deliberately the non-empty direction only.

  No leaked tenant is available to rescue these: neither `export.ex`,
  `export/streamer.ex`, `workers/account_export.ex` nor `billing.ex` calls
  `Repo.with_tenant/2`, so unlike `LifecycleRlsTest` this file needs no seam to
  clear one. See `docs/context/rls-enforcement-testing-traps.md` trap 7.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Engram.Accounts.Export
  alias Engram.Repo
  alias Engram.Storage.InMemory
  alias Engram.Workers.AccountExport

  setup do
    InMemory.ensure_table()
    :ets.delete_all_objects(:engram_test_storage_in_memory)

    case :ets.whereis(:engram_test_storage_in_memory_multipart) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(:engram_test_storage_in_memory_multipart)
    end

    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    %{user: user, vault: vault, note: note}
  end

  defp count_for(table, user_id) do
    [[n]] =
      Repo.query!("SELECT count(*) FROM #{table} WHERE user_id = $1", [
        Ecto.UUID.dump!(user_id)
      ]).rows

    n
  end

  describe "size estimation under enforced RLS" do
    # CONTROL. Without this, a green file cannot distinguish "the queries are
    # correctly scoped" from "the role drop never engaged" — the two failure
    # modes look identical from the assertions below.
    test "control: the dropped role sees none of the user's own rows", %{user: user} do
      assert {:returned, {0, 0}} =
               as_prod_role(fn ->
                 {count_for("attachments", user.id), count_for("vaults", user.id)}
               end)
    end

    test "the size cap still trips instead of failing open", %{user: user, vault: vault} do
      # 2GB, the same shape as `export_test.exs`'s "size estimate over cap"
      # test, which passes today only because the suite is a superuser.
      insert(:attachment, user: user, vault: vault, size_bytes: 2_000_000_000)

      # Unscoped, `sum(size_bytes)` returns 0, 0 is under the cap, and the
      # oversized export is admitted.
      assert {:returned, {:error, :too_large}} =
               as_prod_role(fn -> Export.request(user) end)
    end
  end

  describe "streaming under enforced RLS" do
    test "the export ships the user's notes instead of an empty zip", %{user: user} do
      # Requested as the superuser: this test is about what the STREAMER reads,
      # not about admission, and `request/1` is covered above.
      {:ok, export} = Export.request(user)

      # The committing harness is required — the claim is about what the worker
      # persisted onto the export row, and a rollback would discard it and pass
      # against a completely unscoped implementation.
      assert :ok =
               as_prod_role_committing(fn ->
                 perform_job(AccountExport, %{"export_id" => export.id})
               end)

      reloaded = Repo.reload!(export)

      # Unscoped, the vault list is `[]`, so the export completes with no parts
      # at all and still reports success.
      assert reloaded.status == :ready

      refute reloaded.s3_keys == [],
             "export was marked :ready with NO parts — the vault query was filtered"

      assert reloaded.size_bytes > 0
    end
  end
end
