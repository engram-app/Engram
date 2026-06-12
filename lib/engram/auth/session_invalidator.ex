defmodule Engram.Auth.SessionInvalidator do
  @moduledoc """
  Force-disconnect every live WebSocket for a user.

  Phoenix sockets identify themselves via the `id/1` callback in
  `EngramWeb.UserSocket` — `"user_socket:\#{user_id}"`. Broadcasting the
  `"disconnect"` event on that topic tears down every socket assigned to
  that user, regardless of which token they connected with.

  Call this from any path that invalidates auth or alters entitlements
  that channels gate on:

    * API key revoke, refresh-token-family revoke, OAuth revoke
    * account self-delete, admin soft-delete, admin suspend
    * Clerk `user.deleted` webhook
    * Paddle subscription cancel / tier downgrade

  Fire-and-forget. If no sockets are listening, `Phoenix.PubSub` drops it.
  """

  def disconnect_user(user_id) when is_binary(user_id) do
    _ = EngramWeb.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})
    :ok
  end
end
