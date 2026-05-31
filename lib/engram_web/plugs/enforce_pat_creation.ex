defmodule EngramWeb.Plugs.EnforcePatCreation do
  @moduledoc """
  Gates PAT (personal access token / API key) MINTING on the user's
  `api_write_enabled` plan flag. Free tier default is `false` — Starter
  and Pro both default `true`.

  Distinct from `RequireApiWriteEnabled` which gates write *operations*
  via existing API keys on the vault-scoped pipeline. This plug runs on
  the JWT-authed `POST /api/connections/pat` route only.

  Rejection: HTTP 402 with
  `{"error": "pat_disabled_on_free", "upgrade_url": "/settings/billing"}`.
  """

  import Plug.Conn

  alias Engram.Billing

  @upgrade_url "/settings/billing"

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    case Billing.check_feature(user, :api_write_enabled) do
      :ok ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          402,
          Jason.encode!(%{
            error: "pat_disabled_on_free",
            upgrade_url: @upgrade_url
          })
        )
        |> halt()
    end
  end

  def call(_conn, _opts) do
    raise "EnforcePatCreation requires :current_user assigned by upstream auth plug"
  end
end
