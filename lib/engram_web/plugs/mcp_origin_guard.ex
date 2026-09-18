defmodule EngramWeb.Plugs.McpOriginGuard do
  @moduledoc """
  Refuses an MCP request whose `Origin` is not allowlisted, with HTTP 403.

  `2025-11-25` made the status explicit ("servers must respond with HTTP 403
  Forbidden for invalid Origin headers in Streamable HTTP transport"), and
  `mcpjam`'s `localhost-host-rebinding-rejected` check has flagged us for it
  since 2026-08-05 (#1259 finding 2).

  ## The threat

  DNS rebinding against a LOCALLY BOUND server. An attacker page resolves its
  own hostname to `127.0.0.1`, so the browser connects to the Engram the user
  runs on their own machine and sends `Origin: https://evil.example`. Bearer
  auth does not help: the attack is aimed at an instance the victim already has
  a token for, or at a self-host deployment that trusts localhost.

  SaaS sits behind Cloudflare with a fixed hostname, so the exposure is smaller
  there. `engram.ax` self-host is precisely the deployment shape the check
  describes.

  ## Why an ABSENT Origin is allowed

  This is the load-bearing decision, and inverting it would be the obvious
  mistake. Every real MCP client — Claude Code, Claude Desktop, ChatGPT,
  `mcpjam`, `curl` — is a non-browser and sends no `Origin` at all. Only a
  browser attaches one, and a browser is the only thing DNS rebinding can
  drive. So refusing an absent `Origin` would reject every legitimate client
  while defending against nothing.

  A present-but-wrong `Origin` is the signal. It means a browser, on a page we
  did not serve, is talking to us.

  ## Why `Origin` and not `Host`

  `Host` is rewritten by every proxy in front of us and legitimately varies
  (`api.`/`mcp.`/`staging.`), so validating it risks refusing a valid
  deployment. `Origin` is set by the browser itself and cannot be forged from
  page JavaScript, which makes it the tighter check for exactly this attack.

  Placed BEFORE `:authed_api` so a rebinding probe is refused on its own terms
  rather than reaching auth. `Plugs.McpErrorEnvelope` rewrites the body into
  JSON-RPC, so a client sees a protocol error rather than a REST shape.
  """

  import Plug.Conn

  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      # No Origin: a non-browser client. See the moduledoc — this is every real
      # MCP client, and the rebinding attack cannot reach here.
      [] ->
        conn

      [origin | _] ->
        if allowed?(origin), do: conn, else: refuse(conn)
    end
  end

  # `"*"` (the dev/CI default when PHX_HOST is unset) disables the check, so
  # local development and the CI stack are unaffected. A deployment that
  # configures `:cors_origin` opts in by doing so.
  defp allowed?(origin) do
    case Application.get_env(:engram, :cors_origin, "*") do
      "*" -> true
      # An explicit nil means the key is present but unconfigured, which
      # `get_env/3`'s default does NOT cover. Same meaning as unset.
      nil -> true
      configured when is_binary(configured) -> origin == configured
      allowlist when is_list(allowlist) -> origin in allowlist
    end
  end

  # Telemetry, NOT a log line — the same call this repo already makes for
  # `Plugs.RateLimit`, which is "deliberately unlogged ... so the metric tag is
  # the whole signal" (#1643).
  #
  # Two reasons here. This plug sits BEFORE `PreAuthRateLimit`, so a refusal is
  # unauthenticated and unthrottled: one log line per request is an ingest bill
  # an attacker controls. And the rejected `Origin` is attacker-supplied free
  # text, so emitting it invites log injection and unbounded cardinality. The
  # count is the whole signal — nothing actionable is lost.
  defp refuse(conn) do
    :telemetry.execute([:engram, :abuse, :mcp_origin_rejected], %{count: 1}, %{})

    Halt.json(conn, 403, %{"error" => "origin_not_allowed"})
  end
end
