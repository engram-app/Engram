defmodule EngramWeb.Plugs.BodyParser do
  @moduledoc """
  `Plug.Parsers`, plus a record of every body it refuses as too large.

  The parser runs in the endpoint, before the router, and raises
  `Plug.Parsers.RequestTooLargeError` after reading up to the ceiling. Phoenix
  renders that 413 from the endpoint's ENTRY conn, so `Plug.Telemetry`'s stop
  event never fires: no request log line, no route on the span, and nothing in
  PromEx. In the 2026-10-19 bulk-upload storm 47 such refusals, each 15-26 s
  of body read, were visible only as routeless spans.

  This logs one warning (route, method, declared size, content type) and tags
  the request span, then re-raises the same exception, so the status and body
  the client sees are unchanged. A parseable body whose declared
  content-length is already over the ceiling gets that same exception before
  any of it is read.
  """

  alias EngramWeb.RequestMeta

  require Logger
  require OpenTelemetry.Tracer

  # Client-controlled; RedactFilter neither scrubs nor bounds it.
  @content_type_log_limit 100

  def init(opts), do: {Plug.Parsers.init(opts), Keyword.fetch!(opts, :length)}

  def call(conn, {parsers, length}) do
    if refuse_unread?(conn, length) do
      record_too_large(conn)
      raise Plug.Parsers.RequestTooLargeError
    end

    Plug.Parsers.call(conn, parsers)
  rescue
    e in Plug.Parsers.RequestTooLargeError ->
      unless refuse_unread?(conn, length), do: record_too_large(conn)
      reraise e, __STACKTRACE__
  end

  # A body the parser WOULD read, declared over its length, gets the parser's
  # own refusal without the read: an honest content-length cannot shrink.
  # Chunked / undeclared bodies, and types the parser passes through
  # (octet-stream: the raw attachment upload has its own early refusal), keep
  # the read-then-refuse path. A body an earlier parser already fetched
  # (`McpBodyParser`) is left alone.
  defp refuse_unread?(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, length) do
    case RequestMeta.declared_length(conn) do
      n when is_integer(n) and n > length -> parsed_type?(conn)
      _ -> false
    end
  end

  defp refuse_unread?(_conn, _length), do: false

  # Mirrors the parsers in the endpoint's @parser_opts: :json, :urlencoded,
  # :multipart.
  defp parsed_type?(conn) do
    with [header | _] <- Plug.Conn.get_req_header(conn, "content-type"),
         {:ok, type, subtype, _} <- Plug.Conn.Utils.media_type(header) do
      case {type, subtype} do
        {"application", "json"} -> true
        {"application", "x-www-form-urlencoded"} -> true
        {"multipart", _} -> true
        {"application", sub} -> String.ends_with?(sub, "+json")
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp record_too_large(conn) do
    route_info =
      Phoenix.Router.route_info(EngramWeb.Router, conn.method, conn.path_info, conn.host)

    declared = RequestMeta.declared_length(conn)

    content_type =
      case Plug.Conn.get_req_header(conn, "content-type") do
        [type | _] -> String.byte_slice(type, 0, @content_type_log_limit)
        [] -> nil
      end

    OpenTelemetry.Tracer.set_attributes(
      for {k, v} <- [
            {"http.route", route_template(route_info)},
            {"engram.request.reject_reason", "request_too_large"},
            {"engram.request.declared_bytes", declared},
            {"engram.request.content_type", content_type}
          ],
          v != nil,
          do: {k, v}
    )

    Logger.warning(
      "request body too large",
      Engram.Logger.Metadata.with_category(:warning, :http,
        method: conn.method,
        status: 413,
        route: route_name(route_info),
        reason: "request_too_large",
        declared_bytes: declared,
        content_type: content_type
      )
    )
  end

  defp route_template(%{route: route}) when is_binary(route), do: route
  defp route_template(_), do: nil

  # Same "Module#action" shape as `EngramWeb.RequestLogger`'s `route`.
  defp route_name(%{plug: plug, plug_opts: action}) when is_atom(action),
    do: "#{inspect(plug)}##{action}"

  defp route_name(_), do: nil
end
