defmodule EngramWeb.OAuthAuthorizeErrorPagesTest do
  # async: false — the CIMD fetch rate limiter's ETS buckets are node-global and
  # this file resets them, same as Engram.OAuth.CimdTest.
  use EngramWeb.ConnCase, async: false

  import Mox

  alias Engram.OAuth.Cimd.FetcherMock

  setup :verify_on_exit!

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  @cimd_url "https://claude.ai/.well-known/oauth-client"

  defp authorize_params(client_id) do
    %{
      "client_id" => client_id,
      "redirect_uri" => "http://127.0.0.1:9999/callback",
      "response_type" => "code",
      "code_challenge" => "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
      "code_challenge_method" => "S256",
      "scope" => "mcp"
    }
  end

  # Both branches of `GET /oauth/authorize` that answer HTML rather than
  # redirecting. They used to be `send_resp/3` over an interpolated string; they
  # now render `EngramWeb.OAuthAuthorizeHTML`. Either way, the thing worth
  # pinning is that a request actually reaches a rendered page — the 503 branch
  # had no test at all, so a render-time crash on it would have been invisible.
  describe "GET /oauth/authorize HTML error pages" do
    test "the client-error branch renders a 400 HTML page naming the code", %{conn: conn} do
      conn = get(conn, "/oauth/authorize", authorize_params(Ecto.UUID.generate()))

      assert conn.status == 400
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "invalid_client"
      assert conn.resp_body =~ "Authorization error"
    end

    # `{:server_error, _}` is only reachable through a CIMD fetch that fails on
    # OUR side (transport, vendor 5xx, our own fetch limiter) — see
    # Engram.OAuth.cimd_error/1. Nothing else in the authorize path produces it.
    test "the server-error branch renders a 503 HTML page naming the code", %{conn: conn} do
      expect(FetcherMock, :fetch, fn @cimd_url -> {:error, :fetch_failed} end)

      conn = get(conn, "/oauth/authorize", authorize_params(@cimd_url))

      assert conn.status == 503
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "temporarily_unavailable"
      assert conn.resp_body =~ "Authorization temporarily unavailable"
    end
  end
end
