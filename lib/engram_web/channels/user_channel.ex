defmodule EngramWeb.UserChannel do
  @moduledoc """
  Per-user notification channel. Topic: `"user:{user_id}"`.

  Read-only from the client's perspective — used by the FTUX vault page to
  wait for `vault_created` and `vault_populated` events when an Obsidian
  user is mid-plugin-install. Server broadcasts via
  `EngramWeb.Endpoint.broadcast("user:{id}", "vault_created", payload)`.

  Auth: socket.assigns.current_user.id must match the topic's user_id.
  """

  use Phoenix.Channel

  @impl true
  def join("user:" <> user_id_str, _params, socket) do
    user = socket.assigns.current_user

    if to_string(user.id) == user_id_str do
      {:ok, %{plan: Engram.Billing.plan_state(user)}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end
end
