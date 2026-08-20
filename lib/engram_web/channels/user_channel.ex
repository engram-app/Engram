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

  # Server-push-only is a CLIENT convention; Phoenix does not enforce it.
  # `Phoenix.Channel.Server.handle_info/2` dispatches inbound events straight
  # to `socket.channel.handle_in/3`, so with no clause here any frame a client
  # sends raises UndefinedFunctionError and kills the channel process. This
  # topic is deliberately reachable before onboarding completes (the FTUX vault
  # screen needs it), which means it is reachable by accounts that have
  # accepted nothing and paid nothing — so it has to tolerate being talked to.
  # Ignore rather than reply: there is no client request shape to answer.
  @impl true
  def handle_in(_event, _payload, socket), do: {:noreply, socket}
end
