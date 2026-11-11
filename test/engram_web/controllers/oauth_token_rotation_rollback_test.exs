defmodule EngramWeb.OAuthTokenRotationRollbackTest do
  @moduledoc """
  A refresh rotation whose transaction rolls back changed nothing: the
  presented token is still unconsumed and still valid. Before the fix,
  `rotate_existing/3` matched `{:ok, outcome} =` on the transaction, so the
  rollback raised a `MatchError` and the token endpoint answered 500.

  It must be retryable, never `invalid_grant`: `invalid_grant` makes clients
  drop the connection and the user reconnect by hand (#2299, #2333).

  The only rollback (`Repo.rollback/1` in `decide/2`) fires when the token's
  user cannot be loaded AFTER the successor insert passed its `user_id` FK
  check, in the same transaction. On real data that cannot happen (the insert
  holds a key-share lock on the user row), so the test makes the user lookup
  fail through the node cache (`Accounts.get_user/1` reads `:user` first), the
  one input to it that is not the database. A user row deleted outright fails
  earlier, at that FK, and is not this path.
  """
  use EngramWeb.ConnCase, async: true

  import Ecto.Query
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]
  import ExUnit.CaptureLog

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  setup do
    user = insert(:user)

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

    redirect_uri = hd(client.redirect_uris)
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    {:ok, %{refresh_token: raw}} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    %{user: user, client_id: client.client_id, raw: raw}
  end

  # The rotation's user lookup answers "no such user" while the row exists,
  # so `decide/2` rolls the transaction back after consuming and minting.
  defp fail_user_lookup(user) do
    :ok = Engram.Cache.put(:user, user.id, nil)
    on_exit(fn -> Engram.Cache.evict_local(:user, user.id) end)
  end

  defp row(raw) do
    hash = Engram.Crypto.sha256_hex(raw)
    Repo.one!(from(r in RefreshToken, where: r.token_hash == ^hash), skip_tenant_check: true)
  end

  defp family_size(family_id) do
    Repo.aggregate(from(r in RefreshToken, where: r.family_id == ^family_id), :count,
      skip_tenant_check: true
    )
  end

  test "a rolled-back rotation is temporarily_unavailable, and changes nothing", %{
    user: user,
    client_id: client_id,
    raw: raw
  } do
    fail_user_lookup(user)
    before = row(raw)

    {result, log} =
      with_log(fn -> OAuth.rotate_refresh_token(raw, client_id, ip: "203.0.113.9") end)

    assert result == {:error, :temporarily_unavailable}
    assert log =~ "oauth_refresh_rotation_rolled_back"
    assert log =~ "user_not_found"

    after_row = row(raw)
    assert is_nil(after_row.consumed_at)
    assert is_nil(after_row.revoked_at)
    assert family_size(before.family_id) == 1
  end

  test "POST /oauth/token answers 503 temporarily_unavailable with Retry-After, not 500 or invalid_grant",
       %{conn: conn, user: user, client_id: client_id, raw: raw} do
    fail_user_lookup(user)
    ref = make_ref()
    pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :oauth, :token],
      fn _event, _measure, meta, _ -> send(pid, {ref, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    conn =
      post(conn, "/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => raw,
        "client_id" => client_id
      })

    assert json_response(conn, 503) == %{"error" => "temporarily_unavailable"}
    assert get_resp_header(conn, "retry-after") == ["2"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert_receive {^ref,
                    %{
                      grant_type: :refresh_token,
                      result: :rejected,
                      error: "temporarily_unavailable",
                      reason: :rotation_rolled_back
                    }}

    assert is_nil(row(raw).consumed_at)
  end
end
