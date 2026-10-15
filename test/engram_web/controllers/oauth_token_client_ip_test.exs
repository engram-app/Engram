defmodule EngramWeb.OAuthTokenClientIpTest do
  @moduledoc """
  The token endpoint records the CLIENT's IP (CF-Connecting-IP behind the
  edge), not the load balancer's: the grace re-issue's `ip_matched` compares
  them, and behind an ALB `conn.remote_ip` is the same for every caller.
  """
  # async: false — flips the global :trust_cf_connecting_ip flag.
  use EngramWeb.ConnCase, async: false

  import Ecto.Query
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]
  import ExUnit.CaptureLog

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  setup do
    previous = Application.get_env(:engram, :trust_cf_connecting_ip)
    Application.put_env(:engram, :trust_cf_connecting_ip, true)
    on_exit(fn -> Application.put_env(:engram, :trust_cf_connecting_ip, previous) end)

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

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

    user = insert(:user)
    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    tokens =
      "198.51.100.1"
      |> conn_from()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code_from_redirect(url),
        "redirect_uri" => hd(client.redirect_uris),
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })
      |> json_response(200)

    %{client: client, user: user, refresh: tokens["refresh_token"]}
  end

  defp conn_from(ip), do: put_req_header(build_conn(), "cf-connecting-ip", ip)

  defp refresh(ip, client, raw) do
    post(conn_from(ip), "/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => raw,
      "client_id" => client.client_id
    })
  end

  defp live_row(user) do
    Repo.one!(
      from(r in RefreshToken,
        where: r.user_id == ^user.id and is_nil(r.consumed_at) and is_nil(r.revoked_at)
      ),
      skip_tenant_check: true
    )
  end

  test "the exchange and each rotation record the CF client IP", ctx do
    assert live_row(ctx.user).last_used_ip == "198.51.100.1"

    assert %{status: 200} = refresh("203.0.113.7", ctx.client, ctx.refresh)
    assert live_row(ctx.user).last_used_ip == "203.0.113.7"
  end

  test "a grace re-issue from a different client IP logs ip_matched=false", ctx do
    assert %{status: 200} = refresh("203.0.113.7", ctx.client, ctx.refresh)

    log =
      capture_log(fn ->
        assert %{status: 200} = refresh("192.0.2.55", ctx.client, ctx.refresh)
      end)

    assert log =~ "oauth_refresh_grace_reissue"
    assert log =~ "ip_matched=false"
  end
end
