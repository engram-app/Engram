defmodule EngramWeb.MeteredSerializerChannelTest do
  @moduledoc """
  Contract test against Phoenix's REAL channel subscription shape.

  `MeteredSerializer` counts broadcast recipients by selecting Phoenix's own
  subscription entries out of the PubSub Registry. That shape is a Phoenix
  internal: 1.8.16 moved it from `{:fastlane, pid, serializer, intercepts}` to
  the `:sender` form, and the hand-built subscriptions in
  `metered_serializer_test.exs` kept passing while every real broadcast
  reported zero frames. This file subscribes through an actual channel join,
  so the next shape change fails here.

  `Phoenix.ChannelTest` uses its own no-op serializer, so the joined socket's
  serializer is swapped for `MeteredSerializer` before the join; the join then
  registers exactly what a production socket registers.
  """

  use EngramWeb.ChannelCase, async: false

  alias EngramWeb.MeteredSerializer

  @event [:engram, :websocket, :frame]

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    socket = %{user_socket(user) | serializer: MeteredSerializer}
    topic = "user:#{user.id}"
    {:ok, _, socket} = subscribe_and_join(socket, EngramWeb.UserChannel, topic, %{})
    Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), socket.channel_pid)

    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _, m, meta, _ -> send(test_pid, {:frame, m, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    %{socket: socket, topic: topic}
  end

  test "a joined channel registers the subscription shape the meter selects on", %{
    socket: socket,
    topic: topic
  } do
    channel_pid = socket.channel_pid

    assert [
             {^channel_pid,
              [Phoenix.Channel.Server | {_transport, MeteredSerializer, intercepts}]}
           ] =
             Engram.PubSub
             |> Registry.lookup(topic)
             |> Enum.filter(fn {pid, _} -> pid == channel_pid end)

    assert "vault_created" in intercepts
  end

  test "a broadcast to a joined channel counts one delivered frame", %{topic: topic} do
    # Not intercepted by UserChannel, so it takes the fastlane path.
    EngramWeb.Endpoint.broadcast!(topic, "subscription_activated", %{"tier" => "pro"})

    assert_receive {:socket_push, :text, data}

    assert_receive {:frame, %{count: 1, bytes: bytes},
                    %{direction: :out, kind: :broadcast, topic_prefix: "user"}}

    assert bytes == IO.iodata_length(data)
  end
end
