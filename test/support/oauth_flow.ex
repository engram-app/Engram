defmodule Engram.OAuthFlow do
  @moduledoc """
  Drives one MCP connector end to end over the real router: discovery,
  registration (DCR or CIMD), authorize, consent, code exchange, MCP calls,
  refresh, and a grace-window replay (#1977).

  Every other OAuth test mints its code by calling `OAuth` directly, so none of
  them crossed the hop that broke in #1974: the token endpoint, as a real
  client calls it, after a real authorize. This one does.

  Consent goes the way the SPA sends it: the query string of the authorize
  redirect, posted back unchanged. A parameter the controller forgets to
  forward is therefore a failing test here, not a silent drop in prod.

  A vendor is a map:

    * `:registration` - `{:dcr, body}` or `{:cimd, document}`. Copy both from
      real prod `oauth_clients` rows, never guess.
    * `:redirect_uri` - the URI the client sends at runtime. For a loopback
      client this carries the runtime port its registration omits.
    * `:auth` - `:none` or `{:private_key_jwt, private_jwk_map, kid}`.
    * `:authorize` - extra authorize params the vendor sends (`resource`, `scope`).

  CIMD documents and JWKS are served through `FetcherMock`: `SsrfGuard`
  refuses loopback, so a Bypass server could never reach the real fetch path.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Plug.Conn

  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Cimd.Jwks

  @endpoint EngramWeb.Endpoint

  @doc """
  Fetches both discovery documents and checks they agree. Returns the
  authorization-server metadata.
  """
  def discover do
    resource = get_json("/.well-known/oauth-protected-resource/api/mcp")
    server = get_json("/.well-known/oauth-authorization-server")

    # ChatGPT compares `issuer` to the server it was pointed at, byte for byte.
    assert resource["authorization_servers"] == [server["issuer"]]

    for key <- ~w(authorization_endpoint token_endpoint registration_endpoint) do
      assert String.starts_with?(server[key], server["issuer"] <> "/"), key
    end

    assert "S256" in server["code_challenge_methods_supported"]
    Map.put(server, "resource", resource["resource"])
  end

  @doc """
  Registers the vendor and returns its wire `client_id`. CIMD documents (and a
  JWKS, when `jwks` is given) are served through `FetcherMock` for the rest of
  the test.
  """
  def register(vendor, jwks \\ nil)

  def register(%{registration: {:dcr, body}}, _jwks) do
    conn = post(json_conn(), "/oauth/register", body)
    assert %{"client_id" => client_id} = json_response(conn, 201)
    client_id
  end

  def register(%{registration: {:cimd, document}}, jwks) do
    served =
      %{document["client_id"] => document}
      |> then(fn m -> if jwks, do: Map.put(m, document["jwks_uri"], jwks), else: m end)

    Mox.stub(FetcherMock, :fetch, fn url ->
      case Map.fetch(served, url) do
        {:ok, body} -> {:ok, body}
        :error -> {:error, :not_found}
      end
    end)

    document["client_id"]
  end

  @doc """
  Runs authorize and consent for `user`, who must hold a Local access token.
  Returns `{code, verifier}`.
  """
  def authorize(vendor, client_id, user_token) do
    {verifier, challenge} = Engram.OAuthHelpers.pkce_pair()
    state = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    params =
      Map.merge(
        %{
          "client_id" => client_id,
          "redirect_uri" => vendor.redirect_uri,
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => state
        },
        Map.get(vendor, :authorize, %{})
      )

    conn = get(build_conn(), "/oauth/authorize", params)
    assert conn.status == 302, "authorize refused: #{conn.resp_body}"
    [location] = get_resp_header(conn, "location")
    assert location =~ "/oauth/consent?"

    forwarded = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    redirect =
      json_conn()
      |> put_req_header("authorization", "Bearer #{user_token}")
      |> post("/api/oauth/authorize/consent", forwarded)
      |> json_response(200)
      |> Map.fetch!("redirect_uri")

    assert String.starts_with?(redirect, vendor.redirect_uri),
           "redirected to #{redirect}, not the client's #{vendor.redirect_uri}"

    query = redirect |> URI.parse() |> Map.fetch!(:query)
    pairs = URI.query_decoder(query) |> Enum.to_list()

    # A client that reads the first `code` and one that reads the last must agree.
    for key <- ~w(code state), do: assert(Enum.count(pairs, &(elem(&1, 0) == key)) == 1, key)
    refute List.keymember?(pairs, "error", 0)

    decoded = Map.new(pairs)
    assert decoded["state"] == state
    {decoded["code"], verifier}
  end

  @doc "Exchanges the code. Returns the 200 token body."
  def exchange(vendor, client_id, {code, verifier}) do
    token(vendor, client_id, %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => vendor.redirect_uri,
      "code_verifier" => verifier
    })
  end

  @doc "Rotates `refresh_token`. Returns the raw conn so callers can check failures."
  def refresh(vendor, client_id, refresh_token) do
    token_conn(vendor, client_id, %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token
    })
  end

  @doc "POSTs to the token endpoint, asserts a 200, returns the body."
  def token(vendor, client_id, params) do
    conn = token_conn(vendor, client_id, params)
    body = json_response(conn, 200)

    assert is_binary(body["access_token"])
    assert is_binary(body["refresh_token"])
    assert body["token_type"] == "Bearer"
    body
  end

  defp token_conn(vendor, client_id, params) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post("/oauth/token", URI.encode_query(Map.merge(params, credentials(vendor, client_id))))

    # RFC 6749 §5.1: a response carrying tokens MUST NOT be cached.
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    conn
  end

  defp credentials(%{auth: :none}, client_id), do: %{"client_id" => client_id}

  defp credentials(%{auth: {:private_key_jwt, private, kid}}, client_id) do
    now = System.os_time(:second)

    claims = %{
      "iss" => client_id,
      "sub" => client_id,
      "aud" => EngramWeb.Endpoint.url() <> "/oauth/token",
      "jti" => Ecto.UUID.generate(),
      "exp" => now + 300,
      "iat" => now
    }

    {:ok, assertion, _} =
      Joken.encode_and_sign(claims, Joken.Signer.create("RS256", private, %{"kid" => kid}))

    %{
      "client_id" => client_id,
      "client_assertion" => assertion,
      "client_assertion_type" => Jwks.assertion_type()
    }
  end

  @doc "Runs MCP `initialize` and `tools/list` with the access token."
  def mcp_session(access_token) do
    init =
      mcp(access_token, "initialize", %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oauth-flow-test", "version" => "1"}
      })

    assert is_binary(init["result"]["protocolVersion"]), inspect(init)

    tools = mcp(access_token, "tools/list", %{})
    assert [_ | _] = tools["result"]["tools"], inspect(tools)
    :ok
  end

  defp mcp(access_token, method, params) do
    json_conn()
    |> put_req_header("authorization", "Bearer #{access_token}")
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    |> json_response(200)
  end

  defp get_json(path), do: build_conn() |> get(path) |> json_response(200)

  defp json_conn do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end
end
