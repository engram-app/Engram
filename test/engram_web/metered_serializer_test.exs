defmodule EngramWeb.MeteredSerializerTest do
  @moduledoc """
  Pins the frame meter on the WebSocket wire. The serializer is the one choke
  point every frame crosses in both directions, so if it stops emitting, the
  dashboard's message rate and throughput panels go quiet without erroring.
  """

  use ExUnit.Case, async: false

  alias EngramWeb.MeteredSerializer
  alias Phoenix.Socket.{Broadcast, Message, Reply}
  alias Phoenix.Socket.V2.JSONSerializer

  @event [:engram, :websocket, :frame]

  setup do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _, m, meta, _ -> send(test_pid, {:frame, m, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "encode!/1 output is byte-identical to the V2 JSON serializer" do
    msg = %Message{topic: "sync:v1", event: "note_changed", payload: %{"a" => 1}, ref: "1"}
    assert MeteredSerializer.encode!(msg) == JSONSerializer.encode!(msg)
  end

  test "encode!/1 of a push counts one outbound push frame with its bytes" do
    msg = %Message{topic: "crdt:n1", event: "crdt_msg", payload: %{"b" => "xyz"}}
    {:socket_push, :text, data} = MeteredSerializer.encode!(msg)

    assert_receive {:frame, %{count: 1, bytes: bytes},
                    %{direction: :out, kind: :push, topic_prefix: "crdt"}}

    assert bytes == IO.iodata_length(data)
  end

  test "encode!/1 of a reply is tagged kind: :reply" do
    reply = %Reply{topic: "phoenix", status: :ok, payload: %{}, ref: "1", join_ref: nil}
    MeteredSerializer.encode!(reply)

    assert_receive {:frame, %{count: 1},
                    %{direction: :out, kind: :reply, topic_prefix: "phoenix"}}
  end

  test "decode!/2 counts one inbound frame with the raw frame size" do
    raw = ~s(["1","2","sync:v1","push",{"x":1}])
    assert %Message{topic: "sync:v1"} = MeteredSerializer.decode!(raw, opcode: :text)

    assert_receive {:frame, %{count: 1, bytes: bytes},
                    %{direction: :in, kind: :push, topic_prefix: "sync"}}

    assert bytes == byte_size(raw)
  end

  test "client-chosen topics outside the routed set collapse to \"other\"" do
    # Join replies echo whatever topic the client asked for, so an unbounded
    # topic must never become a Prometheus label value.
    MeteredSerializer.decode!(~s(["1","2","attacker-#{System.unique_integer()}","phx_join",{}]),
      opcode: :text
    )

    assert_receive {:frame, _, %{topic_prefix: "other"}}
  end

  test "fastlane!/1 counts one frame per local subscriber that receives the encoding" do
    topic = "user:#{System.unique_integer([:positive])}"
    event = "vault_renamed"

    subscribe = fn intercepts ->
      test_pid = self()

      spawn(fn ->
        Phoenix.PubSub.subscribe(Engram.PubSub, topic,
          metadata: {:fastlane, self(), MeteredSerializer, intercepts}
        )

        send(test_pid, :subscribed)
        Process.sleep(5_000)
      end)

      assert_receive :subscribed
    end

    subscribe.([])
    subscribe.([])
    # Intercepting subscribers get the raw Broadcast and push it themselves
    # (counted by encode!/1), so they must not count here.
    subscribe.([event])

    msg = %Broadcast{topic: topic, event: event, payload: %{"k" => "v"}}
    {:socket_push, :text, data} = MeteredSerializer.fastlane!(msg)

    assert_receive {:frame, %{count: 2, bytes: bytes},
                    %{direction: :out, kind: :broadcast, topic_prefix: "user"}}

    assert bytes == 2 * IO.iodata_length(data)
  end

  test "is the v2 serializer on both channel sockets, with v1 still accepted" do
    for path <- ["/socket", "/socket/device"] do
      {^path, _handler, opts} = List.keyfind(EngramWeb.Endpoint.__sockets__(), path, 0)
      serializers = Keyword.fetch!(opts[:websocket], :serializer)

      assert {MeteredSerializer, "~> 2.0.0"} in serializers
      assert {Phoenix.Socket.V1.JSONSerializer, "~> 1.0.0"} in serializers
    end
  end
end
