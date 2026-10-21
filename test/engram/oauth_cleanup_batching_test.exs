defmodule Engram.OAuthCleanupBatchingTest do
  # Guard: the hourly OAuth token reap runs one short transaction per user.
  #
  # It used to take every affected user's grant lock and FOR UPDATE every row
  # in ONE transaction, so the transaction (and the locks it holds against
  # sign-ins and refreshes) grew with the number of users in the sweep
  # (2026-10-20 audit, P1-5). The lock order inside each transaction is
  # unchanged: grant lock first, then rows by id (OAuthRotationRaceTest).
  use Engram.DataCase, async: true

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.QueryRecorder

  test "each affected user's tokens are deleted in a transaction of their own" do
    long_ago = DateTime.add(DateTime.utc_now(:second), -8 * 24 * 3600, :second)
    client = insert(:oauth_client)

    users =
      for _ <- 1..3 do
        user = insert(:user)

        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          revoked_at: long_ago
        )

        user
      end

    {_, queries} = QueryRecorder.record(fn -> OAuth.cleanup_expired() end)

    locking =
      queries
      |> QueryRecorder.transactions()
      |> Enum.filter(fn stmts -> Enum.any?(stmts, &(&1 =~ "pg_advisory_xact_lock")) end)

    assert length(locking) == 3, QueryRecorder.format(queries)

    for stmts <- locking do
      assert Enum.count(stmts, &(&1 =~ "pg_advisory_xact_lock")) == 1
    end

    ids = Enum.map(users, & &1.id)

    refute Repo.exists?(from(t in RefreshToken, where: t.user_id in ^ids),
             skip_tenant_check: true
           )
  end
end
