defmodule Engram.Storage.ExAwsHackney do
  @moduledoc """
  ex_aws HTTP client backed by `:hackney`.

  Identical to the stock `ExAws.Request.Hackney` adapter for responses that
  carry a body (the 4-tuple `{:ok, status, headers, body}` — GET/PUT), but it
  also handles hackney 4.x's 3-tuple `{:ok, status, headers}` reply for
  body-less responses (HEAD requests, e.g. `ExAws.S3.head_object/2` behind
  `Engram.Storage.S3.exists?/1`).

  The stock adapter only matches the 4-tuple, so a HEAD on hackney >= 4.0
  raises `CaseClauseError` even though ex_aws 2.7.0 advertises `hackney ~> 4.0`
  support. This shim is the minimal fix: it keeps hackney's exact request
  semantics (MinIO path-style, TLS opts) and only adds the missing clause.
  Remove it once ex_aws ships a hackney-4-aware adapter.

  Configured via `config :ex_aws, :http_client, Engram.Storage.ExAwsHackney`.
  """
  @behaviour ExAws.Request.HttpClient

  @default_opts [recv_timeout: 30_000]

  @impl true
  def request(method, url, body \\ "", headers \\ [], http_opts \\ []) do
    opts = http_opts ++ Application.get_env(:ex_aws, :hackney_opts, @default_opts)

    case :hackney.request(method, url, headers, body, opts) do
      {:ok, status, resp_headers, resp_body} ->
        {:ok, %{status_code: status, headers: resp_headers, body: resp_body}}

      # hackney >= 4.0 omits the body element for body-less responses (HEAD).
      {:ok, status, resp_headers} ->
        {:ok, %{status_code: status, headers: resp_headers, body: ""}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end
end
