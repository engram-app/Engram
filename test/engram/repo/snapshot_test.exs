defmodule Engram.Repo.SnapshotTest do
  # `Repo.with_tenant_snapshot!/2`: a top-level reader runs in ONE read-only
  # REPEATABLE READ snapshot; a nested call runs inline in the caller's
  # transaction (its isolation can only be set by its first statement).
  #
  # The sandbox runs every transaction as a savepoint of the test's own, so
  # the top-level case runs `unboxed_run/2` (a real BEGIN, nothing written).
  use Engram.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  defp isolation do
    %{rows: [[level]]} = Repo.query!("SHOW transaction_isolation")
    %{rows: [[read_only]]} = Repo.query!("SHOW transaction_read_only")
    {level, read_only}
  end

  test "top level: REPEATABLE READ, READ ONLY" do
    tenant = Ecto.UUID.generate()

    result =
      Sandbox.unboxed_run(Repo, fn ->
        Process.put(:engram_unboxed_top_level, true)

        try do
          {Repo.with_tenant_snapshot!(tenant, &isolation/0),
           Repo.with_tenant!(tenant, &isolation/0)}
        after
          Process.delete(:engram_unboxed_top_level)
        end
      end)

    # Control: the plain block is READ COMMITTED, read-write.
    assert result == {{"repeatable read", "on"}, {"read committed", "off"}}
  end

  test "nested: runs inline in the caller's transaction, at its isolation" do
    tenant = Ecto.UUID.generate()

    {:ok, inner} =
      Repo.transaction(fn ->
        Repo.query!("SELECT 1")
        Repo.with_tenant_snapshot!(tenant, &isolation/0)
      end)

    assert inner == {"read committed", "off"}
  end

  test "the sandbox's own transactions are left as they are" do
    assert Repo.with_tenant_snapshot!(Ecto.UUID.generate(), &isolation/0) ==
             {"read committed", "off"}
  end
end
