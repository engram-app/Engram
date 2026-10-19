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
  the client sees are unchanged.
  """

  alias EngramWeb.RequestMeta

  require Logger
  require OpenTelemetry.Tracer

  # Client-controlled; RedactFilter neither scrubs nor bounds it.
  @content_type_log_limit 100

  def init(opts), do: Plug.Parsers.init(opts)

  def call(conn, parsers) do
    Plug.Parsers.call(conn, parsers)
  rescue
    e in Plug.Parsers.RequestTooLargeError ->
      record_too_large(conn)
      reraise e, __STACKTRACE__
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
