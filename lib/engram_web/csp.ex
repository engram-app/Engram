defmodule EngramWeb.CSP do
  @moduledoc """
  Content-Security-Policy header builder, computed from runtime config.

  Each external integration (Clerk auth, Paddle billing, Cloudflare
  Turnstile) contributes its own host allowlist via a private builder
  function. The aggregator dedups + flattens into the final header
  string. Adding a new integration = adding one builder function and
  one entry in `extra_directives/0`. No CSP edit required when a
  Clerk custom-domain operator deploys to a new tenant zone — the
  host is derived from `:engram, :clerk_issuer` at request time.

  ## Why runtime, not compile-time

  The legacy implementation stored the full CSP string in a module
  attribute (`@csp_policy`) so it was baked into the BEAM at compile
  time. That made custom-domain Clerk impossible: the issuer host
  isn't known until `runtime.exs` reads `CLERK_ISSUER` at boot, after
  modules are already compiled. Pulling the lookup into `header/0`
  costs ~µs per request — Phoenix's existing header pipeline does
  similar map merges on every response.

  ## Test contract

  - `EngramWeb.CSPTest` asserts the function-of-env-var behaviour:
    given `:clerk_issuer`, the rendered header contains the host in
    `script-src` / `connect-src` / `frame-src`. The test does not
    pin the literal CSP string — that would fossilize the policy.
  """

  @static %{
    "default-src" => ["'self'"],
    "script-src" => ["'self'", "'unsafe-inline'"],
    "style-src" => ["'self'", "'unsafe-inline'"],
    "img-src" => ["'self'", "data:", "blob:", "https:"],
    "font-src" => ["'self'", "data:"],
    "connect-src" => ["'self'"],
    "frame-src" => [],
    "worker-src" => ["'self'", "blob:"],
    "form-action" => ["'self'"],
    "base-uri" => ["'self'"],
    "frame-ancestors" => ["'none'"]
  }

  @directive_order [
    "default-src",
    "script-src",
    "style-src",
    "img-src",
    "font-src",
    "connect-src",
    "frame-src",
    "worker-src",
    "form-action",
    "base-uri",
    "frame-ancestors"
  ]

  @doc """
  Render the full Content-Security-Policy header value.

  Returns a single-line string suitable for `put_resp_header/3`.
  Empty directives (e.g. `frame-src` with no integrations contributing)
  are dropped from the output entirely.
  """
  @spec header() :: String.t()
  def header do
    extra_directives()
    |> Enum.reduce(@static, &merge_directives/2)
    |> render()
  end

  # ── Aggregation ────────────────────────────────────────────────────

  defp extra_directives do
    [
      clerk_directives(),
      paddle_directives(),
      turnstile_directives()
    ]
  end

  defp merge_directives(addition, acc) do
    Map.merge(acc, addition, fn _directive, base, more ->
      Enum.uniq(base ++ more)
    end)
  end

  defp render(directives) do
    @directive_order
    |> Enum.map_join("; ", fn name ->
      sources = Map.get(directives, name, [])

      case sources do
        [] -> ""
        list -> name <> " " <> Enum.join(list, " ")
      end
    end)
    |> String.replace(~r/; +;/, ";")
    |> String.replace(~r/;\s*$/, "")
    |> String.replace(~r/^;\s*/, "")
    |> String.replace(~r/(?:^|; )(; )+/, "; ")
  end

  # ── Integrations ───────────────────────────────────────────────────

  # Clerk auth (Frontend API).
  #
  # Static hosts cover Clerk's dev instances (`*.clerk.accounts.dev`)
  # and the legacy multi-tenant Clerk frontend (`*.clerk.com`). The
  # `custom` entry derives the host from `:engram, :clerk_issuer`
  # which `runtime.exs:223` populates from `CLERK_ISSUER` — supports
  # Clerk's "custom domain" feature where each tenant gets a
  # `clerk.<their-zone>` Frontend API host (e.g. `clerk.engram.page`
  # for prod). Without this derivation the prod SPA cannot load
  # `clerk.browser.js` and Clerk auth silently fails.
  defp clerk_directives do
    static = ["https://*.clerk.accounts.dev", "https://*.clerk.com"]
    custom = clerk_custom_domain_host()
    hosts = static ++ custom

    %{
      "script-src" => hosts,
      "connect-src" => hosts,
      "frame-src" => hosts
    }
  end

  defp clerk_custom_domain_host do
    case Application.get_env(:engram, :clerk_issuer) do
      nil ->
        []

      "" ->
        []

      url when is_binary(url) ->
        url
        |> String.trim()
        |> String.trim_trailing("/")
        |> URI.parse()
        |> case do
          %URI{host: host, scheme: scheme}
          when is_binary(host) and host != "" and scheme in ["http", "https"] ->
            ["https://#{host}"]

          _ ->
            []
        end
    end
  end

  # Paddle billing (Checkout overlay + Frontend SDK).
  # Both sandbox and live Paddle environments serve from `*.paddle.com`.
  # PADDLE_ENV (read in runtime.exs:341) selects which Paddle backend
  # API the server calls; the browser-facing CDN hosts are stable.
  defp paddle_directives do
    hosts = ["https://*.paddle.com"]

    %{
      "script-src" => hosts,
      "connect-src" => hosts,
      "frame-src" => hosts
    }
  end

  # Cloudflare Turnstile (Clerk's integrated bot protection).
  # When Clerk is configured to require Turnstile on sign-up/sign-in,
  # the widget loads its frame + script from challenges.cloudflare.com.
  # No `connect-src` entry — the widget reports verification status
  # through Clerk's Frontend API, not directly to Cloudflare.
  defp turnstile_directives do
    hosts = ["https://challenges.cloudflare.com"]

    %{
      "script-src" => hosts,
      "frame-src" => hosts
    }
  end
end
