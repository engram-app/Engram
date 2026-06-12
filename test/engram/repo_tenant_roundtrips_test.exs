defmodule Engram.RepoTenantRoundtripsTest do
  use Engram.DataCase, async: false

  alias Engram.Notes.Note

  # Counts utility statements (the SELECT set_config / SET / RESET overhead)
  # emitted by with_tenant, excluding the caller's own queries. Telemetry
  # handlers run synchronously in the emitting process.
  defp count_utility_statements(fun) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _e, _m, %{query: q}, _c ->
        if self() == test_pid and (q =~ "set_config" or q =~ ~r/^(SET|RESET)/) do
          send(test_pid, {:utility, q})
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect(:utility)
  end

  defp collect(tag, acc \\ []) do
    receive do
      {^tag, q} -> collect(tag, [q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "with_tenant/2 wire overhead" do
    test "one combined set_config statement in, one reset out" do
      # The old shape spent three utility round-trips per call
      # (SET LOCAL app.current_tenant + SET LOCAL ROLE + RESET ROLE) —
      # and hot requests open several with_tenant blocks.
      user = insert(:user)

      utility =
        count_utility_statements(fn ->
          {:ok, _} = Repo.with_tenant(user.id, fn -> Repo.all(Note) end)
        end)

      assert length(utility) == 2,
             "expected 2 utility statements (combined set + reset), got: #{inspect(utility)}"
    end

    test "the tenant setting is bound as a parameter, not interpolated" do
      user = insert(:user)

      utility =
        count_utility_statements(fn ->
          {:ok, _} = Repo.with_tenant(user.id, fn -> Repo.all(Note) end)
        end)

      set_stmt = Enum.find(utility, &(&1 =~ "app.current_tenant"))
      assert set_stmt, "no tenant-setting statement seen: #{inspect(utility)}"
      refute set_stmt =~ user.id, "tenant uuid interpolated into SQL instead of bound"
    end
  end

  describe "with_tenant/2 re-entrancy" do
    test "nested same-tenant call adds no transaction or utility statements" do
      user = insert(:user)

      utility =
        count_utility_statements(fn ->
          {:ok, {:ok, inner}} =
            Repo.with_tenant(user.id, fn ->
              # e.g. batch folder ops: an outer tenant block composing
              # helpers that each take their own with_tenant.
              Repo.with_tenant(user.id, fn -> Repo.all(Note) end)
            end)

          assert inner == []
        end)

      assert length(utility) == 2,
             "nested same-tenant call must reuse the outer context, got: #{inspect(utility)}"
    end

    test "nested call still enforces RLS isolation" do
      user_a = insert(:user)
      vault_a = insert(:vault, user: user_a)

      {:ok, _} =
        Engram.Notes.upsert_note(user_a, vault_a, %{
          "path" => "nested.md",
          "content" => "x",
          "mtime" => 1_000.0
        })

      {:ok, {:ok, notes}} =
        Repo.with_tenant(user_a.id, fn ->
          Repo.with_tenant(user_a.id, fn -> Repo.all(Note) end)
        end)

      assert length(notes) == 1

      user_b = insert(:user)

      {:ok, {:ok, foreign}} =
        Repo.with_tenant(user_b.id, fn ->
          Repo.with_tenant(user_b.id, fn -> Repo.all(Note) end)
        end)

      assert foreign == []
    end

    test "nested call for a DIFFERENT tenant raises instead of silently switching" do
      user_a = insert(:user)
      user_b = insert(:user)

      assert_raise ArgumentError, ~r/different tenant/, fn ->
        Repo.with_tenant(user_a.id, fn ->
          Repo.with_tenant(user_b.id, fn -> Repo.all(Note) end)
        end)
      end
    end
  end
end
