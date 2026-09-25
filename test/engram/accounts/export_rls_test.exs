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
  alias Engram.Accounts.Export.Schema
  alias Engram.Repo
  alias Engram.Storage.InMemory
  alias Engram.Workers.AccountExport
  alias Engram.Workers.ExportExpirySweep

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
      [job] = all_enqueued(worker: AccountExport)

      # The committing harness is required — the claim is about what the worker
      # persisted onto the export row, and a rollback would discard it and pass
      # against a completely unscoped implementation.
      assert :ok =
               as_prod_role_committing(fn -> perform_job(AccountExport, job.args) end)

      reloaded = Repo.reload!(export, skip_tenant_check: true)

      # Unscoped, the vault list is `[]`, so the export completes with no parts
      # at all and still reports success.
      assert reloaded.status == :ready

      refute reloaded.s3_keys == [],
             "export was marked :ready with NO parts — the vault query was filtered"

      assert reloaded.size_bytes > 0
    end
  end

  # engram-app/Engram#1758. `account_exports` carries its own tenant policy, so
  # every read and write of it has to name the tenant. `skip_tenant_check: true`
  # names nothing: under the policy a read returns zero rows and an UPDATE
  # reports zero affected, and neither raises.
  describe "account_exports under its own RLS policy" do
    defp insert_export!(user, status, attrs \\ %{}) do
      %Schema{}
      |> Schema.changeset(
        Map.merge(%{user_id: user.id, status: status, reason: :user_request}, attrs)
      )
      |> Repo.insert!(skip_tenant_check: true)
    end

    # CONTROL. Proves the policy exists and the role drop engaged: with no
    # tenant set, the user's own export row is invisible.
    test "control: the dropped role sees none of the user's exports", %{user: user} do
      insert_export!(user, :ready)

      assert {:returned, 0} = as_prod_role(fn -> count_for("account_exports", user.id) end)
    end

    test "list and get return the user's own export", %{user: user} do
      export = insert_export!(user, :ready)
      id = export.id

      assert {:returned, {[%Schema{id: ^id}], {:ok, %Schema{id: ^id}}}} =
               as_prod_role(fn -> {Export.list(user), Export.get(user, id)} end)
    end

    test "get does not return another user's export", %{user: user} do
      other = insert(:user)
      theirs = insert_export!(other, :ready)

      assert {:returned, {:error, :not_found}} =
               as_prod_role(fn -> Export.get(user, theirs.id) end)
    end

    # Filtered to zero, the quota count grants unlimited exports and nothing errors.
    test "the lifetime quota still trips instead of failing open", %{user: user} do
      insert_export!(user, :ready)

      assert {:returned, {:error, :lifetime_exceeded}} =
               as_prod_role(fn -> Export.request(user) end)
    end

    # The unique violation happens inside `with_tenant`'s transaction. Without a
    # savepoint its trailing role reset dies with 25P02 and the caller gets a 500.
    test "a second concurrent request is :already_running, not a crash", %{user: user} do
      insert_export!(user, :pending)

      assert {:returned, {:error, :already_running}} =
               as_prod_role(fn -> Export.request(user) end)
    end

    test "request inserts the row and enqueues a job that names its tenant", %{user: user} do
      assert {:returned, {:ok, %Schema{id: id}}} = as_prod_role(fn -> Export.request(user) end)

      # Rolled back with the rest of `as_prod_role`, so assert on the job the
      # superuser path enqueues — same function, same args shape.
      {:ok, _} = Export.request(user)
      assert [%Oban.Job{args: %{"user_id" => uid}}] = all_enqueued(worker: AccountExport)
      assert uid == user.id
      assert is_binary(id)
    end

    test "the paid 24h quota still trips instead of failing open", %{user: user} do
      insert(:subscription, user: user, tier: "pro", status: "active")
      insert_export!(user, :ready)

      assert {:returned, {:error, :rate_exceeded}} = as_prod_role(fn -> Export.request(user) end)
    end

    # WITH CHECK, not just USING: a write naming another tenant is rejected
    # outright rather than landing a row its own tenant cannot see.
    test "the policy rejects an export written for another tenant", %{user: user} do
      other = insert(:user)

      cs =
        Schema.changeset(%Schema{}, %{user_id: other.id, status: :pending, reason: :user_request})

      assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               as_prod_role(fn -> Repo.with_tenant!(user.id, fn -> Repo.insert!(cs) end) end)
    end

    # Run as the SUPERUSER on purpose: `with_tenant/2` drops to `engram_app`
    # itself, so only a worker that ignores its `user_id` and reads unscoped
    # finds the row. Under `as_prod_role` that bug would be filtered too, and
    # this test would pass against it.
    test "a job naming the wrong owner touches nothing", %{user: user} do
      export = insert_export!(user, :pending)
      other = insert(:user)

      assert :ok =
               perform_job(AccountExport, %{"export_id" => export.id, "user_id" => other.id})

      assert Repo.reload!(export, skip_tenant_check: true).status == :pending
    end

    # The one live path into the worker's failure branch: an Oban retry of a
    # :failed export after the user already requested a new one. Flipping the
    # old row to :running trips `account_exports_one_active_per_user` inside
    # `with_tenant/2`, whose role reset then 25P02s unless the update has a
    # savepoint to roll back to.
    test "a retried export that collides with a newer one is marked :failed", %{user: user} do
      old = insert_export!(user, :failed)
      _new = insert_export!(user, :pending)

      assert {:error, %Ecto.Changeset{}} =
               as_prod_role_committing(fn ->
                 perform_job(AccountExport, %{"export_id" => old.id, "user_id" => user.id})
               end)

      reloaded = Repo.reload!(old, skip_tenant_check: true)
      assert reloaded.status == :failed
      assert reloaded.error_reason =~ "one_active_per_user"
    end

    # A pre-#1758 job has no `user_id`. Its owner lookup hidden by RLS returns
    # nil, which reads exactly like "row gone": the job succeeds, the row stays
    # :pending, and the unique index then answers :already_running forever.
    test "a legacy job refuses loudly instead of stranding the export", %{user: user} do
      export = insert_export!(user, :pending)

      assert {:returned, {:error, :tenancy_unsafe}} =
               as_prod_role(fn -> perform_job(AccountExport, %{"export_id" => export.id}) end)
    end

    test "the expiry sweep refuses loudly instead of expiring nothing", %{user: user} do
      insert_export!(user, :ready, %{expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)})

      assert {:returned, {:error, :tenancy_unsafe}} =
               as_prod_role(fn -> perform_job(ExportExpirySweep, %{}) end)
    end
  end
end
