defmodule EngramWeb.Plugs.RotationLockCheck do
  @moduledoc """
  T3.7 — short-circuits requests for any user whose DEK rotation is
  in flight. Mounted on the authenticated API pipeline AFTER auth so
  `:current_user` is populated. Returns 503 with `Retry-After: 60`
  to signal a transient block, not a permanent failure.

  Read AND write paths block — see spec §6 (rotated rows on disk
  reference a `dek_version` whose master mapping has not yet been
  flipped, so any decrypt with the old DEK fails until the rotation
  completes).
  """

  import Plug.Conn

  alias Engram.Accounts.User

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    case conn.assigns[:current_user] do
      %User{dek_rotation_locked_at: %DateTime{}} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "rotation_in_progress"}))
        |> halt()

      _ ->
        conn
    end
  end
end
