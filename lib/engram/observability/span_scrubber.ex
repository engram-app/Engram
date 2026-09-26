defmodule Engram.Observability.SpanScrubber do
  @moduledoc """
  Span processor that strips user data from HTTP span attributes before any
  span can be exported to Tempo (a third party).

  `opentelemetry_bandit` stamps the raw `conn.request_path` as `url.path`, the
  raw query string as `url.query`, and the full client IP as `client.address`.
  Wildcard routes (`/api/notes/*path`, `/api/folders/*path`, `/note/*path`, …)
  embed note and folder names in the path, so every such request shipped the
  plaintext name the database only holds encrypted.

  Runs in `on_start`, which the SDK folds over every processor in order and
  whose return value is the span that gets recorded, so it must be listed
  BEFORE the exporting processor (see `config/runtime.exs`). The sampler runs
  even earlier and still sees the raw path, which is fine: it is in-process
  only and `Engram.Observability.TraceSampler` matches fixed probe paths.

  What a scrubbed span keeps:

    * `url.path` - the route template (`/api/notes/*path`), `"unmatched"` for
      anything the router does not know (a 404 can carry any string), or the
      path itself for the fixed socket-upgrade paths.
    * `engram.path.ref` - 12 hex chars of a keyed HMAC of the raw path, so
      "was it the same note?" stays answerable without the name.
    * `engram.path.depth` / `engram.path.ext` - wildcard segment count and
      file extension, enough to triage ("a depth-4 .png upload 502'd").
    * `client.address` / `network.peer.address` - truncated to /24 or /48.

  `url.query` is dropped outright: it carries device-link codes, `return_to`
  note paths and folder filters.
  """

  @behaviour :otel_span_processor

  require Record
  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @span_fields)

  @path :"url.path"
  @query :"url.query"
  @method :"http.request.method"
  @ip_keys [:"client.address", :"network.peer.address"]

  @socket_path ~r{\A/socket(/[a-z][a-z_-]*)*/(websocket|longpoll)\z}

  # Allowlisted, never derived: the last segment is user-chosen and still
  # URL-encoded, so `Dr.%20Smith` or `Q3.Layoffs` would otherwise leak the
  # tail of a name through `Path.extname/1`.
  @known_exts ~w(md canvas base pdf png jpg jpeg gif webp svg bmp avif heic
                 mp3 wav m4a ogg flac mp4 webm mov mkv txt csv json zip)

  # Fallback limits (the SDK defaults) if `otel_attributes`' private record
  # ever changes shape.
  @default_count_limit 128

  @impl :otel_span_processor
  def on_start(_ctx, span(attributes: attributes) = s, _config) when attributes != :undefined do
    span(s, attributes: scrub_attributes(attributes))
  end

  def on_start(_ctx, s, _config), do: s

  @impl :otel_span_processor
  def on_end(_span, _config), do: true

  @impl :otel_span_processor
  def force_flush(_config), do: :ok

  defp scrub_attributes(attributes) do
    map = :otel_attributes.map(attributes)

    if sensitive?(map) do
      {count_limit, length_limit} = limits(attributes)
      map |> scrub() |> :otel_attributes.new(count_limit, length_limit)
    else
      attributes
    end
  end

  # Keep the span's configured limits, so later set_attributes calls on this
  # span stay capped. The record is private to otel_attributes.erl:
  # {attributes, count_limit, value_length_limit, dropped, map}.
  defp limits({:attributes, count_limit, length_limit, _dropped, _map}),
    do: {count_limit, length_limit}

  defp limits(_), do: {@default_count_limit, :infinity}

  defp sensitive?(map), do: Enum.any?([@path, @query | @ip_keys], &Map.has_key?(map, &1))

  @doc """
  Scrub a span attribute map. Pure and total: any shape it does not recognise
  loses the sensitive key rather than passing it through (fail closed).
  """
  @spec scrub(map()) :: map()
  def scrub(attrs) when is_map(attrs) do
    attrs
    |> Map.delete(@query)
    |> scrub_path()
    |> scrub_ips()
  end

  defp scrub_path(%{@path => path} = attrs) when is_binary(path) do
    method = attrs |> Map.get(@method) |> method_string()

    cond do
      Regex.match?(@socket_path, path) ->
        attrs

      route = method && route_template(method, path) ->
        attrs
        |> Map.put(@path, route)
        |> put_path_shape(route, path)

      true ->
        Map.put(attrs, @path, "unmatched")
    end
  end

  defp scrub_path(%{@path => _} = attrs), do: Map.put(attrs, @path, "unmatched")
  defp scrub_path(attrs), do: attrs

  defp method_string(m) when is_atom(m) and m not in [nil, :_OTHER], do: Atom.to_string(m)
  defp method_string(m) when is_binary(m), do: m
  defp method_string(_), do: nil

  defp route_template(method, path) do
    case Phoenix.Router.route_info(EngramWeb.Router, method, path, "") do
      %{route: route} when is_binary(route) -> route
      _ -> nil
    end
  end

  # Only wildcard/param routes carry user data; a static route IS its path.
  defp put_path_shape(attrs, route, route), do: attrs

  defp put_path_shape(attrs, route, path) do
    dynamic =
      Enum.drop(
        String.split(path, "/", trim: true),
        length(String.split(route, "/", trim: true)) - 1
      )

    attrs
    |> Map.put(:"engram.path.depth", length(dynamic))
    |> put_ref(path)
    |> put_ext(List.last(dynamic))
  end

  defp put_ref(attrs, path) do
    case Application.get_env(:engram, :hmac_key_user_id) do
      key when is_binary(key) and key != "" ->
        ref =
          :crypto.mac(:hmac, :sha256, key, "span-path:" <> path) |> Base.encode16(case: :lower)

        Map.put(attrs, :"engram.path.ref", binary_part(ref, 0, 12))

      _ ->
        attrs
    end
  end

  defp put_ext(attrs, segment) when is_binary(segment) do
    ext = segment |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    if ext in @known_exts, do: Map.put(attrs, :"engram.path.ext", ext), else: attrs
  end

  defp put_ext(attrs, _), do: attrs

  defp scrub_ips(attrs) do
    Enum.reduce(@ip_keys, attrs, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, ip} -> put_truncated_ip(acc, key, ip)
        :error -> acc
      end
    end)
  end

  defp put_truncated_ip(attrs, key, ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {a, b, c, _}} ->
        Map.put(attrs, key, :inet.ntoa({a, b, c, 0}) |> to_string())

      {:ok, {a, b, c, _, _, _, _, _}} ->
        Map.put(attrs, key, :inet.ntoa({a, b, c, 0, 0, 0, 0, 0}) |> to_string())

      _ ->
        Map.delete(attrs, key)
    end
  end

  defp put_truncated_ip(attrs, key, _), do: Map.delete(attrs, key)
end
