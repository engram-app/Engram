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
    # One test per transient shape `HttpFetcher` really returns (review #2:
    # the old test mocked `:fetch_failed`, which the fetcher no longer emits,
    # so every real transport error rendered a terminal invalid_client page).
    for reason <- [
          {:transport_error, :connect, :timeout},
          {:transport_error, :connect, :econnrefused},
          {:transport_error, :tls, :tls_alert},
          {:transport_error, :recv, :timeout},
          :dns_failure,
          :budget_exhausted,
          {:http_status, 503},
          {:http_status, 429}
        ] do
      test "a #{inspect(reason)} fetch renders the 503 page", %{conn: conn} do
        expect(FetcherMock, :fetch, fn @cimd_url -> {:error, unquote(Macro.escape(reason))} end)

        conn = get(conn, "/oauth/authorize", authorize_params(@cimd_url))

        assert conn.status == 503
        assert ["text/html" <> _] = get_resp_header(conn, "content-type")
        assert conn.resp_body =~ "temporarily_unavailable"
        assert conn.resp_body =~ "Authorization temporarily unavailable"
      end
    end

    # A name that does not exist will not exist on retry either.
    test "an NXDOMAIN document host is a terminal invalid_client", %{conn: conn} do
      expect(FetcherMock, :fetch, fn @cimd_url -> {:error, :dns_nxdomain} end)

      conn = get(conn, "/oauth/authorize", authorize_params(@cimd_url))
      assert conn.status == 400
      assert conn.resp_body =~ "invalid_client"
    end

    test "a vendor 404 stays a terminal invalid_client", %{conn: conn} do
      expect(FetcherMock, :fetch, fn @cimd_url -> {:error, {:http_status, 404}} end)

      conn = get(conn, "/oauth/authorize", authorize_params(@cimd_url))
      assert conn.status == 400
      assert conn.resp_body =~ "invalid_client"
    end
  end
end
