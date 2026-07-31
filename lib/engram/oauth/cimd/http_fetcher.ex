defmodule Engram.OAuth.Cimd.HttpFetcher do
  @moduledoc """
  Default `Engram.OAuth.Cimd.Fetcher`: applies the SSRF guard, then fetches the
  document with Req over a connection pinned to the validated address.

  Every option in `request_options/1` is load-bearing. See `Engram.Http.SsrfGuard`
  for why the URL is pinned to an address at all.
  """

  @behaviour Engram.OAuth.Cimd.Fetcher

  alias Engram.Http.SsrfGuard

  @max_body_bytes 64 * 1024
  @timeout_ms 5_000

  @typedoc "A validated, address-pinned fetch target."
  @type target :: %{
          required(:url) => String.t(),
          required(:host) => String.t(),
          optional(any) => any
        }

  @impl true
  def fetch(url) do
    with {:ok, target} <- SsrfGuard.resolve(url) do
      fetch_target(target)
    end
  end

  @doc """
  Fetches an already-validated target.

  Public so the transport's own behaviour — the body cap, the content-type check,
  a non-200, a redirect it must not follow — can be tested against a local
  server. `Engram.Http.SsrfGuard` would never *produce* a loopback target, which
  is exactly why the guard is applied in `fetch/1` and not here: one function
  decides what may be fetched, the other fetches what it is handed.
  """
  @spec fetch_target(target()) :: {:ok, map()} | {:error, term()}
  def fetch_target(target) do
    case Req.get(request_options(target)) do
      {:ok, %Req.Response{status: 200} = response} -> decode(response)
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, _exception} -> {:error, :fetch_failed}
    end
  end

  defp request_options(target) do
    [
      # The pinned address, with the real hostname supplied separately.
      url: target.url,
      headers: [{"host", target.host}, {"accept", "application/json"}],
      # `hostname:` is what makes TLS verify the NAME rather than the address.
      # Without it the handshake fails against every real vendor, because the
      # certificate does not cover the IP we dialed.
      connect_options: [hostname: target.host, timeout: @timeout_ms],
      receive_timeout: @timeout_ms,
      # The Finch pool key includes the pinned address, so a long-lived idle pool
      # per vendor IP is pure accumulation.
      pool_max_idle_time: 30_000,
      # A redirect is a NEW URL, and following it would bypass the guard that
      # approved the first one. A vendor that redirects its metadata document
      # therefore does not work, which is the correct outcome.
      redirect: false,
      retry: false,
      decode_body: false,
      into: &collect_capped/2
    ]
  end

  # Halting mid-stream is the point. Checking `byte_size` after the response
  # completes would mean already holding a hostile vendor's whole body in memory.
  defp collect_capped({:data, data}, {request, response}) do
    body = response.body <> data

    if byte_size(body) > @max_body_bytes,
      do: {:halt, {request, %{response | body: :too_large}}},
      else: {:cont, {request, %{response | body: body}}}
  end

  defp decode(%Req.Response{body: :too_large}), do: {:error, :body_too_large}

  defp decode(%Req.Response{body: body} = response) when is_binary(body) do
    if json_content_type?(response) do
      case Jason.decode(body) do
        {:ok, document} when is_map(document) -> {:ok, document}
        _ -> {:error, :invalid_json}
      end
    else
      {:error, :not_json}
    end
  end

  defp decode(_), do: {:error, :invalid_json}

  defp json_content_type?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn value ->
      value |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
        "application/json"
    end)
  end
end
