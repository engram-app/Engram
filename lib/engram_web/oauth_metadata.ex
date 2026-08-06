defmodule EngramWeb.OAuthMetadata do
  @moduledoc """
  Host-derived OAuth discovery values, shared by everything that has to name
  the MCP resource: the RFC 8414 / RFC 9728 documents `WellKnownController`
  serves, and the RFC 9728 §5.1 challenge `Plugs.McpAuthChallenge` attaches to
  an unauthenticated 401.

  These two must agree exactly. A strict client resolves metadata for the URL
  it dialed and aborts when the document's `resource` does not match, so if the
  challenge pointed at one location and the document advertised another, the
  client would fail *after* successfully fetching both — the least debuggable
  shape of this bug. One module, one derivation.
  """

  @well_known "/.well-known/oauth-protected-resource"

  @doc """
  Base URL for the host the client actually dialed, when that host is in the
  `:cors_origin` allowlist (populated from `PHX_HOST`); otherwise the canonical
  endpoint URL.

  One backend fronts several canonical domains, and a client dialing one must
  not be handed metadata pointing at another. An unvetted `Host` header is
  never reflected — that would let a spoofed Host poison discovery.
  """
  def base_url(conn) do
    canonical = EngramWeb.Endpoint.url()
    scheme = URI.parse(canonical).scheme
    candidate = "#{scheme}://#{conn.host}"

    if candidate in Application.get_env(:engram, :cors_origin, []) do
      # Matched WITHOUT the port on purpose: `:cors_origin` is built from
      # PHX_HOST, which carries hostnames only, so a port-bearing candidate
      # would never match and every deployment would fall back to canonical.
      # `with_port/2` puts it back on the RETURN value — advertising a
      # port-less origin for a deployment reachable on :8080 names somewhere
      # the client never dialed, which strict clients self-check and abort on.
      with_port(candidate, conn)
    else
      canonical
    end
  end

  # `conn.port` is not "the port the client dialed". When the Host header
  # carries no port — the norm — the adapter substitutes the default for the
  # scheme the SOCKET arrived on. Every saas deployment terminates TLS at the
  # edge and speaks plain HTTP to us, so that substituted default is 80 while
  # the advertised scheme is https.
  #
  # Deciding against ONE scheme's default is what broke: gated on the advertised
  # scheme, 80 looked like a real dialed port and got welded onto every URL, and
  # `https://host:80/oauth/token` is a TLS handshake against a plaintext port —
  # not a mismatch a client recovers from, a connection it cannot make at all.
  # Gating on the connection's scheme instead would fix that and break the
  # mirror case, a proxy that forwards `Host: host:443` over a plaintext hop.
  #
  # Both defaults are therefore "no port", which is safe because 80 and 443 are
  # the defaults for the only two schemes we ever serve: a deployment whose URL
  # genuinely needs one of them in it does not exist. Everything else is a port
  # really dialed and is preserved — self-host on `:8080`, a port-mapped
  # container, a reverse proxy on `:8443`, the loopback CI stack on `:4000`.
  #
  # Guarding on `port > 0` covers both nil and the `%Plug.Conn{}` struct
  # default, either of which would otherwise render a trailing bare colon.
  defp with_port(base, %{port: port}) when port in [80, 443], do: base
  defp with_port(base, %{port: port}) when is_integer(port) and port > 0, do: "#{base}:#{port}"
  defp with_port(base, _conn), do: base

  @doc """
  The advertised RFC 9728 `resource`.

  On the saas dedicated MCP host, `HostRewrite` serves MCP at the bare root, so
  the resource is the bare host — users paste `https://mcp.engram.page` with no
  path, and advertising the path made strict clients abort (#634). Everywhere
  else (selfhost `engram.ax`, the `app`/`api` hosts) bare `/` is the SPA and MCP
  lives only at `/api/mcp`, so the path must be kept.
  """
  def resource(conn) do
    if mcp_rewrite_host?(conn), do: base_url(conn), else: base_url(conn) <> "/api/mcp"
  end

  @doc """
  Where the protected-resource metadata for `resource/1` lives, per RFC 9728 §3.1.

  The well-known segment is inserted BEFORE the resource's path, so a resource
  at `https://host/api/mcp` publishes metadata at
  `https://host/.well-known/oauth-protected-resource/api/mcp`. A root resource
  uses the bare well-known path. Deriving this from `resource/1` rather than
  hardcoding it keeps the two forms from drifting apart per host.
  """
  def resource_metadata_url(conn) do
    base = base_url(conn)

    case URI.parse(resource(conn)).path do
      nil -> base <> @well_known
      "/" -> base <> @well_known
      path -> base <> @well_known <> path
    end
  end

  @doc """
  True only on the saas dedicated MCP host that `HostRewrite` serves at the bare
  root. Selfhost leaves `:host_rewrite` unset, so this is always false there.
  """
  def mcp_rewrite_host?(conn) do
    case Application.get_env(:engram, :host_rewrite, []) do
      opts when is_list(opts) -> opts[:mcp_host] != nil and conn.host == opts[:mcp_host]
      _ -> false
    end
  end
end
