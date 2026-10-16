defmodule EngramWeb.OAuthIssuerHostTest do
  @moduledoc """
  RFC 9207 `iss` on a non-canonical host (#1977). Prod clients dial
  `mcp.engram.page` or `api.engram.page`, never the canonical endpoint URL, so
  the `:cors_origin` branch of `OAuthMetadata.issuer?/1` is the one that runs
  there. Every other test dials the canonical host and short-circuits past it.
  """
  # async: false: sets the global `:cors_origin`.
  use EngramWeb.ConnCase, async: false

  alias Engram.Auth.Providers.Local
  alias Engram.OAuth
  alias EngramWeb.OAuthMetadata

  @origin "http://mcp.engram.page"
  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    prior = Application.fetch_env(:engram, :cors_origin)
    Application.put_env(:engram, :cors_origin, [@origin])

    # Unset must be restored as unset: a `nil` value crashes every later
    # `x in cors_origin` read.
    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:engram, :cors_origin, value)
        :error -> Application.delete_env(:engram, :cors_origin)
      end
    end)

    :ok
  end

  defp on_mcp_host(conn), do: %{conn | host: "mcp.engram.page"}

  test "iss matches the discovered issuer from authorize through consent", %{conn: conn} do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    user = :user |> insert() |> ensure_external_id()
    insert(:vault, user: user)

    issuer =
      conn
      |> on_mcp_host()
      |> get("/.well-known/oauth-authorization-server")
      |> json_response(200)
      |> Map.fetch!("issuer")

    assert issuer == @origin

    params = %{
      "client_id" => client.client_id,
      "redirect_uri" => @redirect,
      "response_type" => "code",
      "code_challenge" => "abc123challenge",
      "code_challenge_method" => "S256",
      "state" => "s"
    }

    [location] =
      build_conn()
      |> on_mcp_host()
      |> get("/oauth/authorize", params)
      |> get_resp_header("location")

    forwarded = URI.decode_query(URI.parse(location).query)
    assert forwarded["iss"] == issuer

    # Consent arrives on another host (the SPA's API base), canonical here.
    {:ok, token} = Local.issue_access_token(user.external_id, user.email)

    redirect =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/oauth/authorize/consent", forwarded)
      |> json_response(200)
      |> Map.fetch!("redirect_uri")

    assert URI.decode_query(URI.parse(redirect).query)["iss"] == issuer
  end

  test "discovery advertises iss support", %{conn: conn} do
    assert conn
           |> get("/.well-known/oauth-authorization-server")
           |> json_response(200)
           |> Map.fetch!("authorization_response_iss_parameter_supported")
  end

  # RFC 9207 §2: error responses carry it too.
  test "an authorize error redirect carries iss" do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})

    [location] =
      build_conn()
      |> on_mcp_host()
      |> get("/oauth/authorize", %{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "token",
        "code_challenge" => "abc123challenge",
        "code_challenge_method" => "S256"
      })
      |> get_resp_header("location")

    query = URI.decode_query(URI.parse(location).query)
    assert query["error"] == "unsupported_response_type"
    assert query["iss"] == @origin
  end

  # RFC 9207 §2: a consent that ends in an error redirect names the issuer too.
  test "a consent error redirect carries the forwarded iss" do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    user = :user |> insert() |> ensure_external_id()
    insert(:vault, user: user)
    {:ok, token} = Local.issue_access_token(user.external_id, user.email)

    redirect =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/oauth/authorize/consent", %{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge_method" => "S256",
        "state" => "s",
        "iss" => @origin
      })
      |> json_response(200)
      |> Map.fetch!("redirect_uri")

    query = URI.decode_query(URI.parse(redirect).query)
    assert query["error"] == "invalid_request"
    assert query["iss"] == @origin
  end

  # A forged iss is the mix-up attack itself: it makes our response look like
  # another server's, so the client sends the code to that server.
  test "consent drops an issuer that is not ours" do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    user = :user |> insert() |> ensure_external_id()
    insert(:vault, user: user)
    {:ok, token} = Local.issue_access_token(user.external_id, user.email)

    redirect =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/oauth/authorize/consent", %{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => "abc123challenge",
        "code_challenge_method" => "S256",
        "iss" => "https://attacker.example"
      })
      |> json_response(200)
      |> Map.fetch!("redirect_uri")

    query = URI.decode_query(URI.parse(redirect).query)
    assert is_binary(query["code"])
    refute Map.has_key?(query, "iss")
  end

  describe "issuer?/1" do
    test "accepts an allowlisted origin and the canonical URL" do
      assert OAuthMetadata.issuer?(@origin)
      assert OAuthMetadata.issuer?(EngramWeb.Endpoint.url())
    end

    # `base_url/1` never names a scheme's default port, so neither may iss.
    test "refuses a default port spelled out, a path, or a foreign host" do
      refute OAuthMetadata.issuer?(@origin <> ":80")
      refute OAuthMetadata.issuer?(@origin <> "/")
      refute OAuthMetadata.issuer?("http://attacker.example")
      refute OAuthMetadata.issuer?("https://mcp.engram.page")
      refute OAuthMetadata.issuer?(nil)
    end

    test "accepts an allowlisted origin on a non-default port" do
      assert OAuthMetadata.issuer?(@origin <> ":8080")
    end
  end
end
