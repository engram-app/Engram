defmodule EngramWeb.ClearCacheController do
  @moduledoc """
  Answers `Clear-Site-Data: "cache"` so a signing-out browser drops its HTTP
  cache for this origin. `GET /api/vault/tree` is `private, no-cache` with an
  ETag, so the browser keeps the signed-out user's tree on disk otherwise.

  The local provider's logout sets the header itself; Clerk signs out
  client-side, so the SPA calls this. Unauthenticated by design: the only
  effect is on the caller's own browser cache.
  """
  use EngramWeb, :controller

  def create(conn, _params) do
    conn
    |> clear_http_cache()
    |> send_resp(204, "")
  end

  @doc "Adds the `Clear-Site-Data: \"cache\"` header."
  def clear_http_cache(conn), do: put_resp_header(conn, "clear-site-data", ~s("cache"))
end
