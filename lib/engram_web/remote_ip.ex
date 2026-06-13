defmodule EngramWeb.RemoteIp do
  @moduledoc """
  Resolves the real client IP for rate limiting.

  In prod the request path is Cloudflare → AWS ALB → ECS (Bandit), so
  `conn.remote_ip` is the ALB's private IP — identical for every external
  client. Keying a rate limiter on it collapses every per-IP bucket into one
  shared bucket. The fix is to trust Cloudflare's `CF-Connecting-IP` header,
  which Cloudflare *overwrites* with the true client IP on every proxied
  request (unspoofable through Cloudflare — unlike `X-Forwarded-For`, which it
  appends to and a client can pre-seed).

  ## Trust model — AOP coupling (READ BEFORE CHANGING)

  Trusting that header is only safe because prod enforces **Cloudflare
  Authenticated Origin Pulls (AOP) in `verify` mode** (engram-infra
  `main/envs/prod/aop.tf`, `alb.tf`): the ALB rejects any TLS handshake lacking
  a valid Cloudflare-signed client cert, so every request reaching us provably
  transited Cloudflare. The ALB security group is `0.0.0.0/0` — AOP at the TLS
  layer, NOT a network ACL, is what guarantees CF transit.

  If AOP is ever disabled or set to `passthrough`, `CF-Connecting-IP` becomes
  client-spoofable and `:trust_cf_connecting_ip` MUST be turned off, or the
  rate limiter is bypassable. The flag is default-deny (`config/config.exs`)
  and only flipped on in prod via `runtime.exs` + `TRUST_CF_CONNECTING_IP`.
  Dev / test / self-host / staging-fastraid are not behind Cloudflare+AOP and
  keep using the raw socket IP.
  """

  @header "cf-connecting-ip"

  @doc """
  Returns the client IP as an `:inet.ip_address` tuple.

  When `:trust_cf_connecting_ip` is enabled and the `CF-Connecting-IP` header
  holds a valid address, that address is returned; otherwise (flag off, header
  missing, or header unparseable) it falls back to `conn.remote_ip` — the
  fail-safe direction (over-limit, never bypass).
  """
  @spec resolve(Plug.Conn.t()) :: :inet.ip_address()
  def resolve(%Plug.Conn{} = conn) do
    if Application.get_env(:engram, :trust_cf_connecting_ip, false) do
      cf_connecting_ip(conn) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  defp cf_connecting_ip(conn) do
    case Plug.Conn.get_req_header(conn, @header) do
      [value | _] -> parse_ip(value)
      [] -> nil
    end
  end

  defp parse_ip(value) do
    case value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end
end
