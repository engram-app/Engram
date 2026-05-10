defmodule EngramWeb.SpaController do
  use EngramWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, injected_html())
  end

  defp injected_html do
    {pre, post} = cached_split()
    pre <> config_script() <> post
  end

  # Cache the split around </head> so each request only interpolates
  # the (cheap) config script. Config changes are picked up on every
  # request since we never cache the rendered output.
  #
  # In :dev/:test the cache is disabled (see config/dev.exs) so a
  # `vite build` rewriting priv/static/app/index.html with new asset
  # hashes is picked up on the next request without restarting Phoenix.
  defp cached_split do
    if cache_enabled?() do
      case :persistent_term.get({__MODULE__, :split}, nil) do
        nil ->
          split = build_split()
          :persistent_term.put({__MODULE__, :split}, split)
          split

        cached ->
          cached
      end
    else
      build_split()
    end
  end

  defp cache_enabled? do
    Application.get_env(:engram, :spa_cache_enabled?, true)
  end

  defp build_split do
    path = Application.app_dir(:engram, "priv/static/app/index.html")
    html = File.read!(path)

    case String.split(html, "</head>", parts: 2) do
      [pre, rest] -> {pre, "</head>" <> rest}
      [_] -> raise "SPA index.html missing </head> — cannot inject runtime config (#{path})"
    end
  end

  defp config_script do
    provider =
      case Application.get_env(:engram, :auth_provider, :local) do
        :local ->
          "local"

        :clerk ->
          "clerk"

        other ->
          # noqa: T3.0.6 — boot-time raise; value is an app config atom, never user input.
          # noqa: T3.0.6
          raise "Invalid :auth_provider config: #{inspect(other)}"
      end

    config = %{
      authProvider: provider,
      clerkPublishableKey: Application.get_env(:engram, :clerk_publishable_key, "")
    }

    json =
      config
      |> Jason.encode!()
      |> String.replace("</", "<\\/")
      |> String.replace("<!--", "<\\!--")

    ~s[<script>window.__ENGRAM_CONFIG__=#{json};</script>]
  end
end
