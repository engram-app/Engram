defmodule EngramWeb.ChannelAccess do
  @moduledoc """
  Whether a joined vault channel (`sync:`, `crdt:`) may still reach its vault,
  for the life of the channel. The one place that judges it: join, the
  refresh when a credential changes, the periodic re-check and the stop.

  Join judges the credential's scope now (`check/3`, through
  `ChannelGate.vault_scope/1`, never the connect-time assigns). After that the
  channel holds the result instead of re-judging every frame or push: the hot
  paths (inbound frames, fanned-out broadcasts) cost nothing, and broadcasts
  keep Phoenix's fastlane (no intercept).

  It is re-judged when it can have changed:

    * on the owner's `user_socket:<id>` disconnect broadcast, which every
      writer that narrows or revokes a credential sends after commit
      (`Engram.OAuth.grants_changed/1`, API-key edits and revokes,
      `SessionInvalidator`), after evicting the cached scope;
    * every `@recheck_ms` (the `:api_key` / `:oauth_grant` cache TTL), so a
      lost broadcast, or a change made without one (raw SQL, another node's
      NOTIFY-only eviction), still lands within that bound.

  A re-judgement reads the cached scope (ETS; one query on a miss).

  When the vault is no longer reachable at the level the channel needs, the
  channel stops and its own socket is closed, so the client reconnects and
  its rejoin gets the join's refusal. Closing only the channel is not enough:
  the plugin has no per-topic rejoin and would keep using a dead topic. Only
  this channel's socket is closed, once (the channel stops), and not when the
  trigger was the user-wide disconnect itself, which already closes it.
  """

  import Phoenix.Socket, only: [assign: 3]

  alias Engram.Permissions
  alias EngramWeb.ChannelGate

  @recheck_ms 60_000
  @recheck {__MODULE__, :recheck}

  @type need :: :read | :write
  @type result :: :ok | :read_only | :forbidden | :revoked

  @doc """
  True for the messages `refresh/2` handles. Each channel routes them with
  one clause: `def handle_info(msg, socket) when is_access_message(msg)`.
  """
  defguard is_access_message(msg)
           when msg == @recheck or
                  (is_struct(msg, Phoenix.Socket.Broadcast) and
                     :erlang.map_get(:event, msg) == "disconnect")

  @doc "Whether the socket's credential reaches `vault` at `need` now."
  @spec check(Phoenix.Socket.t() | map(), map(), need) :: result
  def check(%Phoenix.Socket{assigns: assigns}, vault, need), do: check(assigns, vault, need)

  def check(assigns, vault, need) do
    case ChannelGate.vault_scope(assigns) do
      :revoked ->
        :revoked

      scope ->
        cond do
          not Permissions.allows?(scope, vault) -> :forbidden
          need == :read or Permissions.allows_write?(scope, vault) -> :ok
          true -> :read_only
        end
    end
  end

  @doc "The join reply's reason for a refusal from `check/3`."
  @spec refusal_reason(:read_only | :forbidden | :revoked) :: String.t()
  def refusal_reason(:read_only), do: "read_only_vault"
  def refusal_reason(:revoked), do: "unauthorized"
  # Same reply as a missing vault: no existence oracle.
  def refusal_reason(:forbidden), do: "vault_not_found"

  @doc """
  Call from `join/3` once `check/3` passed: remembers what to re-judge,
  subscribes to the owner's disconnect broadcast and arms the re-check.
  """
  @spec track(Phoenix.Socket.t(), map(), need) :: Phoenix.Socket.t()
  def track(%Phoenix.Socket{assigns: %{current_user: %{id: user_id}}} = socket, vault, need) do
    :ok = Phoenix.PubSub.subscribe(Engram.PubSub, "user_socket:#{user_id}")
    arm()
    assign(socket, :channel_access, %{vault: vault, need: need})
  end

  @doc "Re-judges on an `is_access_message/1` message; stops the channel on loss."
  @spec refresh(term(), Phoenix.Socket.t()) ::
          {:noreply, Phoenix.Socket.t()}
          | {:stop, {:shutdown, :access_changed}, Phoenix.Socket.t()}
  def refresh(
        msg,
        %Phoenix.Socket{assigns: %{channel_access: %{vault: vault, need: need}}} = socket
      ) do
    case check(socket, vault, need) do
      :ok ->
        if msg == @recheck, do: arm()
        {:noreply, socket}

      _lost ->
        # The user-wide disconnect already closes this socket.
        if msg == @recheck, do: send(socket.transport_pid, disconnect())
        {:stop, {:shutdown, :access_changed}, socket}
    end
  end

  defp arm,
    do:
      Process.send_after(
        self(),
        @recheck,
        Application.get_env(:engram, :channel_access_recheck_ms, @recheck_ms)
      )

  # What the socket transport acts on to close itself (`Phoenix.Socket`).
  defp disconnect, do: %Phoenix.Socket.Broadcast{event: "disconnect", payload: %{}}
end
