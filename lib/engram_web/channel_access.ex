defmodule EngramWeb.ChannelAccess do
  @moduledoc """
  Whether a joined vault channel (`sync:`, `crdt:`) may still reach its vault,
  for the life of the channel: the join judgement, the periodic re-check and
  the stop. The decision itself is `Engram.Permissions.decide/3`, the one
  REST and MCP use too; this module only applies it to a channel.

  Join judges the credential's scope now (`check/3`, through
  `ChannelGate.vault_scope/1`, never the connect-time assigns). After that
  the channel holds the result instead of re-judging every frame or push:
  the hot paths (inbound frames, fanned-out broadcasts) cost nothing, and
  broadcasts keep Phoenix's fastlane (no intercept).

  A narrowing or revoke normally ends the channel without this module: the
  writer broadcasts the owner's `user_socket:<id>` disconnect after commit
  (`Engram.OAuth.grants_changed/1`, API-key edits and revokes), and the
  socket transport closes on it. This module does not also re-judge on that
  broadcast: every channel of the user would read a just-evicted cache at
  once, a DB stampede for a socket that is closing anyway.

  The re-check is for a broadcast that was lost, or a change made without
  one: every `@recheck_ms` (60 s, the `:api_key` / `:oauth_grant` cache
  TTL) the channel re-reads its scope through the same cache. A value
  cached just before the change can outlive it by up to one TTL, so the
  worst case from the change to the stop is about 2x the TTL (~120 s).

  On that path a lost vault stops the channel AND closes its whole socket
  (transport), not just the channel: the plugin has no per-topic rejoin,
  so a closed channel alone would leave it talking to a dead topic, while
  a closed socket makes it reconnect and rejoin into the join's refusal.
  The socket's other channels reconnect with it. Accepted because this
  path only runs when a disconnect broadcast was lost. Only this channel's
  own socket is closed, once (the channel stops), never the user's others.
  """

  import Phoenix.Socket, only: [assign: 3]

  alias Engram.Permissions
  alias EngramWeb.ChannelGate

  @recheck_ms 60_000
  @recheck {__MODULE__, :recheck}

  @type need :: :read | :write

  @doc """
  True for the message `refresh/2` handles. Each channel routes it with one
  clause: `def handle_info(msg, socket) when is_access_message(msg)`.
  """
  defguard is_access_message(msg) when msg == @recheck

  @doc "`Permissions.decide/3` for the socket's credential, re-read now."
  @spec check(Phoenix.Socket.t() | map(), map(), need) ::
          :ok | :read_only | :forbidden | :revoked
  def check(%Phoenix.Socket{assigns: assigns}, vault, need), do: check(assigns, vault, need)

  def check(assigns, vault, need),
    do: Permissions.decide(ChannelGate.vault_scope(assigns), vault, need)

  @doc "The join reply's reason for a refusal from `check/3`."
  @spec refusal_reason(:read_only | :forbidden | :revoked) :: String.t()
  def refusal_reason(:read_only), do: "read_only_vault"
  def refusal_reason(:revoked), do: "unauthorized"
  # Same reply as a missing vault: no existence oracle.
  def refusal_reason(:forbidden), do: "vault_not_found"

  @doc "Call from `join/3` once `check/3` passed: arms the periodic re-check."
  @spec track(Phoenix.Socket.t(), map(), need) :: Phoenix.Socket.t()
  def track(%Phoenix.Socket{} = socket, vault, need) do
    :ok = arm()
    assign(socket, :channel_access, %{vault: vault, need: need})
  end

  @doc "The periodic re-check: re-arms, or stops the channel and closes its socket."
  @spec refresh(term(), Phoenix.Socket.t()) ::
          {:noreply, Phoenix.Socket.t()}
          | {:stop, {:shutdown, :access_changed}, Phoenix.Socket.t()}
  def refresh(
        @recheck,
        %Phoenix.Socket{assigns: %{channel_access: %{vault: vault, need: need}}} = socket
      ) do
    case check(socket, vault, need) do
      :ok ->
        :ok = arm()
        {:noreply, socket}

      _lost ->
        _ = send(socket.transport_pid, disconnect())
        {:stop, {:shutdown, :access_changed}, socket}
    end
  end

  defp arm do
    _timer =
      Process.send_after(
        self(),
        @recheck,
        Application.get_env(:engram, :channel_access_recheck_ms, @recheck_ms)
      )

    :ok
  end

  # What the socket transport acts on to close itself (`Phoenix.Socket`).
  defp disconnect, do: %Phoenix.Socket.Broadcast{event: "disconnect", payload: %{}}
end
