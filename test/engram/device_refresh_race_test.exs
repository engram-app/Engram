defmodule Engram.DeviceRefreshRaceTest do
  @moduledoc """
  Device refresh vs revoke races on REAL, separately committing connections
  (#2231 review).

  `Engram.DataCase` runs a test and its tasks on one sandbox connection, so
  races there are serialized away. These check out with `sandbox: false`
  (as `Engram.OAuthRotationRaceTest` does), so writes commit and row locks
  really block. Rows outlive the test, hence the cleanup.

  Determinism comes from a row lock, not timing: a holder takes `FOR UPDATE`
  on the device token, the racers queue behind it (seen in
  `pg_stat_activity`), and only then does the holder commit.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Engram.Factory

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Auth.{DeviceFlow, DeviceRefreshToken}
  alias Engram.Repo

  setup do
    real_checkout!()
    user = insert(:user)
    vault = insert(:vault, user: user)
    raw = "engram_rt_race_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    token =
      insert(:device_refresh_token,
        user: user,
        vault: vault,
        token_hash: Engram.Crypto.sha256_hex(raw)
      )

    on_exit(fn -> cleanup(user.id) end)
    %{user: user, vault: vault, raw: raw, family_id: token.family_id}
  end

  defp real_checkout! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  defp cleanup(user_id) do
    real_checkout!()
    uid = Ecto.UUID.dump!(user_id)
    Repo.query!("DELETE FROM device_refresh_tokens WHERE user_id = $1", [uid])
    Repo.query!("DELETE FROM vaults WHERE user_id = $1", [uid])
    Repo.query!("DELETE FROM users WHERE id = $1", [uid])
  end

  defp hold_row_lock(raw) do
    test = self()
    hash = Engram.Crypto.sha256_hex(raw)

    holder =
      Task.async(fn ->
        real_checkout!()

        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM device_refresh_tokens WHERE token_hash = $1 FOR UPDATE", [
            hash
          ])

          send(test, :locked)

          receive do
            :commit -> :ok
          after
            15_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive :locked, 5_000
    holder
  end

  defp lock_waiters do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    n
  end

  defp await_lock_waiters(n, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      lock_waiters() >= n ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("only #{lock_waiters()} of #{n} blocked")

      true ->
        Process.sleep(10) && await_lock_waiters(n, deadline)
    end
  end

  defp async_real(fun) do
    Task.async(fn ->
      real_checkout!()
      fun.()
    end)
  end

  defp live(family_id) do
    Repo.aggregate(
      from(rt in DeviceRefreshToken, where: rt.family_id == ^family_id and is_nil(rt.revoked_at)),
      :count
    )
  end

  defp revoke(:disconnect, ctx),
    do: Engram.Connections.revoke_device_family(ctx.user.id, ctx.family_id)

  defp revoke(:vault_delete, ctx),
    do: Engram.Connections.revoke_by_vault(ctx.user.id, ctx.vault.id)

  defp revoke(:logout_everywhere, ctx), do: Engram.Accounts.revoke_all_user_tokens(ctx.user)

  for name <- [:disconnect, :vault_delete, :logout_everywhere] do
    # A refresh that already read the token live, then a revoke: whichever
    # commits first, nothing in the family may be live afterwards.
    test "#{name} racing an in-flight refresh leaves no live token", ctx do
      holder = hold_row_lock(ctx.raw)
      refresh = async_real(fn -> DeviceFlow.refresh_access_token(ctx.raw) end)
      await_lock_waiters(1)

      revoke = async_real(fn -> revoke(unquote(name), ctx) end)
      await_lock_waiters(2)

      send(holder.pid, :commit)
      Task.await(holder)
      Task.await(refresh, 20_000)
      Task.await(revoke, 20_000)

      assert live(ctx.family_id) == 0
    end
  end

  # The leeway's reason to exist: a plugin racing itself (or a lost response
  # and its retry) presents the same token twice at once. Both must succeed:
  # no logout, no deadlock.
  test "two concurrent refreshes of one token both succeed", ctx do
    holder = hold_row_lock(ctx.raw)
    refreshes = for _ <- 1..2, do: async_real(fn -> DeviceFlow.refresh_access_token(ctx.raw) end)
    await_lock_waiters(2)

    send(holder.pid, :commit)
    Task.await(holder)

    results = Task.await_many(refreshes, 20_000)
    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
    assert live(ctx.family_id) >= 1
  end
end
