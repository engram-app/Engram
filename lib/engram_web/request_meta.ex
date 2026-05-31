defmodule EngramWeb.RequestMeta do
  @moduledoc """
  Helpers for extracting client metadata (IP, user agent) from a `%Plug.Conn{}`
  to stamp on database rows for provenance (DCR registrations, onboarding
  agreements, etc).
  """

  @spec format_ip(:inet.ip_address() | term()) :: String.t() | nil
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  def format_ip(tuple) when is_tuple(tuple) and tuple_size(tuple) == 8 do
    tuple |> :inet.ntoa() |> to_string()
  end

  def format_ip(_), do: nil

  @spec get_user_agent(Plug.Conn.t()) :: String.t() | nil
  def get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
