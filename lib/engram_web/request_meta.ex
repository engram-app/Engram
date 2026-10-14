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

  # The user agent is attacker-controlled, RedactFilter neither scrubs nor
  # bounds `:user_agent`, and prod serializes all metadata: with Bandit's
  # 10_000-byte header cap, an unbounded one is ~10 KB of arbitrary text per
  # request in a long-retention aggregator. 200 chars holds every real UA (the
  # Obsidian one is ~120) and nothing else.
  @user_agent_log_limit 200

  @doc "The user agent, bounded for a log line or metadata. Nil when absent."
  @spec log_user_agent(Plug.Conn.t()) :: String.t() | nil
  def log_user_agent(conn) do
    case get_user_agent(conn) do
      nil -> nil
      ua -> String.slice(ua, 0, @user_agent_log_limit)
    end
  end
end
