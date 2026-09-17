defmodule Engram.Repo.CrossTenantTest do
  @moduledoc """
  `cross_tenant/1` and `with_tenant!/2` — the two seams that replace a keyword
  repeated 235 times and an unwrapping match repeated 11 times.

  Both are thin, and thin is what makes them worth pinning: the whole value is
  that they behave EXACTLY like the shapes they replace, so a test that only
  proved "it runs" would not catch the ways they could silently differ.
  """
  use Engram.DataCase, async: true

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

      :telemetry.attach(
        handler,
        [:engram, :repo, :tenant_check_skipped],
        fn _event, _measure, meta, _cfg -> send(test_pid, {:skipped, meta}) end,
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
end
