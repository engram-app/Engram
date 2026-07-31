defmodule Engram.Http.SsrfGuard do
  @moduledoc """
  Validates an attacker-supplied URL before the server fetches it, and pins the
  fetch to a resolved public address.

  ## Why this exists

  CIMD (`Engram.OAuth.Cimd`) takes a `client_id` URL from an **unauthenticated**
  `/oauth/authorize` request and makes this server fetch it. That is a textbook
  SSRF primitive: without a guard, `client_id=https://169.254.169.254/latest/meta-data/`
  turns our authorization endpoint into a proxy for the instance metadata
  service, and `https://10.0.0.5:6432/` into an internal port scanner.

  ## What it enforces

    * **https only.** No `http`, no `file`, no custom schemes.
    * **Port 443 only.** Rejecting other ports keeps a public-host fetch from
      being aimed at an arbitrary service. Relax this deliberately if a real
      client ever needs it; nothing in the CIMD draft forbids other ports, we
      just have no reason to allow them yet.
    * **No userinfo.** `https://claude.ai@169.254.169.254/` has host
      `169.254.169.254`; a reader sees `claude.ai`. The ambiguity is the bug.
    * **No fragment.** It is never sent to the server, so two `client_id`s
      differing only by fragment would fetch one document as two identities.
    * **Public addresses only.** Every resolved address is checked against the
      reserved IPv4/IPv6 ranges below. If *any* address for the name is
      non-public the whole name is refused, which also covers a split-horizon
      resolver returning one public and one internal answer.
    * **Pinning.** `resolve/1` returns a URL with the host replaced by the
      address it validated. The caller connects to *that*, passing the original
      hostname for SNI and certificate verification (see `Engram.OAuth.Cimd`).
      Handing the *hostname* to the HTTP client instead would re-resolve it, and
      the second answer is free to be `127.0.0.1` — DNS rebinding, where the
      check and the connection disagree.

  ## What it does NOT do

  Redirect following and response-size limits belong to the fetch, not here: a
  redirect is a *new* URL that must come back through `resolve/1`, and a body
  cap needs the streaming response. `Engram.OAuth.Cimd` disables redirects
  outright and caps the body. Rate limiting is also the caller's job.
  """

  import Bitwise

  @max_url_bytes 2048

  @type target :: %{url: String.t(), host: String.t(), ip: :inet.ip_address()}
  @type reason ::
          :invalid_url
          | :url_too_long
          | :not_https
          | :missing_host
          | :userinfo_present
          | :fragment_present
          | :unsupported_port
          | :dns_failure
          | :private_address

  # Reserved IPv4 ranges (IANA special-purpose registry). 240.0.0.0/4 covers
  # 255.255.255.255, so broadcast needs no separate entry.
  @v4_blocked [
    # "this network"
    {{0, 0, 0, 0}, 8},
    # private
    {{10, 0, 0, 0}, 8},
    # CGNAT
    {{100, 64, 0, 0}, 10},
    # loopback
    {{127, 0, 0, 0}, 8},
    # link-local, incl. 169.254.169.254 cloud metadata
    {{169, 254, 0, 0}, 16},
    # private
    {{172, 16, 0, 0}, 12},
    # IETF protocol assignments
    {{192, 0, 0, 0}, 24},
    # TEST-NET-1
    {{192, 0, 2, 0}, 24},
    # 6to4 relay anycast
    {{192, 88, 99, 0}, 24},
    # private
    {{192, 168, 0, 0}, 16},
    # benchmarking
    {{198, 18, 0, 0}, 15},
    # TEST-NET-2
    {{198, 51, 100, 0}, 24},
    # TEST-NET-3
    {{203, 0, 113, 0}, 24},
    # multicast
    {{224, 0, 0, 0}, 4},
    # reserved + broadcast
    {{240, 0, 0, 0}, 4}
  ]

  # Reserved IPv6 ranges. 2002::/16 (6to4) and 2001::/32 (Teredo) are included
  # because both embed an IPv4 address a relay will forward to, so a
  # public-looking v6 address can still land on an internal v4 host.
  @v6_blocked [
    # unspecified
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    # loopback
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    # NAT64
    {{0x64, 0xFF9B, 0, 0, 0, 0, 0, 0}, 96},
    # discard-only
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    # Teredo
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 32},
    # documentation
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    # 6to4
    {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
    # unique local
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    # link-local
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    # multicast
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc """
  Validates `url` and resolves it to a single public address.

  Returns `{:ok, %{url: pinned, host: original_host, ip: address}}` where
  `pinned` has the host replaced by the address literal. Connect to `pinned` and
  pass `host` as the TLS hostname, or certificate verification will fail against
  an IP.
  """
  @spec resolve(term()) :: {:ok, target()} | {:error, reason()}
  def resolve(url) when is_binary(url) do
    with :ok <- check_length(url),
         {:ok, uri} <- parse(url),
         {:ok, ip} <- pin_address(uri.host) do
      {:ok, %{url: pinned_url(uri, ip), host: uri.host, ip: ip}}
    end
  end

  def resolve(_), do: {:error, :invalid_url}

  defp check_length(url) when byte_size(url) > @max_url_bytes, do: {:error, :url_too_long}
  defp check_length(_), do: :ok

  defp parse(url) do
    case URI.new(url) do
      {:ok, uri} -> validate_uri(uri)
      {:error, _} -> {:error, :invalid_url}
    end
  end

  defp validate_uri(%URI{scheme: scheme}) when scheme != "https", do: {:error, :not_https}

  defp validate_uri(%URI{host: host}) when not is_binary(host) or host == "",
    do: {:error, :missing_host}

  # `is_binary` rather than `not is_nil`: URI leaves both fields nil when absent
  # and a string when present, so the positive form says the same thing and keeps
  # credo's negated-guard check happy.
  defp validate_uri(%URI{userinfo: info}) when is_binary(info), do: {:error, :userinfo_present}
  defp validate_uri(%URI{fragment: frag}) when is_binary(frag), do: {:error, :fragment_present}
  defp validate_uri(%URI{port: port}) when port != 443, do: {:error, :unsupported_port}
  defp validate_uri(%URI{} = uri), do: {:ok, uri}

  # An IP literal skips DNS entirely; a name is resolved and every answer
  # checked. Both end at the same address filter.
  defp pin_address(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} -> if public_address?(ip), do: {:ok, ip}, else: {:error, :private_address}
      {:error, :einval} -> resolve_hostname(charlist)
    end
  end

  defp resolve_hostname(charlist) do
    case getaddrs(charlist, :inet) ++ getaddrs(charlist, :inet6) do
      [] ->
        {:error, :dns_failure}

      addresses ->
        # Reject if ANY answer is non-public, not merely the one we would pin.
        # A resolver that returns both a public and an internal address for a
        # name is either split-horizon or hostile, and we cannot tell which.
        if Enum.all?(addresses, &public_address?/1),
          do: {:ok, hd(addresses)},
          else: {:error, :private_address}
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end

  # `URI.to_string/1` brackets a host containing ":" itself, so the literal goes
  # in bare. Adding brackets here yields `https://[[::1]]/`.
  defp pinned_url(uri, ip) do
    URI.to_string(%{uri | host: ip |> :inet.ntoa() |> to_string()})
  end

  @doc """
  True when `address` is a routable public address.

  IPv4-mapped IPv6 (`::ffff:a.b.c.d`) is unwrapped and judged as the IPv4
  address it carries: `::ffff:169.254.169.254` is the metadata service wearing a
  v6 costume.
  """
  @spec public_address?(term()) :: boolean()
  def public_address?({_, _, _, _} = ip), do: not blocked?(ip, @v4_blocked, 8)

  def public_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: public_address?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})

  def public_address?({_, _, _, _, _, _, _, _} = ip), do: not blocked?(ip, @v6_blocked, 16)
  def public_address?(_), do: false

  defp blocked?(ip, ranges, word_bits) do
    value = to_integer(ip, word_bits)
    total_bits = tuple_size(ip) * word_bits

    Enum.any?(ranges, fn {network, prefix_bits} ->
      shift = total_bits - prefix_bits
      value >>> shift == to_integer(network, word_bits) >>> shift
    end)
  end

  defp to_integer(tuple, word_bits) do
    Enum.reduce(Tuple.to_list(tuple), 0, fn part, acc -> (acc <<< word_bits) + part end)
  end
end
