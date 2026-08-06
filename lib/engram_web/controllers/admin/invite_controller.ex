defmodule EngramWeb.Admin.InviteController do
  use EngramWeb, :controller
  alias Engram.Invites

  action_fallback EngramWeb.FallbackController

  def create(conn, params) do
    attrs = %{
      label: params["label"],
      max_uses: parse_int(params["max_uses"], 1),
      expires_in_days: parse_int(params["expires_in_days"], 7)
    }

    case Invites.create_invite(conn.assigns.current_user, attrs) do
      {:ok, {raw, invite}} ->
        conn
        |> put_status(:created)
        |> json(%{token: raw, url: invite_url(raw), invite: render_invite(invite)})

      {:error, _cs} ->
        conn |> put_status(422) |> json(%{error: "invalid_invite"})
    end
  end

  def index(conn, _params) do
    json(conn, %{invites: Enum.map(Invites.list_active(), &render_invite/1)})
  end

  def delete(conn, %{"id" => id}) do
    # 200 + JSON (not 204): the frontend `api.del` parses the body.
    with {:ok, _} <- Invites.revoke(id) do
      json(conn, %{ok: true})
    end
  end

  defp render_invite(i) do
    %{
      id: i.id,
      label: i.label,
      max_uses: i.max_uses,
      use_count: i.use_count,
      expires_at: i.expires_at,
      inserted_at: i.inserted_at
    }
  end

  # Canonical URL, never the connection — see the admin password-reset link for
  # the full reasoning. `conn.scheme` is :http behind an edge that terminates
  # TLS, which would hand out a plaintext link carrying this live token, and
  # `conn.host` may be a backend host that serves no SPA.
  defp invite_url(raw), do: EngramWeb.Endpoint.url() <> "/sign-up?invite=#{raw}"

  defp parse_int(nil, default), do: default
  defp parse_int(v, _default) when is_integer(v), do: v

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end
end
