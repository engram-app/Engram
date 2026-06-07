defmodule EngramWeb.Plugs.EnforceDeviceCap do
  @moduledoc """
  Mounted on `POST /api/auth/device/authorize` — the user-confirming action
  that, on success, causes the next `/api/auth/device/token` poll to mint a
  device refresh token. Halts 402 if the user is already at their per-tier
  `concurrent_devices` cap, or if a swap-cooldown window is still in effect
  after a recent device revoke.

  Distinct from `EnforceConnectionCap`, which gates MCP OAuth consent
  (`oauth_authorizations`). This plug only serves the Obsidian plugin
  (device flow has no MCP clients today).

  ## Emit shape (Free-tier launch §4.5)

  Both 402 paths go through `EngramWeb.LimitResponse.halt/5` so the body
  shape matches the rest of the standardized 402 sites. Reasons:

    * `concurrent_devices_exceeded` — user is at the per-tier cap.
    * `device_swap_cooldown` — user is at cap AND a recent revoke happened
      within `device_swap_cooldown_hours`. The `current` field carries
      hours remaining until the next swap is allowed (rounded up).

  ## Race note

  Two concurrent authorize POSTs at cap−1 can both pass and mint two
  device refresh tokens, briefly exceeding cap by one. Acceptable trade-off
  for a low-frequency user action; consistent with the same note in
  `EnforceConnectionCap`.
  """

  alias Engram.{Billing, Connections}
  alias EngramWeb.LimitResponse

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    limit = Billing.effective_limit(user, :concurrent_devices)
    current = Connections.count_active(user.id, :obsidian)

    cond do
      # -1 is the canonical "unlimited" sentinel — same convention as
      # Engram.Billing.check_limit/3 and BillingController.cap_json/1.
      limit in [:unlimited, nil, -1] ->
        conn

      is_integer(limit) and current < limit ->
        conn

      true ->
        emit_402(conn, user, limit, current)
    end
  end

  def call(_conn, _opts) do
    raise "EnforceDeviceCap requires :current_user assigned by upstream auth plug"
  end

  # At cap. Check whether a swap-cooldown window is still in effect — i.e.
  # the user revoked a device family within `device_swap_cooldown_hours`
  # and is now trying to add another one. If so, emit the cooldown reason
  # with `current` = hours remaining; otherwise emit the plain at-cap
  # reason.
  defp emit_402(conn, user, limit, current) do
    cooldown_hours = Billing.effective_limit(user, :device_swap_cooldown_hours)

    case remaining_cooldown_hours(user.id, cooldown_hours) do
      nil ->
        LimitResponse.halt(
          conn,
          "concurrent_devices_exceeded",
          :concurrent_devices,
          limit,
          current
        )

      remaining when is_integer(remaining) and remaining > 0 ->
        LimitResponse.halt(
          conn,
          "device_swap_cooldown",
          :device_swap_cooldown_hours,
          cooldown_hours,
          remaining
        )

      _ ->
        LimitResponse.halt(
          conn,
          "concurrent_devices_exceeded",
          :concurrent_devices,
          limit,
          current
        )
    end
  end

  # Returns hours remaining until the cooldown elapses, or nil if no
  # cooldown is in effect (no recent revoke, cooldown disabled, or
  # window already passed). Rounded UP so a sub-hour remainder still
  # surfaces a positive integer.
  defp remaining_cooldown_hours(_user_id, hours)
       when hours in [nil, :unlimited, -1] or hours == 0,
       do: nil

  defp remaining_cooldown_hours(user_id, hours) when is_integer(hours) and hours > 0 do
    case Connections.most_recent_device_revoke(user_id) do
      nil ->
        nil

      %DateTime{} = revoked_at ->
        elapsed_seconds = DateTime.diff(DateTime.utc_now(), revoked_at, :second)
        window_seconds = hours * 3600

        if elapsed_seconds < window_seconds do
          remaining_seconds = window_seconds - elapsed_seconds
          # Round up so e.g. 30 minutes remaining surfaces as 1, not 0.
          div(remaining_seconds + 3599, 3600)
        else
          nil
        end
    end
  end
end
