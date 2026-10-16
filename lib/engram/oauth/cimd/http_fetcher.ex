defmodule Engram.OAuth.Cimd.HttpFetcher do
  @moduledoc """
  Default `Engram.OAuth.Cimd.Fetcher`: applies the SSRF guard, then fetches the
  document with Mint over a connection pinned to the validated address.

  Mint directly, one connection per attempt, no pool. The vendor hostname is
  attacker-chosen (any CIMD `client_id`, wildcard DNS), and TLS must verify
  that NAME on a connection dialed to a pinned IP. Through Req/Finch the
  hostname is a pool option, so every distinct host started a permanent Finch
  instance under a new atom (second review of #1974). A fetch here is rare
  (results are cached and persisted), so a pool buys nothing. See
  `Engram.Http.SsrfGuard` for why the URL is pinned to an address at all.
  """

  @behaviour Engram.OAuth.Cimd.Fetcher

  alias Engram.Http.SsrfGuard
  alias Engram.Logger.Metadata
  alias Engram.OAuth.Cimd.Fetcher

  require Logger

  @max_body_bytes 64 * 1024

  # #1974: one fetch, every address and the retry included, finishes inside
  # 3 s, well under the ~10 s ChatGPT and Claude give the token request. Each
  # connect gets 1.5 s so a black-holed address leaves room for the next one.
  @budget_ms 3_000
  @connect_timeout_ms 1_500

  @user_agent "Engram-OAuth/1.0 (+https://engram.page)"

  @doc "The hard budget for one `fetch_target/1`, every attempt included, in ms."
  @spec budget_ms() :: unquote(@budget_ms)
  def budget_ms, do: @budget_ms

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
  error, a 5xx or a 429. Every attempt shares one #{@budget_ms} ms deadline.
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
        {:error, {:transport_error, _, _}} = error ->
          try_attempts(rest, host, deadline, error)

        # A 5xx or 429 is the vendor's transient trouble: try the next attempt.
        {:error, {:http_status, s}} = error when s >= 500 or s == 429 ->
          try_attempts(rest, host, deadline, error)

        result ->
          result
      end
    end
  end

  # The request runs in its own process so the deadline is HARD: a vendor
  # dribbling a byte every few seconds would otherwise hold the token request
  # open indefinitely. The attempt reports its phase as it goes, so a kill at
  # the deadline still says where it stalled.
  defp attempt(url, ip, host, remaining) do
    parent = self()
    ref = make_ref()
    started = now_ms()
    phase = fn p -> send(parent, {ref, p}) end

    # `async_nolink`: a crash inside the transport must fail this attempt,
    # not the token request that is waiting on it.
    task =
      Task.Supervisor.async_nolink(Engram.TaskSupervisor, fn ->
        request(URI.parse(url), ip, host, started + remaining, phase)
      end)

    result =
      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, {:transport_error, last_phase(ref, :connect), reason_of(reason)}}

        nil ->
          {:error, {:transport_error, last_phase(ref, :connect), :timeout}}
      end

    last_phase(ref, nil)
    log_failure(result, host, ip, now_ms() - started)
    result
  end

  defp request(uri, ip, host, deadline, phase) do
    phase.(:connect)

    case Mint.HTTP1.connect(scheme(uri), ip || uri.host, uri.port,
           mode: :passive,
           # `hostname:` is what makes TLS verify the NAME (and send it as SNI)
           # rather than the address we dialed. Without it the handshake fails
           # against every real vendor.
           hostname: host,
           transport_opts: [timeout: min(@connect_timeout_ms, max(deadline - now_ms(), 1))]
         ) do
      {:ok, conn} ->
        phase.(:recv)

        try do
          get(conn, uri, host, deadline)
        after
          Mint.HTTP1.close(conn)
        end

      # The TLS handshake is part of connect: any failure here is the connect
      # (or the TLS layer, when it says so), never a read.
      {:error, error} ->
        {:error, {:transport_error, connect_phase(error), reason_of(error)}}
    end
  end

  defp get(conn, uri, host, deadline) do
    target = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    headers = [
      {"host", host},
      {"accept", "application/json, application/jwk-set+json"},
      {"user-agent", @user_agent}
    ]

    case Mint.HTTP1.request(conn, "GET", target, headers, nil) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, deadline, %{status: nil, headers: nil, body: ""})

      {:error, _conn, error} ->
        {:error, {:transport_error, :recv, reason_of(error)}}
    end
  end

  # A redirect is a NEW URL, and following it would bypass the guard that
  # approved the first one, so a 3xx is just a status. The body is capped while
  # it streams: checking `byte_size` after the response completes would mean
  # already holding a hostile vendor's whole body in memory.
  defp receive_response(conn, ref, deadline, acc) do
    case Mint.HTTP1.recv(conn, 0, max(deadline - now_ms(), 1)) do
      {:ok, conn, responses} ->
        case Enum.reduce_while(responses, {:cont, acc}, &collect(&1, &2, ref)) do
          {:done, acc} -> finish(acc)
          {:cont, acc} -> receive_response(conn, ref, deadline, acc)
          {:error, _} = error -> error
        end

      {:error, _conn, error, _responses} ->
        {:error, {:transport_error, :recv, reason_of(error)}}
    end
  end

  # A non-200 is decided by its status line: its body is never the document,
  # so reading (and capping) it would only turn a 503 into body_too_large.
  defp collect({:status, ref, 200}, {:cont, acc}, ref), do: {:cont, {:cont, %{acc | status: 200}}}

  defp collect({:status, ref, status}, {:cont, _acc}, ref),
    do: {:halt, {:error, {:http_status, status}}}

  # The first headers frame is the response's; a later one is chunked
  # trailers, which must not replace it (the content-type lives here).
  defp collect({:headers, ref, headers}, {:cont, %{headers: nil} = acc}, ref),
    do: {:cont, {:cont, %{acc | headers: headers}}}

  defp collect({:headers, ref, _trailers}, {:cont, acc}, ref), do: {:cont, {:cont, acc}}

  defp collect({:data, ref, data}, {:cont, acc}, ref) do
    body = acc.body <> data

    if byte_size(body) > @max_body_bytes,
      do: {:halt, {:error, :body_too_large}},
      else: {:cont, {:cont, %{acc | body: body}}}
  end

  defp collect({:done, ref}, {:cont, acc}, ref), do: {:halt, {:done, acc}}
  defp collect(_other, state, _ref), do: {:cont, state}

  defp finish(%{status: 200} = response), do: decode(response)

  defp scheme(%URI{scheme: "http"}), do: :http
  defp scheme(_uri), do: :https

  # Drains the attempt's phase messages and returns the latest, or `default`
  # when the attempt never reported one.
  defp last_phase(ref, default) do
    receive do
      {^ref, phase} -> last_phase(ref, phase)
    after
      0 -> default
    end
  end

  defp connect_phase(%{reason: {:tls_alert, _}}), do: :tls
  defp connect_phase(_error), do: :connect

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

  defp decode(%{body: body} = response) do
    if json_content_type?(response) do
      case Jason.decode(body) do
        {:ok, document} when is_map(document) -> {:ok, put_max_age(document, response)}
        _ -> {:error, :invalid_json}
      end
    else
      {:error, :not_json}
    end
  end

  defp put_max_age(document, %{headers: headers}) do
    case max_age(headers || %{}) do
      nil -> document
      seconds -> Map.put(document, Fetcher.max_age_key(), seconds)
    end
  end

  @doc false
  # Public for its test: Bypass always sends a `cache-control`, so "absent"
  # cannot be produced end to end. `Expires` is ignored; it is legacy.
  @spec max_age(map() | list()) :: non_neg_integer() | nil
  def max_age(headers) do
    directives =
      headers
      |> Enum.flat_map(fn {name, values} ->
        if String.downcase(name) == "cache-control", do: List.wrap(values), else: []
      end)
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    cond do
      Enum.any?(directives, &(&1 in ["no-store", "no-cache"])) -> 0
      seconds = Enum.find_value(directives, &parse_max_age/1) -> seconds
      true -> nil
    end
  end

  defp parse_max_age("max-age=" <> value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end

  defp parse_max_age(_), do: nil

  # `application/json` or any `+json` structured suffix (RFC 6839), which is
  # how a JWKS is properly served: `application/jwk-set+json`.
  defp json_content_type?(%{headers: headers}) do
    (headers || [])
    |> Enum.filter(fn {name, _} -> String.downcase(name) == "content-type" end)
    |> Enum.any?(fn {_name, value} ->
      mime = value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      mime == "application/json" or String.ends_with?(mime, "+json")
    end)
  end
end
