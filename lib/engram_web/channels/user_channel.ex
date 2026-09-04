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

  alias Engram.Permissions
  alias EngramWeb.ChannelGate

  # `vault_created` carries the DECRYPTED vault name and `vault_populated`
  # carries a vault id, so both are vault-scoped facts and a credential
  # restricted away from that vault must not see them. Intercepting is what
  # gives each subscriber its own decision point; a bare broadcast fans out to
  # every joined socket on the topic, scoped or not.
  #
  # The join itself is NOT refused for a scoped credential, even though that
  # would be a smaller change: the Obsidian plugin joins `user:{id}` on every
  # socket open purely to read `plan` off the join reply
  # (`plugin/src/channel.ts`), and an OAuth-linked install holds a vault-scoped
  # grant. Refusing the join would strip plan state from exactly those
  # first-party users. `subscription_activated` is deliberately not intercepted
  # for the same reason — it names no vault, and it is the plugin's live plan
  # feed.
  intercept ["vault_created", "vault_populated"]

  @impl true
  def join("user:" <> user_id_str, _params, socket) do
    user = socket.assigns.current_user

    if to_string(user.id) == user_id_str do
      # Deletion only. Suspension and onboarding are deliberately NOT gated
      # here — a suspended user needs `subscription_activated` to pay their
      # way out, and the FTUX vault screen blocks on `vault_created` /
      # `vault_populated` before onboarding is complete. Deletion has no such
      # exemption on the HTTP side and gets none here. (#1435)
      case ChannelGate.check_not_deleted(user) do
        :ok -> {:ok, %{plan: Engram.Billing.plan_state(user)}, socket}
        {:error, payload} -> {:error, payload}
      end
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

  # Both intercepted events always carry `vault_id`; there is deliberately no
  # catch-all clause, so adding a third event to `intercept` above without
  # deciding its scope rule fails loudly rather than fanning out unfiltered.
  @impl true
  def handle_out(event, %{vault_id: vault_id} = payload, socket) do
    if Permissions.allows?(Permissions.vault_scope(socket.assigns), %{id: vault_id}) do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end
end
