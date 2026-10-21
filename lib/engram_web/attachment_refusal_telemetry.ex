defmodule EngramWeb.AttachmentRefusalTelemetry do
  @moduledoc """
  Every refused attachment upload says why, on the request span and on the
  request's one log line (`EngramWeb.RequestLogger` reads the `:reject_reason`
  and `:reject_meta` assigns), so a refusal storm is attributable from
  telemetry alone: before this, a device's 250 402s could not be split into
  text-only / file_too_large / quota, and the plan, size and body shape were
  unknowable (2026-10-19).

  A controller plug (`plug EngramWeb.AttachmentRefusalTelemetry when ...`),
  shared by the single-request and the chunked upload controllers.
  """

  @behaviour Plug

  import Plug.Conn

  alias Engram.Billing
  alias EngramWeb.RequestMeta

  require OpenTelemetry.Tracer

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: register_before_send(conn, &tag/1)

  @doc "Whether the request carries a raw `application/octet-stream` body."
  @spec raw_body?(Plug.Conn.t()) :: boolean()
  def raw_body?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> String.starts_with?(String.downcase(type), "application/octet-stream")
      [] -> false
    end
  end

  defp tag(%Plug.Conn{status: status} = conn) when status in 200..299, do: conn

  defp tag(conn) do
    body = sent_body(conn)
    reason = sent_reason(body, conn.status)

    meta = [
      plan: plan(conn.assigns[:current_user]),
      rejected_type: rejected_type(body),
      declared_bytes: RequestMeta.declared_length(conn),
      body_kind: if(raw_body?(conn), do: "raw", else: "json"),
      plugin_version: log_plugin_version(conn.assigns[:plugin_version])
    ]

    OpenTelemetry.Tracer.set_attributes(
      for {k, v} <- [
            {"engram.plan", meta[:plan]},
            {"engram.attachment.reject_reason", reason},
            {"engram.attachment.rejected_type", meta[:rejected_type]},
            {"engram.attachment.declared_bytes", meta[:declared_bytes]},
            {"engram.attachment.body_kind", meta[:body_kind]},
            {"engram.plugin_version", meta[:plugin_version]}
          ],
          v != nil,
          do: {k, v}
    )

    conn
    |> assign(:reject_reason, reason)
    |> assign(:reject_meta, meta)
  end

  # The reason the client was actually sent: a LimitResponse 402 names it in
  # `reason` (its `error` is the generic "limit_exceeded"), every other refusal
  # in `error`. Both are server-chosen constants, never client input.
  defp sent_body(conn) do
    case Jason.decode(IO.iodata_to_binary(conn.resp_body || "")) do
      {:ok, %{} = body} -> body
      _ -> %{}
    end
  end

  defp sent_reason(%{"reason" => r}, _status) when is_binary(r), do: r
  defp sent_reason(%{"error" => e}, _status) when is_binary(e), do: e
  defp sent_reason(_body, status), do: "http_#{status}"

  # Which extension a 415 refused, so a refusal storm names the file type a
  # client keeps sending. The gate is extension-only, so the 415 body carries
  # the (blocklisted, hence short) extension and never a client-sent MIME.
  defp rejected_type(%{"extension" => e}) when is_binary(e), do: e
  defp rejected_type(_body), do: nil

  defp plan(%Engram.Accounts.User{} = user), do: user |> Billing.tier() |> Atom.to_string()
  defp plan(_), do: nil

  # The header is client-controlled and `RequirePluginVersion` passes anything
  # it cannot parse, so only a real version is echoed into telemetry.
  defp log_plugin_version(nil), do: nil

  defp log_plugin_version(v) when is_binary(v) and byte_size(v) <= 32 do
    case Version.parse(v) do
      {:ok, _} -> v
      :error -> "unparsed"
    end
  end

  defp log_plugin_version(_), do: "unparsed"
end
