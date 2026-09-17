defmodule Engram.Repo.CrossTenantTest do
  @moduledoc """
  `cross_tenant/1` and `with_tenant!/2` — the two seams that replace a keyword
  repeated 235 times and an unwrapping match repeated 11 times.

  Both are thin, and thin is what makes them worth pinning: the whole value is
  that they behave EXACTLY like the shapes they replace, so a test that only
  proved "it runs" would not catch the ways they could silently differ.
  """
  # NOT async: the telemetry test attaches a GLOBAL `:telemetry` handler, and
  # `[:engram, :repo, :tenant_check_skipped]` is emitted by 229 other live
  # `skip_tenant_check: true` sites. A concurrent test reading `notes` with the
  # keyword would deliver a matching message into this test's mailbox.
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Notes.Note

  describe "cross_tenant/1" do
    test "a tenant-table query raises outside the block" do
      # The control. Without it, every assertion below is ambiguous between
      # "the block suppressed the guard" and "the guard never fires here".
      assert_raise Engram.TenantError, fn -> Repo.all(Note) end
    end

    test "suppresses the tripwire inside the block" do
      assert Repo.cross_tenant(fn -> Repo.all(Note) end) == []
    end

    test "returns the function's value unchanged" do
      # Not wrapped in {:ok, _}, unlike with_tenant/2. A caller swapping
      # `skip_tenant_check: true` for this block must not have to re-shape its
      # return value, or the migration stops being mechanical.
      assert Repo.cross_tenant(fn -> :sentinel end) == :sentinel
    end

    test "clears the flag once the block exits" do
      Repo.cross_tenant(fn -> Repo.all(Note) end)

      assert_raise Engram.TenantError, fn -> Repo.all(Note) end
    end

    test "clears the flag even when the block raises" do
      assert_raise RuntimeError, fn ->
        Repo.cross_tenant(fn -> raise "boom" end)
      end

      assert_raise Engram.TenantError, fn -> Repo.all(Note) end
    end

    test "a nested block does not re-arm the guard for the outer one" do
      # The reason `cross_tenant/1` restores the PREVIOUS value instead of
      # clearing the flag. With a naive `Process.delete/1` in the `after`, the
      # inner block's exit would switch the tripwire back on for the rest of
      # the outer block — turning a refactor of two adjacent call sites into a
      # runtime raise in whichever one happened to be nested.
      Repo.cross_tenant(fn ->
        Repo.cross_tenant(fn -> Repo.all(Note) end)

        assert Repo.all(Note) == []
      end)

      assert_raise Engram.TenantError, fn -> Repo.all(Note) end
    end

    test "emits the same telemetry event the keyword does" do
      # The metric counts how much of the system runs outside a tenant scope.
      # If this spelling emitted a different event, that baseline would drop to
      # zero as sites migrate and the number would read as progress.
      handler = {__MODULE__, make_ref()}
      test_pid = self()

      # `self() == test_pid` inside the handler is what makes this
      # discriminating, and it is not ceremony. `:telemetry.execute/3` runs the
      # handler in the EMITTING process, and handlers are global — so without
      # this filter any of the 229 other `skip_tenant_check` sites firing on
      # `notes` in another process satisfies the `assert_received` below, and
      # the test passes even if `cross_tenant/1` emitted nothing at all.
      :telemetry.attach(
        handler,
        [:engram, :repo, :tenant_check_skipped],
        fn _event, _measure, meta, _cfg ->
          if self() == test_pid, do: send(test_pid, {:skipped, meta})
        end,
        nil
      )

      try do
        Repo.cross_tenant(fn -> Repo.all(Note) end)
      after
        :telemetry.detach(handler)
      end

      assert_received {:skipped, %{table: "notes"}}
    end
  end

  describe "with_tenant!/2" do
    setup do
      %{user: insert(:user)}
    end

    test "returns the bare result, not {:ok, result}", %{user: user} do
      assert Repo.with_tenant!(user.id, fn -> :sentinel end) == :sentinel
    end

    test "still sets the tenant, so a scoped query does not raise", %{user: user} do
      # The bang variant must differ from `with_tenant/2` ONLY in its return
      # shape. If it dropped the scope it would still pass the test above.
      assert Repo.with_tenant!(user.id, fn -> Repo.all(Note) end) == []
    end

    test "rejects a non-UUID tenant the same way with_tenant/2 does" do
      assert_raise ArgumentError, fn -> Repo.with_tenant!("not-a-uuid", fn -> :nope end) end
    end
  end

  describe "cross_tenant/1 is NOT a Postgres scope" do
    setup do
      user = insert(:user)
      %{note: insert(:note, user: user, vault: insert(:vault, user: user))}
    end

    test "a query inside the block is still filtered by the policy", %{note: note} do
      # The most important property in this file, and the one a reader is most
      # likely to get wrong. `cross_tenant/1` suppresses `prepare_query/3` — an
      # APPLICATION guard — and sets no Postgres session state whatsoever.
      # Where RLS is enforced, the query inside it is filtered exactly as it
      # would be without the block.
      #
      # Believing otherwise is how you write a sweep that reads zero rows and
      # reports success, which is the entire bug class this change addresses.
      # `Engram.Repo.maintenance/0` is what actually exempts a query; the block
      # only stops Engram from raising first.
      counted = from(n in Note, where: n.id == ^note.id, select: count(n.id))

      # The row exists — read as the superuser, so this cannot be confused with
      # a fixture problem.
      assert Repo.one(counted, skip_tenant_check: true) == 1

      assert {:returned, 0} =
               as_prod_role(fn -> Repo.cross_tenant(fn -> Repo.one(counted) end) end)
    end
  end

  describe "Engram.RlsCase itself" do
    # Six test files rest on these two properties and nothing pinned them. The
    # extraction already broke once on a scope problem invisible to every
    # adopter (`alias Engram.Repo` did not follow the functions into the new
    # module), so the harness having its own tests is not ceremony.
    test "as_prod_role/1 tags a raise instead of letting it escape" do
      assert {:raised, %RuntimeError{message: "boom"}} = as_prod_role(fn -> raise "boom" end)
    end

    test "as_prod_role/1 leaves the connection on its original role" do
      [[before]] = Repo.query!("SELECT current_user").rows
      as_prod_role(fn -> :ok end)

      assert [[^before]] = Repo.query!("SELECT current_user").rows
    end

    test "as_prod_role_committing/1 leaves the connection on its original role" do
      # This is the variant that can leak: it COMMITS, so unlike the rolling
      # back one there is no discarded transaction to undo its `SET LOCAL`.
      # `RESET ROLE` on the success path is what holds it, and a leak here
      # would silently enforce RLS on every later test sharing the connection.
      [[before]] = Repo.query!("SELECT current_user").rows
      as_prod_role_committing(fn -> :ok end)

      assert [[^before]] = Repo.query!("SELECT current_user").rows
    end
  end
end
