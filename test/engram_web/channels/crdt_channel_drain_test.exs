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
    push_step1(socket, note, client)

    room = CrdtRegistry.lookup(note.id)
    assert is_pid(room)
    {client, room}
  end

  # A handshake, NOT an edit. Opens the room through ensure_room while changing
  # no content — which matters for the announce tests: a content-changing
  # checkpoint fires its own `crdt_doc_ready` (crdt_checkpoint.ex:213), so
  # re-spinning with an edit makes the two announce sources indistinguishable.
  defp push_step1(socket, note, client) do
    {:ok, {:sync_step1, sv}} = Yex.Sync.get_sync_step1(client)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_step1, sv}})

    push(socket, "crdt_msg", %{"doc_id" => note.id, "b64" => Base.encode64(frame)})
    assert_push "crdt_msg", %{"doc_id" => _, "b64" => _}, 3_000
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
      :ok ->
        :ok

      {:error, last} ->
        flunk("#{inspect(needle)} never materialized; last content: #{inspect(last)}")
    end
  end

  test "an edit already queued when the drain lands is not lost", ctx do
    %{socket: socket, user: user, vault: vault, note: note} = ctx
    {client, room} = open_room(socket, note)

    # [edit, drain] — the edit is ahead of the drain in the channel's mailbox,
    # so it must be routed to the still-live room before the room is released.
    push(socket, "crdt_msg", %{
      "doc_id" => note.id,
      "b64" => edit_frame(client, "EDIT BEFORE DRAIN")
    })

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

    push(socket, "crdt_msg", %{
      "doc_id" => note.id,
      "b64" => edit_frame(client, "EDIT AFTER DRAIN")
    })

    assert_content_eventually(user, vault, note.id, "EDIT AFTER DRAIN")

    respun = CrdtRegistry.lookup(note.id)
    assert is_pid(respun)
    refute respun == room, "the edit must land on a NEW room, not the drained one"
  end

  # The whole point of the feature is bounding memory, so "did a room actually
  # get released" has to be observable in prod, not just in a test.
  test "a released room emits the telemetry ops needs to see the drain working", ctx do
    %{socket: socket, note: note} = ctx
    {_client, room} = open_room(socket, note)

    test_pid = self()
    handler = "drain-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :crdt, :room_drain],
      fn _e, measurements, meta, _ -> send(test_pid, {:drain_telemetry, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    send(socket.channel_pid, {:crdt_room_drain, room})

    assert_receive {:drain_telemetry, %{count: 1}, %{phase: :released}}, 3_000
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

  # The production shape: two devices on one note share ONE room, so the drain
  # has to be handled by every observer and the exit must happen exactly once,
  # on the last release. A drain that assumed a single observer would either
  # strand the room (nobody else lets go) or exit it under a live observer.
  test "a drain releases EVERY observer, and the room exits on the last one", ctx do
    %{socket: socket_a, user: user, vault: vault, note: note} = ctx
    {_client, room} = open_room(socket_a, note)

    {:ok, _, socket_b} =
      subscribe_and_join(
        socket(EngramWeb.UserSocket, "user_#{user.id}_b", %{
          current_user: user,
          current_api_key: nil
        }),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket_b.channel_pid)
    {_client_b, ^room} = open_room(socket_b, note)

    ref = Process.monitor(room)

    Phoenix.PubSub.broadcast(
      Engram.PubSub,
      CrdtRegistry.drain_topic(note.id),
      {:crdt_room_drain, room}
    )

    assert_receive {:DOWN, ^ref, :process, ^room, :normal}, 5_000
  end

  # The announce is a DISCOVERY signal and recipients answer it with a
  # syncStep1. A drain->edit->re-spin discovers nothing (every peer already
  # heard about this note), so re-announcing would turn every drain cycle into a
  # handshake fanned out to every other device on the vault — against @hs_limit
  # here and the plugin's 240/10s crdt_msg budget, with handshake starvation
  # being the documented trigger for the wrong-mint overwrite class.
  test "a re-spin after a drain does NOT re-announce crdt_doc_ready", ctx do
    %{socket: socket, note: note} = ctx
    {client, room} = open_room(socket, note)

    # The FIRST open announces — pin that, so this test cannot pass by the
    # announce being broken outright.
    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}

    send(socket.channel_pid, {:crdt_room_drain, room})
    push_step1(socket, note, client)

    refute_broadcast "crdt_doc_ready", %{"doc_id" => _}, 300
  end

  # Suppression is consumed once per drain, not latched: a crash-shaped
  # eviction still announces, because THAT peer state is genuinely unknown.
  test "only the drain-induced re-spin is suppressed, not every later open", ctx do
    %{socket: socket, note: note} = ctx
    {client, room} = open_room(socket, note)
    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}

    # Drain -> re-spin is quiet.
    send(socket.channel_pid, {:crdt_room_drain, room})
    push_step1(socket, note, client)
    refute_broadcast "crdt_doc_ready", %{"doc_id" => _}, 300

    # Crash-shaped eviction (no drain recorded) -> announces again.
    respun = CrdtRegistry.lookup(note.id)
    send(socket.channel_pid, {:DOWN, make_ref(), :process, respun, :crashed})
    push_step1(socket, note, client)
    assert_broadcast "crdt_doc_ready", %{"doc_id" => _}, 3_000
  end

  # `SharedDoc.unobserve/1` is a GenServer.call with y_ex's 5 s default and no
  # timeout knob, so a dead or wedged room would exit or stall the channel.
  # These drive release_room/1 with PLAIN processes that simply do not reply —
  # no y_ex message shapes encoded here, so the tests keep meaning across a dep
  # bump. The responsive path is covered end-to-end by the drain tests above.
  describe "release_room/1" do
    defp elapsed_ms(fun) do
      t0 = System.monotonic_time(:millisecond)
      result = fun.()
      {result, System.monotonic_time(:millisecond) - t0}
    end

    test "a room that already exited is a fast no-op, not a channel-killing exit" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      {result, ms} = elapsed_ms(fn -> EngramWeb.CrdtChannel.release_room(dead) end)

      assert result == :ok
      assert ms < 500, "a dead room should short-circuit, took #{ms}ms"
    end

    test "a wedged room is abandoned at the probe, not held for the 5s call default" do
      # Assert against a SHORT configured probe rather than racing the 1s
      # default on a loaded shared runner — the timing headroom is what keeps
      # this from flaking.
      # DELETE on restore when the key was previously unset. put_env(…, nil)
      # would leave the key PRESENT with a nil value, which is not the same as
      # absent — it poisoned every later test in this file with `timeout: nil`.
      prev = Application.get_env(:engram, :crdt_room_probe_ms)
      Application.put_env(:engram, :crdt_room_probe_ms, 100)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:engram, :crdt_room_probe_ms)
          v -> Application.put_env(:engram, :crdt_room_probe_ms, v)
        end
      end)

      wedged = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      {result, ms} = elapsed_ms(fn -> EngramWeb.CrdtChannel.release_room(wedged) end)

      assert result == :ok
      # The point: bounded by the probe, nowhere near y_ex's 5_000ms default.
      assert ms < 1_000, "a wedged room stalled the channel for #{ms}ms"
    end

    # Rooms are `:global`-registered, so a channel on this node routinely
    # observes a room on ANOTHER node. `Process.alive?/1` is local-only and
    # raises ArgumentError on a remote pid — :error class, which the `catch
    # :exit` in release_room/1 does NOT contain. Unguarded, every drain of a
    # remote room crashes the channel, in a cluster that has been live in prod
    # since 2026-06-23.
    #
    # NOTE: `:cluster` is excluded unless CLUSTER_TESTS=1, and nothing in CI
    # sets it — so this does not currently gate a merge. It is still the only
    # executable proof of the guard; run it with
    #   CLUSTER_TESTS=1 mix test test/engram_web/channels/crdt_channel_drain_test.exs
    @tag :cluster
    test "a room on ANOTHER node does not crash the channel" do
      # Engram.ClusterCase owns the net_kernel/cookie/code-path dance (and the
      # start-not-start_link subtlety around on_exit) — no reason to re-roll it.
      {_peer, peer_node} = Engram.ClusterCase.start_peer!([], &on_exit/1)

      remote = :erpc.call(peer_node, :erlang, :spawn, [:timer, :sleep, [60_000]])
      refute node(remote) == node()

      # The bug this pins RAISES rather than exits, so a bare call is the test:
      # an ArgumentError from Process.alive?/1 is :error class and would blow
      # straight through release_room/1's `catch :exit`.
      assert EngramWeb.CrdtChannel.release_room(remote) == :ok
    end

    # The `:cluster` test below proves this against a real peer but does NOT run
    # in CI. This one covers the same guard on a single node by injecting the
    # "self" node instead of faking a remote pid: with a mismatched node the
    # check must short-circuit BEFORE Process.alive?/1, which is the local-only
    # call that raises. Drop the node guard and this flips to true.
    test "a pid whose node is not ours never reaches the local-only alive? check" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      refute EngramWeb.CrdtChannel.locally_dead?(dead, :somewhere@else)
      assert EngramWeb.CrdtChannel.locally_dead?(dead), "sanity: locally it IS dead"
    end

    # Locks the `|| @room_probe_ms` reader. A key SET to nil is not the same as
    # absent, and get_env/3's default would not fire — feeding `timeout: nil` to
    # GenServer.call/3, which is how one sloppy test restore crashed every later
    # test in this file.
    test "a nil-valued probe override still yields a usable timeout" do
      Application.put_env(:engram, :crdt_room_probe_ms, nil)
      on_exit(fn -> Application.delete_env(:engram, :crdt_room_probe_ms) end)

      wedged = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(wedged, :kill) end)

      assert EngramWeb.CrdtChannel.release_room(wedged) == :ok
    end

    test "a skipped release is still counted, so ops can see rooms refusing to go" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      test_pid = self()
      handler = "skip-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :room_drain],
        fn _e, m, meta, _ -> send(test_pid, {:drain_telemetry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      EngramWeb.CrdtChannel.release_room(dead)

      assert_receive {:drain_telemetry, %{count: 1}, %{phase: :skipped}}, 1_000
    end

    test "a room that dies mid-call is swallowed rather than exiting the channel" do
      # Answers the probe, then exits before the unobserve can land.
      dying =
        spawn(fn ->
          receive do
            {:"$gen_call", from, _} -> GenServer.reply(from, :ok)
          end

          exit(:normal)
        end)

      assert EngramWeb.CrdtChannel.release_room(dying) == :ok
    end
  end

  # assigns.drained holds a doc_id until its re-spin consumes it — but a note
  # drained and never re-opened leaves one behind for the life of the socket,
  # and @default_max_rooms bounds CONCURRENT rooms, not cumulative ones, while
  # drain-churn is the intended steady state.
  describe "remember_drained/3" do
    test "accumulates entries below the cap" do
      set =
        Enum.reduce(1..5, MapSet.new(), &EngramWeb.CrdtChannel.remember_drained(&2, "d#{&1}", 10))

      assert MapSet.size(set) == 5
    end

    # Overflow CLEARS rather than evicting: the degradation is only ever lost
    # suppression (a re-spin announces, i.e. pre-drain behaviour), never
    # incorrectness — so it needs no ordering bookkeeping.
    test "clears at the cap instead of growing without bound" do
      set =
        Enum.reduce(
          1..50,
          MapSet.new(),
          &EngramWeb.CrdtChannel.remember_drained(&2, "d#{&1}", 10)
        )

      assert MapSet.size(set) <= 10
    end
  end

  # Phoenix.PubSub does NOT dedupe: subscribing twice delivers twice. A room
  # evicted by :DOWN (a crash) is never drained, so without unsubscribing on
  # that path too its subscription survives and the next start_and_observe_room
  # stacks a second one.
  test "a crash-evicted room does not leave its drain subscription behind", ctx do
    %{socket: socket, note: note} = ctx
    {client, _room} = open_room(socket, note)
    topic = CrdtRegistry.drain_topic(note.id)

    # Counting via the Registry backing Phoenix.PubSub is the only way to
    # observe a duplicate subscription (a doubled delivery is indistinguishable
    # from a single one here, since the second drain finds an empty room_doc and
    # no-ops). If PubSub ever stops being Registry-backed this raises rather
    # than quietly passing, which is the acceptable direction for that coupling.
    channel_subs = fn ->
      Engram.PubSub
      |> Registry.lookup(topic)
      |> Enum.count(fn {pid, _} -> pid == socket.channel_pid end)
    end

    assert channel_subs.() == 1

    # Crash-shaped eviction, then re-open: the re-subscribe must not stack.
    room = CrdtRegistry.lookup(note.id)
    send(socket.channel_pid, {:DOWN, make_ref(), :process, room, :crashed})
    push_step1(socket, note, client)

    assert channel_subs.() == 1, "duplicate subscription — every later drain would arrive twice"
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
