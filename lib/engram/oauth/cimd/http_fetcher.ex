defmodule Engram.OAuth.Cimd.HttpFetcher do
  @moduledoc """
  Default `Engram.OAuth.Cimd.Fetcher`: applies the SSRF guard, then fetches the
  document with Req over a connection pinned to the validated address.

  Every option in `request_options/1` is load-bearing. See `Engram.Http.SsrfGuard`
  for why the URL is pinned to an address at all.
  """

  @behaviour Engram.OAuth.Cimd.Fetcher

  alias Engram.Http.SsrfGuard
  alias Engram.Logger.Metadata

  require Logger

  @max_body_bytes 64 * 1024

  # #1974: one fetch, every address and the retry included, finishes inside
  # 3 s, well under the ~10 s ChatGPT and Claude give the token request. Each
  # connect gets 1.5 s so a black-holed address leaves room for the next one.
  @budget_ms 3_000
  @connect_timeout_ms 1_500

  @user_agent "Engram-OAuth/1.0 (+https://engram.page)"

  @typedoc "A validated, address-pinned fetch target."
  @type target :: %{
          required(:url) => String.t(),
          required(:host) => String.t(),
          optional(:ips) => [:inet.ip_address()],
          optional(any) => any
        }

  @typedoc """
  Where a transport failure happened. `:connect` covers TCP and the TLS
  handshake unless the TLS layer said so itself; `:recv` is a response that
  started (or never came) inside the budget.
  """
  @type phase :: :connect | :tls | :recv

  @impl true
  def fetch(url) do
    with {:ok, target} <- SsrfGuard.resolve(url) do
      fetch_target(target)
    end
  end

  @doc """
  Fetches an already-validated target.

  Public so the transport's own behaviour — the body cap, the content-type check,
  a non-200, a redirect it must not follow, failover and the time budget — can
  be tested against a local server. `Engram.Http.SsrfGuard` would never
  *produce* a loopback target, which is exactly why the guard is applied in
  `fetch/1` and not here: one function decides what may be fetched, the other
  fetches what it is handed.

  Tries each address in `target.ips` (or the pinned `url` alone) in order, then
  the first once more, stopping at the first answer that is not a transport
  error. Every attempt shares one #{@budget_ms} ms deadline.
  """
  @spec fetch_target(target()) :: {:ok, map()} | {:error, term()}
  def fetch_target(target) do
    deadline = now_ms() + @budget_ms
    [first | _] = candidates = attempts(target)
    try_attempts(candidates ++ [first], target.host, deadline, {:error, :budget_exhausted})
  end

  defp attempts(%{ips: [_ | _] = ips, url: url}),
    do: Enum.map(ips, &{SsrfGuard.pin_url(url, &1), &1})

  defp attempts(%{url: url}) do
    ip =
      case :inet.parse_address(String.to_charlist(URI.parse(url).host || "")) do
        {:ok, ip} -> ip
        _ -> nil
      end

    [{url, ip}]
  end

  defp try_attempts([], _host, _deadline, last), do: last

  defp try_attempts([{url, ip} | rest], host, deadline, last) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      last
    else
      case attempt(url, ip, host, remaining) do
        {:error, {:transport_error, _, _}} = error -> try_attempts(rest, host, deadline, error)
        result -> result
      end
    end
  end

  # The request runs in its own process so the deadline is HARD: Req's
  # `receive_timeout` is per read, and a vendor dribbling a byte every few
  # seconds would otherwise hold the token request open indefinitely.
  defp attempt(url, ip, host, remaining) do
    parent = self()
    ref = make_ref()
    started = now_ms()

    # `async_nolink`: a crash inside Req must fail this attempt, not the
    # token request that is waiting on it.
    task =
      Task.Supervisor.async_nolink(Engram.TaskSupervisor, fn ->
        request(url, host, remaining, fn -> send(parent, {ref, :recv}) end)
      end)

    result =
      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, %Req.Response{status: 200} = response}} ->
          decode(response)

        {:ok, {:ok, %Req.Response{status: status}}} ->
          {:error, {:http_status, status}}

        {:ok, {:error, exception}} ->
          {:error, {:transport_error, phase_of(exception), reason_of(exception)}}

        {:exit, reason} ->
          {:error, {:transport_error, :connect, reason_of(reason)}}

        nil ->
          {:error, {:transport_error, :recv, :timeout}}
      end

    flush_progress(ref)
    log_failure(result, host, ip, now_ms() - started)
    result
  end

  defp request(url, host, remaining, on_progress) do
    Req.get(request_options(url, host, remaining, on_progress))
  end

  defp request_options(url, host, remaining, on_progress) do
    [
      # The pinned address, with the real hostname supplied separately.
      url: url,
      headers: [
        {"host", host},
        {"accept", "application/json, application/jwk-set+json"},
        {"user-agent", @user_agent}
      ],
      # `hostname:` is what makes TLS verify the NAME rather than the address.
      # Without it the handshake fails against every real vendor, because the
      # certificate does not cover the IP we dialed.
      connect_options: [hostname: host, timeout: min(@connect_timeout_ms, remaining)],
      # Just past the hard deadline, so the deadline (and its `:recv` phase)
      # is what fires, not Req's per-read timer.
      receive_timeout: remaining + 100,
      # The Finch pool key includes the pinned address, so a long-lived idle pool
      # per vendor IP is pure accumulation.
      pool_max_idle_time: 30_000,
      # A redirect is a NEW URL, and following it would bypass the guard that
      # approved the first one. A vendor that redirects its metadata document
      # therefore does not work, which is the correct outcome.
      redirect: false,
      retry: false,
      decode_body: false,
      into: fn chunk, acc ->
        on_progress.()
        collect_capped(chunk, acc)
      end
    ]
  end

  defp flush_progress(ref) do
    receive do
      {^ref, :recv} -> flush_progress(ref)
    after
      0 -> :ok
    end
  end

  defp phase_of(%{reason: {:tls_alert, _}}), do: :tls
  defp phase_of(%{reason: :closed}), do: :recv
  defp phase_of(_exception), do: :connect

  # Only the exception's REASON, which is an atom or a small tagged tuple from
  # the transport. Never `Exception.message/1`: it may echo the URL.
  defp reason_of(%{reason: reason}) when is_atom(reason), do: reason
  defp reason_of(%{reason: {tag, _}}) when is_atom(tag), do: tag
  defp reason_of(reason) when is_atom(reason), do: reason
  defp reason_of(_other), do: :unknown

  # One line per failed attempt, so a failover that ends in success still
  # shows which address stalled. This is the evidence the 2026-10-13 timeout
  # did not leave (#1974).
  defp log_failure({:error, {:transport_error, phase, reason}}, host, ip, duration_ms) do
    Logger.warning(
      "mcp_cimd_fetch_failed",
      Metadata.with_category(:warning, :lifecycle,
        cimd_host: host,
        dialed_ip: ip && to_string(:inet.ntoa(ip)),
        family: family(ip),
        phase: phase,
        reason: inspect(reason),
        duration_ms: duration_ms
      )
    )
  end

  defp log_failure(_result, _host, _ip, _duration_ms), do: :ok

  defp family({_, _, _, _}), do: :inet
  defp family({_, _, _, _, _, _, _, _}), do: :inet6
  defp family(_), do: nil

  defp now_ms, do: System.monotonic_time(:millisecond)

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

  # `application/json` or any `+json` structured suffix (RFC 6839), which is
  # how a JWKS is properly served: `application/jwk-set+json`.
  defp json_content_type?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(fn value ->
      mime = value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      mime == "application/json" or String.ends_with?(mime, "+json")
    end)
  end
end
