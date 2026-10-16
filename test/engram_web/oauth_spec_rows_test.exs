defmodule EngramWeb.OAuthSpecRowsTest do
  @moduledoc """
  Spec requirements the #1977 audit found implemented but unasserted, one
  test each, named by the section it pins. The bigger behaviours live with
  their controllers; these are the small MUSTs that would otherwise break
  silently.
  """
  use EngramWeb.ConnCase, async: true

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth

  @redirect "https://claude.ai/api/mcp/auth_callback"

  defp tokens(user) do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    build_conn()
    |> post("/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => code_from_redirect(url),
      "client_id" => client.client_id,
      "code_verifier" => verifier
    })
    |> json_response(200)
  end

  # RFC 8414 §2: an https URL (https in prod; the test endpoint is http) with
  # no query or fragment.
  test "RFC 8414 §2: issuer has no query or fragment", %{conn: conn} do
    issuer =
      conn
      |> get("/.well-known/oauth-authorization-server")
      |> json_response(200)
      |> Map.fetch!("issuer")

    assert issuer == EngramWeb.Endpoint.url()
    assert %URI{query: nil, fragment: nil} = URI.parse(issuer)
  end

  # RFC 9207 §3: advertised, since every authorization response carries it.
  test "RFC 9207 §3: iss support is advertised", %{conn: conn} do
    metadata = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)
    assert metadata["authorization_response_iss_parameter_supported"] == true
  end

  # RFC 6749 §3.2: the token endpoint is POST only.
  test "RFC 6749 §3.2: GET /oauth/token is refused", %{conn: conn} do
    status = conn |> get("/oauth/token") |> Map.fetch!(:status)
    assert status in [404, 405]
  end

  # OAuth 2.1 §7.1.3 / MCP "Token Theft": short-lived access tokens.
  test "OAuth 2.1 §7.1.3: access tokens live 15 minutes" do
    body = tokens(insert(:user))
    assert body["expires_in"] == 900

    {:ok, claims} = Joken.peek_claims(body["access_token"])
    assert claims["exp"] - claims["iat"] == 900
  end

  # RFC 6750 §2.3 / MCP "Token Requirements": never from the query string.
  test "RFC 6750 §2.3: an access token in the query string is ignored" do
    token = insert(:user) |> tokens() |> Map.fetch!("access_token")
    conn = get(build_conn(), "/api/vaults?access_token=#{token}")
    assert conn.status == 401
  end

  # RFC 6749 §5.1 / §5.2: no-store on every answer, errors included.
  test "RFC 6749 §5.1: no-store on token errors too" do
    for {params, status} <- [
          {%{"grant_type" => "password"}, 400},
          {%{"grant_type" => "authorization_code", "client_id" => Ecto.UUID.generate()}, 401}
        ] do
      conn = post(build_conn(), "/oauth/token", params)
      assert conn.status == status
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  # RFC 6749 §5.2: a failed HTTP Basic client auth answers with a Basic challenge.
  test "RFC 6749 §5.2: bad Basic credentials get a WWW-Authenticate challenge" do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => [@redirect],
        "client_name" => "C",
        "token_endpoint_auth_method" => "client_secret_basic"
      })

    conn =
      build_conn()
      |> put_req_header("authorization", "Basic " <> Base.encode64("#{client.client_id}:wrong"))
      |> post("/oauth/token", %{"grant_type" => "authorization_code", "code" => "x"})

    assert json_response(conn, 401)["error"] == "invalid_client"
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~r/^Basic/
  end

  # CIMD §7.1: an issued client_id must never look like a document URL, or a
  # later CIMD client could be confused with it.
  test "CIMD §7.1: issued client_ids are UUIDs, never https URLs" do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    assert {:ok, _} = Ecto.UUID.cast(client.client_id)
    refute String.starts_with?(client.client_id, "https://")
  end
end
