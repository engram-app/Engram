defmodule Engram.OAuth.Cimd.Fetcher do
  @moduledoc """
  Behaviour for retrieving a CIMD metadata document over the network.

  Split out for the same reason every other outbound integration here is
  (`Engram.Paddle.Client`, `Engram.Auth.Clerk.Api`, `Engram.Storage`): the
  transport is the one part that cannot be exercised without a server, so it sits
  behind a seam and `Engram.OAuth.Cimd`'s policy — the client_id binding, the TTL,
  stale retention, the first-contact race — is tested without touching a socket.

  The seam carries only the transport. Everything security-relevant about *which*
  URLs may be fetched lives in `Engram.Http.SsrfGuard`, which the default
  implementation applies and which has its own tests, so a mocked fetcher cannot
  quietly widen what production will request.

  Implementations: `Engram.OAuth.Cimd.HttpFetcher` (Req-based, default) and
  `Engram.OAuth.Cimd.FetcherMock` (Mox, test env). Dispatch through `impl/0`.
  """

  @doc """
  Fetches and decodes the JSON document at `url`.

  Returns the decoded map on success. Errors are reason atoms suitable for the
  `mcp_cimd_rejected` tripwire (`:not_json`, `:body_too_large`,
  `{:http_status, 404}`, an `Engram.Http.SsrfGuard` reason, …).
  """
  @callback fetch(url :: String.t()) :: {:ok, map()} | {:error, term()}

  @default_impl Engram.OAuth.Cimd.HttpFetcher

  @doc """
  The key under which an implementation MAY report the response's
  `Cache-Control: max-age` (seconds; `no-store`/`no-cache` read as 0) inside
  the returned map. An atom, so it can never collide with a decoded JSON key,
  and callers pop it before treating the map as the document.
  """
  @spec max_age_key() :: atom()
  def max_age_key, do: :__cache_max_age__

  @spec impl() :: module()
  def impl, do: Application.get_env(:engram, :cimd_fetcher, @default_impl)
end
