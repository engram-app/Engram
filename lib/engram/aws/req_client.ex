defmodule Engram.Aws.ReqClient do
  @moduledoc """
  ExAws HTTP client. Delegates to `ExAws.Request.Req`, correcting one req 0.7
  behaviour first.

  ## Why this module exists

  req 0.7 upgrades an explicit `method: :get` to `POST` whenever a non-nil
  `:body` is present. `:method` defaults to `:get`, so req cannot distinguish
  "the caller asked for GET" from "the caller said nothing"; a body present is
  read as "you meant POST". Other verbs are left alone.

  `ExAws.Request.Req` always hands req `""` — never `nil` — for bodyless verbs.
  Under req 0.7 that made every S3 `GetObject` leave as a `POST`, so uploads
  kept returning 200 while every download failed a signature check. That
  asymmetry is what made it read as a flake rather than a break. See #1252.

  Normalising `""` to `nil` restores the verb. Scoped to `:get`/`:head` so
  every other verb keeps its body byte-for-byte, including a legitimately
  empty `PUT`.

  Retire this module and point `:ex_aws, :http_client` back at
  `ExAws.Request.Req` once req stops rewriting the method.
  """

  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(method, url, body, headers, http_opts) do
    ExAws.Request.Req.request(method, url, drop_empty_body(method, body), headers, http_opts)
  end

  # req reads a non-nil body on a GET as "you meant POST"; nil is the only value
  # that leaves the verb alone.
  defp drop_empty_body(method, "") when method in [:get, :head], do: nil
  defp drop_empty_body(_method, body), do: body
end
