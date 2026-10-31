defmodule Engram.Vaults.SeqGatePoolTest do
  @moduledoc """
  RED/GREEN proof for the 2026-10-31 pool-starvation incident, on a REAL pool.

  The sandbox shares one connection across processes, so it cannot show pool
  exhaustion. This runs on a dynamic repo with a real pool of 3, outside the
  sandbox (pattern: `Engram.Repo.TenantTxnCommitResetTest`). Rows are committed,
  so the test deletes its user at the end.

  One process holds the vault row lock (what `Vaults.next_seq!` takes), then 50
  single deletes fire at that vault. Without the gate each delete checks out a
  connection and blocks on the row lock, the pool empties, and an unrelated
  query cannot get a connection. With the gate only the gate holder is in the
  DB, so the unrelated query gets one.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.Attachments
  alias Engram.Repo

  @deletes 50

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn _k, _b, _o -> :ok end)

    {:ok, pool} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 3, log: false)

    Repo.put_dynamic_repo(pool)
    %{pool: pool, sup: start_supervised!(Task.Supervisor)}
  end

  # nolink: on a red run, deletes die with pool errors; that must fail the
  # assertions below, not kill the test process before its cleanup runs.
  defp on_pool(%{pool: pool, sup: sup}, fun) do
    Task.Supervisor.async_nolink(sup, fn ->
      Repo.put_dynamic_repo(pool)
      fun.()
    end)
  end

  test "50 deletes queued on one vault's seq lock leave the pool usable", ctx do
    user = insert(:user, email: "seq-gate-#{Ecto.UUID.generate()}@example.com")

    try do
      vault = insert(:vault, user: user)

      for i <- 1..@deletes do
        {:ok, _} =
          Attachments.upsert_attachment(user, vault, %{
            "path" => "a/#{i}.png",
            "content_base64" => Base.encode64("x")
          })
      end

      parent = self()

      holder =
        on_pool(ctx, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT 1 FROM vaults WHERE id = $1 FOR NO KEY UPDATE", [
              Ecto.UUID.dump!(vault.id)
            ])

            send(parent, :locked)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :locked, 5_000

      deletes =
        for i <- 1..@deletes,
            do: on_pool(ctx, fn -> Attachments.delete_attachment(user, vault, "a/#{i}.png") end)

      Process.sleep(300)

      probe = on_pool(ctx, fn -> Repo.query("SELECT 1", [], timeout: 2_000) end)
      probe_result = Task.yield(probe, 3_000) || Task.shutdown(probe, :brutal_kill)

      # Release before asserting, so a red run still drains and cleans up.
      send(holder.pid, :release)
      Task.yield(holder, 5_000)
      results = Task.yield_many(deletes, 30_000)

      assert {:ok, {:ok, %{rows: [[1]]}}} = probe_result,
             "an unrelated query could not get a pool connection"

      assert Enum.all?(results, &match?({_, {:ok, :ok}}, &1))
      assert {:ok, []} = Attachments.list_attachments(user, vault)
    after
      # On a red run the pool is still jammed by blocked deletes: clean up on a
      # fresh pool so committed rows never leak into later tests.
      {:ok, cleanup} = Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)
      Repo.put_dynamic_repo(cleanup)
      id = Ecto.UUID.dump!(user.id)
      Repo.query!("DELETE FROM attachments WHERE user_id = $1", [id])
      Repo.query!("DELETE FROM users WHERE id = $1", [id])
    end
  end
end
