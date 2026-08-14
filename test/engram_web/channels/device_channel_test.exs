defmodule EngramWeb.DeviceChannelTest do
  @moduledoc """
  The pre-auth notification channel that replaces device-flow polling.

  The plugin has no token until the flow completes — that is the whole point
  of the flow — so this rides an unauthenticated socket and is keyed by the
  `device_code`, which under RFC 8628 is already the bearer credential.

  The channel carries a NOTIFICATION, never tokens: every subscriber to a
  topic receives a broadcast simultaneously, whereas the token exchange is
  single-use. Pushing credentials here would be strictly weaker than the
  REST endpoint it replaces.
  """
  use EngramWeb.ChannelCase, async: false

  import Ecto.Query

  alias Engram.Auth.DeviceFlow
  alias Engram.Repo

  defp socket_conn do
    {:ok, socket} = connect(EngramWeb.DeviceSocket, %{})
    socket
  end

  describe "join" do
    test "accepts a real pending device code" do
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "My Vault")

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket_conn(), "device:#{auth.device_code}")
    end

    test "rejects an unknown device code" do
      assert {:error, %{reason: "unknown_or_expired"}} =
               subscribe_and_join(socket_conn(), "device:not-a-real-code")
    end

    # Without this the topic is an unauthenticated, unbounded fan-out surface:
    # anyone could hold subscriptions to arbitrary topic names forever.
    test "rejects an expired device code" do
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "My Vault")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(da in Engram.Auth.DeviceAuthorization, where: da.id == ^auth.id),
        [set: [expires_at: past]],
        skip_tenant_check: true
      )

      assert {:error, %{reason: "unknown_or_expired"}} =
               subscribe_and_join(socket_conn(), "device:#{auth.device_code}")
    end

    test "rejects a code that has already been authorized" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "My Vault")
      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

      assert {:error, %{reason: "unknown_or_expired"}} =
               subscribe_and_join(socket_conn(), "device:#{auth.device_code}")
    end

    # Topics that don't match `device:*` never reach join/3 — Phoenix rejects
    # them at the socket router. The reachable degenerate case is a `device:`
    # topic with an EMPTY code, which the byte_size guard drops so it can't
    # fall through to a lookup for "".
    test "rejects a device topic with an empty code" do
      assert {:error, %{reason: "unknown_topic"}} = subscribe_and_join(socket_conn(), "device:")
    end
  end

  describe "authorization notification" do
    test "subscribers are told the code was authorized, and are NOT sent tokens" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      {:ok, auth} = DeviceFlow.start_device_flow("client_1", "My Vault")

      {:ok, _reply, _socket} = subscribe_and_join(socket_conn(), "device:#{auth.device_code}")

      {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)
      DeviceFlow.notify_authorized(auth.device_code)

      assert_push("authorized", payload)
      # The plugin reacts by doing exactly ONE token exchange. Credentials must
      # never ride the channel — see moduledoc.
      refute Map.has_key?(payload, :access_token)
      refute Map.has_key?(payload, :refresh_token)
    end
  end
end
