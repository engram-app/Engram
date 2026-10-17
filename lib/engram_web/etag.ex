defmodule EngramWeb.ETag do
  @moduledoc """
  If-None-Match matching for controllers that answer 304. Browsers send
  lists and `*`, and Cloudflare weakens ETags (`W/`) when it compresses a
  response, so all three count as a match for a strong `etag`.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @spec matches?(Plug.Conn.t(), String.t()) :: boolean()
  def matches?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 in ["*", etag, "W/" <> etag]))
  end
end
