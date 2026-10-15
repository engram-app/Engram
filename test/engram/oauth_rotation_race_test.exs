defmodule Engram.OAuthRotationRaceTest do
  @moduledoc """
  Refresh-token rotation races on REAL, separately committing connections
  (review of #1974).

  `Engram.DataCase` runs a test and every task it spawns on one sandbox
  connection inside one transaction, so concurrent rotations there are
  serialized and the race they guard against never happens. These tests check
  out with `sandbox: false` instead (see `Engram.CheckpointInterleave`), so
  writes commit and row locks really block. The rows outlive the test, hence
  the cleanup.

  Determinism comes from a row lock, not timing: a holder takes `FOR UPDATE`
  on the refresh token, every rotation reads the live row and then blocks on
  its UPDATE, and only once all of them are waiting (seen in
  `pg_stat_activity`) does the holder commit.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Engram.Factory
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  setup do
    real_checkout!()
    user = insert(:user)

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

    on_exit(fn -> cleanup(user.id, client.client_id) end)

    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => hd(client.redirect_uris),
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    {:ok, %{refresh_token: raw}} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => hd(client.redirect_uris),
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    %{user: user, client_id: client.client_id, raw: raw}
  end

  defp real_checkout! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end

  defp cleanup(user_id, client_id) do
    real_checkout!()
    uid = Ecto.UUID.dump!(user_id)
    Repo.query!("DELETE FROM oauth_refresh_tokens WHERE user_id = $1", [uid])
    Repo.query!("DELETE FROM oauth_authorization_codes WHERE user_id = $1", [uid])
    Repo.query!("DELETE FROM oauth_clients WHERE client_id = $1", [Ecto.UUID.dump!(client_id)])
    Repo.query!("DELETE FROM users WHERE id = $1", [uid])
  end

  # Holds FOR UPDATE on the token row in its own transaction until told to
  # commit; `before_commit` runs inside that transaction first.
  defp hold_row_lock(raw, before_commit \\ fn -> :ok end) do
    test = self()
    hash = Engram.Crypto.sha256_hex(raw)

    holder =
      Task.async(fn ->
        real_checkout!()

        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM oauth_refresh_tokens WHERE token_hash = $1 FOR UPDATE", [
            hash
          ])

          send(test, :locked)

          receive do
            :commit -> before_commit.()
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

  defp rotate_concurrently(raw, client_id, n) do
    tasks =
      for _ <- 1..n do
        Task.async(fn ->
          real_checkout!()
          OAuth.rotate_refresh_token(raw, client_id)
        end)
      end

    {tasks, fn -> Task.await_many(tasks, 20_000) end}
  end

  defp live(user) do
    Repo.aggregate(
      from(r in RefreshToken,
        where: r.user_id == ^user.id and is_nil(r.consumed_at) and is_nil(r.revoked_at)
      ),
      :count,
      skip_tenant_check: true
    )
  end

  for n <- [2, 3, 5] do
    test "#{n} rotations that all read the live token all succeed, leaving one live token",
         ctx do
      holder = hold_row_lock(ctx.raw)
      {_tasks, await} = rotate_concurrently(ctx.raw, ctx.client_id, unquote(n))

      await_lock_waiters(unquote(n))
      send(holder.pid, :commit)
      Task.await(holder)

      results = await.()
      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
      assert live(ctx.user) == 1
    end
  end

  # A Disconnect committing between the rotation's read and its UPDATE must
  # stop it: the token is revoked, so no successor may be minted.
  test "a revoke that commits after the read stops the rotation", ctx do
    hash = Engram.Crypto.sha256_hex(ctx.raw)

    holder =
      hold_row_lock(ctx.raw, fn ->
        Repo.query!("UPDATE oauth_refresh_tokens SET revoked_at = now() WHERE token_hash = $1", [
          hash
        ])
      end)

    {_tasks, await} = rotate_concurrently(ctx.raw, ctx.client_id, 1)
    await_lock_waiters(1)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(holder.pid, :commit)
        Task.await(holder)

        # Third review #4: a revoked token is reported as revoked, not as reuse
        # (theft), and leaves no reuse line.
        assert [{:error, {:invalid_grant, :refresh_token_revoked}}] = await.()
      end)

    refute log =~ "oauth_refresh_reuse"
    assert live(ctx.user) == 0
  end

  # Third review #5: a Disconnect racing a rotation must not leave the
  # successor the rotation minted live. The rotation is parked holding the
  # token, the Disconnect queued behind it; whichever order they commit in,
  # nothing in the grant is live afterwards.
  test "a Disconnect racing a rotation leaves no live token", ctx do
    holder = hold_row_lock(ctx.raw)
    {_tasks, await_rotation} = rotate_concurrently(ctx.raw, ctx.client_id, 1)
    await_lock_waiters(1)

    disconnect =
      Task.async(fn ->
        real_checkout!()
        Engram.Connections.revoke_oauth_family(ctx.user.id, row_client_id(ctx.raw), nil)
      end)

    await_lock_waiters(2)
    send(holder.pid, :commit)
    Task.await(holder)

    assert [{:ok, _}] = await_rotation.()
    assert :ok = Task.await(disconnect)
    assert live(ctx.user) == 0
  end

  defp row_client_id(raw) do
    hash = Engram.Crypto.sha256_hex(raw)

    Repo.one!(from(r in RefreshToken, where: r.token_hash == ^hash, select: r.client_id),
      skip_tenant_check: true
    )
  end
end
