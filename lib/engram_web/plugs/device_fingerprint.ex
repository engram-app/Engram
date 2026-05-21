defmodule EngramWeb.Plugs.DeviceFingerprint do
  @moduledoc """
  Pricing v2 §I — telemetry-only device-fingerprint capture per authenticated
  request. No enforcement, no rate limit. The fingerprint is a stable 12-char
  hash of the User-Agent header so a downstream aggregator can count distinct
  devices per account and spot account-sharing patterns.

  IP is intentionally excluded — mobile networks rotate IPs constantly and
  would dominate the distinct-count signal.
  """

  alias Plug.Conn

  def init(opts), do: opts

  def call(%Conn{assigns: %{current_user: %{id: user_id}}} = conn, _opts) do
    fingerprint = fingerprint_from(conn)

    :telemetry.execute(
      [:engram, :abuse, :device_fingerprint],
      %{count: 1},
      %{user_id: user_id, fingerprint: fingerprint}
    )

    conn
  end

  def call(conn, _opts), do: conn

  defp fingerprint_from(%Conn{} = conn) do
    ua =
      conn
      |> Conn.get_req_header("user-agent")
      |> List.first()
      |> case do
        nil -> ""
        v -> v
      end

    :crypto.hash(:sha256, ua)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
