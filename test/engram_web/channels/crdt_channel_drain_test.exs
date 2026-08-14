defmodule EngramWeb.CrdtChannelDrainTest do
  @moduledoc """
  The half of the #1152 room-lifetime model that can actually lose data.

  A client edit is a `sync_update` frame, which y_ex dispatches as a
  `GenServer.cast` (`deps/y_ex/lib/server/doc_server_worker.ex:26`). A cast to a
  dead pid returns `:ok` and drops the frame — `crdt_channel.ex` says so at its
  room monitor: "send_yjs_message casts to a dead pid return :ok and every
  subsequent edit is silently dropped." Today that only happens on a crash. An
  idle-exit would make it happen on a timer, on purpose, which is why the room
  is drained (observers let go first) rather than stopped.

  The drain closes the window by MESSAGE ORDERING, so these tests pin both
  orderings. Both `push/3` and the drain are sent from the test process, so
  Erlang's per-sender-pair FIFO guarantee makes the interleaving deterministic
  rather than a race these tests would flake on.

  Materialization is the assertion because it is the user-visible loss: if a
  frame is cast into a corpse, no room ever applies it and nothing reaches the
  row, no matter which checkpoint path runs.
  """
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtChannelDrainTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "base"})

    {:ok, _, socket} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket.channel_pid)

    %{socket: socket, user: user, vault: vault, note: note}
  end

  # Drive the channel to start + observe the room, and hand back its pid.
  defp open_room(socket, note) do
    client = CrdtBridge.new_doc()
    {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(frame)})
    assert_push "crdt_msg", %{"doc_id" => _, "b64" => _}, 3_000

    room = CrdtRegistry.lookup(note.id)
    assert is_pid(room)
    {client, room}
  end

  # A sync_update frame carrying `content` as the note's full plaintext.
  defp edit_frame(client, content) do
    :ok = CrdtBridge.ingest_plaintext(client, content)
    {:ok, update} = Yex.encode_state_as_update(client)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  defp assert_content_eventually(user, vault, note_id, needle, deadline \\ 3_000) do
    stop = System.monotonic_time(:millisecond) + deadline

    Stream.repeatedly(fn ->
      case Notes.get_note_by_id(user, vault, note_id) do
        {:ok, %{content: c}} when is_binary(c) -> c
        _ -> ""
      end
    end)
    |> Enum.reduce_while(nil, fn content, _ ->
      cond do
        content =~ needle -> {:halt, :ok}
        System.monotonic_time(:millisecond) >= stop -> {:halt, {:error, content}}
        true -> Process.sleep(25) && {:cont, nil}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, last} -> flunk("#{inspect(needle)} never materialized; last content: #{inspect(last)}")
    end
  end

  test "an edit already queued when the drain lands is not lost", ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    {client, room} = open_room(socket, note)

    # [edit, drain] — the edit is ahead of the drain in the channel's mailbox,
    # so it must be routed to the still-live room before the room is released.
    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => edit_frame(client, "EDIT BEFORE DRAIN")})
    send(socket.channel_pid, {:crdt_room_drain, room})

    assert_content_eventually(user, vault, note.id, "EDIT BEFORE DRAIN")
  end

  test "an edit arriving after the drain re-spins a fresh room instead of casting into a corpse",
       ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    {client, room} = open_room(socket, note)

    # [drain, edit] — the drain evicts the cached pid FIRST, so the edit behind
    # it must re-resolve through ensure_room rather than cast at the dead room.
    send(socket.channel_pid, {:crdt_room_drain, room})
    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => edit_frame(client, "EDIT AFTER DRAIN")})

    assert_content_eventually(user, vault, note.id, "EDIT AFTER DRAIN")

    respun = CrdtRegistry.lookup(note.id)
    assert is_pid(respun)
    refute respun == room, "the edit must land on a NEW room, not the drained one"
  end

  test "a drain broadcast on the room's topic reaches the channel and releases the room", ctx do
    %{socket: socket, note: note} = ctx
    {_client, room} = open_room(socket, note)
    ref = Process.monitor(room)

    # The real wiring: the idle timer broadcasts, the channel is subscribed.
    Phoenix.PubSub.broadcast(
      Engram.PubSub,
      CrdtRegistry.drain_topic(note.id),
      {:crdt_room_drain, room}
    )

    # Channel was the only observer, so letting go trips auto_exit.
    assert_receive {:DOWN, ^ref, :process, ^room, :normal}, 5_000
  end

  test "a drain for a room this channel does not hold is ignored", ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    {client, room} = open_room(socket, note)

    send(socket.channel_pid, {:crdt_room_drain, self()})

    # The channel is still alive and still holding its real room.
    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => edit_frame(client, "STILL WORKING")})
    assert_content_eventually(user, vault, note.id, "STILL WORKING")
    assert CrdtRegistry.lookup(note.id) == room
  end
end
