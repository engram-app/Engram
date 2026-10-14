defmodule EngramWeb.OAuthDiscoveryRoutingTest do
  @moduledoc """
  Every OAuth endpoint discovery advertises must route, on every host that
  advertises it (#1974).

  `api.engram.page` advertised `https://api.engram.page/oauth/token` while
  `EngramWeb.Plugs.HostRewrite` rewrote `/oauth/*` there to `/api/oauth/*`,
  which has no such routes: discovery pointed clients at a 404, confirmed live.
  This walks the documents a client actually reads and dials each URL.
  """
  # async: false — sets :host_rewrite and :cors_origin app env.
  use EngramWeb.ConnCase, async: false

  @api_host "api.engram.page"
  @mcp_host "mcp.engram.page"
  @selfhost "engram.example"

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    rewrite = Application.get_env(:engram, :host_rewrite)
    cors = Application.get_env(:engram, :cors_origin)

    Application.put_env(:engram, :host_rewrite, api_host: @api_host, mcp_host: @mcp_host)

    # `OAuthMetadata.base_url/1` only echoes a host it was configured for.
    scheme = URI.parse(EngramWeb.Endpoint.url()).scheme

    Application.put_env(
      :engram,
      :cors_origin,
      Enum.map([@api_host, @mcp_host, @selfhost], &"#{scheme}://#{&1}") ++ List.wrap(cors)
    )

    on_exit(fn ->
      restore(:host_rewrite, rewrite)
      restore(:cors_origin, cors)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:engram, key)
  defp restore(key, value), do: Application.put_env(:engram, key, value)

  @endpoints ~w(authorization_endpoint token_endpoint registration_endpoint revocation_endpoint)

  for host <- [@api_host, @mcp_host, @selfhost] do
    test "every endpoint advertised on #{host} routes" do
      metadata =
        build_conn()
        |> get("http://#{unquote(host)}/.well-known/oauth-authorization-server")
        |> json_response(200)

      for key <- @endpoints do
        url = Map.fetch!(metadata, key)
        assert URI.parse(url).host == unquote(host), "#{key} left the host: #{url}"

        conn =
          if key == "authorization_endpoint",
            do: get(build_conn(), url),
            else: post(build_conn(), url, %{})

        refute conn.status == 404, "#{key} #{url} is a 404 on #{unquote(host)}"
      end
    end
  end
end
