defmodule EngramWeb.OAuthTokenRotationUserNotFoundTest do
  @moduledoc """
  A refresh rotation whose user cannot be loaded.

  At c79fc37e4 the user was loaded AFTER the presented token was consumed and
  its successor inserted, so a miss had two outcomes:

    * a fresh rotation rolled the transaction back, and `rotate_existing/3`'s
      `{:ok, outcome} =` raised `MatchError`: HTTP 500;
    * a replay inside the 60 s grace window fell to `:not_eligible` and killed
      the family as `:refresh_reuse`: a false theft signal.

  Every real cause of a miss is permanent (the user is gone, or a loader rule
  refuses it), so the answer is a terminal 400 `invalid_grant`, reason
  `user_not_found`, decided before anything is written: no row consumed, no
  successor minted, no family killed. A retryable answer would be a retry loop
  on a token that can never work (#2299, #2333).

  On real data a miss cannot happen today (`users` has no RLS, the `:user`
  cache never stores nil, a hard delete cascades the token row away first), so
  the tests delete the user row with FK triggers off, inside the sandbox, and
  evict it from the node cache: the token row stays and the lookup misses.
  (Poisoning the shared `:user` cache instead is racy: other async tests clear
  it, `Engram.DataCase`.)
  """
  use EngramWeb.ConnCase, async: true

  import Ecto.Query
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

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

    ref = make_ref()
    pid = self()

    for event <- [[:engram, :oauth, :token], [:engram, :oauth, :family_revoked]] do
      :telemetry.attach(
        {__MODULE__, ref, event},
        event,
        fn name, _measure, meta, _ -> send(pid, {ref, name, meta}) end,
        nil
      )
    end

    on_exit(fn ->
      for event <- [[:engram, :oauth, :token], [:engram, :oauth, :family_revoked]],
          do: :telemetry.detach({__MODULE__, ref, event})
    end)

    %{user: user, client_id: client.client_id, raw: raw, ref: ref}
  end

  # The user row goes, its refresh tokens stay (FK triggers off, sandbox
  # only), so the rotation's user lookup misses while the token row exists.
  # Evicted after the delete: a concurrent clear only forces the same miss.
  defp fail_user_lookup(user) do
    Repo.query!("SET LOCAL session_replication_role = replica")
    Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
    Repo.query!("SET LOCAL session_replication_role = origin")
    :ok = Engram.Cache.evict_local(:user, user.id)
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

  defp revoked_in_family(family_id) do
    Repo.aggregate(
      from(r in RefreshToken, where: r.family_id == ^family_id and not is_nil(r.revoked_at)),
      :count,
      skip_tenant_check: true
    )
  end

  defp refresh(conn, raw, client_id) do
    post(conn, "/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => raw,
      "client_id" => client_id
    })
  end

  test "a fresh rotation with no user is refused user_not_found and consumes nothing", %{
    user: user,
    client_id: client_id,
    raw: raw
  } do
    fail_user_lookup(user)

    assert OAuth.rotate_refresh_token(raw, client_id, ip: "203.0.113.9") ==
             {:error, {:invalid_grant, :user_not_found}}

    after_row = row(raw)
    assert is_nil(after_row.consumed_at)
    assert is_nil(after_row.revoked_at)
    assert family_size(after_row.family_id) == 1
  end

  test "POST /oauth/token answers a fresh rotation with no user 400 invalid_grant, not 500 or 503",
       %{conn: conn, user: user, client_id: client_id, raw: raw, ref: ref} do
    fail_user_lookup(user)

    conn = refresh(conn, raw, client_id)

    assert json_response(conn, 400) == %{"error" => "invalid_grant"}
    assert get_resp_header(conn, "retry-after") == []

    assert_receive {^ref, [:engram, :oauth, :token],
                    %{
                      grant_type: :refresh_token,
                      result: :rejected,
                      error: "invalid_grant",
                      reason: :user_not_found
                    }}

    assert is_nil(row(raw).consumed_at)
    assert family_size(row(raw).family_id) == 1
  end

  test "a grace-window replay with no user is refused user_not_found and does not kill the family",
       %{conn: conn, user: user, client_id: client_id, raw: raw, ref: ref} do
    %{"refresh_token" => successor} = json_response(refresh(conn, raw, client_id), 200)
    assert_receive {^ref, [:engram, :oauth, :token], %{result: :issued}}

    fail_user_lookup(user)

    conn = refresh(build_conn(), raw, client_id)

    assert json_response(conn, 400) == %{"error" => "invalid_grant"}

    assert_receive {^ref, [:engram, :oauth, :token],
                    %{result: :rejected, error: "invalid_grant", reason: :user_not_found}}

    refute_received {^ref, [:engram, :oauth, :family_revoked], _}

    family_id = row(raw).family_id
    assert revoked_in_family(family_id) == 0
    assert is_nil(row(successor).revoked_at)
    assert family_size(family_id) == 2
  end
end
