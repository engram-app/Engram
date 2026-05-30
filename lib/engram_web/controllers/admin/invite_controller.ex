defmodule EngramWeb.Admin.InviteController do
  use EngramWeb, :controller
  alias Engram.Invites

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
        |> json(%{token: raw, url: invite_url(conn, raw), invite: render_invite(invite)})

      {:error, _cs} ->
        conn |> put_status(422) |> json(%{error: "invalid_invite"})
    end
  end

  def index(conn, _params) do
    json(conn, %{invites: Enum.map(Invites.list_active(), &render_invite/1)})
  end

  def delete(conn, %{"id" => id}) do
    case Invites.revoke(id) do
      # 200 + JSON (not 204): the frontend `api.del` parses the body.
      {:ok, _} -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "not_found"})
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

  defp invite_url(conn, raw),
    do: "#{conn.scheme}://#{conn.host}/sign-up?invite=#{raw}"

  defp parse_int(nil, default), do: default
  defp parse_int(v, _default) when is_integer(v), do: v

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end
end
