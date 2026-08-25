defmodule EngramWeb.Plugs.EnforcePatCreation do
  @moduledoc """
  Gates PAT (personal access token / API key) MINTING on the user's
  `api_write_enabled` plan flag. API keys are Pro-only: Free and Starter
  both default `false`, Pro defaults `true`.

  The rejection code is still `pat_disabled_on_free` for wire
  compatibility with shipped clients; it now fires for Starter too.

  Distinct from `RequireApiWriteEnabled` which gates write *operations*
  via existing API keys on the vault-scoped pipeline. This plug runs on
  the JWT-authed `POST /api/connections/pat` route only.

  Rejection: HTTP 402 with
  `{"error": "pat_disabled_on_free", "upgrade_url": "/#settings/billing"}`.
  """

  alias Engram.Billing
  alias EngramWeb.Plugs.Halt

  @upgrade_url "/#settings/billing"

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    case Billing.check_feature(user, :api_write_enabled) do
      :ok ->
        conn

      _ ->
        Halt.json(conn, 402, %{error: "pat_disabled_on_free", upgrade_url: @upgrade_url})
    end
  end

  def call(_conn, _opts) do
    raise "EnforcePatCreation requires :current_user assigned by upstream auth plug"
  end
end
