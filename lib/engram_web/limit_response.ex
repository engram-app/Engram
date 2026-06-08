defmodule EngramWeb.LimitResponse do
  @moduledoc """
  Standardized 402 emit helper. Use from controllers and plugs that
  enforce plan limits.

  Response shape (per `docs/superpowers/specs/2026-06-07-free-tier-launch-design.md` §4.5):

      %{
        "error" => "limit_exceeded",
        "reason" => "<machine_key>",
        "tier" => "free" | "starter" | "pro" | nil,
        "limit_key" => "<key>" | nil,
        "limit" => integer() | boolean() | nil,
        "current" => integer() | nil,
        "upgrade_url" => string() | nil
      }
  """
  import Plug.Conn

  @spec halt(
          Plug.Conn.t(),
          reason :: String.t(),
          limit_key :: atom() | nil,
          limit :: integer() | boolean() | nil,
          current :: integer() | nil
        ) :: Plug.Conn.t()
  def halt(conn, reason, limit_key, limit, current)
      when is_binary(reason) do
    tier = tier_string(conn.assigns[:current_user])
    upgrade_url = Application.get_env(:engram, :upgrade_url)

    body = %{
      "error" => "limit_exceeded",
      "reason" => reason,
      "tier" => tier,
      "limit_key" => limit_key && Atom.to_string(limit_key),
      "limit" => limit,
      "current" => current,
      "upgrade_url" => upgrade_url
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(402, Jason.encode!(body))
    |> Plug.Conn.halt()
  end

  defp tier_string(nil), do: nil
  defp tier_string(user), do: user |> Engram.Billing.tier() |> Atom.to_string()
end
